import Foundation
import SwiftData
import Observation
import ActivityKit
import UIKit
import UserNotifications

/// L'accueil automatique : une connexion EPFL, et l'app fait le reste.
///
/// Une fois Moodle connecté :
///   1. les cours du semestre en cours sont lus dans les inscriptions Moodle et
///      créés (ou retrouvés) — reliés à leur page Moodle ;
///   2. Courseware, MediaSpace et Explique sont connectés en silence, s'ils le
///      peuvent (`SiteAutoLogin`) ;
///   3. chaque cours est importé : théorie, séries, échéances, consignes ;
///   4. les énoncés des séries se lisent en arrière-plan.
///
/// **Détenu par `AppContainer`, pas par l'écran** : l'import continue quand on
/// quitte l'accueil, quand l'app passe en arrière-plan (tant qu'iOS le permet),
/// et reprend tout seul au retour si iOS l'a suspendu. Une Live Activity montre
/// l'avancement dans l'îlot et sur l'écran verrouillé.
///
/// L'écran, lui, écoute : l'avancement pondéré (`ImportProgress`), la grille du
/// semestre (`SemesterGridRow`), et chaque élément trouvé (`onDrop`) — que la
/// scène physique fait tomber dans le semestre.
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

    /// Un cours à trier (garder ou ignorer, choisir sa couleur).
    struct CourseCard: Identifiable, Equatable {
        let id: String
        var code: String
        var name: String
        var colorHex: String
        var decided = false
        var kept = true
    }

    /// Un élément trouvé, que la scène fait tomber.
    struct Drop: Equatable {
        enum Kind: String { case page, video, theory, series, deadline }
        var kind: Kind
        var colorHex: String
        var courseID: String
        var week: Int?
    }

    private(set) var phase: Phase = .idle
    private(set) var headline = "Connexion à Moodle…"
    private(set) var progress = ImportProgress()
    private(set) var grid: [SemesterGridRow] = []
    private(set) var weeks = 14
    private(set) var currentID: String?
    private(set) var highlights: [Highlight] = []
    private(set) var totals = (courses: 0, series: 0, theory: 0, deadlines: 0)
    private(set) var extraSites: [String] = []
    private(set) var cards: [CourseCard] = []
    /// Vrai quand iOS a suspendu l'import (app en arrière-plan trop longtemps).
    private(set) var isPaused = false

    /// Chaque élément trouvé, au moment où il l'est (la scène physique).
    @ObservationIgnored var onDrop: ((Drop) -> Void)?
    /// Un cours fini : ses éléments rejoignent la grille.
    @ObservationIgnored var onCourseFinished: ((String) -> Void)?

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var coursesByID: [String: Course] = [:]
    @ObservationIgnored private var skipped: Set<String> = []
    @ObservationIgnored private var activity: Activity<ImportActivityAttributes>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var isWorking: Bool { phase == .working }

    func currentLine(at now: Date) -> (code: String, step: String)? {
        guard let id = currentID, let row = grid.first(where: { $0.id == id }),
              let course = progress.courses.first(where: { $0.id == id }) else { return nil }
        if isPaused { return (row.code, "en pause") }
        if course.stage == .activities, course.total > 0 {
            return (row.code, "activités \(course.done) / \(course.total)")
        }
        return (row.code, course.stage.label)
    }

    // MARK: Tri des cours

    /// Garder un cours (glissé à droite).
    func keep(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].decided = true
        cards[index].kept = true
        skipped.remove(id)
        coursesByID[id]?.isTracked = true
        try? context?.save()
    }

    /// Ignorer un cours (glissé à gauche) : il n'est pas importé s'il ne l'est
    /// pas encore, et ne sera pas suivi.
    func skip(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].decided = true
        cards[index].kept = false
        skipped.insert(id)
        coursesByID[id]?.isTracked = false
        try? context?.save()
        withAnimationIfNeeded { self.grid.removeAll { $0.id == id } }
    }

    func setColor(_ hex: String, for id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].colorHex = hex
        coursesByID[id]?.colorHex = hex
        if let row = grid.firstIndex(where: { $0.id == id }) { grid[row].colorHex = hex }
        try? context?.save()
    }

    private func withAnimationIfNeeded(_ change: () -> Void) { change() }

    // MARK: Import

    func run(context: ModelContext, settings: SettingsStore, term: AcademicTerm) async {
        guard !isWorking else { return }
        self.context = context
        phase = .working
        isPaused = false
        headline = "Connexion à Moodle…"
        observeLifecycle()
        let client = MoodleClient()
        guard await client.ensureSignedIn() else {
            phase = .failed("Moodle ne te reconnaît pas encore. Réessaie la connexion, ou continue sans Moodle.")
            return
        }
        ConnectionCenter.shared.report(.moodle, .connected)
        let others = Task { @MainActor in await SiteAutoLogin.connectAll() }

        headline = "Lecture de tes cours…"
        var refs = (try? await client.enrolled(classification: "inprogress")) ?? []
        if MoodleOnboarding.courses(from: refs).isEmpty {
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
                                term: term, sectionCode: settings.sectionCode)
                context.insert(course)
            }
            if course.term == nil { course.term = term }
            course.isTracked = true
            if !course.contentSources.contains(plan.ref.url.absoluteString) {
                course.contentSources = course.contentSources + [plan.ref.url.absoluteString]
            }
            targets.append((course, plan.ref))
            coursesByID[course.id.uuidString] = course
        }
        try? context.save()

        weeks = max(term.totalWeeks, 1)
        grid = targets.map { course, _ in
            SemesterGridRow(id: course.id.uuidString, code: course.displayCode, colorHex: course.colorHex, weeks: weeks)
        }
        cards = targets.map { course, _ in
            CourseCard(id: course.id.uuidString, code: course.displayCode, name: course.name, colorHex: course.colorHex)
        }
        progress.reset(courseIDs: grid.map(\.id), now: Date())
        totals.courses = targets.count
        headline = "Ton semestre se construit"
        startActivity()

        // 2. Le contenu, cours par cours.
        var imported: [Course] = []
        for (course, ref) in targets {
            let id = course.id.uuidString
            if skipped.contains(id) {
                progress.fail(course: id, now: Date())
                continue
            }
            currentID = id
            await waitIfSuspended()
            var attempt = 0
            while true {
                attempt += 1
                let wasInBackground = UIApplication.shared.applicationState != .active
                do {
                    try await importCourse(course, ref: ref, client: client, settings: settings,
                                           term: term, context: context, imported: &imported)
                    break
                } catch {
                    // Échec pendant qu'iOS suspendait l'app : on réessaie au
                    // retour, plutôt que de perdre le cours.
                    let suspended = wasInBackground || UIApplication.shared.applicationState != .active || isPaused
                    if suspended, attempt < 3 {
                        await waitIfSuspended(force: true)
                        continue
                    }
                    progress.fail(course: id, now: Date())
                    break
                }
            }
            onCourseFinished?(id)
            updateActivity()
        }
        currentID = nil
        totals.courses = targets.count - skipped.count

        if !imported.isEmpty {
            SeriesAutoReading.start(courses: imported, context: context, settings: settings)
        }
        settings.contentLastRefresh = Date()
        extraSites = await others.value.filter(\.value).map(\.key.label).sorted()
        headline = "C'est prêt"
        phase = .done
        finishActivity()
        notifyIfBackground()
        endBackgroundTask()
    }

    /// Un cours : sa page Moodle, ses activités, ses sources, le rangement.
    private func importCourse(_ course: Course, ref: MoodleCourseRef, client: MoodleClient,
                              settings: SettingsStore, term: AcademicTerm, context: ModelContext,
                              imported: inout [Course]) async throws {
        let id = course.id.uuidString
        beginBackgroundTask()
        progress.enter(.outline, course: id, now: Date())
        var lastDone = 0
        let snapshot = try await client.snapshot(of: ref, onOutline: { [weak self] numbers in
            self?.updateRow(id) { $0.outline(sectionNumbers: numbers) }
        }, onActivities: { [weak self] done, total in
            guard let self else { return }
            self.progress.activities(done: done, total: total, course: id, now: Date())
            // Une page lue = un caillou qui tombe.
            for _ in 0..<max(0, min(done - lastDone, 18)) {
                self.onDrop?(Drop(kind: .page, colorHex: self.color(of: id), courseID: id, week: nil))
            }
            lastDone = done
            self.updateActivity()
        })
        progress.enter(.sources, course: id, now: Date())
        updateActivity()
        let outcome = await CourseImportPipeline.draft(from: snapshot,
                                                       termStart: course.term?.startDate ?? term.startDate,
                                                       totalWeeks: course.term?.totalWeeks ?? term.totalWeeks,
                                                       settings: settings) { [weak self] message in
            guard let stage = ImportProgress.stage(forMessage: message) else { return }
            self?.progress.enter(stage, course: id, now: Date())
            self?.updateActivity()
        }
        progress.enter(.writing, course: id, now: Date())
        let draft = outcome.draft
        if !draft.isEmpty, !skipped.contains(id) {
            ContentDraftWriter.apply(draft, to: course, context: context)
            try? context.save()
            imported.append(course)
            updateRow(id) { $0.fill(with: draft) }
            record(draft, for: course)
            dropItems(of: draft, course: id)
        }
        progress.enter(.done, course: id, now: Date())
    }

    private func color(of id: String) -> String { grid.first { $0.id == id }?.colorHex ?? "#6B655A" }

    /// Les éléments rangés d'un cours tombent dans la scène, un à un.
    private func dropItems(of draft: ContentDraft, course id: String) {
        let hex = color(of: id)
        var drops: [Drop] = []
        for section in draft.sections where section.isIncluded {
            for item in section.items {
                let kind: Drop.Kind
                switch item.kind {
                case .theory: kind = item.videoCount > 0 ? .video : .theory
                case .series: kind = .series
                case .deadline: kind = .deadline
                default: continue
                }
                drops.append(Drop(kind: kind, colorHex: hex, courseID: id, week: item.plannedWeek(in: section)))
            }
        }
        for drop in drops.prefix(40) { onDrop?(drop) }
    }

    private func updateRow(_ id: String, _ change: (inout SemesterGridRow) -> Void) {
        guard let index = grid.firstIndex(where: { $0.id == id }) else { return }
        change(&grid[index])
    }

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

    // MARK: Arrière-plan

    /// Suit l'app : au retour au premier plan, l'import suspendu reprend.
    private func observeLifecycle() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeIfPaused() }
        })
    }

    private func resumeIfPaused() {
        guard isPaused || !resumeWaiters.isEmpty else { return }
        isPaused = false
        let waiters = resumeWaiters
        resumeWaiters = []
        waiters.forEach { $0.resume() }
        updateActivity()
    }

    /// Attend le retour au premier plan si iOS a suspendu l'import, ou s'il ne
    /// reste plus assez de temps d'arrière-plan pour lire un cours.
    private func waitIfSuspended(force: Bool = false) async {
        let app = UIApplication.shared
        if app.applicationState == .active {
            isPaused = false
            return
        }
        let lowTime = app.backgroundTimeRemaining < 25
        guard isPaused || force || lowTime else { return }
        isPaused = true
        updateActivity()
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    /// Demande à iOS le temps de finir le cours en cours (une trentaine de
    /// secondes après la fermeture). À expiration : pause, dite partout.
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Import du semestre") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPaused = true
                self.updateActivity()
                self.notifyPaused()
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Live Activity

    private func activityState() -> ImportActivityAttributes.ContentState {
        let now = Date()
        let line = currentLine(at: now)
        let remaining = progress.remainingSeconds(at: now)
        return .init(fraction: phase == .done ? 1 : progress.fraction(at: now),
                     courseCode: line?.code ?? "",
                     step: line?.step ?? "",
                     coursesDone: progress.courses.filter { $0.stage == .done }.count,
                     coursesTotal: progress.courses.count,
                     estimatedEnd: remaining.map { now.addingTimeInterval($0) },
                     phase: phase == .done ? .done : (isPaused ? .paused : .running))
    }

    private func startActivity() {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        let attributes = ImportActivityAttributes(colors: grid.map(\.colorHex))
        activity = try? Activity.request(attributes: attributes,
                                         content: .init(state: activityState(), staleDate: nil),
                                         pushType: nil)
        // L'anneau suit le temps : une mise à jour par seconde suffit.
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.phase == .working else { return }
                self.updateActivity()
            }
        }
    }

    private func updateActivity() {
        guard let activity else { return }
        let state = activityState()
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func finishActivity() {
        ticker?.cancel()
        guard let activity else { return }
        let state = activityState()
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60 * 10))) }
        self.activity = nil
    }

    // MARK: Notifications

    private func notifyIfBackground() {
        guard UIApplication.shared.applicationState != .active else { return }
        post("Ton semestre est prêt",
             "\(totals.courses) cours, \(totals.series) séries et \(totals.theory) éléments de théorie rangés semaine par semaine.")
    }

    private func notifyPaused() {
        post("Import en pause", "iOS a mis StudyTrack en pause. Rouvre l'app : l'import reprend là où il s'est arrêté.")
    }

    private func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "onboarding-import-\(title.hashValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    #if DEBUG
    /// Un import simulé (quatre cours), pour voir l'accueil sans Moodle.
    func runDemo(fast: Bool = false) async {
        phase = .working
        headline = "Ton semestre se construit"
        let courses = [("MATH-101", "Analyse I", "#0891B2", 34), ("MATH-111", "Algèbre linéaire", "#4F46E5", 55),
                       ("CS-107", "Introduction à la programmation", "#059669", 24), ("PHYS-101", "Physique générale", "#D97706", 18)]
        weeks = 14
        grid = courses.map { SemesterGridRow(id: $0.0, code: $0.0, colorHex: $0.2, weeks: 14) }
        cards = courses.map { CourseCard(id: $0.0, code: $0.0, name: $0.1, colorHex: $0.2) }
        progress.reset(courseIDs: courses.map(\.0), now: Date())
        totals.courses = courses.count
        startActivity()
        let pace = fast ? 0.05 : 1.0
        for (code, name, color, activities) in courses {
            if skipped.contains(code) { progress.fail(course: code, now: Date()); continue }
            currentID = code
            progress.enter(.outline, course: code, now: Date())
            try? await Task.sleep(for: .seconds(1.2 * pace))
            updateRow(code) { $0.outline(sectionNumbers: Array(1...14)) }
            var last = 0
            for done in stride(from: 0, through: activities, by: 18) {
                progress.activities(done: min(done, activities), total: activities, course: code, now: Date())
                for _ in 0..<(done - last) { onDrop?(Drop(kind: .page, colorHex: color, courseID: code, week: nil)) }
                last = done
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
                var items = [ContentDraftItem(kind: .theory, number: "\(week).1", title: "Chapitre \(week) — vidéos", url: "",
                                              videoCount: 2, seriesNumber: nil, theoryKind: .video)]
                if week % 7 != 0 {
                    items.append(ContentDraftItem(kind: .series, number: "\(week)", title: "Série \(week)", url: "",
                                                  videoCount: 0, seriesNumber: week, theoryKind: .reading))
                }
                if week == 8 {
                    items.append(ContentDraftItem(kind: .deadline, number: "", title: "Midterm", url: "", videoCount: 0,
                                                  seriesNumber: nil, theoryKind: .reading))
                }
                return ContentDraftSection(title: "Semaine \(week)", week: week, weekIsInferred: false, isIncluded: true, items: items)
            }
            updateRow(code) { $0.fill(with: draft) }
            totals.series += draft.seriesCount
            totals.theory += draft.theoryCount
            highlights.append(Highlight(code: code, name: name, colorHex: color, week: 4, theory: 1, series: 1, videos: 2))
            dropItems(of: draft, course: code)
            progress.enter(.done, course: code, now: Date())
            onCourseFinished?(code)
            updateActivity()
        }
        currentID = nil
        extraSites = ["Courseware", "MediaSpace"]
        headline = "C'est prêt"
        phase = .done
        finishActivity()
    }
    #endif
}
