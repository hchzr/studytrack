import Foundation
import SwiftData
import Observation

/// L'accueil automatique : une connexion EPFL, et l'app fait le reste.
///
/// Une fois Moodle connecté :
///   1. les cours du semestre en cours sont lus dans les inscriptions Moodle et
///      créés (ou retrouvés, s'ils existent déjà) — reliés à leur page Moodle ;
///   2. Courseware, MediaSpace et Explique sont connectés en silence, s'ils le
///      peuvent (`SiteAutoLogin`) — ils servent à la chaîne d'import ;
///   3. chaque cours est importé : théorie, séries, échéances, consignes de la
///      semaine — sans relecture ; tout reste modifiable ensuite ;
///   4. les énoncés des séries se lisent en arrière-plan.
///
/// Pendant ce temps, l'écran montre **ce qui se passe vraiment** : l'avancement
/// pondéré et le temps restant (`ImportProgress`), et la grille du semestre qui
/// se remplit (`SemesterGridRow`) — semaine par semaine, cours par cours.
@MainActor
@Observable
final class OnboardingAutoSetup {

    enum Phase: Equatable {
        case idle
        case working
        case done
        case failed(String)
    }

    /// Ce que l'import a trouvé, pour les cartes de présentation et la fin.
    struct Highlight: Equatable {
        var code: String
        var name: String
        var colorHex: String
        var week: Int
        var theory: Int
        var series: Int
        var videos: Int
    }

    private(set) var phase: Phase = .idle
    private(set) var headline = "Connexion à Moodle…"
    private(set) var progress = ImportProgress()
    private(set) var grid: [SemesterGridRow] = []
    private(set) var weeks = 14
    /// Le cours en cours d'import (son identifiant de ligne).
    private(set) var currentID: String?
    /// La semaine en cours de chaque cours importé : de quoi illustrer les cartes
    /// avec **ses** cours plutôt qu'un exemple.
    private(set) var highlights: [Highlight] = []
    private(set) var totals = (courses: 0, series: 0, theory: 0, deadlines: 0)
    /// Les autres sites connectés en passant (« Courseware, MediaSpace »).
    private(set) var extraSites: [String] = []

    var isWorking: Bool { phase == .working }

    func currentLine(at now: Date) -> (code: String, step: String)? {
        guard let id = currentID, let row = grid.first(where: { $0.id == id }),
              let course = progress.courses.first(where: { $0.id == id }) else { return nil }
        if course.stage == .activities, course.total > 0 {
            return (row.code, "activités \(course.done) / \(course.total)")
        }
        return (row.code, course.stage.label)
    }

    func run(context: ModelContext, settings: SettingsStore, term: AcademicTerm) async {
        guard !isWorking else { return }
        phase = .working
        headline = "Connexion à Moodle…"
        let client = MoodleClient()
        guard await client.ensureSignedIn() else {
            phase = .failed("Moodle ne te reconnaît pas encore. Réessaie la connexion, ou continue sans Moodle.")
            return
        }
        ConnectionCenter.shared.report(.moodle, .connected)

        // Les autres sites pendant que Moodle travaille : ils ne partagent que
        // les cookies EPFL, pas le navigateur.
        let others = Task { @MainActor in await SiteAutoLogin.connectAll() }

        headline = "Lecture de tes cours…"
        var refs = (try? await client.enrolled(classification: "inprogress")) ?? []
        if MoodleOnboarding.courses(from: refs).isEmpty {
            // Hors semestre (ou cours mal datés sur Moodle) : tous les cours.
            refs = (try? await client.enrolled()) ?? []
        }
        let planned = MoodleOnboarding.courses(from: refs)
        guard !planned.isEmpty else {
            phase = .failed("Aucun cours EPFL trouvé dans tes inscriptions Moodle. Ajoute-les depuis ton horaire ou à la main.")
            return
        }

        // 1. Les cours, créés ou retrouvés.
        let existing = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let palette = Theme.coursePalette
        var targets: [(Course, MoodleCourseRef)] = []
        for (index, plan) in planned.enumerated() {
            let course: Course
            if let known = existing.first(where: { MoodleCourseMatcher.baseCode($0.code) == plan.code }) {
                course = known
            } else {
                course = Course(code: plan.code, name: plan.name,
                                colorHex: palette[(existing.count + index) % palette.count],
                                term: term,
                                sectionCode: settings.sectionCode)
                context.insert(course)
            }
            if course.term == nil { course.term = term }
            course.isTracked = true
            // Relié à **sa** page Moodle : la mise à jour automatique et les
            // imports suivants n'ont plus à chercher la bonne section.
            if !course.contentSources.contains(plan.ref.url.absoluteString) {
                course.contentSources = course.contentSources + [plan.ref.url.absoluteString]
            }
            targets.append((course, plan.ref))
        }
        try? context.save()

        weeks = max(term.totalWeeks, 1)
        grid = targets.map { course, _ in
            SemesterGridRow(id: course.id.uuidString, code: course.displayCode, colorHex: course.colorHex, weeks: weeks)
        }
        progress.reset(courseIDs: grid.map(\.id), now: Date())
        totals.courses = targets.count
        headline = "Ton semestre se construit"

        // 2. Le contenu, cours par cours.
        var imported: [Course] = []
        for (course, ref) in targets {
            let id = course.id.uuidString
            currentID = id
            progress.enter(.outline, course: id, now: Date())
            do {
                let snapshot = try await client.snapshot(of: ref, onOutline: { [weak self] numbers in
                    self?.updateRow(id) { $0.outline(sectionNumbers: numbers) }
                }, onActivities: { [weak self] done, total in
                    self?.progress.activities(done: done, total: total, course: id, now: Date())
                })
                progress.enter(.sources, course: id, now: Date())
                let outcome = await CourseImportPipeline.draft(from: snapshot,
                                                               termStart: course.term?.startDate ?? term.startDate,
                                                               totalWeeks: course.term?.totalWeeks ?? term.totalWeeks,
                                                               settings: settings) { [weak self] message in
                    guard let stage = ImportProgress.stage(forMessage: message) else { return }
                    self?.progress.enter(stage, course: id, now: Date())
                }
                progress.enter(.writing, course: id, now: Date())
                let draft = outcome.draft
                if !draft.isEmpty {
                    ContentDraftWriter.apply(draft, to: course, context: context)
                    try? context.save()
                    imported.append(course)
                    updateRow(id) { $0.fill(with: draft) }
                    record(draft, for: course)
                }
                progress.enter(.done, course: id, now: Date())
            } catch {
                progress.fail(course: id, now: Date())
            }
        }
        currentID = nil

        // 3. Les énoncés, en arrière-plan ; la mise à jour automatique prend le relais.
        if !imported.isEmpty {
            SeriesAutoReading.start(courses: imported, context: context, settings: settings)
        }
        settings.contentLastRefresh = Date()

        extraSites = await others.value.filter(\.value).map(\.key.label).sorted()
        headline = "C'est prêt"
        phase = .done
    }

    private func updateRow(_ id: String, _ change: (inout SemesterGridRow) -> Void) {
        guard let index = grid.firstIndex(where: { $0.id == id }) else { return }
        change(&grid[index])
    }

    /// Retient la semaine en cours du cours importé, et les totaux.
    private func record(_ draft: ContentDraft, for course: Course) {
        totals.series += draft.seriesCount
        totals.theory += draft.theoryCount
        totals.deadlines += draft.deadlineCount
        let week = min(max(course.currentWeek, 1), weeks)
        var theory = 0, series = 0, videos = 0
        for section in draft.sections where section.isIncluded {
            for item in section.items where item.plannedWeek(in: section) == week {
                switch item.kind {
                case .theory: theory += 1; videos += item.videoCount
                case .series: series += 1
                default: break
                }
            }
        }
        highlights.append(Highlight(code: course.displayCode, name: course.name, colorHex: course.colorHex,
                                    week: week, theory: theory, series: series, videos: videos))
    }

    #if DEBUG
    /// Un import simulé (quatre cours, ~25 s), pour voir l'accueil sans Moodle.
    func runDemo(fast: Bool = false) async {
        phase = .working
        headline = "Ton semestre se construit"
        let courses = [("MATH-101", "Analyse I", "#0891B2", 34), ("MATH-111", "Algèbre linéaire", "#4F46E5", 55),
                       ("CS-107", "Introduction à la programmation", "#059669", 24), ("PHYS-101", "Physique générale", "#D97706", 18)]
        weeks = 14
        grid = courses.map { SemesterGridRow(id: $0.0, code: $0.0, colorHex: $0.2, weeks: 14) }
        progress.reset(courseIDs: courses.map(\.0), now: Date())
        totals.courses = courses.count
        let pace = fast ? 0.05 : 1.0
        for (code, name, color, activities) in courses {
            currentID = code
            progress.enter(.outline, course: code, now: Date())
            try? await Task.sleep(for: .seconds(1.2 * pace))
            updateRow(code) { $0.outline(sectionNumbers: Array(1...14)) }
            for done in stride(from: 0, through: activities, by: 18) {
                progress.activities(done: min(done, activities), total: activities, course: code, now: Date())
                try? await Task.sleep(for: .seconds(1.4 * pace))
            }
            progress.activities(done: activities, total: activities, course: code, now: Date())
            progress.enter(.sources, course: code, now: Date())
            try? await Task.sleep(for: .seconds(1.5 * pace))
            progress.enter(.analysis, course: code, now: Date())
            try? await Task.sleep(for: .seconds(2.5 * pace))
            progress.enter(.writing, course: code, now: Date())
            var draft = ContentDraft(source: .moodle, courseTitle: name, url: "", sections: [])
            draft.sections = (1...14).map { week in
                var items = [ContentDraftItem(kind: .theory, number: "\(week).1", title: "", url: "", videoCount: 2,
                                              seriesNumber: nil, theoryKind: .video)]
                if week % 7 != 0 {
                    items.append(ContentDraftItem(kind: .series, number: "\(week)", title: "", url: "", videoCount: 0,
                                                  seriesNumber: week, theoryKind: .reading))
                }
                if week == 8 {
                    items.append(ContentDraftItem(kind: .deadline, number: "", title: "", url: "", videoCount: 0,
                                                  seriesNumber: nil, theoryKind: .reading))
                }
                return ContentDraftSection(title: "Semaine \(week)", week: week, weekIsInferred: false, isIncluded: true, items: items)
            }
            updateRow(code) { $0.fill(with: draft) }
            totals.series += draft.seriesCount
            totals.theory += draft.theoryCount
            highlights.append(Highlight(code: code, name: name, colorHex: color, week: 4, theory: 1, series: 1, videos: 2))
            progress.enter(.done, course: code, now: Date())
        }
        currentID = nil
        extraSites = ["Courseware", "MediaSpace"]
        headline = "C'est prêt"
        phase = .done
    }
    #endif
}
