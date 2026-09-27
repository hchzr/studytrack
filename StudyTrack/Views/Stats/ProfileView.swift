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
    @State private var showingReset = false
    @State private var showingDeleteAccount = false
    @State private var csvURL: URL?

    var body: some View {
        NavigationStack {
            // Une page par sujet. Les quinze sections empilées faisaient un
            // formulaire de plusieurs écrans où rien ne se retrouvait ; la racine
            // ne garde que qui tu es, ton bilan, et un sommaire.
            Form {
                storeSection
                identitySection(app.settings)
                Section {
                    NavigationLink {
                        StatsView()
                    } label: {
                        Label("Bilan et statistiques", systemImage: "chart.bar.xaxis")
                    }
                }
                Section {
                    page("Semestre et cours", icon: "graduationcap") {
                        sectionPicker(app.settings)
                        workloadSection(app.settings)
                    }
                    page("Calendrier et tâches", icon: "calendar.badge.checkmark") {
                        calendarSection(app.settings)
                        tasksSection(app.settings)
                        ankiSection
                    }
                    page("Notifications", icon: "bell.badge") {
                        notificationsSection(app.settings)
                    }
                    page("Focus et chrono", icon: "timer") {
                        focusSection(app.settings)
                    }
                    page("Import intelligent", icon: "sparkles") {
                        aiSection
                    }
                }
                Section {
                    page("Compte et groupes", icon: "person.2") {
                        accountSection(app.settings)
                    }
                    page("Confidentialité et données", icon: "lock.shield") {
                        privacySection(app.settings)
                        dataSection
                    }
                    page("Diagnostic", icon: "stethoscope") {
                        diagnosticsSection
                    }
                    page("À propos", icon: "info.circle") {
                        aboutSection
                    }
                }
            }
            .navigationTitle("Profil & réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportSheet(defaultSectionCode: app.settings.sectionCode)
            }
            .navigationDestination(isPresented: $showingSchool) {
                SchoolSetupView()
            }
            .navigationDestination(isPresented: $showingAIImport) {
                AIImportSettingsView()
            }
            .onAppear {
                #if DEBUG
                // `-school` : cet écran est au bout d'un tap, et `simctl` ne sait
                // pas taper.
                if PreviewLaunch.isSet(PreviewLaunch.schoolFlag) { showingSchool = true }
                if PreviewLaunch.isSet(PreviewLaunch.aiImportFlag) { showingAIImport = true }
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
                    .foregroundStyle(Color.orange.accessibleInk)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Stockage")
            } footer: {
                Text("Vérifie l'espace disponible, puis relance l'app. En attendant, cette session risque de ne pas être conservée.")
            }
        }
    }

    /// Anki, à côté des autres intégrations.
    private var ankiSection: some View {
        Section {
            NavigationLink {
                AnkiSettingsView()
            } label: {
                HStack(spacing: Layout.control) {
                    Label("Anki", systemImage: "rectangle.stack.fill")
                    Spacer()
                    Text(app.settings.isAnkiConfigured ? "configuré" : "non configuré")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Révision espacée")
        } footer: {
            Text("Envoie tes exercices à refaire et ta théorie à résumer dans un paquet Anki, via AnkiConnect.")
        }
    }

    /// Le journal, à côté des intégrations.
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        } footer: {
            Text("Les erreurs de synchronisation, d'import et d'intégration, horodatées. Utile quand quelque chose ne marche pas et qu'on ne sait pas quoi.")
        }
    }

    /// Une sous-page de réglages : ses sections, dans un formulaire à elle.
    private func page<Content: View>(_ title: String, icon: String,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationLink {
            Form { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label(title, systemImage: icon)
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
                    Circle().fill(Theme.accent.accessibleMark)
                    if let initial {
                        Text(initial)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.knockedOutInk)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.knockedOutInk)
                    }
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Layout.tight) {
                    TextField("Ton prénom", text: $settings.displayName)
                        .font(.title3.weight(.semibold))
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

    /// Section, cours et dates : tout ce que l'onboarding a demandé reste
    /// modifiable ici, y compris la date de début du semestre — qui commande le
    /// numéro de semaine affiché partout.
    private func sectionPicker(_ settings: SettingsStore) -> some View {
        Section {
            NavigationLink {
                SchoolSetupView()
            } label: {
                HStack(spacing: Layout.control) {
                    Label("Section et semestre", systemImage: "graduationcap.fill")
                    Spacer()
                    Text(app.sectionDisplayName(settings.sectionCode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: Layout.control) {
                Label("Cours suivis", systemImage: "books.vertical.fill")
                Spacer()
                Text("\(courses.filter(\.isTracked).count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Scolarité")
        } footer: {
            Text("Tout est modifiable : section, cours suivis, heures d'amphi et dates du semestre.")
        }
    }

    /// Écrit l'instantané destiné au serveur MCP et ouvre la feuille de partage.
    private func shareAssistantExport() {
        let payload = AssistantExport.data(courses: courses,
                                           sessions: sessions,
                                           milestones: milestones,
                                           groups: groups,
                                           hoursPerCredit: app.settings.hoursPerCredit,
                                           displayName: app.settings.displayName)
        guard let payload else {
            message = "Export impossible."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(AssistantExport.fileName)
        do {
            try payload.write(to: url, options: .atomic)
            exportURL = url
            message = "Instantané prêt : enregistre-le sur ton Mac, puis lis-le avec le serveur MCP."
        } catch {
            message = "Export impossible — \(error.localizedDescription)"
        }
    }

    // MARK: Calendrier

    private func calendarSection(_ settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return Section {
            HStack {
                Image(systemName: "calendar")
                Text(app.calendar.hasAccess ? "Calendrier autorisé" : "Calendrier non autorisé")
                    .font(.subheadline)
                Spacer()
                Button(app.calendar.hasAccess ? "Synchroniser" : "Autoriser") {
                    Task { await syncCalendar() }
                }
                .buttonStyle(.bordered)
                .font(.caption)
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
            Text("Calendrier et horaire")
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

    // MARK: Tâches

    /// Huit fournisseurs, chacun avec ses champs et sa notice : en ligne dans le
    /// profil, ça faisait un écran de trois mètres. Un lien, et un compteur.
    private func tasksSection(_ settings: SettingsStore) -> some View {
        let active = TaskServiceFactory.shared.configuredServices(settings: settings)
        return Section {
            NavigationLink {
                TaskIntegrationsView()
            } label: {
                HStack(spacing: Layout.control) {
                    Label("Fournisseurs de tâches", systemImage: "checklist")
                    Spacer()
                    Text(active.isEmpty
                         ? "Aucun"
                         : active.map(\.provider.label).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("Tâches")
        } footer: {
            Text("Rappels, Todoist, Things, Notion, Microsoft To Do, Google Tasks, TickTick ou un webhook.")
        }
    }

    // MARK: Import intelligent

    private var aiSection: some View {
        Section {
            NavigationLink {
                AIImportSettingsView()
            } label: {
                HStack(spacing: Layout.control) {
                    Label("Import intelligent des PDF", systemImage: "sparkles")
                    Spacer()
                    Text(SeriesAIExtractor.plannedSource(app.settings)?.label ?? "désactivé")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("Analyse des PDF")
        } footer: {
            Text("Un modèle de langage — sur l'appareil quand c'est possible — complète la détection des séries et des exercices.")
        }
    }

    // MARK: Charge EPFL

    private func workloadSection(_ settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return Section {
            Stepper(value: Binding(
                get: { Int(settings.hoursPerCredit) },
                set: { settings.hoursPerCredit = Double($0) }
            ), in: 20...40, step: 1) {
                LabeledContent("Heures par crédit ECTS", value: "\(Int(settings.hoursPerCredit)) h")
            }
        } header: {
            Text("Charge de travail EPFL")
        } footer: {
            Text("Charge attendue = crédits × heures par crédit, dont les heures d'amphi déclarées des cours qui en ont.")
        }
    }

    // MARK: Focus

    /// Le cycle Pomodoro : le même formulaire que depuis le chrono.
    @ViewBuilder
    private func focusSection(_ settings: SettingsStore) -> some View {
        PomodoroSettingsForm(settings: settings)
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
            Text("Notifications")
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
        return Section("Confidentialité") {
            Toggle("Apparaître anonymement dans les classements", isOn: $settings.anonymousInLeaderboards)
            Toggle("Partager mon avancement avec mes groupes", isOn: $settings.shareProgressWithGroups)
            Toggle("Suivre la présence en amphi", isOn: $settings.trackAttendance)
        }
    }

    // MARK: Données

    private var dataSection: some View {
        Section {
            NavigationLink {
                StatsView()
            } label: {
                Label("Statistiques et récapitulatif", systemImage: "chart.bar.fill")
            }
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
            Button {
                shareAssistantExport()
            } label: {
                Label("Exporter pour un assistant", systemImage: "sparkles")
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
            Text("Données")
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
                    .foregroundStyle(app.social.isSignedIn ? Color.green.accessibleInk : Color.orange.accessibleInk)
            }
            if let error = app.social.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.red.accessibleInk)
            }
        } header: {
            Text("Groupes (Supabase)")
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
    private static func appleMessage(for error: Error) -> String {
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

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var aboutSection: some View {
        Section("À propos") {
            LabeledContent("Version", value: Self.versionLabel)
            Text("StudyTrack — suivi du temps d'étude EPFL : théorie par vidéos, exercices et corrections, charge attendue, agenda, groupes et intégrations.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
