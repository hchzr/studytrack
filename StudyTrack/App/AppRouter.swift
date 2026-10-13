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
    /// Trois onglets, et le chrono à part.
    ///
    /// « Carnet de verre » : Aujourd'hui (travailler), Cours (tout le contenu),
    /// Groupes (ensemble). Moi (bilan, réglages) s'ouvre depuis l'avatar,
    /// l'agenda depuis l'horaire du jour. Le chrono est le rond de
    /// verre à droite de la barre (le rôle « recherche » d'iOS 26 le détache) :
    /// le toucher ouvre Focus par-dessus l'onglet courant, sans le quitter.
    enum Tab: Int, Hashable, CaseIterable {
        // Les valeurs brutes ne bougent pas — liens et captures en dépendent
        // (4 était l’agenda, 5 Moi).
        case today = 0
        case courses = 1
        case groups = 3
        case focus = 2

        var title: String {
            switch self {
            case .today: return "Aujourd'hui"
            case .courses: return "Cours"
            case .groups: return "Groupes"
            case .focus: return "Chrono"
            }
        }

        var icon: String {
            switch self {
            case .today: return "sun.max"
            case .courses: return "books.vertical"
            case .groups: return "person.2"
            case .focus: return "timer"
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
    /// L'écran plein du mode étude (lancé ici ou adopté du Mac).
    var showingStudyMode = false
    /// L'agenda complet, en feuille (depuis l'horaire du jour, une évaluation…).
    var showingAgenda = false
    /// « Moi » (bilan de la semaine, réglages) : une feuille ouverte depuis
    /// l'avatar d'« Aujourd'hui », plus un onglet.
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
        showingAgenda = true
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
