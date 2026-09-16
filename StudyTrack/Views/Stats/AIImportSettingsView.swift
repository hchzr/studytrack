import SwiftUI

/// Réglages de l'analyse des PDF par un modèle de langage.
///
/// Le modèle embarqué (Apple Intelligence) ne demande rien. Le service distant
/// est une option pour les appareils qui n'y ont pas droit : n'importe quelle API
/// compatible OpenAI, avec la clé de l'étudiant·e — jamais une clé de l'app.
struct AIImportSettingsView: View {
    @Environment(AppContainer.self) private var app
    @State private var testMessage: String?
    @State private var isTesting = false

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
                Text("Rien à configurer : l'analyse choisit toute seule, dans l'ordre, le modèle sur l'appareil, puis la fonction StudyTrack (clé côté serveur), puis ton service perso si tu en as saisi un. La lecture par motifs est toujours faite d'abord ; le modèle la complète et tout passe par l'écran de relecture.")
            }

            Section {
                HStack(spacing: Layout.control) {
                    Image(systemName: "apple.intelligence")
                        .foregroundStyle(SeriesAIExtractor.isOnDeviceAvailable ? Color.green.accessibleMark : .secondary)
                    Text(SeriesAIExtractor.isOnDeviceAvailable ? "Disponible sur cet appareil" : (SeriesAIExtractor.onDeviceUnavailabilityReason ?? "Indisponible"))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Sur l'appareil")
            } footer: {
                Text("Gratuit, privé et hors ligne : le texte du PDF ne quitte pas le téléphone. Demande iOS 26 et Apple Intelligence activé.")
            }

            Section {
                HStack(spacing: Layout.control) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(SeriesAIExtractor.isSharedAvailable ? Color.green.accessibleMark : .secondary)
                    Text(SeriesAIExtractor.isSharedAvailable
                         ? "Disponible : la clé du fournisseur est sur le serveur de l'app, rien à saisir."
                         : "Indisponible dans cette build (pas de projet Supabase).")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Fonction StudyTrack")
            } footer: {
                Text("Le texte du PDF est envoyé à la fonction `extract-series` du projet Supabase de l'app, qui interroge le fournisseur configuré par le mainteneur (Groq par défaut). Utilisée seulement si le modèle embarqué manque.")
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
