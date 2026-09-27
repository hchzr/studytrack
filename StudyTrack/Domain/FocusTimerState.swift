import Foundation

/// L'état du chrono, tel qu'il survit à une fermeture de l'app.
///
/// Le chrono vivait en mémoire, dans l'écran Focus : une app tuée par le système
/// (ou par l'étudiant·e, par réflexe) perdait la session en cours — une heure de
/// travail réel, disparue sans un mot. Ce type **valeur** est écrit à chaque
/// changement d'état (démarrage, pause, reprise) et relu au lancement suivant : le
/// temps écoulé se déduit des dates, pas d'un compteur qui aurait dû tourner.
struct FocusTimerState: Codable, Equatable {
    /// Secondes accumulées avant la période en cours.
    var accumulated: TimeInterval
    /// Début de la période en cours ; `nil` quand le chrono est en pause.
    var runningSince: Date?
    /// Premier démarrage de la session (sert au journal et à la présence).
    var sessionStartedAt: Date
    var courseID: UUID?
    var taskTypeRaw: String
    var targetID: UUID?
    var note: String
    var contextLabel: String
    var pomodoro: Bool
    /// Pause Pomodoro en cours : son type et ses bornes.
    ///
    /// Optionnels : un état écrit par une version précédente se relit, et
    /// « pas de pause » est exactement `nil`.
    var breakKindRaw: String?
    var breakStartedAt: Date?
    var breakEndsAt: Date?

    init(accumulated: TimeInterval = 0,
         runningSince: Date? = nil,
         sessionStartedAt: Date = Date(),
         courseID: UUID? = nil,
         taskTypeRaw: String = TaskType.exercise.rawValue,
         targetID: UUID? = nil,
         note: String = "",
         contextLabel: String = "",
         pomodoro: Bool = false) {
        self.accumulated = accumulated
        self.runningSince = runningSince
        self.sessionStartedAt = sessionStartedAt
        self.courseID = courseID
        self.taskTypeRaw = taskTypeRaw
        self.targetID = targetID
        self.note = note
        self.contextLabel = contextLabel
        self.pomodoro = pomodoro
    }

    var isRunning: Bool { runningSince != nil }

    var taskType: TaskType { TaskType(rawValue: taskTypeRaw) ?? .other }

    /// Secondes écoulées à l'instant `now`.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Une session restaurée trop ancienne n'est plus une session : un chrono
    /// oublié pendant trois jours ne vaut pas 72 h de travail.
    static let maxRestorableAge: TimeInterval = 18 * 3600

    /// Faut-il proposer cette session à la reprise ?
    ///
    /// Une pause en cours compte comme une session vivante, même au tout
    /// premier bloc : le chrono est arrêté, mais la session ne l'est pas.
    func isRestorable(at now: Date = Date()) -> Bool {
        (elapsed(at: now) >= 1 || breakEndsAt != nil)
            && now.timeIntervalSince(sessionStartedAt) < Self.maxRestorableAge
    }

    /// Reprendre le travail met fin à toute pause Pomodoro en cours.
    mutating func start(at now: Date = Date()) {
        breakKindRaw = nil
        breakStartedAt = nil
        breakEndsAt = nil
        guard runningSince == nil else { return }
        runningSince = now
    }

    mutating func pause(at now: Date = Date()) {
        guard let since = runningSince else { return }
        accumulated += max(0, now.timeIntervalSince(since))
        runningSince = nil
    }
}

/// Persistance du chrono dans `UserDefaults`.
///
/// Séparée de l'état pour que la logique (`FocusTimerState`) reste testable sans
/// toucher au disque.
enum FocusTimerStore {
    static let key = "focus.timerState"
    /// Posté à chaque écriture : le bandeau « chrono en cours » suit l'état
    /// sans que l'écran Focus soit ouvert.
    static let didSave = Notification.Name("studytrack.focusTimerDidSave")

    static func load(defaults: UserDefaults = .standard) -> FocusTimerState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FocusTimerState.self, from: data)
    }

    static func save(_ state: FocusTimerState?, defaults: UserDefaults = .standard) {
        defer { NotificationCenter.default.post(name: didSave, object: nil) }
        guard let state else {
            defaults.removeObject(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: key)
        }
    }
}
