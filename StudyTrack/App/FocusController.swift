import Foundation
import SwiftData
import Observation

/// Le chrono de l'iPhone : le moteur commun (`TimerEngine`, le même que sur le
/// Mac) et ce que l'iPhone en fait — Live Activity, présence dans les groupes,
/// notifications Pomodoro, widgets, bouclier du Temps d'écran, haptique.
///
/// Un seul chrono, partagé par Focus, le dock, l'écran verrouillé et le mode
/// étude : chaque geste passe par le moteur, qui l'écrit et le publie aux
/// autres appareils, puis appelle `timerDidChange` — le seul endroit où
/// l'iPhone répercute un changement.
@MainActor
@Observable
final class FocusController: TimerEngineHost {

    @ObservationIgnored let engine = TimerEngine()
    @ObservationIgnored weak var app: AppContainer? {
        didSet { engine.container = app?.modelContainer }
    }

    init() {
        engine.host = self
    }

    // MARK: TimerEngineHost

    var localCycle: PomodoroSettings { app?.settings.pomodoro ?? PomodoroSettings() }
    var pomodoroByDefault: Bool { app?.settings.pomodoroDefault ?? false }

    func timerDidChange(_ change: TimerEngine.Change) {
        StudyLock.shared.sync(state)
        guard let app else { return }
        switch change {
        case .closed(let session):
            StudyActivityController.end(session: session)
            app.notifications.cancelPomodoro()
            let context = ModelContext(app.modelContainer)
            app.presence.stop(context: context, social: app.social)
            WidgetSnapshotWriter.scheduleRefresh(context: context, settings: app.settings)
            return
        case .boundary(let events, _):
            switch events.last {
            case .blockEnded: Haptics.success()
            case .breakEnded: Haptics.tap()
            case nil: break
            }
        case .saved:
            // Une note tapée : rien de visible ailleurs.
            return
        case .gesture, .remote, .refresh:
            break
        }
        guard let state else { return }
        StudyActivityController.publish(state, container: app)
        schedulePomodoroNotifications(state)
        if change == .gesture(presence: true) { announcePresence(state) }
        WidgetSnapshotWriter.scheduleRefresh(context: ModelContext(app.modelContainer), settings: app.settings)
    }

    // MARK: Lecture

    /// L'état du chrono ; `nil` quand aucune session n'est ouverte.
    var state: FocusTimerState? { engine.state }
    /// Le dernier événement du cycle, pour que l'écran puisse le saluer.
    var lastEvent: PomodoroEvent? { engine.lastEvent }
    var hasSession: Bool { engine.hasSession }
    var isRunning: Bool { engine.isRunning }
    var isPomodoro: Bool { state?.pomodoro ?? pomodoroByDefault }
    /// Les durées du cycle en vigueur (celles de la session ouverte).
    var cycle: PomodoroSettings { engine.cycle }
    func elapsed(at now: Date = Date()) -> TimeInterval { engine.elapsed(at: now) }
    func phase(at now: Date = Date()) -> FocusPhase { engine.phase(at: now) }
    func pomodoroStatus(at now: Date = Date()) -> PomodoroStatus { engine.pomodoroStatus(at: now) }
    var isStudying: Bool { engine.isStudying }
    var studyIsOver: Bool { engine.studyIsOver }

    // MARK: Cycle de vie

    /// Relit l'état persisté et rattrape le temps passé app fermée.
    func reload() {
        engine.reload()
        StudyLock.shared.sync(state)
    }

    func startRelay() { engine.startRelay() }
    func applyRemote() { engine.applyRemote() }

    // MARK: Gestes

    func start(courseID: UUID?, taskType: TaskType, targetID: UUID? = nil, label: String = "", pomodoro: Bool? = nil) {
        engine.start(courseID: courseID, taskType: taskType, targetID: targetID, label: label, pomodoro: pomodoro)
    }

    func resume() { engine.resume() }
    func pause() { engine.pause() }

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

    func skipBreak() { engine.skipBreak() }
    func extendBreak(minutes: Int = 5) { engine.extendBreak(minutes: minutes) }

    /// Active ou coupe le Pomodoro (la session ouverte et le réglage par défaut).
    func setPomodoro(_ enabled: Bool) {
        app?.settings.pomodoroDefault = enabled
        engine.setPomodoro(enabled)
    }

    /// Les durées du cycle ont changé : la session ouverte les prend.
    func settingsDidChange() { engine.cycleDidChange() }

    func updateContext(courseID: UUID?? = nil, taskType: TaskType? = nil, targetID: UUID?? = nil,
                       note: String? = nil, label: String? = nil) {
        engine.updateContext(courseID: courseID, taskType: taskType, targetID: targetID, note: note, label: label)
    }

    func adjust(by delta: TimeInterval) { engine.setElapsed(elapsed() + delta) }
    func setElapsed(_ total: TimeInterval) { engine.setElapsed(total) }

    /// Enregistre la session ; rend la durée enregistrée, `nil` si rien ne
    /// l'a été (moins d'une minute).
    @discardableResult
    func finish() -> Int? {
        guard let finished = engine.finish(), !finished.parts.isEmpty else { return nil }
        return finished.totalSeconds
    }

    func discard() { engine.discard() }

    /// Coche la sous-question en cours de la cible (bouton de l'îlot).
    func tickNextQuestion() {
        guard let current = state, let app else { return }
        let context = ModelContext(app.modelContainer)
        guard let course = TimerEngine.course(current.courseID, in: context),
              let exercise = Self.target(of: current, in: course).exercise,
              let next = exercise.leafSubQuestions.first(where: { !$0.isDone }) else { return }
        next.isDone = true
        next.doneAt = Date()
        exercise.refreshCompletion()
        try? context.save()
        engine.refresh()
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

    // MARK: Mode étude

    func enterStudy(minutes: Int, courseID: UUID?, taskType: TaskType, targetID: UUID? = nil, locks: Bool = true) {
        engine.enterStudy(minutes: minutes, courseID: courseID, taskType: taskType, targetID: targetID, locks: locks)
    }

    func extendStudy(minutes: Int) { engine.extendStudy(minutes: minutes) }
    func leaveStudy() { engine.leaveStudy() }

    // MARK: Effets

    /// Planifie la fin du bloc et la fin de la pause qui suit.
    private func schedulePomodoroNotifications(_ state: FocusTimerState) {
        guard let app else { return }
        let settings = cycle
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
        let course = TimerEngine.course(state.courseID, in: context)
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

    /// La cible de la session : un exercice ou un élément de théorie.
    static func target(of state: FocusTimerState, in course: Course?) -> (exercise: Exercise?, theoryItem: TheoryItem?) {
        TimerEngine.target(of: state.targetID, in: course)
    }

    static func target(of targetID: UUID?, in course: Course?) -> (exercise: Exercise?, theoryItem: TheoryItem?) {
        TimerEngine.target(of: targetID, in: course)
    }
}
