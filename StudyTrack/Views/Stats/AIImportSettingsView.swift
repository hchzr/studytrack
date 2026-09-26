import SwiftUI

/// Réglages de l'analyse des PDF par un modèle de langage.
///
/// **Le modèle servi d'abord, celui de l'appareil ensuite.**
///
/// L'ordre inverse semblait prudent — gratuit, privé, hors ligne — mais il plaçait
/// un modèle de quelques milliards de paramètres devant un modèle servi, sur une
/// tâche qu'il rate souvent. Le modèle embarqué reste le filet : hors ligne, ou
/// quand la fonction n'est pas déployée.
///
/// Le service perso est une troisième option, pour qui veut son propre fournisseur :
/// n'importe quelle API compatible OpenAI, avec la clé de l'étudiant·e — jamais une
/// clé de l'app.
struct AIImportSettingsView: View {
    @Environment(AppContainer.self) private var app
    @State private var testMessage: String?
    @State private var isTesting = false

    /// État réel de la fonction partagée, **constaté** et non supposé.
    ///
    /// L'écran affichait « Disponible » dès que la build portait un projet
    /// Supabase — alors que la fonction `extract-series` peut très bien n'avoir
    /// jamais été déployée. C'était le cas, et c'est ce qui faisait croire à un
    /// import IA « mauvais » plutôt qu'absent.
    private enum SharedStatus: Equatable {
        case unknown
        case checking
        case ready
        /// La fonction n'existe pas : il faut la déployer.
        case notDeployed(String)
        /// La fonction répond, mais l'analyse échoue : clé, modèle ou quota.
        case failing(String)
        case unconfigured(String)
    }

    @State private var sharedStatus: SharedStatus = .unknown
    @State private var onDeviceMessage: String?
    @State private var isTestingOnDevice = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Analyser les PDF avec l'IA", isOn: $settings.aiExtractionEnabled)
                LabeledContent("Moteur utilisé") {
                    Text(SeriesAIExtractor.plannedSource(settings)?.label ?? "aucun")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Import de séries")
            } footer: {
                Text("Rien à configurer : l'analyse essaie, dans l'ordre, la **fonction StudyTrack** (modèle servi, meilleure qualité), puis le **modèle sur l'appareil** (hors ligne), puis ton service perso si tu en as saisi un. La lecture par motifs est toujours faite d'abord ; le modèle la complète et tout passe par l'écran de relecture.")
            }

            Section {
                HStack(alignment: .top, spacing: Layout.control) {
                    Image(systemName: SeriesAIExtractor.isOnDeviceAvailable
                          ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(SeriesAIExtractor.isOnDeviceAvailable
                                         ? Color.green.accessibleMark : .secondary)
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        Text(SeriesAIExtractor.isOnDeviceAvailable
                             ? "Disponible sur cet appareil"
                             : (SeriesAIExtractor.onDeviceUnavailabilityReason ?? "Indisponible"))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let onDeviceMessage {
                            Text(onDeviceMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: Layout.inline)
                    if isTestingOnDevice { ProgressView() }
                }

                if SeriesAIExtractor.isOnDeviceAvailable {
                    Button {
                        Task { await checkOnDevice() }
                    } label: {
                        Label("Tester sur cet appareil", systemImage: "apple.intelligence")
                    }
                    .disabled(isTestingOnDevice)
                }
            } header: {
                Text("Sur l'appareil")
            } footer: {
                Text("Gratuit, privé et hors ligne : le texte du PDF ne quitte pas le téléphone. Demande iOS 26 et Apple Intelligence activé. **Sert de relais** : quand la fonction StudyTrack n'est pas joignable — hors ligne, ou pas encore déployée. Sur une série d'exercices réels, ses lectures sont moins fiables que celles d'un modèle servi : relis l'écran de relecture d'autant plus attentivement.")
            }

            Section {
                HStack(alignment: .top, spacing: Layout.control) {
                    Image(systemName: sharedIcon)
                        .foregroundStyle(sharedTint)
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        Text(sharedTitle)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = sharedDetail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: Layout.inline)
                    if sharedStatus == .checking { ProgressView() }
                }

                if SeriesAIExtractor.isSharedAvailable, sharedStatus != .ready {
                    Button {
                        Task { await checkShared() }
                    } label: {
                        Label("Vérifier la fonction", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(sharedStatus == .checking)
                }
            } header: {
                Text("Fonction StudyTrack")
            } footer: {
                Text("**Essayée en premier.** Le texte du PDF est envoyé à la fonction `extract-series` du projet Supabase de l'app, qui interroge un modèle servi (Groq par défaut). C'est le moteur qui lit le mieux les séries réelles : numéros, bonus, intitulés. Elle doit être **déployée** une fois (voir `Support/SUPABASE.md`) ; sans cela, l'analyse se rabat sur le modèle de l'appareil, puis sur la lecture par motifs.")
            }

            Section {
                TextField("URL de base (…/v1)", text: $settings.aiEndpoint)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                SecureField("Clé d'API", text: $settings.aiAPIKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Modèle", text: $settings.aiModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    test()
                } label: {
                    if isTesting {
                        HStack(spacing: Layout.snug) {
                            ProgressView()
                            Text("Test…")
                        }
                    } else {
                        Label("Tester le service", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(isTesting || !SeriesAIExtractor.isRemoteConfigured(settings))

                Button("Pré-remplir pour Groq") {
                    settings.aiEndpoint = SettingsStore.defaultAIEndpoint
                    settings.aiModel = SettingsStore.defaultAIModel
                }

                if let testMessage {
                    Text(testMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Service perso (facultatif)")
            } footer: {
                Text("Pour choisir ton propre modèle : n'importe quelle API compatible OpenAI (Groq et OpenRouter ont un palier gratuit, Ollama tourne sur un Mac). La clé reste sur l'appareil. Ce maillon n'est utilisé que si les deux précédents ont échoué.")
            }
        }
        .navigationTitle("Import intelligent")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // On constate au lieu d'affirmer : l'écran ne doit pas dire
            // « disponible » sans avoir posé la question au serveur.
            if SeriesAIExtractor.isSharedAvailable, sharedStatus == .unknown {
                await checkShared()
            }
        }
    }

    // MARK: Fonction partagée

    private var sharedIcon: String {
        switch sharedStatus {
        case .ready: return "checkmark.circle.fill"
        case .checking: return "sparkles"
        // Déployée mais en échec : la fonction existe, c'est la clé ou le modèle
        // qui coince — une nuance que l'icône dit aussi.
        case .failing: return "exclamationmark.arrow.triangle.2.circlepath"
        case .notDeployed, .unconfigured: return "exclamationmark.triangle.fill"
        case .unknown: return SeriesAIExtractor.isSharedAvailable ? "questionmark.circle" : "minus.circle"
        }
    }

    private var sharedTint: Color {
        switch sharedStatus {
        case .ready: return .green.accessibleMark
        case .notDeployed: return .orange.accessibleInk
        case .failing: return .orange.accessibleInk
        case .unconfigured: return .secondary
        default: return SeriesAIExtractor.isSharedAvailable ? .secondary : .secondary
        }
    }

    /// Le détail technique, quand il y en a un.
    private var sharedDetail: String? {
        switch sharedStatus {
        case .notDeployed(let detail), .failing(let detail), .unconfigured(let detail):
            return detail
        case .unknown, .checking, .ready:
            return nil
        }
    }

    private var sharedTitle: String {
        guard SeriesAIExtractor.isSharedAvailable else {
            return "Indisponible dans cette build : aucun projet Supabase n'est compilé."
        }
        switch sharedStatus {
        case .ready:
            return "Déployée et joignable : la clé du fournisseur est sur le serveur, rien à saisir."
        case .checking:
            return "Vérification…"
        case .notDeployed:
            return "Pas encore déployée sur ton projet — l'import se rabat sur la lecture par motifs."
        case .failing:
            // La fonction **répond** : dire « pas déployée » enverrait déployer une
            // fonction qui l'est déjà, au lieu de corriger la clé ou le modèle.
            return "Déployée et joignable, mais l'analyse échoue — l'import se rabat sur la lecture par motifs."
        case .unconfigured:
            return "Aucun projet Supabase compilé dans cette version."
        case .unknown:
            return "État inconnu : appuie sur « Vérifier la fonction »."
        }
    }

    private func checkOnDevice() async {
        isTestingOnDevice = true
        onDeviceMessage = nil
        onDeviceMessage = await SeriesAIExtractor.diagnoseOnDevice()
        isTestingOnDevice = false
    }

    private func checkShared() async {
        sharedStatus = .checking
        switch await SeriesAIExtractor.diagnoseShared() {
        case .ready:
            sharedStatus = .ready
        case .notDeployed(let status):
            sharedStatus = .notDeployed("HTTP \(status) — la fonction n'existe pas sur le projet.")
        case .failing(let detail):
            sharedStatus = .failing(detail)
        case .unconfigured:
            sharedStatus = .unconfigured("Aucun projet Supabase n'est compilé dans cette version.")
        }
    }

    /// Un mini-PDF de test : deux exercices, un bonus. Si le service renvoie la
    /// structure, il est prêt.
    private func test() {
        isTesting = true
        testMessage = nil
        let sample = "Série 3 — Récurrences\nExercice 3.1 Tri fusion\nExercice 3.2 (bonus) Master theorem"
        Task {
            defer { isTesting = false }
            do {
                // On force le distant : c'est lui qu'on teste, pas le modèle local.
                let probe = SettingsStore(defaults: UserDefaults(suiteName: "studytrack.ai.probe") ?? .standard)
                probe.aiExtractionEnabled = true
                probe.aiEndpoint = app.settings.aiEndpoint
                probe.aiAPIKey = app.settings.aiAPIKey
                probe.aiModel = app.settings.aiModel
                let result = try await SeriesAIExtractor.extractRemoteForTest(sample, settings: probe)
                let count = result.reduce(0) { $0 + $1.exercises.count }
                testMessage = count >= 2
                    ? "Le service répond : \(result.count) série, \(count) exercices reconnus."
                    : "Le service répond, mais n'a reconnu que \(count) exercice(s) sur 2 : essaie un autre modèle."
                Haptics.success()
            } catch {
                testMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
