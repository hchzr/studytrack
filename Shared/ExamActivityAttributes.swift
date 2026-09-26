import Foundation
import ActivityKit

/// La Live Activity du jour d'examen.
///
/// Séparée de celle du chrono, et non un cas de plus dans son état : les deux
/// peuvent vivre **en même temps** — on révise, chrono lancé, le matin de
/// l'examen —, et une activité ne sait afficher qu'une chose à la fois. Deux types
/// d'attributs donnent deux activités indépendantes, que le système place et
/// termine séparément.
struct ExamActivityAttributes: ActivityAttributes {
    /// La logique vit dans `ExamActivityState`, qui est **pur** et donc testable
    /// sans ActivityKit. Ce type ne fait que le transporter.
    typealias ContentState = ExamActivityState

    var courseCode: String
    var courseName: String
    /// « Midterm », « Examen final ».
    var title: String
    /// Le début de l'épreuve. Dans les attributs, pas dans l'état : une date
    /// d'examen ne bouge pas pendant la journée, et le compte à rebours se dessine
    /// à partir d'elle sans que l'app envoie quoi que ce soit.
    var examDate: Date
    /// La salle, si elle est connue — l'information qu'on cherche en arrivant.
    var room: String?
}
