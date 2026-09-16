import Foundation
import ActivityKit

/// État partagé entre l'app et la Live Activity du chrono.
///
/// Le chrono ne vit pas dans SwiftData : il est tenu par l'écran Focus, en mémoire.
/// La Live Activity reçoit donc exactement ce qu'il lui faut pour s'afficher, et
/// rien de plus — l'extension ne doit jamais avoir à lire la base.
struct StudyActivityAttributes: ActivityAttributes {

    /// Ce qui change pendant la session.
    public struct ContentState: Codable, Hashable {
        /// Secondes accumulées avant la période en cours.
        var accumulated: TimeInterval
        /// Début de la période en cours, `nil` quand le chrono est en pause.
        ///
        /// Quand il est présent, l'interface affiche `Text(timerInterval:)` : le
        /// système fait avancer le compteur tout seul, sans qu'on lui envoie une
        /// mise à jour par seconde. C'est ce qui rend la Live Activity gratuite en
        /// batterie et en réseau.
        var runningSince: Date?

        /// Secondes écoulées à cet instant.
        var elapsed: TimeInterval {
            accumulated + (runningSince.map { Date().timeIntervalSince($0) } ?? 0)
        }
    }

    /// Ce qui ne change pas de la session.
    var courseCode: String
    var courseName: String
    var taskLabel: String
    /// Symbole SF du type de travail, pour l'îlot dynamique.
    var taskIcon: String
    /// Sur quoi porte la session, s'il a été précisé (« Exercice 3.2 »).
    var target: String?
}
