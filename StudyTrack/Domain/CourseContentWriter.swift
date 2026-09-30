import Foundation
import SwiftData

/// Ce qu'un import a changé, pour le dire en une phrase.
struct ContentImportResult: Equatable {
    var theoryAdded = 0
    var theoryUpdated = 0
    var seriesAdded = 0
    var seriesUpdated = 0
    var exercisesAdded = 0

    var isEmpty: Bool { theoryAdded + theoryUpdated + seriesAdded + seriesUpdated == 0 }

    var message: String {
        var parts: [String] = []
        if theoryAdded > 0 { parts.append("\(theoryAdded) élément\(theoryAdded > 1 ? "s" : "") de théorie") }
        if seriesAdded > 0 { parts.append("\(seriesAdded) série\(seriesAdded > 1 ? "s" : "")") }
        if exercisesAdded > 0 { parts.append("\(exercisesAdded) exercice\(exercisesAdded > 1 ? "s" : "")") }
        let updated = theoryUpdated + seriesUpdated
        if parts.isEmpty {
            return updated > 0 ? "Déjà à jour · \(updated) élément\(updated > 1 ? "s" : "") rafraîchi\(updated > 1 ? "s" : "")." : "Rien de nouveau."
        }
        return "Ajouté : " + parts.joined(separator: " et ") + (updated > 0 ? " · \(updated) mis à jour." : ".")
    }
}

/// Écrit un brouillon relu dans un cours.
///
/// **Ne supprime jamais rien** : réimporter Moodle en semaine 8 doit ajouter la
/// série 8, pas effacer l'avancement des sept premières. Un élément déjà présent
/// — même adresse, ou même numéro — est mis à jour (titre, semaine, vidéos) et
/// garde ce qui a été coché.
enum ContentDraftWriter {

    /// Le thème, le corrigé et les exercices d'une série, quand la source les
    /// donne. Les exercices passent par `SeriesDraftWriter` en mode fusion :
    /// l'avancement (questions cochées, correction) est gardé par numéro.
    @discardableResult
    private static func writeDetails(of item: ContentDraftItem, into series: ExerciseSeries,
                                     course: Course, context: ModelContext) -> Int {
        let topic = item.title.trimmingCharacters(in: .whitespaces)
        if !topic.isEmpty, topic != "Série \(series.seriesNumber)",
           ContentDraftBuilder.seriesNumber(in: topic) == nil || topic.count > 12 {
            series.topic = topic
        }
        if let date = item.solutionsAt { series.solutionsAt = date }
        if !item.solutionURL.isEmpty { series.solutionURLString = item.solutionURL }
        guard !item.exercises.isEmpty else { return 0 }
        let before = series.exercises.count
        let draft = SeriesDraft(existingID: series.id, number: series.seriesNumber, title: "",
                                plannedWeek: series.plannedWeek,
                                exercises: item.exercises.map { spec in
                                    var exercise = ExerciseDraft(minor: spec.number.split(separator: ".").last.map(String.init) ?? spec.number,
                                                                 title: spec.title, isBonus: spec.isBonus,
                                                                 subQuestions: spec.questions)
                                    exercise.statement = spec.statement
                                    return exercise
                                })
        SeriesDraftWriter.write(draft, to: course, mode: .importMerge, context: context)
        for spec in item.exercises {
            guard let exercise = series.exercises.first(where: { $0.exerciseNumber == spec.number }) else { continue }
            if !spec.hint.isEmpty { exercise.hint = spec.hint }
            if !spec.solution.isEmpty { exercise.solution = spec.solution }
            if !spec.url.isEmpty { exercise.statementURLString = spec.url }
        }
        return max(0, series.exercises.count - before)
    }

    /// - Parameter updateWeeks: réécrire la semaine des éléments déjà là. Vrai
    ///   pour un import **relu** (la relecture fait foi) ; faux pour une mise à
    ///   jour automatique, qui ne doit jamais défaire une semaine corrigée à la
    ///   main.
    @discardableResult
    static func apply(_ draft: ContentDraft, to course: Course, context: ModelContext,
                      updateWeeks: Bool = true) -> ContentImportResult {
        var result = ContentImportResult()
        var nextSort = (course.theoryItems.map(\.sortOrder).max() ?? -1) + 1

        // Ce qui a été écarté à une relecture reste écarté : une relecture le
        // décide (et peut le reprendre), une mise à jour automatique jamais.
        var ignored = course.contentIgnored
        if updateWeeks {
            for section in draft.sections {
                for item in section.items where !item.url.isEmpty {
                    if section.isIncluded && item.kind != .ignore {
                        ignored.remove(item.url)
                    } else {
                        ignored.insert(item.url)
                    }
                }
            }
            if ignored != course.contentIgnored { course.contentIgnored = ignored }
        }

        for (sectionIndex, section) in draft.sections.enumerated() where section.isIncluded {
            let chapter = ContentDraftBuilder.leadingNumber(in: section.title).flatMap { Int($0.number) }
            for item in section.items {
                if !updateWeeks, !item.url.isEmpty, ignored.contains(item.url) { continue }
                switch item.kind {
                case .ignore:
                    continue
                case .theory:
                    let existing = course.theoryItems.first { existing in
                        (!item.url.isEmpty && existing.urlString == item.url) || existing.number == item.number
                    }
                    let sectionNumber = Int(item.number.split(separator: ".").first ?? "") ?? chapter ?? (sectionIndex + 1)
                    if let existing {
                        existing.title = item.title
                        if updateWeeks || existing.plannedWeek == 0 { existing.plannedWeek = item.plannedWeek(in: section) }
                        existing.videoCount = item.videoCount
                        existing.sectionTitle = section.title
                        existing.kind = item.theoryKind
                        if existing.urlString.isEmpty { existing.urlString = item.url }
                        existing.sourceRaw = draft.source.rawValue
                        result.theoryUpdated += 1
                    } else {
                        let theory = TheoryItem(course: course,
                                                sectionNumber: sectionNumber,
                                                number: item.number,
                                                title: item.title,
                                                kind: item.theoryKind,
                                                plannedWeek: item.plannedWeek(in: section),
                                                sortOrder: nextSort,
                                                urlString: item.url)
                        theory.videoCount = item.videoCount
                        theory.sectionTitle = section.title
                        theory.sourceRaw = draft.source.rawValue
                        context.insert(theory)
                        nextSort += 1
                        result.theoryAdded += 1
                    }
                case .series:
                    guard let number = item.seriesNumber ?? Int(item.number) else { continue }
                    let series: ExerciseSeries
                    if let existing = course.series.first(where: { $0.seriesNumber == number }) {
                        if updateWeeks || existing.plannedWeek == 0 { existing.plannedWeek = item.plannedWeek(in: section) }
                        if existing.urlString.isEmpty { existing.urlString = item.pdfURL.isEmpty ? item.url : item.pdfURL }
                        series = existing
                        result.seriesUpdated += 1
                    } else {
                        series = ExerciseSeries(course: course,
                                                seriesNumber: number,
                                                plannedWeek: item.plannedWeek(in: section),
                                                urlString: item.pdfURL.isEmpty ? item.url : item.pdfURL)
                        context.insert(series)
                        result.seriesAdded += 1
                    }
                    result.exercisesAdded += writeDetails(of: item, into: series, course: course, context: context)
                }
            }
        }

        var sources = course.contentSources
        if !draft.url.isEmpty, !sources.contains(draft.url) {
            sources.append(draft.url)
            course.contentSources = sources
        }
        return result
    }
}
