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
                            .modifier(LegacyFocusDockInset())
                            .tabItem { Label(tab.title, systemImage: tab.icon) }
                            .tag(tab)
                    }
                }
                .modifier(FocusDockPlacement())
                // Focus, profil et bilan s'ouvrent depuis **n'importe quel** onglet :
                // une seule présentation, pilotée par le routeur.
                .sheet(item: rootSheet) { sheet in
                    switch sheet {
                    case .focus:
                        FocusView(onClose: { app.router.showingFocus = false })
                    case .profile:
                        ProfileView()
                    case .stats:
                        NavigationStack {
                            StatsView()
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Fermer") { app.router.showingStats = false }
                                    }
                                }
                        }
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
            app.focus.reload()
            StudyActivityController.reconcile(with: app.focus.state)
            // Même raccord pour le jour d'examen : une activité laissée par une
            // épreuve passée doit disparaître, et une épreuve qui arrive dans les
            // douze heures doit s'afficher sans attendre un passage en arrière-plan.
            ExamActivityController.reconcileFromStore(context: context)
        }
        .onOpenURL { url in
            handle(url)
        }
        // Les widgets suivent **chaque** enregistrement — une question cochée, une
        // série importée —, pas seulement le passage en arrière-plan.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            WidgetSnapshotWriter.scheduleRefresh(context: context, settings: app.settings)
            // Cocher (a) dans la liste des exercices doit faire passer l'îlot de
            // « 3/9 » à « 4/9 ». Le contrôleur ne republie que si le compte change
            // vraiment : `didSave` se déclenche à chaque écriture, et ActivityKit
            // limite les mises à jour.
            StudyActivityController.refreshQuestions(container: app)
        }
        .onReceive(NotificationCenter.default.publisher(for: FocusTimerStore.didSave)) { _ in
            WidgetSnapshotWriter.scheduleRefresh(context: context, settings: app.settings)
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
                    // Le chrono rattrape ce qui s'est passé app fermée : une fin
                    // de bloc, une pause écoulée.
                    app.focus.reload()
                    FocusTimerCommandHandler.consumePending(container: app)
                    // Les coches faites dans un widget pendant que l'app dormait.
                    if WidgetSnapshotWriter.applyPendingCompletions(context: context) > 0 {
                        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
                    }
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

    enum RootSheet: String, Identifiable {
        case focus, profile, stats
        var id: String { rawValue }
    }

    /// Les trois drapeaux du routeur, vus comme une seule feuille. Fermer la
    /// feuille remet le drapeau à faux — sinon le bouton ne rouvrirait plus rien.
    private var rootSheet: Binding<RootSheet?> {
        Binding(get: {
            if app.router.showingFocus { return .focus }
            if app.router.showingProfile { return .profile }
            if app.router.showingStats { return .stats }
            return nil
        }, set: { value in
            if value == nil {
                app.router.showingFocus = false
                app.router.showingProfile = false
                app.router.showingStats = false
            }
        })
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
            if items.isEmpty {
                app.router.openFocus()
                return
            }
            let type = TaskType(rawValue: value("type") ?? "") ?? .exercise
            let code = value("course") ?? ""
            let label = value("label") ?? (code.isEmpty ? "Session libre" : "\(code) · \(type.label)")
            app.router.startFocus(courseID: nil,
                                  courseCode: code,
                                  taskType: type,
                                  label: label)
        case "course":
            // `studytrack://course?id=…` — depuis le widget « Cours de la semaine ».
            if let id = value("id").flatMap(UUID.init(uuidString:)) {
                app.router.openCourse(id)
            } else {
                app.router.selectedTab = .courses
            }
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
        case .groups: GroupsView()
        case .agenda: AgendaView()
        }
    }
}

/// L'accès au profil, aux réglages et au bilan, en haut à gauche de **chaque**
/// onglet — il n'existait que sur « Aujourd'hui ».
struct ProfileButton: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        Button {
            app.router.showingProfile = true
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Profil, réglages et bilan")
    }
}
