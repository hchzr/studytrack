import SwiftUI
import SwiftData
import UIKit

/// « Assistant IA » : relier Claude, ChatGPT ou tout client MCP à ses études.
///
/// L'ancien serveur MCP lisait un fichier exporté à la main puis copié sur un
/// Mac : un instantané figé, en lecture seule, qu'aucun assistant du téléphone
/// ne pouvait atteindre. Ici, une adresse suffit. L'assistant lit l'état à jour
/// et **demande** des modifications que l'app applique elle-même.
struct AssistantSettingsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context

    @State private var syncing = false
    @State private var copied = false
    @State private var confirmingDisconnect = false
    @State private var confirmingRotate = false

    private var url: URL? { AssistantSync.serverURL(token: app.settings.assistantToken) }

    var body: some View {
        Form {
            if !SupabaseConfig.isConfigured {
                Section {
                    Label("Cette version de l'app n'a pas de serveur configuré.", systemImage: "icloud.slash")
                        .foregroundStyle(.secondary)
                }
            } else if let url {
                connectedSections(url)
            } else {
                Section {
                    VStack(alignment: .leading, spacing: Layout.control) {
                        Text("Demande à ton assistant « qu'est-ce qu'il me reste en Analyse cette semaine ? », fais-lui corriger ta série, ou dis-lui « j'ai fini le 3.4, pas sûr de la (b) » : il le note dans StudyTrack.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                if syncing { ProgressView().tint(.white) }
                                Text("Relier un assistant")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Layout.tight)
                        }
                        .buttonStyle(.carnetPrimary)
                        .disabled(syncing)
                    }
                    .padding(.vertical, Layout.tight)
                } footer: {
                    Text("Fonctionne avec Claude (app, web, Claude Code), ChatGPT et tout client MCP. Tes cours, séries, exercices, théorie, évaluations et sessions sont copiés sur le serveur de StudyTrack pour que l'assistant les lise ; rien d'autre (ni compte, ni groupe). Tu peux tout effacer d'un geste.")
                }
            }

            Section {
                capability("Lire", "où tu en es, ce qui reste, tes séries exercice par exercice, tes évaluations, ton temps de travail")
                capability("Noter", "un exercice fait, sa sureté, sa correction, « à refaire », une remarque ; des questions cochées")
                capability("Ajouter", "une série et ses exercices, une évaluation, une session passée, un résumé de théorie")
            } header: {
                Text("Ce que l'assistant peut faire")
            } footer: {
                Text("Il ne peut rien supprimer. Ses demandes sont appliquées par l'app, avec les mêmes règles que l'interface, et listées ci-dessous.")
            }

            if !AssistantSync.lastApplied.isEmpty {
                Section("Dernières modifications de l'assistant") {
                    ForEach(Array(AssistantSync.lastApplied.enumerated()), id: \.offset) { _, result in
                        Label(result.message, systemImage: result.status == "applied" ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(result.status == "applied" ? Color.primary : Color.orange.accessibleInk)
                    }
                }
            }
        }
        .carnetBackground()
        .navigationTitle("Assistant IA")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Déconnecter l'assistant ?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Déconnecter et tout effacer du serveur", role: .destructive) {
                Task { await AssistantSync.disconnect(settings: app.settings) }
            }
        } message: {
            Text("L'adresse cessera de fonctionner, et la copie de tes données sur le serveur sera effacée. Tes données dans l'app ne changent pas.")
        }
        .confirmationDialog("Changer d'adresse ?", isPresented: $confirmingRotate, titleVisibility: .visible) {
            Button("Changer l'adresse", role: .destructive) {
                Task {
                    await AssistantSync.disconnect(settings: app.settings)
                    await connect()
                }
            }
        } message: {
            Text("L'ancienne adresse cessera de fonctionner : il faudra coller la nouvelle dans ton assistant.")
        }
    }

    // MARK: Relié

    @ViewBuilder
    private func connectedSections(_ url: URL) -> some View {
        Section {
            Text(url.absoluteString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    copied = true
                    Haptics.success()
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copiée" : "Copier l'adresse", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.carnetPrimary)
                Spacer()
                ShareLink(item: url) {
                    Label("Partager", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Text(syncLine).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        syncing = true
                        await AssistantSync.sync(context: context, settings: app.settings)
                        syncing = false
                    }
                } label: {
                    if syncing { ProgressView() } else { Text("Synchroniser") }
                }
                .font(.footnote.weight(.semibold))
                .disabled(syncing)
            }
        } header: {
            Text("Adresse du serveur MCP")
        } footer: {
            Text("Cette adresse est un **mot de passe** : qui l'a peut lire tes études et y noter des choses. Ne la colle que dans ton propre assistant.")
        }

        Section("Brancher ton assistant") {
            instruction("Claude (app, web, Desktop)",
                        "Réglages › Connecteurs › Ajouter un connecteur personnalisé. Nom : StudyTrack. Colle l'adresse.")
            instruction("ChatGPT",
                        "Réglages › Applications et connecteurs › Avancé : active le mode développeur, puis Créer. Colle l'adresse, sans authentification.")
            VStack(alignment: .leading, spacing: Layout.tight) {
                Text("Claude Code").font(.subheadline.weight(.semibold))
                let command = "claude mcp add --transport http studytrack \(url.absoluteString)"
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Button("Copier la commande") {
                    UIPasteboard.general.string = command
                    Haptics.success()
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(.vertical, Layout.micro)
        }

        Section {
            Button("Changer d'adresse…") { confirmingRotate = true }
            Button("Déconnecter l'assistant…", role: .destructive) { confirmingDisconnect = true }
        }
    }

    private var syncLine: String {
        if let error = AssistantSync.lastError { return "Échec : \(error)" }
        guard let last = app.settings.assistantLastSync else { return "Jamais synchronisé" }
        return "Synchronisé \(DateUtils.relativeLabel(last).lowercased()) à \(DateUtils.time.string(from: last))"
    }

    private func capability(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Layout.micro) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, Layout.micro)
    }

    private func instruction(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Layout.micro) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Layout.micro)
    }

    private func connect() async {
        syncing = true
        defer { syncing = false }
        app.settings.assistantToken = AssistantSync.makeToken()
        await AssistantSync.sync(context: context, settings: app.settings)
        Haptics.success()
    }
}
