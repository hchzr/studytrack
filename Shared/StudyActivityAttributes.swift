import Foundation
import ActivityKit

/// État partagé entre l'app et la Live Activity du chrono.
///
/// Le chrono ne vit pas dans SwiftData : il est tenu par l'écran Focus, en mémoire.
/// La Live Activity reçoit donc exactement ce qu'il lui faut pour s'afficher, et
/// rien de plus — l'extension ne doit jamais avoir à lire la base.
struct StudyActivityAttributes: ActivityAttributes {

    /// Ce qui change pendant la session.
    ///
    /// Le calcul du temps vit dans `ActivityTimerState`, qui est **pur** et donc
    /// testable sans ActivityKit. Ce type ne fait que le transporter.
    public typealias ContentState = ActivityTimerState

    /// Ce qui ne change pas de la session.
    var courseCode: String
    var courseName: String
    var taskLabel: String
    /// Symbole SF du type de travail, pour l'îlot dynamique.
    var taskIcon: String
    /// Sur quoi porte la session, s'il a été précisé (« Exercice 3.2 »).
    var target: String?
}
