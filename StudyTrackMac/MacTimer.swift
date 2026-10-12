import AppKit
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
    /// Change à chaque frontière du cycle (fin de bloc, de pause, du mode
    /// étude) : ce qui dépend de l'heure **et** de l'état se relit alors.
    ///
    /// Le chrono avançait un `now` observé chaque seconde : toute vue qui le
    /// lisait — la fenêtre entière, avec ses requêtes et ses calculs de
    /// planning — se recalculait 60 fois par minute, même cachée. C'est ce qui
    /// vidait la batterie. Désormais, seules les petites vues qui affichent des
    /// secondes battent (`TimelineView`, voir `MacClock.swift`) ; le modèle,
    /// lui, ne se réveille qu'aux instants où quelque chose change vraiment.
    private(set) var revision = 0
    /// La session qu'on vient de terminer ici : le récapitulatif propose de
    /// cocher ce qui a été fait, et d'annuler un « Terminer » de trop.
    private(set) var recap: Recap?

    struct Recap: Identifiable, Equatable {
        struct Part: Identifiable, Equatable {
            var sessionID: UUID
            var courseID: UUID?
            var taskType: TaskType
            var targetID: UUID?
            var seconds: Int
            var id: UUID { sessionID }
        }
        var id = UUID()
        var startedAt: Date
        var endedAt: Date
        var totalSeconds: Int
        var parts: [Part]
        /// Moins d'une minute : rien n'a été enregistré.
        var discarded: Bool { parts.isEmpty }
    }

    @ObservationIgnored let settings: MacSettings
    /// Appelé à chaque changement d'état (widgets du bureau).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored weak var container: ModelContainer?
    @ObservationIgnored private var boundary: Timer?
    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var baseObserver: NSObjectProtocol?
    @ObservationIgnored private var lastLoggedRemote: Date?

    private var relayContext: ModelContext? { container.map { ModelContext($0) } }
    @ObservationIgnored private let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "timer")

    /// Un chrono d'aperçu (débogage) : ni sauvegardé, ni partagé.
    @ObservationIgnored private var isolated = false

    init(settings: MacSettings, isolated: Bool = false) {
        self.settings = settings
        self.isolated = isolated
        pomodoro = settings.pomodoroDefault
        if isolated { return }
        state = FocusTimerStore.load()
        if let state, !state.isRestorable(), !state.isRunning {
            self.state = nil
            FocusTimerStore.save(nil)
        }
        syncSelection()
        scheduleBoundary()
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

    func elapsed(at now: Date = Date()) -> TimeInterval { state?.elapsed(at: now) ?? 0 }

    /// La phase fine (bloc prêt après une pause, etc.), déduite de l'état.
    func focusPhase(at now: Date = Date()) -> FocusPhase { state?.phase(settings: settings.pomodoro, at: now) ?? .idle }

    func pomodoroStatus(at now: Date = Date()) -> PomodoroStatus? {
        guard let state, state.pomodoro else { return nil }
        return PomodoroEngine.status(elapsed: elapsed(at: now), focusMinutes: settings.focusMinutes)
    }

    /// Le temps passé sur la cible actuelle (depuis « Passer à… »).
    func targetElapsed(at now: Date = Date()) -> TimeInterval { state?.currentTargetElapsed(at: now) ?? 0 }

    /// Ce que dessine l'anneau : le bloc ou la pause qui s'écoule ; l'heure
    /// entamée en session libre.
    func ringProgress(at now: Date = Date()) -> Double {
        guard let state else { return 0 }
        if let pause = state.currentBreak {
            let total = pause.endsAt.timeIntervalSince(pause.startedAt)
            return total > 0 ? min(1, max(0, 1 - pause.endsAt.timeIntervalSince(now) / total)) : 0
        }
        if case .readyForBlock = focusPhase(at: now) { return 1 }
        let block = state.pomodoro ? settings.pomodoro.blockDuration : 3600
        return elapsed(at: now).truncatingRemainder(dividingBy: block) / block
    }

    /// Ce qui s'affiche en grand : le temps compté, ce qui reste du bloc en
    /// Pomodoro, ou ce qui reste de la pause.
    func displayTime(at now: Date = Date()) -> TimeInterval {
        guard let state else { return 0 }
        // Comptes à rebours arrondis au-dessus, comme sur l'iPhone (« 25:00 »
        // au départ, « 00:01 » à la dernière seconde) : sinon une seconde d'écart.
        if let pause = state.currentBreak { return max(0, pause.endsAt.timeIntervalSince(now)).rounded(.up) }
        if state.pomodoro {
            let block = settings.pomodoro.blockDuration
            let into = elapsed(at: now).truncatingRemainder(dividingBy: block)
            return max(0, block - into).rounded(.up)
        }
        return elapsed(at: now)
    }

    /// Le chrono compte-t-il à rebours (pause, Pomodoro) ?
    var countsDown: Bool { phase == .onBreak || state?.pomodoro == true }

    func statusLabel(at now: Date = Date()) -> String? {
        guard let state else { return nil }
        if let pause = state.currentBreak { return pause.kind.label }
        if case .readyForBlock(let block) = focusPhase(at: now) { return "Bloc \(block) prêt" }
        if !state.isRunning { return "En pause" }
        if state.pomodoro {
            let block = Int(elapsed(at: now) / settings.pomodoro.blockDuration) + 1
            return "Bloc \(block)"
        }
        return nil
    }

    // MARK: Mode étude

    /// Le mode étude est en vigueur (relu à chaque frontière, `revision`).
    var isStudying: Bool {
        _ = revision
        return StudyMode.isActive(state)
    }

    /// Le mode étude est arrivé à son terme, la session tourne encore.
    var studyIsOver: Bool {
        _ = revision
        return StudyMode.isOver(state)
    }

    /// Entre en mode étude pour `minutes` : démarre le chrono s'il dort, sinon
    /// verrouille la session en cours. Publié comme un geste : l'iPhone suit.
    func enterStudy(minutes: Int, courseID: UUID? = nil, taskType: TaskType? = nil, targetID: UUID? = nil, label: String = "") {
        if state == nil || phase == .idle {
            start(courseID: courseID, taskType: taskType, targetID: targetID, label: label)
        } else if courseID != nil || targetID != nil {
            retarget(courseID: courseID ?? self.courseID, taskType: taskType ?? self.taskType, targetID: targetID)
        }
        guard var current = state else { return }
        StudyMode.enter(&current, minutes: minutes)
        if !current.isRunning, current.currentBreak == nil { current.start() }
        state = current
        commit()
    }

    func extendStudy(minutes: Int) {
        guard var current = state else { return }
        // Prolonger après l'échéance repart d'un anneau vide.
        if current.studySince == nil || StudyMode.isOver(current) { current.studySince = Date() }
        current.studyUntil = StudyMode.extended(current.studyUntil, by: minutes)
        if !current.isRunning, current.currentBreak == nil { current.start() }
        state = current
        commit()
    }

    /// Sortir du mode étude sans terminer la session.
    func leaveStudy() {
        guard var current = state, current.studyUntil != nil else { return }
        StudyMode.leave(&current)
        state = current
        commit()
    }

    // MARK: Gestes

    func start(courseID: UUID? = nil, taskType: TaskType? = nil, targetID: UUID? = nil, label: String = "") {
        if let courseID { self.courseID = courseID }
        if let taskType { self.taskType = taskType }
        if targetID != nil || courseID != nil { self.targetID = targetID }
        recap = nil
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
        if isolated {
            close()
            recap = Recap(startedAt: current.sessionStartedAt, endedAt: Date(), totalSeconds: Int(current.elapsed()), parts: [])
            return nil
        }
        let seconds = Int(current.elapsed())
        defer { close() }
        guard seconds >= 60, let container else {
            recap = Recap(startedAt: current.sessionStartedAt, endedAt: Date(), totalSeconds: seconds, parts: [])
            return nil
        }
        let context = ModelContext(container)
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        var start = current.sessionStartedAt
        var parts: [Recap.Part] = []
        for (index, part) in current.allocatedSeconds().enumerated() {
            let course = courses.first { $0.id == part.segment.courseID }
            let exercise = course?.allExercises.first { $0.id == part.segment.targetID }
            let theory = course?.theoryItems.first { $0.id == part.segment.targetID }
            let session = StudySession(course: course, taskType: part.segment.taskType, startedAt: start,
                                       durationSeconds: part.seconds, isManual: false,
                                       note: index == 0 ? current.note : "",
                                       exercise: exercise, theoryItem: theory)
            context.insert(session)
            parts.append(Recap.Part(sessionID: session.id, courseID: course?.id, taskType: part.segment.taskType,
                                    targetID: part.segment.targetID, seconds: part.seconds))
            start = start.addingTimeInterval(TimeInterval(part.seconds))
        }
        try? context.save()
        recap = Recap(startedAt: current.sessionStartedAt, endedAt: Date(), totalSeconds: seconds, parts: parts)
        return seconds
    }

    /// « Annuler » dans le récapitulatif : les sessions enregistrées partent.
    func undoRecap() {
        guard let recap, let container else { self.recap = nil; return }
        let context = ModelContext(container)
        let ids = Set(recap.parts.map(\.sessionID))
        let since = recap.startedAt.addingTimeInterval(-1)
        let sessions = (try? context.fetch(FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.startedAt >= since }))) ?? []
        for session in sessions where ids.contains(session.id) { context.delete(session) }
        try? context.save()
        self.recap = nil
    }

    func dismissRecap() { recap = nil }

    func discard() {
        close()
    }

    private func close() {
        let ended = state?.sessionStartedAt
        if !applyingRemote, !isolated, let ended {
            CloudRelay.publishTimer(nil, ended: ended, context: relayContext)
            log.notice("chrono publié : terminé")
        }
        state = nil
        if !isolated { FocusTimerStore.save(nil) }
        cancelNotifications()
        scheduleBoundary()
        onChange?()
    }

    /// `publish` : seuls les gestes partent aux autres appareils ; la fin d'un
    /// bloc ou d'une pause se déduit des dates, pareil partout (voir l'iPhone).
    private func commit(publish: Bool = true) {
        if isolated { scheduleBoundary(); onChange?(); return }
        FocusTimerStore.save(state)
        if publish, !applyingRemote, let state {
            CloudRelay.publishTimer(state, context: relayContext)
            log.notice("chrono publié : \(state.isRunning ? "en cours" : "en pause", privacy: .public)")
        }
        syncSelection()
        scheduleNotifications()
        scheduleBoundary()
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
        guard !isolated, let remote = CloudRelay.remoteTimer(context: relayContext) else { return }
        CloudRelay.noteShared(local: state, remote: remote)
        let decision = CloudRelay.decide(local: state, remote: remote,
                                         lastApplied: CloudRelay.lastAppliedTimer, device: CloudRelay.deviceID,
                                         shared: CloudRelay.sharedSession)
        let fmt = ISO8601DateFormatter()
        let differs = remote.state.map { r in self.state.map { abs($0.sessionStartedAt.timeIntervalSince(r.sessionStartedAt)) >= 1 } ?? false } ?? false
        if decision != .ignore || (differs && remote.updatedAt != lastLoggedRemote) { lastLoggedRemote = remote.updatedAt; log.notice("""
            chrono distant de \(remote.device.prefix(8), privacy: .public) à \(fmt.string(from: remote.updatedAt), privacy: .public) \
            (session \(remote.state.map { fmt.string(from: $0.sessionStartedAt) } ?? "aucune", privacy: .public), \
            \(remote.state?.isRunning == true ? "en cours" : "arrêté", privacy: .public)) ; \
            ici session \(self.state.map { fmt.string(from: $0.sessionStartedAt) } ?? "aucune", privacy: .public), \
            dernier appliqué \(CloudRelay.lastAppliedTimer.map { fmt.string(from: $0) } ?? "-", privacy: .public) → \
            \(decision == .ignore ? "ignore (autre session)" : (decision == .close ? "ferme" : "adopte"), privacy: .public)
            """) }
        guard decision != .ignore else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        CloudRelay.lastAppliedTimer = remote.updatedAt
        switch decision {
        case .adopt(let remoteState):
            CloudRelay.noteAdopted(remoteState)
            state = remoteState
            commit()
        case .close:
            close()
        case .ignore:
            break
        }
    }

    // MARK: Frontières

    /// La prochaine date où l'état change de lui-même : fin du bloc, de la
    /// pause, du mode étude. Un seul réveil, à cet instant — pas un battement
    /// par seconde.
    private func nextBoundary(after now: Date = Date()) -> Date? {
        guard let state else { return nil }
        var dates: [Date] = []
        if let pause = state.currentBreak { dates.append(pause.endsAt) }
        if let end = state.blockEndDate(settings: settings.pomodoro) { dates.append(end) }
        if let until = state.studyUntil { dates.append(until) }
        return dates.filter { $0 > now }.min()
    }

    private func scheduleBoundary() {
        boundary?.invalidate()
        boundary = nil
        revision &+= 1
        guard let date = nextBoundary() else { return }
        let timer = Timer(fire: date.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachBoundary() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        boundary = timer
    }

    private func reachBoundary() {
        guard var current = state else { return }
        let now = Date()
        let studyEnded = current.studyUntil.map { abs($0.timeIntervalSince(now)) < 1 } ?? false
        let events = current.advance(settings: settings.pomodoro, to: now)
        if events.isEmpty {
            // Fin du mode étude seulement : rien à publier, l'heure suffit.
            scheduleBoundary()
            onChange?()
        } else {
            state = current
            commit(publish: false)
        }
        guard settings.sounds else { return }
        if studyEnded {
            NSSound(named: "Funk")?.play()
        } else if let last = events.last {
            switch last {
            case .blockEnded: NSSound(named: "Glass")?.play()
            case .breakEnded: NSSound(named: "Hero")?.play()
            }
        }
    }

    // MARK: Notifications

    private func scheduleNotifications() {
        cancelNotifications()
        guard let state else { return }
        let center = UNUserNotificationCenter.current()
        if let until = state.studyUntil, until.timeIntervalSinceNow > 1 {
            let content = UNMutableNotificationContent()
            content.title = "Mode étude terminé"
            content.body = "Tout est rouvert. Termine la session pour l'enregistrer, ou prolonge."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "mac.study", content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: until.timeIntervalSinceNow, repeats: false)))
        }
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
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["mac.break", "mac.block", "mac.study"])
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
