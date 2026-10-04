import SwiftUI
import SwiftData

/// Navigation principale. Tant que l'accueil n'est pas terminé, l'onboarding
/// remplace l'app : plus aucun cours fictif n'est injecté en douce.
struct RootTabView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var debugBrowse: BrowsedLink?

    var body: some View {
        @Bindable var router = app.router

        Group {
            if app.settings.hasCompletedOnboarding {
                tabs
                // Focus, bilan et agenda s'ouvrent depuis **n'importe quel**
                // onglet : une seule présentation, pilotée par le routeur.
                .sheet(item: rootSheet) { sheet in
                    switch sheet {
                    case .focus:
                        FocusView(onClose: { app.router.showingFocus = false })
                    case .agenda:
                        AgendaView()
                            .carnetPageSheet()
                    case .me:
                        MeView(onClose: { app.router.showingProfile = false })
                    case .stats:
                        NavigationStack {
                            StatsView()
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Fermer") { app.router.showingStats = false }
                                    }
                                }
                        }
                        .carnetPageSheet()
                    }
                }
            } else {
                OnboardingView()
            }
        }
        // L'import de contenu s'ouvre de partout (accueil, cours, onboarding
        // terminé) : une présentation, portée par la racine.
        .sheet(item: $router.contentImport) { route in
            ContentImportView(course: route.courseID.flatMap { id in
                try? context.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })).first
            })
        }
        .task {
            // Les sessions des sites de cours (Moodle, MediaSpace, Switch
            // edu-ID…) d'abord : tout ce qui suit peut en avoir besoin.
            await CookieKeeper.restore()
            // Raccord au lancement : aucune activité d'îlot ne doit survivre à un
            // chrono éteint. Sans ça, une Live Activity laissée par une exécution
            // précédente restait affichée indéfiniment.
            app.focus.reload()
            StudyActivityController.reconcile(with: app.focus.state)
            // Même raccord pour le jour d'examen : une activité laissée par une
            // épreuve passée doit disparaître, et une épreuve qui arrive dans les
            // douze heures doit s'afficher sans attendre un passage en arrière-plan.
            ExamActivityController.reconcileFromStore(context: context)
            // L'horaire lu deux fois (import `.ics` et calendrier de l'iPhone
            // abonné au même flux) et les séances d'exercices rangées comme
            // cours magistraux comptaient d'office dans les heures d'amphi :
            // doublons retirés et séances reclassées, une fois ici.
            CalendarSync.repair(context: context)
            try? context.save()
            #if DEBUG
            if let address = PreviewLaunch.string(PreviewLaunch.browseFlag), let url = URL(string: address) {
                try? await Task.sleep(for: .milliseconds(400))
                debugBrowse = BrowsedLink(title: "Test", url: url, icon: "globe")
            }
            if PreviewLaunch.isSet(PreviewLaunch.contentImportFlag) {
                let code = PreviewLaunch.string(PreviewLaunch.courseFlag)
                let course = (try? context.fetch(FetchDescriptor<Course>()))?.first { $0.code == code }
                try? await Task.sleep(for: .milliseconds(400))
                app.router.openContentImport(courseID: course?.id)
            }
            #endif
        }
        .sheet(item: $debugBrowse) { link in InAppBrowser(link: link) }
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
            // L'assistant lit ce qu'on vient de cocher, sans attendre.
            AssistantSync.scheduleSync(context: context, settings: app.settings)
        }
        // Un autre appareil a écrit (iCloud) : doublons fusionnés, widgets à jour.
        .onReceive(NotificationCenter.default.publisher(for: CloudSyncMonitor.remoteChange)) { _ in
            CloudSyncMonitor.remoteChangeArrived(container: app)
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
            if phase == .background, !app.settings.assistantToken.isEmpty {
                Task { await AssistantSync.sync(context: context, settings: app.settings, force: false) }
            }
            if phase == .background {
                // La liaison instantanée du chrono se ferme : iOS la couperait de
                // toute façon, et une connexion ouverte pour rien compte dans le
                // quota Supabase. Elle se rouvre au retour (`resume`).
                TimerLink.shared.suspend()
                Task { await CookieKeeper.save() }
                MoodleWatcher.schedule(settings: app.settings)
            }
            if phase == .background, AnkiWebSync.shared.isSignedIn {
                // Des révisions pas encore envoyées partent avant que l'app ne
                // s'endorme : iOS laisse quelques secondes pour finir.
                let task = UIApplication.shared.beginBackgroundTask(withName: "AnkiWeb")
                Task { @MainActor in
                    await AnkiWebSync.shared.syncNow()
                    UIApplication.shared.endBackgroundTask(task)
                }
            }
            if phase == .background, app.settings.hasCompletedOnboarding {
                Task { await app.notifications.rescheduleFromStore(context: context, settings: app.settings) }
            }
            if phase == .active {
                // Une commande venue de l'écran verrouillé pendant que l'app
                // dormait attend dans le dépôt partagé : on la rejoue ici.
                // Même principe pour un fichier partagé depuis une autre app.
                // La socket temps réel des groupes a pu être coupée par la veille.
                app.social.realtime?.resume()
                Task { @MainActor in
                    // Le chrono rattrape ce qui s'est passé app fermée : une fin
                    // de bloc, une pause écoulée.
                    app.focus.reload()
                    NSUbiquitousKeyValueStore.default.synchronize()
                    TimerLink.shared.resume()
                    app.focus.applyRemote()
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
                    // Le temps passé dans Anki arrive tout seul, étiqueté.
                    await AnkiReviewSync.syncIfDue(context: context, settings: app.settings)
                    // La série de la semaine, publiée sur Moodle depuis la
                    // dernière fois, arrive toute seule elle aussi.
                    await ContentRefresher.refreshIfDue(context: context, settings: app.settings)
                    // Ses énoncés, gardés pour le métro (si on l'a demandé).
                    await OfflineLibrary.shared.sync(context: context, settings: app.settings)
                    // Ce que l'assistant a demandé pendant que l'app dormait.
                    await AssistantSync.sync(context: context, settings: app.settings)
                }
            }
        }
    }

    enum RootSheet: String, Identifiable {
        case focus, agenda, stats, me
        var id: String { rawValue }
    }

    /// Les drapeaux du routeur, vus comme une seule feuille. Fermer la feuille
    /// remet le drapeau à faux — sinon le bouton ne rouvrirait plus rien.
    private var rootSheet: Binding<RootSheet?> {
        Binding(get: {
            if app.router.showingFocus { return .focus }
            if app.router.showingAgenda { return .agenda }
            if app.router.showingStats { return .stats }
            if app.router.showingProfile { return .me }
            return nil
        }, set: { value in
            if value == nil {
                app.router.showingFocus = false
                app.router.showingAgenda = false
                app.router.showingStats = false
                app.router.showingProfile = false
            }
        })
    }

    /// Le rond « Chrono » n'est pas une page : le choisir ouvre Focus et laisse
    /// l'onglet où l'on était.
    private var tabSelection: Binding<AppRouter.Tab> {
        Binding(get: { app.router.selectedTab }, set: { tab in
            if tab == .focus {
                app.router.openFocus()
                Haptics.tap()
            } else {
                app.router.selectedTab = tab
            }
        })
    }

    /// La barre **système** (Liquid Glass d'iOS 26) : quatre onglets et le
    /// chrono, qui porte le rôle « recherche » — le système le détache en rond à
    /// droite quand il le fait (iOS 26.0), sinon il reste le dernier onglet. Elle
    /// se replie au défilement ; pendant une session, le mini-lecteur est son
    /// accessoire, qui se range à côté de la barre repliée.
    ///
    /// Avant iOS 26 : notre barre (`CarnetTabBar`) sur matière translucide.
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: tabSelection) {
                ForEach(CarnetTabBar.tabs, id: \.self) { tab in
                    Tab(tab.title, systemImage: tab.icon, value: tab) {
                        tabContent(tab)
                    }
                }
                Tab(value: AppRouter.Tab.focus, role: .search) {
                    Color.clear
                } label: {
                    Label(AppRouter.Tab.focus.title, systemImage: AppRouter.Tab.focus.icon)
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .modifier(FocusAccessory())
        } else {
            TabView(selection: tabSelection) {
                ForEach(CarnetTabBar.tabs, id: \.self) { tab in
                    tabContent(tab)
                        .toolbar(.hidden, for: .tabBar)
                        .tag(tab)
                }
            }
            .modifier(CarnetTabBarInset())
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
            app.router.showingStats = true
        case "today":
            app.router.selectedTab = .today
        case "agenda":
            app.router.openAgenda()
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
        case .me: MeView()
        case .focus: EmptyView()
        }
    }
}

/// Le profil — réglages, bilan, compte — **en haut à droite de chaque onglet**,
/// toujours à la même place, toujours le dernier bouton de la barre.
///
/// Un avatar plutôt qu'une silhouette générique : ce sont tes initiales, on
/// reconnaît « moi » sans lire. La barre de chaque onglet suit une seule règle :
/// à gauche le grand titre, à droite l'action de l'onglet (« + ») puis l'avatar.
struct ProfileButton: View {
    @Environment(AppContainer.self) private var app
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Button {
            app.router.showingProfile = true
        } label: {
            ZStack {
                Circle().fill(Theme.accent.badgeFill)
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent.badgeInk)
                } else {
                    Text(initials)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent.badgeInk)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profil, réglages et bilan")
    }

    private var initials: String {
        app.settings.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
    }
}
