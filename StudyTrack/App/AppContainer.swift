import Foundation
import SwiftData
import Observation

/// Conteneur de dépendances de l'app (persistance + réglages + services + navigation).
@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer
    let settings: SettingsStore
    let notifications: NotificationScheduler
    let social: SocialService
    let router: AppRouter
    /// Présence en direct dans les groupes (« untel travaille sur CS-250 »).
    let presence: PresenceService
    /// Le chrono : un seul, partagé par Focus, le dock et l'écran verrouillé.
    let focus: FocusController
    /// L'import du semestre de l'accueil : détenu ici, pas par l'écran, pour
    /// qu'il continue quand on quitte l'accueil ou que l'app passe en arrière-plan.
    let semesterImport = OnboardingAutoSetup()

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

    /// Pourquoi la base n'a pas pu être ouverte, s'il y a lieu.
    ///
    /// Le conteneur retombait **en silence** sur une base en mémoire quand
    /// l'ouverture échouait : l'app fonctionnait, mais rien ne se conservait d'un
    /// lancement à l'autre, et personne ne pouvait le savoir. Un échec de
    /// persistance doit se voir.
    let storeError: String?

    /// Le conteneur iCloud de l'app (base privée de l'étudiant·e).
    static let cloudContainerID = "iCloud.com.hczr.studytrack.app"

    /// Vrai quand la base est synchronisée avec iCloud (iPhone, iPad, Mac).
    let isCloudSynced: Bool

    init() {
        let schema = StudyTrackSchema.current
        var failure: String?
        var synced = false

        // D'abord synchronisée par iCloud ; à défaut (build sans les droits
        // iCloud, simulateur non signé), la même base, locale. `.none` est
        // explicite : `.automatic` activerait iCloud à l'insu du code.
        let cloud = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                       cloudKitDatabase: .private(Self.cloudContainerID))
        let local = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        var cloudError: String?
        var cloudContainer: ModelContainer?
        #if NO_CLOUDKIT
        // Build non signée (`build.sh`, captures du simulateur) : sans le droit
        // iCloud, CloudKit arrête l'app au lieu de lever une erreur.
        cloudError = "build sans iCloud"
        _ = cloud
        #else
        do {
            cloudContainer = try ModelContainer(for: schema, migrationPlan: StudyTrackMigrationPlan.self,
                                                configurations: [cloud])
        } catch {
            cloudError = String(describing: error)
        }
        #endif
        if let cloudContainer {
            self.modelContainer = cloudContainer
            synced = true
        } else if let container = try? ModelContainer(for: schema, migrationPlan: StudyTrackMigrationPlan.self,
                                                      configurations: [local]) {
            self.modelContainer = container
            AppLog.record(.info, AppLog.Category.storage, "iCloud indisponible : base locale", detail: cloudError ?? "")
        } else {
            // Dernier essai **sans** le plan : un plan mal formé ne doit pas
            // empêcher l'app de démarrer, mais l'échec est retenu et affiché.
            if let fallback = try? ModelContainer(for: schema, configurations: [local]) {
                self.modelContainer = fallback
                failure = "La migration du schéma a échoué ; la base a été ouverte sans plan de migration."
            } else {
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                self.modelContainer = try! ModelContainer(for: schema, configurations: [memory])
                failure = "La base n'a pas pu être ouverte : cette session ne sera pas conservée."
            }
        }
        self.isCloudSynced = synced
        self.storeError = failure
        if let failure {
            AppLog.record(.error, AppLog.Category.storage, "Base de données", detail: failure)
        }

        let settings = SettingsStore()
        self.settings = settings
        self.notifications = NotificationScheduler()

        // La configuration vient de la **build**, jamais des réglages : l'étudiant·e
        // n'a pas à connaître l'URL du projet ni la clé anonyme, qui est publique
        // par conception (elle n'autorise que ce que les politiques RLS permettent).
        self.social = SocialService(urlString: SupabaseConfig.urlString,
                                    anonKey: SupabaseConfig.anonKey)
        self.router = AppRouter()
        self.presence = PresenceService()
        self.focus = FocusController()

        // Réparations de données, nommées et jouées une fois par version.
        let repairContext = ModelContext(self.modelContainer)
        DataRepair.run(in: repairContext)
        // Les doublons arrivés d'un autre appareil (ou laissés par une
        // synchronisation interrompue) sont fusionnés dès l'ouverture.
        PreviewSeedCleanup.run(in: repairContext)
        let merged = SyncDeduplicator.run(in: repairContext)
        if merged.total > 0 {
            AppLog.record(.info, AppLog.Category.storage, "Doublons iCloud fusionnés", detail: merged.summary)
        }
        focus.app = self
        focus.startRelay()
        // La voie instantanée du chrono partagé (moins d'une seconde, apps ouvertes).
        if isCloudSynced { TimerLink.shared.startFromBundle(containerID: Self.cloudContainerID) }
        // Les jetons APNs de l'îlot vont au relais : le Mac peut alors le
        // mettre à jour sur l'écran verrouillé.
        StudyActivityController.observePushTokens()
    }

    /// Reconfigure le client social — utile après une connexion ou une déconnexion.
    func reloadSocial() {
        social.configure(urlString: SupabaseConfig.urlString, anonKey: SupabaseConfig.anonKey)
    }
}
