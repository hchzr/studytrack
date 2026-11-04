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
    /// Ouvre « Importer du contenu », puis la source qui suit (`moodle`,
    /// `courseware`, `botafogo`) ; avec `-course`, pour ce cours.
    static let contentImportFlag = "-contentImport"
    /// Avec `-contentImport botafogo`, lit le polycopié à cet index du catalogue
    /// et ouvre la relecture (`-botafogoCourse 0`).
    static let botafogoCourseFlag = "-botafogoCourse"
    static let onboardingStepFlag = "-onboardingStep"
    /// `-onboardingDemo N` : l'accueil EPFL, écran N (0 bienvenue, 1 import
    /// simulé, 2 semestre, 3 to-do, 4 chrono), sans Moodle — pour les captures.
    static let onboardingDemoFlag = "-onboardingDemo"
    /// `-dumpAIPayloads` : relit les cours Moodle sans rien écrire et garde, par
    /// cours, ce que le modèle reçoit et répond (`Documents/ai-eval/`).
    static let dumpAIPayloadsFlag = "-dumpAIPayloads"
    /// `-dumpSeriesPayloads` : ce que l'app enverrait pour lire quelques énoncés
    /// par cours (`Documents/ai-eval/series/`), sans l'envoyer.
    static let dumpSeriesPayloadsFlag = "-dumpSeriesPayloads"
    static let profileFlag = "-profile"
    /// Ouvre Réglages › Personnaliser (captures).
    static let personalizeFlag = "-personalize"
    /// Ouvre « Statistiques » depuis « Aujourd'hui ».
    static let statsFlag = "-stats"
    /// Index du groupe à ouvrir dans l'onglet Groupes.
    static let groupFlag = "-group"
    /// Avec `-group`, ouvre en plus l'avancement d'une matière (`-groupSubject CODE`).
    static let groupSubjectFlag = "-groupSubject"
    /// Avec `-group`, ouvre une sous-page (`members`, `time`, `series`, `planning`).
    static let groupPageFlag = "-groupPage"
    /// Ouvre « Section et semestre » depuis le profil.
    static let schoolFlag = "-school"
    /// Ouvre « Import intelligent » depuis le profil.
    static let aiImportFlag = "-aiImport"
    /// Ouvre Profil › Intelligence artificielle › Assistant IA.
    static let assistantFlag = "-assistant"
    /// Avec `-course` et l'onglet exercices, ouvre le détail de l'exercice
    /// portant ce numéro (`-exerciseDetail 3.1`).
    static let exerciseDetailFlag = "-exerciseDetail"
    /// `-scrollDown` : la fiche d'un cours s'ouvre défilée vers le bas (captures).
    static let scrollDownFlag = "-scrollDown"
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
    /// `-browse <url>` : ouvre l'adresse dans le navigateur intégré, pour voir
    /// ce qu'une page donne *dans l'app* (et non dans Safari).
    static let browseFlag = "-browse"

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
    /// `-studyMode` : le mode étude ouvert sur le premier cours (sans blocage) ;
    /// `-studyTab series|course|calc` : l'onglet de départ.
    static let studyModeFlag = "-studyMode"
    static let studyTabFlag = "-studyTab"
    /// `-studyMoment lecture|revision` : le bureau sous cette forme.
    static let studyMomentFlag = "-studyMoment"

    static func apply(to container: AppContainer) {
        // `-seedBotafogo` : le premier cours lit le site Botafogo d'Analyse I, et un
        // exercice attend sa reprise (captures de « En route »).
        if isSet("-seedBotafogo") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                let context = container.modelContainer.mainContext
                let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
                if let course = courses.first(where: { !$0.sortedSeries.isEmpty }) {
                    course.contentSources.append("https://botafogo.epfl.ch/analyse-1-flipped/")
                    if let exercise = course.sortedSeries.first?.sortedExercises.dropFirst().first {
                        exercise.redoPass = 0
                        exercise.redoDueAt = Calendar.current.startOfDay(for: Date())
                        exercise.redoWhy = "méthode : le signe du dénominateur oublié"
                        exercise.redoFirstMove = "Écris la différence comme une seule fraction"
                        exercise.redoRequired = true
                    }
                    try? context.save()
                }
            }
        }
        if isSet(studyModeFlag) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                let context = ModelContext(container.modelContainer)
                let course = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).first { !$0.sortedSeries.isEmpty }
                let exercise = course?.sortedSeries.first?.sortedExercises.first
                let moment = string(studyMomentFlag)
                let type: TaskType = moment == "lecture" ? .lecture : (moment == "revision" ? .theory : .exercise)
                container.focus.enterStudy(minutes: 50, courseID: course?.id, taskType: type,
                                           targetID: type == .exercise ? exercise?.id : nil, locks: false)
                container.router.showingStudyMode = true
            }
        }
        if let raw = int(tabFlag), let tab = AppRouter.Tab(rawValue: raw), tab != .focus {
            container.router.selectedTab = tab
        } else if let raw = int(tabFlag), raw == 2 || raw == 4 {
            // 2 (Focus) et 4 (l'agenda) s'ouvrent en feuille, après l'apparition
            // de l'interface (une feuille demandée avant n'apparaît pas).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                if raw == 2 { container.router.showingFocus = true } else { container.router.showingAgenda = true }
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

        if isSet(dumpSeriesPayloadsFlag) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await AIPayloadDump.runSeries(container: container.modelContainer)
            }
        }

        if isSet(dumpAIPayloadsFlag) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await AIPayloadDump.run(container: container.modelContainer, settings: container.settings)
            }
        }

        // L'accueil se rejoue à chaque lancement de démo, même après l'avoir fini.
        if isSet(onboardingDemoFlag) {
            container.settings.hasCompletedOnboarding = false
            return
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
        let existingUser = UserDefaults.standard.bool(forKey: "settings.hasCompletedOnboarding")
        AppLanguage.settle(existingUser: existingUser)
        StudyMode.settleBlockingDefaults(["studyMode.blocking"], existingUser: existingUser)
        // Les grands titres en serif, avant la première barre de navigation.
        Carnet.installAppearance()
        // La fiche de révision et « Comprendre avec Claude » : le tuteur gratuit (comme Windows,
        // et le Mac sans Claude Code), sans quoi ces boutons n'existeraient pas sur l'iPhone.
        if SupabaseConfig.isConfigured {
            RevisionSheetMaker.shared.writer = { try await FreeTutor.write(instructions: $0, prompt: $1) }
        }
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
                .environment(container.settings)
                .modelContainer(container.modelContainer)
                .tint(Theme.accent)
                .toggleStyle(CarnetSwitchStyle())
        }
        // Clavier de l'iPad : les onglets et les gestes de tous les jours.
        .commands {
            CommandMenu("Étude") {
                Button("Aujourd'hui") { container.router.selectedTab = .today }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Cours") { container.router.selectedTab = .courses }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Groupes") { container.router.selectedTab = .groups }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Chrono") { container.router.openFocus() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Bilan") { container.router.showingStats = true }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Agenda") { container.router.openAgenda() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Importer du contenu") { container.router.openContentImport() }
                    .keyboardShortcut("i", modifiers: .command)
            }
        }
        // Le réveil d'iOS pour relever les nouveautés Moodle, app fermée.
        .backgroundTask(.appRefresh(MoodleWatcher.taskIdentifier)) {
            await MoodleWatcher.runInBackground()
        }
    }
}
