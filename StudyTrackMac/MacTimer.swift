import Foundation
import Observation
import SwiftData
import UserNotifications

/// Le chrono du Mac, dans la barre des menus.
///
/// Une session terminée devient une `StudySession`, enregistrée dans la base
/// partagée : iCloud la porte sur l'iPhone, où elle compte dans le bilan, les
/// widgets et les groupes comme une session du téléphone.
///
/// L'état est gardé à chaque geste : quitter l'app (ou redémarrer le Mac)
/// pendant une session ne la perd pas.
@MainActor
@Observable
final class MacTimer {
    enum Phase: String, Codable { case idle, running, paused }

    private struct Saved: Codable {
        var phase: Phase
        var courseID: UUID?
        var taskTypeRaw: String
        var sessionStart: Date?
        var segmentStart: Date?
        var accumulated: TimeInterval
        var pomodoro: Bool
    }

    private(set) var phase: Phase = .idle
    var courseID: UUID? { didSet { persist() } }
    var taskType: TaskType = .exercise { didSet { persist() } }
    var pomodoro = false { didSet { persist() } }
    /// Minutes d'un bloc Pomodoro.
    var pomodoroMinutes = 25

    private var sessionStart: Date?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    /// Avance d'une seconde pendant que le chrono tourne ; la barre des menus
    /// s'y abonne.
    private(set) var now = Date()
    @ObservationIgnored private var ticker: Timer?

    private static let key = "mac.timer"
    private static let pomodoroNotification = "mac.pomodoro"

    init() {
        restore()
    }

    var elapsed: TimeInterval {
        accumulated + (phase == .running ? max(0, now.timeIntervalSince(segmentStart ?? now)) : 0)
    }

    /// Ce qui reste du bloc Pomodoro (`nil` hors Pomodoro).
    var pomodoroRemaining: TimeInterval? {
        guard pomodoro, phase != .idle else { return nil }
        return max(0, TimeInterval(pomodoroMinutes * 60) - elapsed)
    }

    // MARK: Gestes

    func start() {
        guard phase == .idle else { return }
        let date = Date()
        sessionStart = date
        segmentStart = date
        accumulated = 0
        now = date
        phase = .running
        persist()
        tick()
        schedulePomodoro()
    }

    func pause() {
        guard phase == .running else { return }
        now = Date()
        accumulated = elapsed
        segmentStart = nil
        phase = .paused
        persist()
        tick()
        cancelPomodoro()
    }

    func resume() {
        guard phase == .paused else { return }
        segmentStart = Date()
        now = Date()
        phase = .running
        persist()
        tick()
        schedulePomodoro()
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    /// Termine et enregistre. Moins d'une minute ne compte pas : c'était un
    /// faux départ, pas une session.
    @discardableResult
    func stop(context: ModelContext) -> StudySession? {
        guard phase != .idle else { return nil }
        now = Date()
        let seconds = Int(elapsed)
        let start = sessionStart ?? Date().addingTimeInterval(-elapsed)
        reset()
        guard seconds >= 60 else { return nil }
        let course = courseID.flatMap { id in
            (try? context.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })))?.first
        }
        let session = StudySession(course: course, taskType: taskType, startedAt: start, durationSeconds: seconds)
        context.insert(session)
        try? context.save()
        return session
    }

    func discard() {
        reset()
    }

    private func reset() {
        phase = .idle
        sessionStart = nil
        segmentStart = nil
        accumulated = 0
        persist()
        tick()
        cancelPomodoro()
    }

    // MARK: Battement

    /// Une seconde, seulement quand le chrono tourne : au repos, rien ne
    /// réveille le processeur.
    private func tick() {
        ticker?.invalidate()
        ticker = nil
        guard phase == .running else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: Pomodoro

    private func schedulePomodoro() {
        cancelPomodoro()
        guard pomodoro, let remaining = pomodoroRemaining, remaining > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Bloc terminé"
        content.body = "\(pomodoroMinutes) min de travail. Une pause ?"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.pomodoroNotification,
                                                                     content: content, trigger: trigger))
    }

    private func cancelPomodoro() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.pomodoroNotification])
    }

    // MARK: Mémoire

    private func persist() {
        let saved = Saved(phase: phase, courseID: courseID, taskTypeRaw: taskType.rawValue,
                          sessionStart: sessionStart, segmentStart: segmentStart,
                          accumulated: accumulated, pomodoro: pomodoro)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        phase = saved.phase
        courseID = saved.courseID
        taskType = TaskType(rawValue: saved.taskTypeRaw) ?? .exercise
        sessionStart = saved.sessionStart
        segmentStart = saved.segmentStart
        accumulated = saved.accumulated
        pomodoro = saved.pomodoro
        now = Date()
        tick()
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
