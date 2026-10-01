import SwiftUI
import SwiftData
import AuthenticationServices
import CryptoKit

/// Profil, réglages et intégrations.
struct ProfileView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @Query private var milestones: [AcademicMilestone]
    @Query private var groups: [StudyGroup]

    @State private var appleNonce = ""
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var showingImport = false
    @State private var exportURL: URL?
    /// Écran « Section et semestre », ouvert par la barre de navigation.
    @State private var showingSchool = false
    @State private var showingAIImport = false
    @State private var showingAssistant = false
    @State private var showingReset = false
    @State private var showingDeleteAccount = false
    @State private var csvURL: URL?

    /// Poussé depuis l'onglet Moi (sans pile ni « Fermer »), ou présenté seul.
    var isEmbedded = false

    var body: some View {
        if isEmbedded {
            settingsForm
        } else {
            NavigationStack {
                settingsForm
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fermer") { dismiss() }
                        }
                    }
            }
        }
    }

    private var settingsForm: some View {
        Group {
            // Une page d'accueil **courte**, rangée par grands sujets : chaque
            // ligne dit l'état en un mot et ouvre sa page. L'ancienne page
            // alignait douze sections (horaire, rappels, compte, données…) :
            // on cherchait longtemps, et l'on ne voyait rien d'un coup d'œil.
            Form {
                Group {
                    storeSection
                    identitySection(app.settings)
                    studiesSection(app.settings)
                    accountsHubSection
                    toolsSection
                    remindersAndDataSection(app.settings)
                    aboutSection
                }
                .listRowBackground(Carnet.sheet)
            }
            .carnetForm()
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingImport) {
                ImportSheet(defaultSectionCode: app.settings.sectionCode)
            }
            .navigationDestination(isPresented: $showingSchool) {
                SchoolSetupView()
            }
            .navigationDestination(isPresented: $showingAIImport) {
                AIImportSettingsView()
            }
            .navigationDestination(isPresented: $showingAssistant) {
                AssistantSettingsView()
            }
            .onAppear {
                #if DEBUG
                // `-school` : cet écran est au bout d'un tap, et `simctl` ne sait
                // pas taper.
                if PreviewLaunch.isSet(PreviewLaunch.schoolFlag) { showingSchool = true }
                if PreviewLaunch.isSet(PreviewLaunch.aiImportFlag) { showingAIImport = true }
                if PreviewLaunch.isSet(PreviewLaunch.assistantFlag) { showingAssistant = true }
                #endif
            }
        }
    }

    // MARK: Identité

    /// Avertissement quand la base n'a pas pu être ouverte normalement.
    ///
    /// Sans ça, l'app fonctionnait sur une base en mémoire et perdait tout à la
    /// fermeture — sans que rien ne le dise.
    @ViewBuilder
    private var storeSection: some View {
        if let problem = app.storeError {
            Section {
                Label(problem, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(Carnet.review)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Stockage")
            } footer: {
                Text("Vérifie l'espace disponible, puis relance l'app. En attendant, cette session risque de ne pas être conservée.")
            }
        }
    }

    // MARK: Accueil des réglages

    /// Études : la section et le semestre, l'horaire, la charge attendue.
    private func studiesSection(_ settings: SettingsStore) -> some View {
        Section {
            NavigationLink {
                SchoolSetupView()
            } label: {
                settingsRow("Semestre et cours", icon: "graduationcap",
                            value: "\(courses.filter(\.isTracked).count) cours")
            }
            NavigationLink {
                subpage("Horaire et calendrier") {
                    calendarSection(settings)
                    workloadSection(settings)
                    Section(header: CarnetFormHeader("Présence")) {
                        Toggle("Suivre la présence en amphi", isOn: Binding(get: { settings.trackAttendance },
                                                                             set: { settings.trackAttendance = $0 }))
                    }
                }
            } label: {
                settingsRow("Horaire et calendrier", icon: "calendar",
                            value: app.calendar.hasAccess ? "relié" : (settings.timetableURLString.isEmpty ? "à importer" : "flux .ics"))
            }
        } header: {
            CarnetFormHeader("Études")
        }
    }

    /// Les comptes : sites des cours (Moodle, MediaSpace…), compte StudyTrack.
    private var accountsHubSection: some View {
        Section {
            NavigationLink {
                ConnectionsView()
            } label: {
                settingsRow("Connexions aux sites", icon: "person.badge.key",
                            value: ConnectionCenter.shared.needingAttention().isEmpty ? nil : "à reconnecter")
            }
            NavigationLink {
                subpage("Compte et groupes") {
                    accountSection(app.settings)
                    privacySection(app.settings)
                }
            } label: {
                settingsRow("Compte et groupes", icon: "person.2",
                            value: app.social.isSignedIn ? (app.social.email ?? "connecté·e") : "aucun")
            }
        } header: {
            CarnetFormHeader("Comptes")
        }
    }

    /// Les outils reliés : Anki, tâches, assistant, IA de lecture, chrono.
    private var toolsSection: some View {
        let tasks = TaskServiceFactory.shared.configuredServices(settings: app.settings)
        return Section {
            NavigationLink {
                AnkiSettingsView()
            } label: {
                settingsRow("Anki", icon: "rectangle.stack",
                            value: AnkiWebSync.shared.isSignedIn ? "AnkiWeb" : (app.settings.isAnkiConfigured ? "Anki Desktop" : "non relié"))
            }
            NavigationLink {
                TaskIntegrationsView()
            } label: {
                settingsRow("Tâches", icon: "checklist",
                            value: tasks.isEmpty ? "aucune" : tasks.map(\.provider.label).joined(separator: ", "))
            }
            NavigationLink {
                AssistantSettingsView()
            } label: {
                settingsRow("Assistant IA", icon: "bubble.left.and.text.bubble.right",
                            value: app.settings.assistantToken.isEmpty ? "non relié" : "relié")
            }
            NavigationLink {
                AIImportSettingsView()
            } label: {
                settingsRow("IA de lecture", icon: "sparkles",
                            value: SeriesAIExtractor.plannedSource(app.settings)?.label ?? "désactivée")
            }
            NavigationLink {
                subpage("Chrono et Pomodoro") { PomodoroSettingsForm(settings: app.settings) }
            } label: {
                settingsRow("Chrono et Pomodoro", icon: "timer",
                            value: "\(app.settings.pomodoro.focusMinutes) / \(app.settings.pomodoro.shortBreakMinutes) min")
            }
        } header: {
            CarnetFormHeader("Outils")
        } footer: {
            Text("L'IA de lecture range les séries des PDF et les cours Moodle aux formats inhabituels.")
        }
    }

    /// Rappels et données : deux pages, rarement ouvertes.
    private func remindersAndDataSection(_ settings: SettingsStore) -> some View {
        Section {
            NavigationLink {
                subpage("Rappels") { notificationsSection(settings) }
            } label: {
                settingsRow("Rappels", icon: "bell",
                            value: settings.dailyReminderEnabled ? "chaque jour à \(settings.dailyReminderHour) h" : "désactivés")
            }
            NavigationLink {
                subpage("Données") { dataSection }
            } label: {
                settingsRow("Données et sauvegarde", icon: "externaldrive",
                            value: "\(sessions.count) session\(sessions.count > 1 ? "s" : "")")
            }
        }
    }

    /// Une page de réglages au même style que l'accueil, avec le message en cours.
    private func subpage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form {
            Group {
                content()
                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(Carnet.inkSecondary) }
                }
            }
            .listRowBackground(Carnet.sheet)
        }
        .carnetForm()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Une ligne de réglage : icône d'encre, titre, et l'état à droite.
    private func settingsRow(_ title: String, icon: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// L'en-tête du profil : qui, dans quelle section, où en est le semestre.
    ///
    /// C'était un champ texte nu sous le mot « Profil » — le premier écran des
    /// réglages ressemblait à un formulaire vide.
    private func identitySection(_ settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        let name = settings.displayName.trimmingCharacters(in: .whitespaces)
        let initial = name.first.map { String($0).uppercased() }
        return Section {
            HStack(spacing: Layout.gutter) {
                ZStack {
                    Circle().fill(Carnet.ink)
                    if let initial {
                        Text(initial)
                            .font(Carnet.serif(.title2))
                            .foregroundStyle(Carnet.ground)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.title3)
                            .foregroundStyle(Carnet.ground)
                    }
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Layout.tight) {
                    TextField("Ton prénom", text: $settings.displayName)
                        .font(Carnet.serif(.title2))
                        .textContentType(.givenName)
                        .submitLabel(.done)
                    Text(settings.section.map { "\($0.name)" } ?? "Section non renseignée")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, Layout.tight)
        } footer: {
            Text("Ton prénom apparaît dans l'accueil et dans tes groupes.")
        }
    }

    // MARK: Calendrier

    private func calendarSection(_ settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return Section {
            HStack {
                Label(app.calendar.hasAccess ? "Calendrier autorisé" : "Calendrier non autorisé",
                      systemImage: "calendar")
                Spacer()
                Button(app.calendar.hasAccess ? "Synchroniser" : "Autoriser") {
                    Task { await syncCalendar() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }

            TextField("Flux iCalendar de ton horaire", text: $settings.timetableURLString)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)

            Button {
                showingImport = true
            } label: {
                Label("Importer un horaire / JSON / CSV", systemImage: "square.and.arrow.down")
            }
        } header: {
            CarnetFormHeader("Horaire")
        } footer: {
            Text("L'EPFL n'ouvre pas d'API aux étudiant·e·s : le flux .ics « Mon horaire » est le moyen fiable d'importer ton emploi du temps. StudyTrack en déduit tes cours et détecte ceux qui ont des heures de cours.")
        }
    }

    private func syncCalendar() async {
        if !app.calendar.hasAccess {
            let granted = await app.calendar.requestAccess()
            guard granted else {
                message = "Accès au calendrier refusé."
                return
            }
        }
        let result = CalendarSync.sync(context: context, courses: courses, service: app.calendar)
        message = result.total == 0
            ? "Aucun événement trouvé sur la période."
            : "\(result.imported) importé(s) · \(result.updated) mis à jour."
    }

    // MARK: Charge EPFL

    private func workloadSection(_ settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return Section {
            Stepper(value: Binding(
                get: { Int(settings.hoursPerCredit) },
                set: { settings.hoursPerCredit = Double($0) }
            ), in: 20...40, step: 1) {
                Label("\(Int(settings.hoursPerCredit)) h par crédit ECTS", systemImage: "scalemass")
            }
        } footer: {
            Text("Charge attendue = crédits × heures par crédit, dont les heures d'amphi déclarées des cours qui en ont.")
        }
    }

    // MARK: Notifications

    /// Un rappel activé sans autorisation ne sonnerait jamais : on la demande au
    /// moment où elle a un sens, et on dit quoi faire si elle a été refusée.
    private func askForNotifications() {
        Task {
            let granted = await app.notifications.requestAuthorization()
            if !granted {
                message = "Notifications refusées. Active-les dans Réglages › StudyTrack."
            }
        }
    }

    private func notificationsSection(_ settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Rappel quotidien", isOn: $settings.dailyReminderEnabled)
                .onChange(of: settings.dailyReminderEnabled) { _, on in if on { askForNotifications() } }
            if settings.dailyReminderEnabled {
                Stepper(value: $settings.dailyReminderHour, in: 6...23, step: 1) {
                    LabeledContent("Heure", value: "\(settings.dailyReminderHour) h")
                }
            }
            Toggle("Récap hebdomadaire", isOn: $settings.weeklyRecapEnabled)
                .onChange(of: settings.weeklyRecapEnabled) { _, on in if on { askForNotifications() } }

            Button {
                Task {
                    let granted = await app.notifications.requestAuthorization()
                    guard granted else {
                        message = "Notifications refusées. Active-les dans Réglages › StudyTrack."
                        return
                    }
                    await reschedule(settings)
                    message = "Rappels replanifiés."
                }
            } label: {
                Label("Autoriser les notifications", systemImage: "bell.badge")
            }
        } header: {
            CarnetFormHeader("Rappels")
        } footer: {
            Text("Les rappels d'évaluation (J-3, J-1) et de session (15 min avant) sont replanifiés automatiquement à chaque passage en arrière-plan.")
        }
        // Un interrupteur qui n'agit qu'après un bouton plus bas n'est pas un
        // interrupteur : chaque changement replanifie.
        .onChange(of: settings.dailyReminderEnabled) { _, _ in Task { await reschedule(settings) } }
        .onChange(of: settings.dailyReminderHour) { _, _ in Task { await reschedule(settings) } }
        .onChange(of: settings.weeklyRecapEnabled) { _, _ in Task { await reschedule(settings) } }
    }

    private func reschedule(_ settings: SettingsStore) async {
        await app.notifications.rescheduleFromStore(context: context, settings: settings)
    }

    // MARK: Confidentialité

    private func privacySection(_ settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return Section(header: CarnetFormHeader("Confidentialité dans les groupes")) {
            Toggle("Apparaître anonymement dans les groupes", isOn: $settings.anonymousInLeaderboards)
            Toggle("Partager mon avancement avec mes groupes", isOn: $settings.shareProgressWithGroups)
        }
    }

    // MARK: Données

    private var dataSection: some View {
        Section {
            NavigationLink {
                SessionHistoryView(embedded: true)
            } label: {
                Label("Historique des sessions", systemImage: "clock.arrow.circlepath")
            }

            Button {
                exportURL = DataExporter.writeFile(courses: courses, sessions: sessions)
                message = exportURL == nil ? "Sauvegarde impossible." : "Sauvegarde prête à partager."
            } label: {
                Label("Créer une sauvegarde (JSON)", systemImage: "square.and.arrow.down")
            }

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Partager la sauvegarde", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                csvURL = DataExporter.writeSessionsCSV(sessions)
            } label: {
                Label("Exporter les sessions (CSV)", systemImage: "tablecells")
            }
            if let csvURL {
                ShareLink(item: csvURL) {
                    Label("Partager le CSV", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                showingImport = true
            } label: {
                Label("Restaurer une sauvegarde", systemImage: "arrow.counterclockwise.circle")
            }

            Button(role: .destructive) {
                showingReset = true
            } label: {
                Label("Effacer toutes les données", systemImage: "trash")
            }
        } header: {
            CarnetFormHeader("Données")
        } footer: {
            Text("La sauvegarde contient les cours, l'avancement (vidéos vues, exercices faits, corrections) et les sessions. Elle se restaure par « Importer » › JSON, sans doublon.")
        }
        .confirmationDialog("Effacer toutes les données ?",
                            isPresented: $showingReset,
                            titleVisibility: .visible) {
            Button("Tout effacer", role: .destructive) { resetAll() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cours, avancement, \(DateUtils.hoursLabel(seconds: sessions.reduce(0) { $0 + $1.durationSeconds })) de sessions, groupes locaux et semestre. Irréversible — fais une sauvegarde d'abord.")
        }
    }

    private func resetAll() {
        for course in courses { context.delete(course) }
        for session in sessions { context.delete(session) }
        for item in (try? context.fetch(FetchDescriptor<PlannedSession>())) ?? [] {
            app.notifications.cancelSession(id: item.id)
            context.delete(item)
        }
        for item in (try? context.fetch(FetchDescriptor<LinkedTask>())) ?? [] { context.delete(item) }
        for item in (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? [] { context.delete(item) }
        for item in (try? context.fetch(FetchDescriptor<StudyGroup>())) ?? [] { context.delete(item) }
        for item in (try? context.fetch(FetchDescriptor<AcademicTerm>())) ?? [] { context.delete(item) }
        try? context.save()
        app.settings.hasSeededSampleData = false
        app.focus.discard()
        Task { await app.notifications.cancelScheduled() }
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
        Haptics.removed()
        message = "Données effacées."
    }

    // MARK: Compte

    private func accountSection(_ settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return Section {
            if !SupabaseConfig.isConfigured {
                // Une build sans configuration reste **pleinement utilisable** : on
                // le dit clairement, au lieu de montrer des champs que personne ne
                // peut remplir — l'URL et la clé sont des constantes de build.
                Label("Groupes non configurés dans cette version", systemImage: "icloud.slash")
                    .font(.subheadline)
                Text("Cette build n'est reliée à aucun serveur de groupes. Le suivi des cours, le temps de travail et l'agenda fonctionnent normalement, et rien n'est envoyé nulle part.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if app.social.isSignedIn {
                LabeledContent("Connecté", value: app.social.email ?? app.social.userID ?? "—")
                Button(role: .destructive) {
                    Task {
                        await app.social.signOut()
                        message = "Déconnecté."
                    }
                } label: {
                    Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) {
                    showingDeleteAccount = true
                } label: {
                    Label("Supprimer mon compte…", systemImage: "person.crop.circle.badge.xmark")
                }
                .confirmationDialog("Supprimer ton compte ?",
                                    isPresented: $showingDeleteAccount,
                                    titleVisibility: .visible) {
                    Button("Supprimer définitivement", role: .destructive) {
                        Task {
                            do {
                                try await app.social.deleteAccount()
                                message = "Compte supprimé."
                            } catch {
                                message = nil
                            }
                        }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("Ton compte, tes adhésions aux groupes et tout ce que tu y as partagé seront effacés du serveur. Tes cours et tes sessions restent sur cet appareil.")
                }
            } else if SupabaseConfig.isConfigured {
                SignInWithAppleButton(.signIn) { request in
                    let nonce = AppleSignInSupport.randomNonce()
                    appleNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = Self.sha256Hex(nonce)
                } onCompletion: { result in
                    handleApple(result)
                }
                .frame(height: 44)

                TextField("Email", text: $email)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                SecureField("Mot de passe (6 caractères min.)", text: $password)

                HStack {
                    Button("Créer un compte") { Task { await authenticate(signUp: true) } }
                    Spacer()
                    Button("Se connecter") { Task { await authenticate(signUp: false) } }
                }
                .disabled(email.isEmpty || password.count < 6)
            } else {
                Text("Sans compte, tes groupes restent locaux à cet appareil.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(app.social.isSignedIn ? Carnet.correct : Carnet.review)
            }
            if let error = app.social.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Carnet.wrong)
            }
        } header: {
            CarnetFormHeader("Compte")
        } footer: {
            Text("Sans Supabase, tout le suivi privé fonctionne hors ligne : seules les fonctions de groupe restent locales.")
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                message = "Jeton Apple illisible."
                return
            }
            Task {
                let ok = await app.social.signInWithApple(idToken: idToken, nonce: appleNonce)
                message = ok ? "Connecté avec Apple." : "Échec de la connexion Apple."
            }
        case .failure(let error):
            message = Self.appleMessage(for: error)
        }
    }

    /// Traduit une erreur Sign in with Apple en quelque chose d'actionnable.
    ///
    /// `ASAuthorizationError` vaut `Code=1000 "(null)"` dans le cas le plus courant
    /// — l'app n'a pas la capacité « Sign in with Apple » — et n'en dit pas plus.
    /// Afficher `localizedDescription` revient à n'afficher rien.
    static func appleMessage(for error: Error) -> String {
        guard let authError = error as? ASAuthorizationError else {
            return "Apple : \(error.localizedDescription)"
        }
        // Comparaison sur la valeur brute : `ASAuthorizationError.Code` gagne des
        // cas à chaque version d'iOS (passkeys…), et un `switch` typé cesserait
        // d'être exhaustif à la prochaine.
        switch authError.code.rawValue {
        case ASAuthorizationError.canceled.rawValue:
            return "Connexion Apple annulée."
        case ASAuthorizationError.unknown.rawValue:
            return "Apple n'a pas pu traiter la demande. Vérifie que la capacité « Sign in with Apple » est activée pour l'app, et que l'appareil est connecté à iCloud."
        case ASAuthorizationError.invalidResponse.rawValue:
            return "Réponse Apple invalide. Réessaie."
        case ASAuthorizationError.notHandled.rawValue:
            return "Demande Apple non traitée. Réessaie."
        case ASAuthorizationError.failed.rawValue:
            return "Apple a refusé la demande. Vérifie l'identifiant et la capacité dans le portail Apple Developer."
        case ASAuthorizationError.notInteractive.rawValue:
            return "Connexion Apple impossible sans interaction."
        default:
            return "Apple : erreur \(authError.code.rawValue)."
        }
    }

    private func authenticate(signUp: Bool) async {
        let ok = signUp
            ? await app.social.signUp(email: email, password: password)
            : await app.social.signIn(email: email, password: password)
        message = ok ? "Connecté." : "Échec de l'authentification."
    }

    /// « 2.1 (14) » — lue dans le bundle, jamais écrite à la main : la valeur
    /// affichée disait « 2.0 » alors que la build portait 1.0.
    static var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var aboutSection: some View {
        Section(header: CarnetFormHeader("À propos")) {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("Diagnostic", systemImage: "stethoscope")
            }
            LabeledContent("Version", value: Self.versionLabel)
            Text("StudyTrack — suivi du temps d'étude EPFL : théorie par vidéos, exercices et corrections, charge attendue, agenda, groupes et intégrations.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
