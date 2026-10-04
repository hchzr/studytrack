import Foundation
import CoreData
import Observation
import OSLog
import SwiftData
import UserNotifications

/// Le chrono du Mac — **le même** que celui de l'iPhone.
///
/// Il repose sur le même état (`FocusTimerState`) : même Pomodoro, mêmes
/// pauses, même temps réparti exercice par exercice. Chaque geste est publié
/// par `CloudRelay` : démarré ici, le chrono tourne sur l'iPhone (et inversement),
/// et c'est l'appareil qui le termine qui enregistre la session — une seule
/// fois, synchronisée par iCloud.
@MainActor
@Observable
final class MacTimer {
    enum Phase: Equatable { case idle, running, paused, onBreak }

    private(set) var state: FocusTimerState?
    /// Ce qui sera chronométré au prochain démarrage.
    var courseID: UUID?
    var taskType: TaskType = .exercise
    var targetID: UUID?
    var pomodoro = false
    /// Avance d'une seconde pendant qu'il se passe quelque chose.
    private(set) var now = Date()

    @ObservationIgnored let settings: MacSettings
    /// Appelé à chaque changement d'état (widgets du bureau).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored weak var container: ModelContainer?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var baseObserver: NSObjectProtocol?

    private var relayContext: ModelContext? { container.map { ModelContext($0) } }
    @ObservationIgnored private let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "timer")

    init(settings: MacSettings) {
        self.settings = settings
        pomodoro = settings.pomodoroDefault
        state = FocusTimerStore.load()
        if let state, !state.isRestorable(), !state.isRunning {
            self.state = nil
            FocusTimerStore.save(nil)
        }
        syncSelection()
        tick()
        observer = NotificationCenter.default.addObserver(forName: CloudRelay.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRemote() }
        }
        baseObserver = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRemote() }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        applyRemote()
    }

    // MARK: Lecture

    var phase: Phase {
        guard let state else { return .idle }
        if state.currentBreak != nil { return .onBreak }
        return state.isRunning ? .running : .paused
    }

    var elapsed: TimeInterval { state?.elapsed(at: now) ?? 0 }

    /// Ce qui s'affiche en grand : le temps compté, ce qui reste du bloc en
    /// Pomodoro, ou ce qui reste de la pause.
    var displayTime: TimeInterval {
        guard let state else { return 0 }
        if let pause = state.currentBreak { return max(0, pause.endsAt.timeIntervalSince(now)) }
        if state.pomodoro {
            let block = settings.pomodoro.blockDuration
            let into = elapsed.truncatingRemainder(dividingBy: block)
            return max(0, block - into)
        }
        return elapsed
    }

    var statusLabel: String? {
        guard let state else { return nil }
        if let pause = state.currentBreak { return pause.kind.label }
        if !state.isRunning { return "En pause" }
        if state.pomodoro {
            let block = Int(elapsed / settings.pomodoro.blockDuration) + 1
            return "Bloc \(block)"
        }
        return nil
    }

    // MARK: Gestes

    func start(courseID: UUID? = nil, taskType: TaskType? = nil, targetID: UUID? = nil, label: String = "") {
        if let courseID { self.courseID = courseID }
        if let taskType { self.taskType = taskType }
        if targetID != nil || courseID != nil { self.targetID = targetID }
        if var current = state {
            current.switchContext(courseID: self.courseID, taskTypeRaw: self.taskType.rawValue, targetID: self.targetID)
            if !label.isEmpty { current.contextLabel = label }
            current.start()
            state = current
        } else {
            var fresh = FocusTimerState(sessionStartedAt: Date(), courseID: self.courseID,
                                        taskTypeRaw: self.taskType.rawValue, targetID: self.targetID,
                                        contextLabel: label, pomodoro: pomodoro)
            fresh.start()
            state = fresh
        }
        commit()
    }

    func pause() {
        guard var current = state, current.isRunning else { return }
        current.pause()
        state = current
        commit()
    }

    func resume() {
        guard var current = state else { return }
        current.start()
        state = current
        commit()
    }

    /// Le geste principal : démarrer, mettre en pause, reprendre.
    func toggle() {
        switch phase {
        case .idle: start()
        case .running: pause()
        case .paused, .onBreak: resume()
        }
    }

    func skipBreak() {
        guard var current = state, current.currentBreak != nil else { return }
        current.skipBreak()
        state = current
        commit()
    }

    /// Change ce qui est chronométré sans couper le chrono : le temps déjà
    /// compté reste à la cible précédente.
    func retarget(courseID: UUID?, taskType: TaskType, targetID: UUID? = nil) {
        self.courseID = courseID
        self.taskType = taskType
        self.targetID = targetID
        guard var current = state else { return }
        current.switchContext(courseID: courseID, taskTypeRaw: taskType.rawValue, targetID: targetID)
        state = current
        commit()
    }

    /// Termine et enregistre — une session par cible, comme sur l'iPhone.
    /// Moins d'une minute : un faux départ, rien n'est enregistré.
    @discardableResult
    func finish() -> Int? {
        guard let current = state else { return nil }
        let seconds = Int(current.elapsed())
        defer { close() }
        guard seconds >= 60, let container else { return nil }
        let context = ModelContext(container)
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        var start = current.sessionStartedAt
        for (index, part) in current.allocatedSeconds().enumerated() {
            let course = courses.first { $0.id == part.segment.courseID }
            let exercise = course?.allExercises.first { $0.id == part.segment.targetID }
            let theory = course?.theoryItems.first { $0.id == part.segment.targetID }
            let session = StudySession(course: course, taskType: part.segment.taskType, startedAt: start,
                                       durationSeconds: part.seconds, isManual: false,
                                       note: index == 0 ? current.note : "",
                                       exercise: exercise, theoryItem: theory)
            context.insert(session)
            start = start.addingTimeInterval(TimeInterval(part.seconds))
        }
        try? context.save()
        return seconds
    }

    func discard() {
        close()
    }

    private func close() {
        let ended = state?.sessionStartedAt
        if !applyingRemote, let ended {
            CloudRelay.publishTimer(nil, ended: ended, context: relayContext)
            log.notice("chrono publié : terminé")
        }
        state = nil
        FocusTimerStore.save(nil)
        cancelNotifications()
        tick()
        onChange?()
    }

    private func commit() {
        FocusTimerStore.save(state)
        if !applyingRemote, let state {
            CloudRelay.publishTimer(state, context: relayContext)
            log.notice("chrono publié : \(state.isRunning ? "en cours" : "en pause", privacy: .public)")
        }
        syncSelection()
        scheduleNotifications()
        now = Date()
        tick()
        onChange?()
    }

    /// Le cours et le travail affichés suivent la session en cours.
    private func syncSelection() {
        guard let state else { return }
        courseID = state.courseID
        taskType = state.taskType
        targetID = state.targetID
        pomodoro = state.pomodoro
    }

    // MARK: Entre appareils

    /// L'état publié par l'iPhone (ou un autre Mac).
    func applyRemote() {
        guard let remote = CloudRelay.remoteTimer(context: relayContext) else { return }
        let decision = CloudRelay.decide(local: state, remote: remote,
                                         lastApplied: CloudRelay.lastAppliedTimer, device: CloudRelay.deviceID)
        log.notice("chrono distant de \(remote.device.prefix(8), privacy: .public) : \(String(describing: decision), privacy: .public)")
        guard decision != .ignore else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        CloudRelay.lastAppliedTimer = remote.updatedAt
        switch decision {
        case .adopt(let remoteState):
            state = remoteState
            commit()
        case .close:
            close()
        case .ignore:
            break
        }
    }

    // MARK: Battement

    /// Une seconde, seulement quand il y a quelque chose qui avance.
    private func tick() {
        ticker?.invalidate()
        ticker = nil
        guard let state, state.isRunning || state.currentBreak != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func beat() {
        now = Date()
        guard var current = state else { return }
        let events = current.advance(settings: settings.pomodoro, to: now)
        guard !events.isEmpty else { return }
        state = current
        commit()
    }

    // MARK: Notifications

    private func scheduleNotifications() {
        cancelNotifications()
        guard let state else { return }
        let center = UNUserNotificationCenter.current()
        if let pause = state.currentBreak {
            let content = UNMutableNotificationContent()
            content.title = "Fin de la pause"
            content.body = "On s'y remet quand tu es prêt·e."
            content.sound = .default
            let interval = pause.endsAt.timeIntervalSinceNow
            if interval > 1 {
                center.add(UNNotificationRequest(identifier: "mac.break", content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
            }
        } else if state.pomodoro, state.isRunning, let end = state.blockEndDate(settings: settings.pomodoro) {
            let content = UNMutableNotificationContent()
            content.title = "Bloc terminé"
            content.body = "\(settings.focusMinutes) min de travail. Pause de \(settings.shortBreakMinutes) min."
            content.sound = .default
            let interval = end.timeIntervalSinceNow
            if interval > 1 {
                center.add(UNNotificationRequest(identifier: "mac.block", content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
            }
        }
    }

    private func cancelNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["mac.break", "mac.block"])
    }
}

extension TimeInterval {
    /// « 24:13 », « 1:05:09 ».
    var clockLabel: String {
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
