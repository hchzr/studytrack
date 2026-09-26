import SwiftUI
import SwiftData

#if DEBUG
/// Arguments de capture pour le simulateur — jamais compilés en Release.
///
/// `xcrun simctl` ne sait pas taper dans l'interface, et ouvrir un lien profond
/// déclenche un « Ouvrir dans StudyTrack ? » qu'on ne peut pas confirmer. Ce sont
/// donc les seuls moyens de rendre l'app **remplie**, un onglet donné, et l'étape
/// « section » de l'accueil — pour les relire sur iPhone **et** sur iPad :
///
///     xcrun simctl launch <udid> com.hczr.studytrack.app -seedSampleData -tab 1
enum PreviewLaunch {
    static let seedFlag = "-seedSampleData"
    static let tabFlag = "-tab"
    static let courseFlag = "-course"
    /// Avec `-course`, ouvre un onglet de la fiche (`theory`, `exercises`,
    /// `progress`, `agenda`).
    static let courseTabFlag = "-courseTab"
    static let onboardingStepFlag = "-onboardingStep"
    static let profileFlag = "-profile"
    /// Ouvre « Statistiques » depuis « Aujourd'hui ».
    static let statsFlag = "-stats"
    /// Index du groupe à ouvrir dans l'onglet Groupes.
    static let groupFlag = "-group"
    /// Avec `-group`, ouvre en plus l'avancement d'une matière (`-groupSubject CODE`).
    static let groupSubjectFlag = "-groupSubject"
    /// Avec `-group`, ouvre une sous-page (`members`, `time`, `series`, `planning`).
    static let groupPageFlag = "-groupPage"
    /// Avec `-group`, ouvre la feuille d'invitation (QR code et lien).
    static let groupInviteFlag = "-groupInvite"
    /// Avec `-group`, ouvre l'éditeur des matières du groupe.
    static let groupSubjectsFlag = "-groupSubjects"
    /// Ouvre « Section et semestre » depuis le profil.
    static let schoolFlag = "-school"
    /// Ouvre « Import intelligent » depuis le profil.
    static let aiImportFlag = "-aiImport"
    /// Avec `-stats`, ouvre en plus « Couverture du suivi ».
    static let coverageFlag = "-coverage"
    /// Avec `-stats`, ouvre en plus « Vie de l'EPFL ».
    static let epflLifeFlag = "-epflLife"
    /// Avec `-course` et l'onglet exercices, ouvre le détail de l'exercice
    /// portant ce numéro (`-exerciseDetail 3.1`).
    static let exerciseDetailFlag = "-exerciseDetail"
    /// Ouvre l'import de série sur ce PDF (`-importFile /chemin/serie4.pdf`).
    static let importFileFlag = "-importFile"
    /// Ouvre la recherche, avec la requête qui suit (`-search cs250`).
    static let searchFlag = "-search"
    /// Active le Pomodoro sur le chrono.
    static let pomodoroFlag = "-pomodoro"
    /// Pré-remplit le chrono de N secondes et le lance (`-timerSeconds 600`).
    static let timerSecondsFlag = "-timerSeconds"
    /// Ouvre l'éditeur de raccourcis du chrono.
    static let shortcutsFlag = "-shortcuts"
    /// Lance l'activité « jour d'examen » sur l'écran verrouillé.
    ///
    /// Elle se déclenche par le **temps** — douze heures avant l'épreuve : sans ce
    /// drapeau, la vérifier demanderait d'attendre la veille d'un vrai examen, ou
    /// de déplacer l'horloge du simulateur.
    static let examActivityFlag = "-examActivity"
    /// **Casse** volontairement le lien cours ↔ semestre, pour vérifier la
    /// réparation du lancement suivant. Outil de diagnostic, pas fonctionnalité.
    static let breakTermFlag = "-breakTermLink"
    /// **Rétrograde** le créateur du groupe à « membre », pour reproduire l'état
    /// migré qui lui retirait ses droits sur son propre groupe.
    static let breakRoleFlag = "-breakGroupRole"

    static func isSet(_ flag: String) -> Bool {
        CommandLine.arguments.contains(flag)
    }

    /// Valeur entière qui suit `flag`, si elle est présente et lisible.
    static func int(_ flag: String) -> Int? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return Int(CommandLine.arguments[index + 1])
    }

    /// Valeur textuelle qui suit `flag`.
    static func string(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Ouvre l'onglet demandé, et installe le semestre d'exemple si `-seedSampleData`.
    static func apply(to container: AppContainer) {
        if let raw = int(tabFlag), let tab = AppRouter.Tab(rawValue: raw) {
            container.router.selectedTab = tab
        } else if int(tabFlag) == 2 {
            // 2 était l'onglet Focus : il s'ouvre maintenant en feuille, après
            // l'apparition de l'interface (une feuille demandée avant n'apparaît pas).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                container.router.showingFocus = true
            }
        }
        // Les feuilles de prévisualisation sont ouvertes par `TodayView.onAppear`,
        // pas ici : une feuille dont `isPresented` est déjà vrai **avant** que la
        // vue existe n'est jamais présentée, SwiftUI attendant un passage de faux
        // à vrai après l'apparition.
        // Le lien est cassé **après** la réparation faite par `AppContainer.init` :
        // l'état cassé est donc visible pour cette exécution, et le lancement
        // suivant — sans ce drapeau — montre la réparation.
        if isSet(breakRoleFlag) {
            let context = ModelContext(container.modelContainer)
            for group in (try? context.fetch(FetchDescriptor<StudyGroup>())) ?? [] {
                group.isAdmin = true
                for member in group.members where member.isMe {
                    member.role = .member
                }
            }
            try? context.save()
        }

        if isSet(breakTermFlag) {
            let context = ModelContext(container.modelContainer)
            for course in (try? context.fetch(FetchDescriptor<Course>())) ?? [] {
                course.term = nil
            }
            for series in (try? context.fetch(FetchDescriptor<ExerciseSeries>())) ?? []
            where series.seriesNumber > 1 {
                series.plannedWeek = 1
            }
            try? context.save()
        }

        if isSet(examActivityFlag) {
            // Après l'installation du semestre d'exemple : l'activité montre alors
            // un vrai cours. Elle est lancée depuis le contrôleur d'essai, sans
            // toucher aux dates des examens enregistrés.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                ExamActivityController.startTest()
            }
        }

        guard isSet(seedFlag) else { return }
        let context = ModelContext(container.modelContainer)
        SeedData.seedIfNeeded(context, settings: container.settings)
        try? context.save()
        container.settings.hasCompletedOnboarding = true
    }
}
#endif

@main
struct StudyTrackApp: App {
    /// Reçoit les raccourcis de l'écran d'accueil d'iOS.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var container: AppContainer

    init() {
        let container = AppContainer()
        _container = State(initialValue: container)
        // Expose le conteneur aux App Intents (Siri, Raccourcis).
        MainActor.assumeIsolated {
            AppRuntime.container = container
            // Les boutons de la Live Activity s'exécutent dans ce processus : le
            // gestionnaire est posé ici, avant que la moindre commande n'arrive.
            FocusTimerCommandHandler.install(container: container)
        }

        #if DEBUG
        PreviewLaunch.apply(to: container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(container)
                .modelContainer(container.modelContainer)
                .tint(Theme.accent)
        }
    }
}
