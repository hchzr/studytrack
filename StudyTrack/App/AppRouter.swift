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
    /// Quatre onglets. Focus n'en est plus un : c'est une **action**, disponible
    /// partout par le bouton flottant au-dessus de la barre — et, pendant une
    /// session, le mini-lecteur qui la montre.
    enum Tab: Int, Hashable, CaseIterable {
        // L'ordre de déclaration est l'ordre de la barre d'onglets : l'agenda
        // (quotidien) avant les groupes (troisième raison d'être de l'app). Les
        // valeurs brutes, elles, ne bougent pas — liens et captures en dépendent
        // (2 était Focus).
        case today = 0
        case courses = 1
        case agenda = 4
        case groups = 3

        var title: String {
            switch self {
            case .today: return "Aujourd'hui"
            case .courses: return "Cours"
            case .groups: return "Groupes"
            case .agenda: return "Agenda"
            }
        }

        var icon: String {
            switch self {
            case .today: return "sun.max.fill"
            case .courses: return "books.vertical.fill"
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

    /// L'écran Focus (chrono, saisie, journal), en feuille au-dessus de l'onglet.
    var showingFocus = false
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

    /// Élément partagé depuis une autre app (extension de partage), en attente.
    var pendingImport: PendingImport?

    /// Raccourci demandé depuis l'écran d'accueil d'iOS, en attente de traitement.
    ///
    /// Le routeur le porte ; l'écran qui sait quoi en faire le consomme.
    var shortcut: ShortcutAction?

    func startFocus(courseID: UUID?, courseCode: String, taskType: TaskType, label: String) {
        focusRequest = FocusRequest(courseID: courseID,
                                    courseCode: courseCode,
                                    taskType: taskType,
                                    label: label)
        showingFocus = true
    }

    /// Ouvre Focus sur un segment (« Manuel », « Journal »).
    func openFocus(_ mode: FocusMode? = nil) {
        focusMode = mode
        showingFocus = true
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
