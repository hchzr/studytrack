import Foundation
import Observation

/// Demande de démarrage d'un chrono, émise depuis n'importe quel écran.
struct FocusRequest: Equatable {
    var courseID: UUID?
    var courseCode: String
    var taskType: TaskType
    var label: String
}

/// Navigation applicative partagée (onglet actif, demandes de chrono, feuilles).
@Observable
final class AppRouter {
    enum Tab: Int, Hashable, CaseIterable {
        case today = 0
        case courses = 1
        case focus = 2
        case groups = 3
        case agenda = 4

        var title: String {
            switch self {
            case .today: return "Aujourd'hui"
            case .courses: return "Cours"
            case .focus: return "Focus"
            case .groups: return "Groupes"
            case .agenda: return "Agenda"
            }
        }

        var icon: String {
            switch self {
            case .today: return "sun.max.fill"
            case .courses: return "books.vertical.fill"
            case .focus: return "timer"
            case .groups: return "person.3.fill"
            case .agenda: return "calendar"
            }
        }
    }

    var selectedTab: Tab = .today

    /// Chrono demandé depuis un autre écran (ex. « Regarder la vidéo 2.1 »).
    var focusRequest: FocusRequest?
    /// Segment de Focus demandé (« Manuel » depuis les actions rapides).
    var focusMode: FocusMode?

    enum FocusMode { case timer, manual, journal }

    var showingProfile = false
    var showingTasks = false
    /// Statistiques et récapitulatif, ouverts depuis « Aujourd'hui ».
    var showingStats = false

    /// Code d'invitation reçu par lien profond (`studytrack://join?code=EPFL-XXXX`).
    ///
    /// Consommé par l'onglet Groupes, qui ouvre alors la feuille « Rejoindre » déjà
    /// remplie. Sans ça, cliquer sur un lien d'invitation ouvrirait l'app… sans rien
    /// faire, ce qui est pire que de ne pas proposer de lien du tout.
    var pendingJoinCode: String?

    func startFocus(courseID: UUID?, courseCode: String, taskType: TaskType, label: String) {
        focusRequest = FocusRequest(courseID: courseID,
                                    courseCode: courseCode,
                                    taskType: taskType,
                                    label: label)
        selectedTab = .focus
    }

    func consumeFocusRequest() -> FocusRequest? {
        defer { focusRequest = nil }
        return focusRequest
    }

    /// Demande l'ouverture de la feuille d'adhésion, pré-remplie.
    func startJoin(code: String) {
        pendingJoinCode = StudyGroup.normalizeInviteCode(code)
        selectedTab = .groups
    }

    func consumeJoinCode() -> String? {
        defer { pendingJoinCode = nil }
        return pendingJoinCode
    }
}
