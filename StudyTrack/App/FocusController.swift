import Foundation
import CoreData
import SwiftData
import Observation

/// Le chrono de l'app, **un seul**, partagé par tous ceux qui le montrent.
///
/// Avant, trois endroits tenaient chacun leur copie : l'écran Focus (ses propres
/// `startDate` et `accumulated`), le dock (relu depuis le disque à chaque
/// notification) et le gestionnaire des commandes de l'écran verrouillé. Chacun
/// publiait la Live Activity, la présence et les widgets à sa façon, et il
/// suffisait qu'un chemin en oublie un pour que l'îlot, le dock et l'écran se
/// contredisent.
///
/// Ici, l'état persisté (`FocusTimerState`) est la seule vérité. Chaque geste
/// passe par une méthode de ce type, qui modifie l'état puis **publie tout** au
/// même endroit : disque, Live Activity, présence, notifications, widgets.
///
/// Le cycle Pomodoro avance tout seul : `tick()` rattrape les fins de bloc et
/// de pause, à la seconde près, même après une longue absence (voir
/// `FocusTimerState.advance`).
@MainActor
@Observable
final class FocusController {

    /// L'état du chrono ; `nil` quand aucune session n'est ouverte.
    private(set) var state: FocusTimerState?

    /// Le dernier événement du cycle, pour que l'écran puisse le saluer.
    private(set) var lastEvent: PomodoroEvent?

    @ObservationIgnored weak var app: AppContainer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Vrai pendant qu'on applique un état venu d'un autre appareil : on ne le
    /// republie pas (sinon les appareils se le renverraient sans fin).
    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var relayObserver: NSObjectProtocol?
    @ObservationIgnored private var baseObserver: NSObjectProtocol?

    /// Le contexte où vit la balise du chrono (voie rapide entre appareils).
    private var relayContext: ModelContext? { app.map { ModelContext($0.modelContainer) } }

    init() {
        state = FocusTimerStore.load()
    }

    // MARK: Lecture

    /// Une session est ouverte : du temps compté, ou une pause en cours.
    var hasSession: Bool {
        guard let state else { return false }
        return state.isRunning || state.isRestorable()
    }

    var isRunning: Bool { state?.isRunning ?? false }

    var isPomodoro: Bool { state?.pomodoro ?? (app?.settings.pomodoroDefault ?? false) }

    private var settings: PomodoroSettings { app?.settings.pomodoro ?? PomodoroSettings() }

    func elapsed(at now: Date = Date()) -> TimeInterval { state?.elapsed(at: now) ?? 0 }

    func phase(at now: Date = Date()) -> FocusPhase {
        state?.phase(settings: settings, at: now) ?? .idle
    }

    /// Où en est le bloc de travail à l'instant `now`.
    func pomodoroStatus(at now: Date = Date()) -> PomodoroStatus {
        PomodoroEngine.status(elapsed: elapsed(at: now), focusMinutes: settings.focusMinutes)
    }

    // MARK: Cycle de vie

    /// Relit l'état persisté et rattrape le temps passé app fermée.
    ///
    /// Une session trop ancienne (chrono oublié la veille) n'est pas reprise :
    /// elle est enregistrée telle quelle, bornée, et le journal la montre avec
    /// une note pour qu'on la corrige.
    func reload() {
        guard var saved = FocusTimerStore.load() else {
            state = nil
            updateTicker()
            return
        }
        guard saved.isRestorable() else {
            FocusTimerStore.save(nil)
            state = nil
            let seconds = min(Int(saved.elapsed()), Int(FocusTimerState.maxRestorableAge))
            if seconds >= 60, let app {
                let context = ModelContext(app.modelContainer)
                let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
                let session = StudySession(course: courses.first { $0.id == saved.courseID },
                                           taskType: saved.taskType,
                                           startedAt: saved.sessionStartedAt,
                                           durationSeconds: seconds,
                                           isManual: false,
                                           note: saved.note.isEmpty
                                               ? "Chrono resté ouvert — durée à vérifier"
                                               : saved.note + " · chrono resté ouvert")
                context.insert(session)
                try? context.save()
            }
            StudyActivityController.end()
            updateTicker()
            return
        }
        let events = saved.advance(settings: settings)
        state = saved
        if !events.isEmpty {
            lastEvent = events.last
            commit(presence: false, publish: false)
        }
        updateTicker()
    }

    /// Fait avancer le cycle Pomodoro. Appelé chaque seconde tant qu'il y a
    /// quelque chose à surveiller.
    func tick(now: Date = Date()) {
        guard var current = state else { return }
        let events = current.advance(settings: settings, to: now)
        guard !events.isEmpty else { return }
        state = current
        lastEvent = events.last
        switch events.last {
        case .blockEnded: Haptics.success()
        case .breakEnded: Haptics.tap()
        case nil: break
        }
        commit(publish: false)
    }

    // MARK: Gestes

    /// Démarre une session — ou reprend celle qui est en pause.
    ///
    /// - Parameters:
    ///   - pomodoro: `nil` garde le réglage de la session ouverte, sinon celui
    ///     choisi par défaut dans les réglages.
    func start(courseID: UUID?,
               taskType: TaskType,
               targetID: UUID? = nil,
               label: String = "",
               pomodoro: Bool? = nil) {
        if var current = state, hasSession {
            // Le temps déjà compté reste à la cible précédente.
            current.switchContext(courseID: courseID, taskTypeRaw: taskType.rawValue, targetID: targetID)
            current.contextLabel = label
            if let pomodoro { current.pomodoro = pomodoro }
            current.start()
            state = current
        } else {
            var fresh = FocusTimerState(sessionStartedAt: Date(),
                                        courseID: courseID,
                                        taskTypeRaw: taskType.rawValue,
                                        targetID: targetID,
                                        contextLabel: label,
                                        pomodoro: pomodoro ?? (app?.settings.pomodoroDefault ?? false))
            fresh.start()
            state = fresh
        }
        lastEvent = nil
        commit()
    }

    /// Relance le chrono : reprise après une pause, ou bloc suivant.
    func resume() {
        guard var current = state else { return }
        current.start()
        state = current
        lastEvent = nil
        commit()
    }

    func pause() {
        guard var current = state, current.isRunning else { return }
        current.pause()
        state = current
        commit()
    }

    /// Le geste du gros bouton : démarrer, mettre en pause ou reprendre.
    func toggle(courseID: UUID?, taskType: TaskType) {
        if isRunning {
            pause()
        } else if hasSession {
            resume()
        } else {
            start(courseID: courseID, taskType: taskType)
        }
    }

    /// Termine la pause Pomodoro et relance le travail.
    func skipBreak() {
        guard var current = state, current.currentBreak != nil else { return }
        current.skipBreak()
        state = current
        lastEvent = nil
        commit()
    }

    /// Allonge la pause en cours.
    func extendBreak(minutes: Int = 5) {
        guard var current = state, current.currentBreak != nil else { return }
        current.extendBreak(by: TimeInterval(minutes * 60))
        state = current
        commit(presence: false)
    }

    /// Active ou coupe le Pomodoro, y compris en pleine session.
    ///
    /// Le couper pendant une pause la termine : sans cycle, il n'y a plus de
    /// pause à décompter, seulement un chrono arrêté.
    func setPomodoro(_ enabled: Bool) {
        guard var current = state else {
            app?.settings.pomodoroDefault = enabled
            return
        }
        current.pomodoro = enabled
        if !enabled { current.clearBreak() }
        current.advance(settings: settings)
        state = current
        app?.settings.pomodoroDefault = enabled
        commit(presence: false)
    }

    /// Les durées du cycle ont changé : la fin du bloc, la pause en cours et
    /// leurs notifications sont recalculées.
    func settingsDidChange() {
        guard var current = state else { return }
        let events = current.advance(settings: settings)
        state = current
        if !events.isEmpty { lastEvent = events.last }
        commit(presence: false, publish: false)
    }

    /// Change le cours, le type, la cible ou la note de la session ouverte.
    func updateContext(courseID: UUID?? = nil,
                       taskType: TaskType? = nil,
                       targetID: UUID?? = nil,
                       note: String? = nil,
                       label: String? = nil) {
        guard var current = state else { return }
        // Cours, type et cible passent par un **segment** : changer d'exercice
        // en pleine session ne réattribue pas le temps déjà passé sur l'autre.
        current.switchContext(courseID: courseID ?? current.courseID,
                              taskTypeRaw: taskType?.rawValue ?? current.taskTypeRaw,
                              targetID: targetID ?? current.targetID)
        if let note { current.note = note }
        if let label { current.contextLabel = label }
        guard current != state else { return }
        let presenceChanged = current.courseID != state?.courseID
            || current.taskTypeRaw != state?.taskTypeRaw
            || current.targetID != state?.targetID
        state = current
        // La note s'écrit à chaque frappe : elle n'a pas à republier l'îlot.
        commit(presence: presenceChanged, activity: presenceChanged)
    }

    /// Applique une **variation** au temps compté (les boutons ±5 min, l'anneau).
    func adjust(by delta: TimeInterval) {
        setElapsed(elapsed() + delta)
    }

    /// Fixe le temps compté **absolu**.
    func setElapsed(_ total: TimeInterval) {
        let bounded = max(0, total)
        if state == nil {
            guard bounded >= 1 else { return }
            state = FocusTimerState(sessionStartedAt: Date(), pomodoro: app?.settings.pomodoroDefault ?? false)
        }
        guard var current = state, abs(bounded - current.elapsed()) >= 0.5 else { return }
        current.accumulated = bounded
        // La période en cours repart de maintenant : le chrono continue de
        // tourner à partir du nouveau total.
        current.runningSince = current.isRunning ? Date() : nil
        state = current
        commit(presence: false)
    }

    /// Enregistre la session dans le journal et libère le chrono.
    ///
    /// - Returns: la durée enregistrée, en secondes ; `nil` s'il n'y avait rien.
    /// Une session passée sur plusieurs cibles (3.2, puis 3.3) est enregistrée
    /// en **une session par cible**, bout à bout : le temps de chaque exercice
    /// se lit ensuite sur l'exercice lui-même.
    @discardableResult
    func finish() -> Int? {
        guard let current = state, let app else { return nil }
        let seconds = Int(current.elapsed())
        defer { close() }
        guard seconds >= 1 else { return nil }
        let context = ModelContext(app.modelContainer)
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        var start = current.sessionStartedAt
        for (index, part) in current.allocatedSeconds().enumerated() {
            let course = courses.first { $0.id == part.segment.courseID }
            let target = Self.target(of: part.segment.targetID, in: course)
            let session = StudySession(course: course,
                                       taskType: part.segment.taskType,
                                       startedAt: start,
                                       durationSeconds: part.seconds,
                                       isManual: false,
                                       note: index == 0 ? current.note : "",
                                       exercise: target.exercise,
                                       theoryItem: target.theoryItem)
            context.insert(session)
            start = start.addingTimeInterval(TimeInterval(part.seconds))
        }
        try? context.save()
        return seconds
    }

    /// Abandonne la session sans l'enregistrer.
    func discard() {
        close()
    }

    /// Coche la sous-question en cours de la cible (bouton de l'îlot).
    func tickNextQuestion() {
        guard let current = state, let app else { return }
        let context = ModelContext(app.modelContainer)
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        guard let course = courses.first(where: { $0.id == current.courseID }),
              let exercise = Self.target(of: current, in: course).exercise,
              let next = exercise.leafSubQuestions.first(where: { !$0.isDone }) else { return }
        next.isDone = true
        next.doneAt = Date()
        exercise.refreshCompletion()
        try? context.save()
        commit(presence: false, publish: false)
    }

    /// Exécute une commande venue de l'écran verrouillé, de l'îlot ou du dock.
    func perform(_ command: FocusTimerCommand) {
        reload()
        switch command {
        case .pause: pause()
        case .resume: resume()
        case .finish: finish()
        case .nextQuestion: tickNextQuestion()
        case .skipBreak: skipBreak()
        }
    }

    // MARK: Entre appareils

    /// Reprend l'état publié par un autre appareil (le Mac a démarré, mis en
    /// pause ou terminé la session). Rien n'est enregistré ici : c'est
    /// l'appareil qui termine qui enregistre.
    /// Écoute les autres appareils **au niveau de l'app**, pas d'une fenêtre :
    /// lancée en arrière-plan (écran éteint, push iCloud), l'app suit quand
    /// même le chrono du Mac.
    func startRelay() {
        guard relayObserver == nil else { return }
        relayObserver = NotificationCenter.default.addObserver(forName: CloudRelay.changed, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRemote() }
        }
        // La voie rapide : la balise d'un autre appareil arrive par la base.
        baseObserver = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRemote() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        applyRemote()
    }

    func applyRemote() {
        guard let remote = CloudRelay.remoteTimer(context: relayContext) else { return }
        CloudRelay.noteShared(local: state, remote: remote)
        let decision = CloudRelay.decide(local: state, remote: remote,
                                         lastApplied: CloudRelay.lastAppliedTimer, device: CloudRelay.deviceID,
                                         shared: CloudRelay.sharedSession)
        guard decision != .ignore else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        CloudRelay.lastAppliedTimer = remote.updatedAt
        switch decision {
        case .adopt(let remoteState):
            state = remoteState
            lastEvent = nil
            commit(presence: false)
        case .close:
            close()
        case .ignore:
            break
        }
    }

    // MARK: Publication

    /// Ferme la session : plus d'état, plus d'îlot, plus de présence.
    private func close() {
        let ended = state?.sessionStartedAt
        if !applyingRemote, let ended { CloudRelay.publishTimer(nil, ended: ended, context: relayContext) }
        state = nil
        lastEvent = nil
        FocusTimerStore.save(nil)
        StudyActivityController.end()
        app?.notifications.cancelPomodoro()
        if let app {
            app.presence.stop(context: ModelContext(app.modelContainer), social: app.social)
            WidgetSnapshotWriter.refresh(context: ModelContext(app.modelContainer), settings: app.settings)
        }
        updateTicker()
    }

    /// Publie l'état partout où il se voit.
    ///
    /// - Parameters:
    ///   - presence: annoncer aux groupes (démarrage, pause, changement de cours).
    ///   - activity: republier la Live Activity.
    private func commit(presence: Bool = true, activity: Bool = true, publish: Bool = true) {
        FocusTimerStore.save(state)
        // Le Mac (et l'iPad) suivent le même chrono. Seule une session se
        // publie : « pas de chrono » ne part que de `close()`, avec la session
        // terminée — sinon un réglage touché au repos (cours, Pomodoro)
        // effaçait la session tout juste démarrée ailleurs.
        //
        // Et seuls les **gestes** se publient (`publish`). La fin d'un bloc ou
        // d'une pause se déduit des dates, pareil sur chaque appareil : la
        // republier, c'était dater de « maintenant » un état périmé (l'iPhone
        // qui se réveille rattrape les blocs de SA dernière version) et
        // écraser le « play » donné entre-temps sur le Mac.
        if publish, !applyingRemote, let state { CloudRelay.publishTimer(state, context: relayContext) }
        guard let app, let state else { updateTicker(); return }
        if activity {
            StudyActivityController.publish(state, container: app)
        }
        schedulePomodoroNotifications(state)
        if presence { announcePresence(state) }
        WidgetSnapshotWriter.scheduleRefresh(context: ModelContext(app.modelContainer), settings: app.settings)
        updateTicker()
    }

    /// Planifie la fin du bloc et la fin de la pause qui suit.
    private func schedulePomodoroNotifications(_ state: FocusTimerState) {
        guard let app else { return }
        let settings = self.settings
        guard state.pomodoro else {
            app.notifications.cancelPomodoro()
            return
        }
        let block = settings.blockDuration
        if let pause = state.currentBreak {
            let next = Int((state.accumulated / block).rounded()) + 1
            app.notifications.schedulePomodoro(blockEndsAt: nil,
                                               breakKind: pause.kind,
                                               breakMinutes: Int(settings.breakDuration(pause.kind) / 60),
                                               breakEndsAt: pause.endsAt,
                                               nextBlock: next)
        } else if let end = state.blockEndDate(settings: settings) {
            let completed = Int(((state.accumulated / block).rounded(.down))) + 1
            let kind = settings.breakKind(afterBlock: completed)
            app.notifications.schedulePomodoro(blockEndsAt: end,
                                               breakKind: kind,
                                               breakMinutes: Int(settings.breakDuration(kind) / 60),
                                               breakEndsAt: end.addingTimeInterval(settings.breakDuration(kind)),
                                               nextBlock: completed + 1)
        } else {
            app.notifications.cancelPomodoro()
        }
    }

    /// Prévient les groupes que je travaille — ou que je viens d'arrêter.
    ///
    /// Une session **sans cours** est publiée elle aussi : c'est du travail, et
    /// l'absence de matière ne justifie pas de disparaître du direct.
    private func announcePresence(_ state: FocusTimerState) {
        guard let app else { return }
        let context = ModelContext(app.modelContainer)
        guard state.isRunning else {
            app.presence.stop(context: context, social: app.social)
            return
        }
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let course = courses.first { $0.id == state.courseID }
        let target = Self.target(of: state, in: course)
        let entry = PresenceEntry(
            userID: app.social.userID ?? "me",
            displayName: app.settings.displayName.isEmpty ? "Moi" : app.settings.displayName,
            courseCode: course?.code ?? "",
            taskLabel: state.taskType.label,
            target: target.exercise?.displayNumber ?? target.theoryItem?.displayNumber ?? "",
            startedAt: state.runningSince ?? Date(),
            updatedAt: Date(),
            isMe: true)
        app.presence.announce(entry, context: context, social: app.social)
    }

    /// Le battement ne tourne que lorsqu'un changement peut survenir : un bloc
    /// qui court vers sa fin, ou une pause qui décompte.
    private func updateTicker() {
        let needsTick = state.map { $0.pomodoro && ($0.isRunning || $0.currentBreak != nil) } ?? false
        if needsTick {
            guard ticker == nil else { return }
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    self?.tick()
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }

    /// La cible de la session : un exercice ou un élément de théorie.
    static func target(of state: FocusTimerState, in course: Course?) -> (exercise: Exercise?, theoryItem: TheoryItem?) {
        target(of: state.targetID, in: course)
    }

    static func target(of targetID: UUID?, in course: Course?) -> (exercise: Exercise?, theoryItem: TheoryItem?) {
        guard let course, let targetID else { return (nil, nil) }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return (exercise, nil)
        }
        if let item = course.theoryItems.first(where: { $0.id == targetID }) {
            return (nil, item)
        }
        return (nil, nil)
    }
}
