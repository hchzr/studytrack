import SwiftUI

/// Réglages › Comptes › Synchronisation : envoyer ses données à son compte StudyTrack
/// pour les retrouver sur le Mac et sur Windows. Éteinte par défaut.
struct SupabaseSyncSection: View {
    @Environment(AppContainer.self) private var app
    @State private var showingPassword = false
    @State private var linkMessage: String?

    var body: some View {
        let sync = app.supabaseSync
        let signedIn = app.social.isSignedIn
        Section {
            if !SupabaseConfig.isConfigured {
                Label { Text(ui: "Synchronisation indisponible dans cette version") } icon: { Image(systemName: "icloud.slash") }
                    .font(.subheadline)
            } else {
                Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })) {
                    Text(ui: "Synchroniser mes données")
                }
                .disabled(!sync.isEnabled && !(signedIn && sync.encryption == .ready))
                // Les modificateurs d'une Section se posent sur chacune de ses lignes : la feuille du
                // mot de passe, présentée par toutes à la fois, se refermait aussitôt. Une seule ligne la porte.
                .sheet(isPresented: $showingPassword) { SetPasswordSheet(sync: sync) }
                .task(id: signedIn) { await sync.refreshProviders() }
                .onChange(of: signedIn) { _, _ in sync.refreshAccount() }

                if signedIn {
                    SyncEncryptionPanel(sync: sync)
                }

                if signedIn, let email = app.social.email ?? sync.accountEmail {
                    LabeledContent {
                        Text(email)
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } label: {
                        Text(ui: "Adresse du compte")
                    }
                    Button {
                        UIPasteboard.general.string = email
                    } label: {
                        Label { Text(ui: "Copier l'adresse") } icon: { Image(systemName: "doc.on.doc") }
                    }
                    Text(ui: "C'est l'adresse à utiliser sur Windows et le Mac.")
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                    Button {
                        showingPassword = true
                    } label: {
                        Label { Text(ui: sync.accountProviders.contains("apple")
                                     ? "Définir un mot de passe pour les autres appareils"
                                     : "Changer le mot de passe") } icon: { Image(systemName: "key") }
                    }
                }

                if signedIn, !sync.accountProviders.contains("google") {
                    Button {
                        Task {
                            linkMessage = nil
                            let ok = await app.social.signInWithGoogle(link: true)
                            if !ok { linkMessage = app.social.lastError }
                            await sync.refreshProviders()
                        }
                    } label: {
                        Label { Text(ui: "Lier un compte Google") } icon: { Image(systemName: "link") }
                    }
                    if let linkMessage {
                        Text(linkMessage).font(.footnote).foregroundStyle(Carnet.wrong)
                    }
                }

                if !signedIn {
                    Text(ui: "Connecte-toi d'abord dans Comptes › Compte et groupes.")
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                }

                if sync.isEnabled {
                    LabeledContent {
                        if sync.isSyncing {
                            ProgressView()
                        } else {
                            Text(Self.lastSyncText(sync.lastSyncAt))
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                    } label: {
                        Text(ui: "Dernière synchronisation")
                    }
                    if let report = sync.lastReport, sync.lastError == nil {
                        Text(report)
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        Label { Text(ui: "Synchroniser maintenant") } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(sync.isSyncing || !signedIn)
                    if sync.awaitingMassDeletion {
                        Button(role: .destructive) {
                            Task { await sync.syncNow(acceptMassDeletion: true) }
                        } label: {
                            Label { Text(ui: "Confirmer la suppression sur les autres appareils") } icon: { Image(systemName: "trash") }
                        }
                    }
                }
                if let error = sync.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Carnet.wrong)
                }
            }
        } header: {
            CarnetFormHeader("Synchronisation")
        } footer: {
            Text(ui: "Envoie tes cours, séries, exercices et sessions à ton compte StudyTrack pour les retrouver sur le Mac et sur Windows, en plus d'iCloud. Désactivée par défaut.")
        }
    }

    static func lastSyncText(_ date: Date?) -> String {
        guard let date else { return Bundle.main.localizedString(forKey: "jamais", value: "jamais", table: nil) }
        return date.formatted(.relative(presentation: .named))
    }
}

/// Donner un mot de passe à son compte (ou le changer), pour se connecter sur Windows et le Mac.
private struct SetPasswordSheet: View {
    let sync: SupabaseSync
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var message: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(text: $password) { Text(ui: "Mot de passe") }
                        .textContentType(.newPassword)
                    SecureField(text: $confirmation) { Text(ui: "Confirmer le mot de passe") }
                        .textContentType(.newPassword)
                } footer: {
                    Text(ui: "6 caractères au moins. Tu t'en serviras avec l'adresse du compte sur Windows et le Mac.")
                }
                if done {
                    Text(ui: "Mot de passe défini.").foregroundStyle(Carnet.correct)
                } else if let message {
                    Text(message).font(.footnote).foregroundStyle(Carnet.wrong)
                }
            }
            .navigationTitle(Text(ui: "Mot de passe"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(ui: done ? "Fermer" : "Annuler") } }
                if !done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task {
                                working = true
                                message = await sync.setPassword(password, confirmation: confirmation)
                                done = message == nil
                                working = false
                            }
                        } label: { Text(ui: "Enregistrer") }
                        .disabled(working || password.isEmpty)
                    }
                }
            }
        }
    }
}
