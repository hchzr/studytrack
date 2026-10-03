import Foundation
import SwiftData

/// Fusionne les doublons qu'iCloud fait apparaître.
///
/// La synchronisation recopie chaque objet tel quel : elle ne sait pas que le
/// « CS-250 » importé sur l'iPhone et celui importé sur l'iPad sont le même
/// cours. Ni que le calendrier de l'EPFL, installé sur chaque appareil, les
/// groupes relus sur le serveur ou les révisions Anki relevées deux fois sont
/// les mêmes. Ici, chaque famille a sa **clé naturelle** ; deux objets de même
/// clé sont fusionnés.
///
/// Deux règles, parce que deux appareils peuvent fusionner en même temps :
///   • **le gardé est choisi de la même façon partout** (le plus petit
///     identifiant) — sinon chacun garderait le sien et supprimerait l'autre ;
///   • **la fusion ne perd rien** : un exercice fait d'un côté reste fait, une
///     session n'est jamais supprimée (elle change de cours), la correction la
///     plus récente l'emporte.
enum SyncDeduplicator {

    struct Report: Equatable {
        var merged: [String: Int] = [:]
        var total: Int { merged.values.reduce(0, +) }

        mutating func count(_ family: String, _ n: Int = 1) {
            guard n > 0 else { return }
            merged[family, default: 0] += n
        }

        var summary: String {
            merged.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " · ")
        }
    }

    @discardableResult
    static func run(in context: ModelContext) -> Report {
        var report = Report()
        mergeTerms(context, &report)
        mergeCourses(context, &report)
        mergeSessions(context, &report)
        mergeEvents(context, &report)
        mergeTasks(context, &report)
        mergePlanned(context, &report)
        mergeMilestones(context, &report)
        mergeGroups(context, &report)
        if report.total > 0 { try? context.save() }
        return report
    }

    // MARK: Outils

    /// Les groupes de doublons : par clé (`nil` = pas de clé, jamais fusionné),
    /// le gardé en tête (plus petit identifiant).
    static func duplicates<T>(_ items: [T], id: (T) -> UUID, key: (T) -> String?) -> [(keep: T, drop: [T])] {
        var buckets: [String: [T]] = [:]
        for item in items {
            guard let k = key(item), !k.isEmpty else { continue }
            buckets[k, default: []].append(item)
        }
        return buckets.values.compactMap { bucket in
            guard bucket.count > 1 else { return nil }
            let sorted = bucket.sorted { id($0).uuidString < id($1).uuidString }
            return (sorted[0], Array(sorted.dropFirst()))
        }
    }

    private static func fetch<T: PersistentModel>(_ context: ModelContext, _ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return min(x, y)
        default: return a ?? b
        }
    }

    private static func fill(_ a: inout String, _ b: String) {
        if a.isEmpty { a = b }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Semestres et cours

    private static func termKey(_ term: AcademicTerm?) -> String {
        guard let term else { return "" }
        return "\(term.year)-\(term.seasonRaw)"
    }

    private static func mergeTerms(_ context: ModelContext, _ report: inout Report) {
        let all = fetch(context, AcademicTerm.self)
        for (keep, drop) in duplicates(all, id: \.id, key: { termKey($0) }) {
            for loser in drop {
                for course in loser.courses ?? [] { course.term = keep }
                context.delete(loser)
                report.count("semestres")
            }
        }
    }

    private static func mergeCourses(_ context: ModelContext, _ report: inout Report) {
        let all = fetch(context, Course.self)
        for (keep, drop) in duplicates(all, id: \.id, key: { "\(normalized($0.code))|\(termKey($0.term))" }) {
            for loser in drop {
                merge(loser, into: keep, context: context)
                context.delete(loser)
                report.count("cours")
            }
        }
    }

    static func merge(_ b: Course, into a: Course, context: ModelContext) {
        a.isTracked = a.isTracked || b.isTracked
        a.isActive = a.isActive || b.isActive
        fill(&a.moodleURLString, b.moodleURLString)
        fill(&a.lecturer, b.lecturer)
        fill(&a.notes, b.notes)
        fill(&a.documentsRaw, b.documentsRaw)
        fill(&a.weekGuideRaw, b.weekGuideRaw)
        var sources = a.contentSources
        for source in b.contentSources where !sources.contains(source) { sources.append(source) }
        a.contentSources = sources
        if a.term == nil { a.term = b.term }

        // Théorie : même nature, même numéro, même titre.
        func theoryKey(_ item: TheoryItem) -> String { "\(item.kindRaw)|\(item.number)|\(normalized(item.title))" }
        var theory = Dictionary(a.theoryItems.map { (theoryKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        for item in b.theoryItems {
            if let match = theory[theoryKey(item)] {
                match.watchedAt = earliest(match.watchedAt, item.watchedAt)
                match.summarizedAt = earliest(match.summarizedAt, item.summarizedAt)
                if (match.summaryText ?? "").isEmpty { match.summaryText = item.summaryText }
                for session in item.targetedSessions ?? [] { session.theoryItem = match }
                for task in item.targetedTasks ?? [] { task.video = match }
                context.delete(item)
            } else {
                item.course = a
                theory[theoryKey(item)] = item
            }
        }

        // Séries : par numéro (ou titre, sans numéro).
        func seriesKey(_ series: ExerciseSeries) -> String {
            series.seriesNumber > 0 ? "n\(series.seriesNumber)" : "t\(normalized(series.title))"
        }
        var series = Dictionary(a.series.map { (seriesKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        for item in b.series {
            if let match = series[seriesKey(item)] {
                merge(item, into: match, context: context)
                context.delete(item)
            } else {
                item.course = a
                series[seriesKey(item)] = item
            }
        }

        // Le temps n'est jamais perdu : chaque session change de cours.
        for session in b.sessions { session.course = a }
        for task in b.linkedTasks { task.course = a }
        for event in b.linkedEvents { event.course = a }

        func examKey(_ exam: Exam) -> String {
            "\(exam.kindRaw)|\(normalized(exam.title))|\(Calendar.current.startOfDay(for: exam.date).timeIntervalSince1970)"
        }
        let examKeys = Set(a.exams.map(examKey))
        for exam in b.exams {
            if examKeys.contains(examKey(exam)) {
                context.delete(exam)
            } else {
                exam.course = a
            }
        }
        var past = Dictionary(a.pastExams.map { ("\($0.year)|\(normalized($0.title))", $0) }, uniquingKeysWith: { first, _ in first })
        for exam in b.pastExams {
            let key = "\(exam.year)|\(normalized(exam.title))"
            if let match = past[key] {
                match.workedAt = earliest(match.workedAt, exam.workedAt)
                if match.confidenceRaw == nil { match.confidenceRaw = exam.confidenceRaw }
                context.delete(exam)
            } else {
                exam.course = a
                past[key] = exam
            }
        }
    }

    static func merge(_ b: ExerciseSeries, into a: ExerciseSeries, context: ModelContext) {
        fill(&a.urlString, b.urlString)
        fill(&a.solutionURLString, b.solutionURLString)
        fill(&a.topic, b.topic)
        if a.dueDate == nil { a.dueDate = b.dueDate }
        if a.solutionsAt == nil { a.solutionsAt = b.solutionsAt }
        if a.publishedAt == nil { a.publishedAt = b.publishedAt }
        var exercises = Dictionary(a.exercises.map { ($0.exerciseNumber, $0) }, uniquingKeysWith: { first, _ in first })
        for exercise in b.exercises {
            if let match = exercises[exercise.exerciseNumber] {
                merge(exercise, into: match, context: context)
                context.delete(exercise)
            } else {
                exercise.series = a
                exercises[exercise.exerciseNumber] = exercise
            }
        }
    }

    static func merge(_ b: Exercise, into a: Exercise, context: ModelContext) {
        fill(&a.title, b.title)
        fill(&a.statement, b.statement)
        fill(&a.hint, b.hint)
        fill(&a.solution, b.solution)
        fill(&a.statementURLString, b.statementURLString)
        a.doneAt = earliest(a.doneAt, b.doneAt)
        if a.confidenceRaw == nil { a.confidenceRaw = b.confidenceRaw }
        // La correction la plus récente l'emporte, en bloc.
        if let corrected = b.correctedAt, corrected > (a.correctedAt ?? .distantPast) {
            a.correctedAt = corrected
            a.correctnessRaw = b.correctnessRaw
            a.redoRequired = b.redoRequired
            a.correctionNote = b.correctionNote ?? a.correctionNote
            a.score = b.score ?? a.score
            a.maxScore = b.maxScore ?? a.maxScore
        }
        mergeQuestions(b.subQuestions.filter { $0.parent == nil },
                       into: a.subQuestions.filter { $0.parent == nil },
                       exercise: a, parent: nil, context: context)
        for session in b.targetedSessions ?? [] { session.exercise = a }
        for task in b.targetedTasks ?? [] { task.exercise = a }
    }

    private static func mergeQuestions(_ incoming: [SubQuestion], into existing: [SubQuestion],
                                       exercise: Exercise, parent: SubQuestion?, context: ModelContext) {
        var byLabel = Dictionary(existing.map { ("\($0.label)|\($0.sortOrder)", $0) }, uniquingKeysWith: { first, _ in first })
        for question in incoming {
            let key = "\(question.label)|\(question.sortOrder)"
            if let match = byLabel[key] {
                match.isDone = match.isDone || question.isDone
                match.doneAt = earliest(match.doneAt, question.doneAt)
                fill(&match.text, question.text)
                mergeQuestions(question.children, into: match.children, exercise: exercise, parent: match, context: context)
                context.delete(question)
            } else {
                question.exercise = exercise
                question.parent = parent
                for child in question.children { child.exercise = exercise }
                byLabel[key] = question
            }
        }
    }

    // MARK: Ce que chaque appareil produit de son côté

    /// Une révision Anki relevée sur deux appareils : même clé externe.
    private static func mergeSessions(_ context: ModelContext, _ report: inout Report) {
        let all = fetch(context, StudySession.self)
        for (_, drop) in duplicates(all, id: \.id, key: { $0.externalKey.isEmpty ? nil : $0.externalKey }) {
            for loser in drop { context.delete(loser) }
            report.count("sessions", drop.count)
        }
    }

    /// L'horaire lu sur chaque appareil (calendrier de l'iPhone, flux `.ics`).
    private static func mergeEvents(_ context: ModelContext, _ report: inout Report) {
        let all = fetch(context, LinkedCalendarEvent.self)
        let groups = duplicates(all, id: \.id) { event -> String? in
            let span = "\(Int(event.startsAt.timeIntervalSince1970))|\(Int(event.endsAt.timeIntervalSince1970))"
            return "\(normalized(event.title))|\(span)"
        }
        for (keep, drop) in groups {
            for loser in drop {
                keep.isAttended = keep.isAttended || loser.isAttended
                keep.isSkipped = keep.isSkipped || loser.isSkipped
                if loser.kindIsManual && !keep.kindIsManual {
                    keep.kindRaw = loser.kindRaw
                    keep.kindIsManual = true
                }
                if keep.course == nil { keep.course = loser.course }
                fill(&keep.notes, loser.notes)
                context.delete(loser)
            }
            report.count("séances", drop.count)
        }
    }

    private static func mergeTasks(_ context: ModelContext, _ report: inout Report) {
        let all = fetch(context, LinkedTask.self)
        for (keep, drop) in duplicates(all, id: \.id, key: { task in task.externalID.map { "\(task.providerRaw)|\($0)" } }) {
            for loser in drop {
                keep.isDone = keep.isDone || loser.isDone
                context.delete(loser)
            }
            report.count("tâches", drop.count)
        }
    }

    private static func mergePlanned(_ context: ModelContext, _ report: inout Report) {
        let all = fetch(context, PlannedSession.self)
        let groups = duplicates(all, id: \.id) { "\($0.groupRemoteID ?? "")|\(normalized($0.title))|\(Int($0.startsAt.timeIntervalSince1970))" }
        for (_, drop) in groups {
            for loser in drop { context.delete(loser) }
            report.count("sessions prévues", drop.count)
        }
    }

    /// Le calendrier académique, installé sur chaque appareil.
    private static func mergeMilestones(_ context: ModelContext, _ report: inout Report) {
        let all = fetch(context, AcademicMilestone.self)
        for (_, drop) in duplicates(all, id: \.id, key: { $0.externalID.isEmpty ? nil : $0.externalID }) {
            for loser in drop { context.delete(loser) }
            report.count("échéances", drop.count)
        }
    }

    /// Les groupes relus sur le serveur par chaque appareil.
    private static func mergeGroups(_ context: ModelContext, _ report: inout Report) {
        let all = fetch(context, StudyGroup.self)
        for (keep, drop) in duplicates(all, id: \.id, key: { $0.remoteID }) {
            for loser in drop {
                keep.isAdmin = keep.isAdmin || loser.isAdmin
                for member in loser.members { member.group = keep }
                for completion in loser.completions { completion.group = keep }
                for completion in loser.itemCompletions { completion.group = keep }
                context.delete(loser)
            }
            report.count("groupes", drop.count)
        }
        // Dans chaque groupe : un membre par personne, une coche par élément.
        for group in fetch(context, StudyGroup.self) {
            for (keep, drop) in duplicates(group.members, id: \.id, key: { $0.userID }) {
                for loser in drop {
                    keep.isMe = keep.isMe || loser.isMe
                    keep.totalSeconds = max(keep.totalSeconds, loser.totalSeconds)
                    keep.weeklySeconds = max(keep.weeklySeconds, loser.weeklySeconds)
                    context.delete(loser)
                }
                report.count("membres", drop.count)
            }
            for (_, drop) in duplicates(group.completions, id: \.id, key: { "\($0.userID)|\($0.courseCode)|\($0.seriesNumber)" }) {
                for loser in drop { context.delete(loser) }
                report.count("coches", drop.count)
            }
            for (_, drop) in duplicates(group.itemCompletions, id: \.id,
                                        key: { "\($0.userID)|\($0.courseCode)|\($0.kindRaw)|\($0.itemNumber)" }) {
                for loser in drop { context.delete(loser) }
                report.count("coches", drop.count)
            }
        }
    }
}
