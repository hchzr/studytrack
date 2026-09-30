import Foundation
import Observation

/// Demande de chrono, émise depuis n'importe quel écran.
struct FocusRequest: Equatable {
    var courseID: UUID?
    var courseCode: String
    var taskType: TaskType
    /// L'exercice ou l'élément de théorie visé : sans lui, « Travailler sur
    /// 3.2 » enregistrait du temps sur le cours entier.
    var targetID: UUID? = nil
    var label: String
    /// Démarrer tout de suite (un bouton « Démarrer »), ou seulement préparer
    /// Focus sur ce contexte (la bulle flottante) : ouvrir un écran ne doit pas
    /// lancer un chrono qu'on n'a pas demandé.
    var autoStart: Bool = true
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

    /// Un cours à ouvrir depuis un autre onglet (accueil, widget, recherche).
    struct CourseRoute: Equatable {
        var id: UUID
        var section: CourseDetailView.Section
    }
    var courseRoute: CourseRoute?

    /// L'agenda à ouvrir : un jour (« Ta journée » mène à aujourd'hui) et, au
    /// besoin, un cours (les séances d'un cours s'y lisent, filtrées).
    struct AgendaRoute: Equatable {
        var day: Date
        var courseID: UUID?
    }
    var agendaRoute: AgendaRoute?

    func openAgenda(day: Date = Date(), courseID: UUID? = nil) {
        agendaRoute = AgendaRoute(day: day, courseID: courseID)
        selectedTab = .agenda
    }

    /// L'import de contenu (Moodle, Courseware, Botafogo), ouvert depuis
    /// n'importe quel onglet ; `nil` dans la route = choisir le cours à la relecture.
    struct ImportRoute: Identifiable, Equatable {
        let id = UUID()
        var courseID: UUID?
    }
    var contentImport: ImportRoute?

    func openContentImport(courseID: UUID? = nil) {
        contentImport = ImportRoute(courseID: courseID)
    }

    func openCourse(_ id: UUID, section: CourseDetailView.Section = .exercises) {
        selectedTab = .courses
        courseRoute = CourseRoute(id: id, section: section)
    }

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

    /// Démarre le chrono sur ce contexte — pour un bouton qui dit « Démarrer ».
    func startFocus(courseID: UUID?, courseCode: String, taskType: TaskType,
                    targetID: UUID? = nil, label: String) {
        focusRequest = FocusRequest(courseID: courseID,
                                    courseCode: courseCode,
                                    taskType: taskType,
                                    targetID: targetID,
                                    label: label)
        showingFocus = true
    }

    /// Ouvre Focus **prêt** sur ce contexte, sans démarrer : c'est au bouton
    /// « Démarrer » de le faire.
    func prepareFocus(courseID: UUID?, courseCode: String, taskType: TaskType, targetID: UUID? = nil) {
        focusRequest = FocusRequest(courseID: courseID,
                                    courseCode: courseCode,
                                    taskType: taskType,
                                    targetID: targetID,
                                    label: "",
                                    autoStart: false)
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
