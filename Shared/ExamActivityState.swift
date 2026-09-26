import Foundation

/// Où en est la journée d'examen.
///
/// **Type pur, sans ActivityKit**, comme `ActivityTimerState` : c'est ici que se
/// trouve la seule vraie logique — quand l'activité s'ouvre, quand elle se ferme,
/// et ce qu'elle raconte à chaque étape. Elle se teste donc sur macOS, sans
/// simulateur ni écran verrouillé.
struct ExamActivityState: Codable, Hashable {
    enum Phase: String, Codable, Hashable {
        /// L'épreuve n'a pas commencé : compte à rebours.
        case upcoming
        /// L'épreuve est en cours.
        case running
        /// L'épreuve est passée : l'activité s'efface.
        case over
    }

    var phase: Phase

    /// Durée supposée d'une épreuve, faute de mieux.
    ///
    /// Le modèle `Exam` ne porte pas de durée : on ne peut donc pas annoncer « il
    /// reste 40 min d'épreuve ». Trois heures couvrent un examen EPFL classique, et
    /// ne servent qu'à savoir quand **retirer** l'activité de l'écran.
    static let assumedDuration: TimeInterval = 3 * 3600

    /// Combien de temps avant l'épreuve l'activité doit apparaître.
    ///
    /// Douze heures : la veille au soir, quand on prépare ses affaires, et pas
    /// trois jours avant, où un compte à rebours permanent n'est plus une
    /// information mais une pression.
    static let lead: TimeInterval = 12 * 3600

    /// L'activité a-t-elle sa place à l'écran pour cet examen ?
    static func isRelevant(examDate: Date, now: Date = Date()) -> Bool {
        phase(examDate: examDate, now: now) != .over
            && examDate.timeIntervalSince(now) <= lead
    }

    /// La phase de la journée, déduite des dates : rien à tenir à jour.
    static func phase(examDate: Date, now: Date = Date()) -> Phase {
        if now < examDate { return .upcoming }
        if now < examDate.addingTimeInterval(assumedDuration) { return .running }
        return .over
    }

    static func make(examDate: Date, now: Date = Date()) -> ExamActivityState {
        ExamActivityState(phase: phase(examDate: examDate, now: now))
    }
}
