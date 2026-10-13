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

    /// Le temps déjà passé sur les cibles **précédentes** de la session.
    ///
    /// On fait une série exercice après exercice, sans arrêter le chrono entre
    /// deux : une heure notée « Exercices sur MATH-101 » ne disait pas que 3.2 a
    /// pris quarante minutes et 3.3 dix. Chaque changement de cible clôt un
    /// segment ; « Terminer » enregistre une session par cible.
    ///
    /// Optionnels, comme tout ce qui a été ajouté après coup : un état écrit par
    /// une version précédente se relit, et « aucun segment » est `nil`.
    var segments: [FocusSegment]?
    /// Temps compté au moment où la cible actuelle a commencé.
    var currentTargetSince: TimeInterval?
    /// Mode étude : jusqu'à cette date, chaque appareil n'ouvre que ce qui sert
    /// à travailler (Moodle, Claude, GoodNotes…). Voyage avec l'état du chrono :
    /// lancé sur le Mac, il verrouille aussi l'iPhone. `nil` : pas de mode étude.
    var studyUntil: Date?
    /// Le début du mode étude (l'anneau de l'écran se remplit de là à `studyUntil`).
    var studySince: Date?
    /// Le mode étude bloque-t-il le reste (apps, sites) ? `false` : un simple
    /// écran de travail, rien n'est fermé. `nil` vaut oui — les états publiés
    /// avant ce champ, et un appareil plus ancien qui l'ignore, bloquent.
    var studyLocks: Bool?
    /// Les durées du cycle Pomodoro **de cette session**, fixées par l'appareil
    /// qui l'a démarrée et publiées avec elle.
    ///
    /// Chaque appareil lisait ses propres réglages : un Mac en 50/10 et un
    /// iPhone en 25/5 ne coupaient pas le bloc au même instant, et l'îlot (bâti
    /// par le Mac) contredisait l'app. `nil` : un état publié avant ce champ —
    /// les réglages de l'appareil s'appliquent, comme avant.
    var cycle: PomodoroSettings?
    /// La session de groupe à laquelle ce chrono est lié, s'il l'est : son
    /// horloge (marche, pause, pauses Pomodoro) est celle du groupe.
    var groupSession: GroupSessionLink?

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

    /// Les durées du cycle de la session, sinon celles de l'appareil.
    func cycle(or local: PomodoroSettings) -> PomodoroSettings { cycle ?? local }

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

    // MARK: Segments

    /// Change de cours, de type ou de cible **sans** couper le chrono : le temps
    /// passé sur la cible précédente devient un segment.
    ///
    /// Rien ne change si la cible est la même — cocher une question n'ouvre pas
    /// un segment de plus.
    mutating func switchContext(courseID: UUID?, taskTypeRaw: String, targetID: UUID?, at now: Date = Date()) {
        guard courseID != self.courseID || taskTypeRaw != self.taskTypeRaw || targetID != self.targetID else { return }
        let total = elapsed(at: now)
        let since = min(currentTargetSince ?? 0, total)
        let spent = total - since
        if spent >= 1 {
            var list = segments ?? []
            list.append(FocusSegment(courseID: self.courseID, taskTypeRaw: self.taskTypeRaw,
                                     targetID: self.targetID, seconds: spent))
            segments = list
        }
        currentTargetSince = total
        self.courseID = courseID
        self.taskTypeRaw = taskTypeRaw
        self.targetID = targetID
    }

    /// Temps passé sur la cible **actuelle** depuis qu'elle l'est.
    func currentTargetElapsed(at now: Date = Date()) -> TimeInterval {
        max(0, elapsed(at: now) - min(currentTargetSince ?? 0, elapsed(at: now)))
    }

    /// La répartition du temps de la session, cible par cible, dans l'ordre.
    ///
    /// Deux passages sur la même cible (3.2, 3.3, retour à 3.2) sont fusionnés.
    /// Si le total a été corrigé **à la baisse** sous la somme des segments, ils
    /// sont réduits en proportion : la somme des sessions enregistrées est
    /// toujours exactement le temps affiché.
    func allocation(at now: Date = Date()) -> [FocusSegment] {
        let total = elapsed(at: now)
        var parts = segments ?? []
        let prior = parts.reduce(0) { $0 + $1.seconds }
        if prior > total, prior > 0 {
            let factor = total / prior
            parts = parts.map { var part = $0; part.seconds *= factor; return part }
        }
        let used = parts.reduce(0) { $0 + $1.seconds }
        parts.append(FocusSegment(courseID: courseID, taskTypeRaw: taskTypeRaw,
                                  targetID: targetID, seconds: max(0, total - used)))
        var merged: [FocusSegment] = []
        for part in parts {
            if let index = merged.firstIndex(where: { $0.sameTarget(as: part) }) {
                merged[index].seconds += part.seconds
            } else {
                merged.append(part)
            }
        }
        return merged.filter { $0.seconds >= 1 }
    }

    /// Les durées **entières** à enregistrer, dont la somme vaut le total arrondi.
    ///
    /// Arrondir chaque segment séparément perdait ou inventait des secondes.
    func allocatedSeconds(at now: Date = Date()) -> [(segment: FocusSegment, seconds: Int)] {
        let parts = allocation(at: now)
        let total = Int(elapsed(at: now))
        var result: [(FocusSegment, Int)] = []
        var assigned = 0
        for (index, part) in parts.enumerated() {
            let seconds = index == parts.count - 1 ? max(0, total - assigned) : Int(part.seconds.rounded(.down))
            assigned += seconds
            result.append((part, seconds))
        }
        return result.filter { $0.1 >= 1 }
    }
}

/// Un morceau de session passé sur une cible précise.
struct FocusSegment: Codable, Equatable {
    var courseID: UUID?
    var taskTypeRaw: String
    var targetID: UUID?
    var seconds: TimeInterval
    /// Le temps d'une session de groupe **avant** qu'on la rejoigne : compté par
    /// l'horloge commune, jamais enregistré pour soi. Optionnel (états d'avant).
    var excluded: Bool? = nil

    var taskType: TaskType { TaskType(rawValue: taskTypeRaw) ?? .other }

    func sameTarget(as other: FocusSegment) -> Bool {
        courseID == other.courseID && taskTypeRaw == other.taskTypeRaw && targetID == other.targetID
            && (excluded ?? false) == (other.excluded ?? false)
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

extension FocusTimerState {
    /// L'instant de référence des secondes affichées.
    ///
    /// Le temps compté change de seconde à des instants précis (quand
    /// `elapsed` passe un entier ; une pause, à `breakEndsAt` moins un nombre
    /// entier de secondes). Rafraîchir **sur ces frontières** — et non toutes
    /// les secondes depuis l'ouverture de l'écran — fait changer l'iPhone et le
    /// Mac à la même seconde. Les 50 ms évitent de tomber pile sur la frontière
    /// (et d'afficher la seconde d'avant par arrondi).
    var tickAnchor: Date {
        let anchor: Date
        if let end = breakEndsAt {
            anchor = end
        } else if let since = runningSince {
            anchor = since.addingTimeInterval(-accumulated)
        } else {
            anchor = sessionStartedAt
        }
        return anchor.addingTimeInterval(0.05)
    }

    /// Pour un `TimelineView(.periodic(from:by:))` : l'ancre de la session, ou maintenant.
    static func tickAnchor(_ state: FocusTimerState?) -> Date {
        state?.tickAnchor ?? Date()
    }
}



// MARK: - Session de groupe

/// Le lien d'un chrono à une session de groupe.
struct GroupSessionLink: Codable, Equatable {
    var sessionID: String
    var groupID: String
    var groupName: String
}

/// L'horloge **commune** d'une session de groupe : ce qui se partage (la
/// marche, les pauses, le cycle Pomodoro), sans ce qui est à chacun (le cours,
/// l'exercice, la note). Tous les chronos liés ont la même : les blocs et les
/// pauses tombent au même instant chez tout le monde.
struct GroupClock: Codable, Equatable {
    var sessionStartedAt: Date
    var accumulated: TimeInterval
    var runningSince: Date?
    var pomodoro: Bool
    var cycle: PomodoroSettings?
    var breakKindRaw: String?
    var breakStartedAt: Date?
    var breakEndsAt: Date?

    init(_ state: FocusTimerState) {
        sessionStartedAt = state.sessionStartedAt
        accumulated = state.accumulated
        runningSince = state.runningSince
        pomodoro = state.pomodoro
        cycle = state.cycle
        breakKindRaw = state.breakKindRaw
        breakStartedAt = state.breakStartedAt
        breakEndsAt = state.breakEndsAt
    }

    /// Le temps compté par l'horloge à l'instant `now`.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Pose l'horloge sur un chrono, sans toucher à son cours, sa cible ni ses
    /// segments.
    func apply(to state: inout FocusTimerState) {
        state.sessionStartedAt = sessionStartedAt
        state.accumulated = accumulated
        state.runningSince = runningSince
        state.pomodoro = pomodoro
        state.cycle = cycle
        state.breakKindRaw = breakKindRaw
        state.breakStartedAt = breakStartedAt
        state.breakEndsAt = breakEndsAt
    }

    /// Le chrono de quelqu'un qui **rejoint** la session maintenant : l'horloge
    /// du groupe, son propre travail, et le temps déjà écoulé mis de côté (il
    /// n'a pas travaillé avant d'arriver).
    func joining(link: GroupSessionLink, courseID: UUID?, taskTypeRaw: String, targetID: UUID?,
                 at now: Date = Date()) -> FocusTimerState {
        var state = FocusTimerState(sessionStartedAt: sessionStartedAt, courseID: courseID,
                                    taskTypeRaw: taskTypeRaw, targetID: targetID, pomodoro: pomodoro)
        apply(to: &state)
        let before = elapsed(at: now)
        if before >= 1 {
            state.segments = [FocusSegment(courseID: nil, taskTypeRaw: TaskType.other.rawValue, targetID: nil,
                                           seconds: before, excluded: true)]
        }
        state.currentTargetSince = before
        state.groupSession = link
        return state
    }
}
