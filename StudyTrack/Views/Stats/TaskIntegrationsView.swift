import SwiftUI

/// Les fournisseurs de tâches, un bloc par fournisseur, avec l'état et la notice.
///
/// Sorti du profil : huit blocs de champs et d'aide en ligne noyaient les réglages
/// qui servent tous les jours (section, semestre, notifications).
struct TaskIntegrationsView: View {
    @Environment(AppContainer.self) private var app

    /// Fournisseur dont la notice de configuration est ouverte.
    @State private var guideProvider: TaskProvider?
    @State private var testMessage: String?
    @State private var testing: TaskProvider?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                ForEach(TaskProvider.allCases) { provider in
                    providerBlock(provider, settings: settings)
                }
            } header: {
                Text("Fournisseurs")
            } footer: {
                Text("Les fournisseurs en écriture seule ne peuvent pas être relus : la tâche est créée, mais son état reste local. Les jetons restent sur l'appareil et ne sont envoyés qu'au service concerné.")
            }

            if let testMessage {
                Section {
                    Text(testMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Fournisseurs de tâches")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $guideProvider) { provider in
            ProviderGuideView(provider: provider)
        }
    }

    @ViewBuilder
    private func providerBlock(_ provider: TaskProvider, settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        let service = TaskServiceFactory.shared.service(for: provider, settings: settings)
        let configured = service != nil

        VStack(alignment: .leading, spacing: Layout.control) {
            HStack(spacing: Layout.control) {
                Image(systemName: provider.icon)
                    .foregroundStyle(configured ? Theme.accentInk : .secondary)
                    .frame(width: 22)
                Text(provider.label).font(.subheadline.weight(.semibold))
                Spacer()
                if provider.supportsReading {
                    Pill(text: configured ? "actif" : "inactif",
                         color: configured ? .green : .secondary)
                } else {
                    Pill(text: "écriture seule", color: .orange)
                }
            }

            switch provider {
            case .reminders:
                EmptyView()

            case .todoist:
                SecureField("Jeton API", text: $settings.todoistToken)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

            case .things:
                Toggle("Activer Things 3", isOn: $settings.thingsEnabled)

            case .notion:
                SecureField("Jeton d'intégration", text: $settings.notionToken)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("ID de la base de données", text: $settings.notionDatabaseID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

            case .webhook:
                TextField("https://…", text: $settings.webhookURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

            case .microsoftToDo:
                SecureField("Jeton d'accès Microsoft Graph", text: $settings.microsoftToken)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

            case .googleTasks:
                SecureField("Identifiant client OAuth", text: $settings.googleClientID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Secret client OAuth", text: $settings.googleClientSecret)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Refresh token", text: $settings.googleRefreshToken)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

            case .tickTick:
                SecureField("Jeton d'accès TickTick", text: $settings.tickTickToken)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Text(provider.helpText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Layout.gutter) {
                Button {
                    guideProvider = provider
                } label: {
                    Label("Comment configurer ?", systemImage: "questionmark.circle")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)

                // Un jeton collé ne dit pas s'il marche : « Tester » pose la
                // question au service, et affiche la réponse ici.
                if configured, provider.supportsReading, let service {
                    Button {
                        test(service)
                    } label: {
                        if testing == provider {
                            HStack(spacing: Layout.snug) {
                                ProgressView()
                                Text("Test…")
                            }
                            .font(.footnote)
                        } else {
                            Label("Tester", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.footnote)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(testing != nil)
                }
            }
        }
        .padding(.vertical, Layout.tight)
    }

    private func test(_ service: TaskService) {
        testing = service.provider
        testMessage = nil
        Task {
            let granted = await service.requestAccess()
            guard granted else {
                testing = nil
                testMessage = "\(service.provider.label) : accès refusé ou jeton invalide."
                return
            }
            let tasks = await service.fetchTasks()
            testing = nil
            testMessage = "\(service.provider.label) : \(tasks.count) tâche\(tasks.count > 1 ? "s" : "") lisible\(tasks.count > 1 ? "s" : "")."
            Haptics.success()
        }
    }
}
