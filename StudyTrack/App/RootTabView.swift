import SwiftUI
import SwiftData

/// Navigation principale. Tant que l'accueil n'est pas terminé, l'onboarding
/// remplace l'app : plus aucun cours fictif n'est injecté en douce.
struct RootTabView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = app.router

        Group {
            if app.settings.hasCompletedOnboarding {
                TabView(selection: $router.selectedTab) {
                    ForEach(AppRouter.Tab.allCases, id: \.self) { tab in
                        tabContent(tab)
                            .tabItem { Label(tab.title, systemImage: tab.icon) }
                            .tag(tab)
                    }
                }
            } else {
                OnboardingView()
            }
        }
        .task {
            // Raccord au lancement : aucune activité d'îlot ne doit survivre à un
            // chrono éteint. Sans ça, une Live Activity laissée par une exécution
            // précédente restait affichée indéfiniment.
            StudyActivityController.reconcile(with: FocusTimerStore.load())
        }
        .onOpenURL { url in
            handle(url)
        }
        .onChange(of: scenePhase) { _, phase in
            // Alimente le widget quand l'app passe au premier plan ou en arrière-plan.
            if phase == .active || phase == .background {
                WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
            }
            // Les rappels suivent les données : une évaluation ajoutée ou une
            // session planifiée a son rappel dès que l'app passe en arrière-plan,
            // sans passer par un bouton dans les réglages.
            if phase == .background, app.settings.hasCompletedOnboarding {
                Task { await app.notifications.rescheduleFromStore(context: context, settings: app.settings) }
            }
            if phase == .active {
                // Une commande venue de l'écran verrouillé pendant que l'app
                // dormait attend dans le dépôt partagé : on la rejoue ici.
                // Même principe pour un fichier partagé depuis une autre app.
                Task { @MainActor in
                    FocusTimerCommandHandler.consumePending(container: app)
                    // Un PDF partagé depuis une autre app : l'accueil ouvre
                    // l'import. Il était auparavant retiré du dépôt… et jeté.
                    if let shared = PendingImportBridge.take() {
                        app.router.selectedTab = .today
                        app.router.pendingImport = shared
                    }
                }
            }
        }
    }

    /// Liens profonds : `studytrack://focus?course=CS-250&type=exercise`.
    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "studytrack" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch (url.host ?? "").lowercased() {
        case "focus":
            let type = TaskType(rawValue: value("type") ?? "") ?? .exercise
            let code = value("course") ?? ""
            app.router.startFocus(courseID: nil,
                                  courseCode: code,
                                  taskType: type,
                                  label: code.isEmpty ? "Session libre" : "\(code) · \(type.label)")
        case "tasks":
            app.router.selectedTab = .today
            app.router.showingTasks = true
        case "stats":
            app.router.selectedTab = .today
            app.router.showingStats = true
        case "today":
            app.router.selectedTab = .today
        case "agenda":
            app.router.selectedTab = .agenda
        case "courses":
            app.router.selectedTab = .courses
        case "groups":
            app.router.selectedTab = .groups
        case "join":
            // `studytrack://join?code=EPFL-XXXX` — le lien partagé par un camarade.
            let code = value("code") ?? ""
            guard !code.isEmpty else {
                app.router.selectedTab = .groups
                return
            }
            app.router.startJoin(code: code)
        default:
            app.router.selectedTab = .today
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppRouter.Tab) -> some View {
        switch tab {
        case .today: TodayView()
        case .courses: CoursesView()
        case .focus: FocusView()
        case .groups: GroupsView()
        case .agenda: AgendaView()
        }
    }
}
