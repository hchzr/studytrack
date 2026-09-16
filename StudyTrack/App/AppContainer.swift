import Foundation
import SwiftData
import Observation

/// Conteneur de dépendances de l'app (persistance + réglages + services + navigation).
@Observable
final class AppContainer {
    let modelContainer: ModelContainer
    let settings: SettingsStore
    let notifications: NotificationScheduler
    let social: SocialService
    let router: AppRouter
    /// Présence en direct dans les groupes (« untel travaille sur CS-250 »).
    let presence: PresenceService

    @ObservationIgnored private var cachedCalendar: CalendarService? = nil

    /// Construit le service de calendrier à la première utilisation réelle.
    ///
    /// `EKEventStore()` charge les métadonnées des calendriers à l'initialisation.
    /// Le construire dans `init()` faisait donc payer ce coût **au lancement, sur le
    /// fil principal, à tout le monde** — y compris aux utilisateurs qui ne touchent
    /// jamais au calendrier. Les trois appelants (`AgendaView`, `GroupsView`,
    /// `ProfileView`) y accèdent depuis un geste ou une tâche explicites.
    var calendar: CalendarService {
        if let cachedCalendar { return cachedCalendar }
        let service = EventKitCalendarService()
        cachedCalendar = service
        return service
    }

    init() {
        let schema = Schema([
            AcademicTerm.self,
            Course.self,
            TheoryItem.self,
            ExerciseSeries.self,
            Exercise.self,
            StudySession.self,
            Exam.self,
            PlannedSession.self,
            LinkedTask.self,
            LinkedCalendarEvent.self,
            StudyGroup.self,
            GroupMember.self,
            GroupSeriesCompletion.self,
            GroupItemCompletion.self
        ])

        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            self.modelContainer = container
        } else {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            self.modelContainer = try! ModelContainer(for: schema, configurations: [memory])
        }

        let settings = SettingsStore()
        self.settings = settings
        self.notifications = NotificationScheduler()

        // Réparation : les cours importés par l'horaire avant la correction n'ont
        // aucun semestre, donc affichaient « semaine 1 » en pleine semaine 2. Ce
        // rattachement est idempotent et ne touche jamais un cours déjà rattaché.
        let repairContext = ModelContext(self.modelContainer)
        AcademicTerm.attachOrphanCourses(in: repairContext)
        // La configuration vient de la **build**, jamais des réglages : l'étudiant·e
        // n'a pas à connaître l'URL du projet ni la clé anonyme, qui est publique
        // par conception (elle n'autorise que ce que les politiques RLS permettent).
        self.social = SocialService(urlString: SupabaseConfig.urlString,
                                    anonKey: SupabaseConfig.anonKey)
        self.router = AppRouter()
        self.presence = PresenceService()
    }

    /// Reconfigure le client social — utile après une connexion ou une déconnexion.
    func reloadSocial() {
        social.configure(urlString: SupabaseConfig.urlString, anonKey: SupabaseConfig.anonKey)
    }
}
