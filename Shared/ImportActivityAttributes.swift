import Foundation
import ActivityKit

/// La Live Activity de l'import du semestre (accueil).
///
/// Un import dure une à trois minutes : l'étudiant·e passe à autre chose, verrouille
/// son téléphone. L'avancement reste visible dans l'îlot dynamique et sur l'écran
/// verrouillé — et, si iOS suspend l'app avant la fin, l'activité le dit
/// (« en pause : rouvre l'app ») au lieu de montrer un pourcentage figé.
struct ImportActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// De 0 à 1.
        var fraction: Double
        /// « MATH-101 », le cours en cours de lecture.
        var courseCode: String
        /// « lecture des activités 18 / 34 ».
        var step: String
        var coursesDone: Int
        var coursesTotal: Int
        /// L'heure de fin estimée (pour un compte à rebours dessiné par le système).
        var estimatedEnd: Date?
        var phase: Phase

        enum Phase: String, Codable, Hashable {
            case running, paused, done
        }
    }

    /// Les couleurs des cours, dans l'ordre (hex), pour l'anneau.
    var colors: [String]
}
