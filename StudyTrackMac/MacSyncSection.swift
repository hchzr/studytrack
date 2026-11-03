import SwiftUI

/// Réglages › iCloud › Synchronisation Supabase : le même interrupteur que sur l'iPhone,
/// avec la connexion au compte StudyTrack (le Mac n'a pas d'autre écran pour ça).
struct MacSupabaseSyncSection: View {
    @State private var sync: SupabaseSync? = SupabaseSync.shared
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        if let sync {
            Section {
                if !sync.isConfigured {
                    Text(ui: "Synchronisation indisponible dans cette version")
                } else if !sync.isSignedIn {
                    TextField(text: $email) { Text(ui: "Adresse e-mail") }
                    SecureField(text: $password) { Text(ui: "Mot de passe") }
                    HStack {
                        Button { Task { await authenticate(sync, signUp: false) } } label: { Text(ui: "Se connecter") }
                        Button { Task { await authenticate(sync, signUp: true) } } label: { Text(ui: "Créer un compte") }
                    }
                    .disabled(working || email.isEmpty || password.count < 6)
                } else {
                    LabeledContent { Text(sync.accountEmail ?? "—") } label: { Text(ui: "Compte") }
                    Toggle(isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })) {
                        Text(ui: "Synchroniser mes données")
                    }
                    if sync.isEnabled {
                        LabeledContent {
                            if sync.isSyncing { ProgressView().controlSize(.small) }
                            else { Text(Self.lastSyncText(sync.lastSyncAt)) }
                        } label: { Text(ui: "Dernière synchronisation") }
                        if let report = sync.lastReport, sync.lastError == nil {
                            Text(report).font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button { Task { await sync.syncNow() } } label: { Text(ui: "Synchroniser maintenant") }
                                .disabled(sync.isSyncing)
                            if sync.awaitingMassDeletion {
                                Button(role: .destructive) { Task { await sync.syncNow(acceptMassDeletion: true) } } label: {
                                    Text(ui: "Confirmer la suppression sur les autres appareils")
                                }
                            }
                        }
                    }
                    Button { Task { await sync.signOut() } } label: { Text(ui: "Se déconnecter") }
                }
                if let error = sync.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text(ui: "Synchronisation Supabase")
            } footer: {
                Text(ui: "Envoie tes cours, séries, exercices et sessions à ton compte StudyTrack pour les retrouver sur l'iPhone et sur Windows, en plus d'iCloud. Désactivée par défaut.")
            }
        }
    }

    private func authenticate(_ sync: SupabaseSync, signUp: Bool) async {
        working = true
        defer { working = false }
        let ok = signUp ? await sync.signUp(email: email, password: password)
                        : await sync.signIn(email: email, password: password)
        if ok { password = "" }
    }

    static func lastSyncText(_ date: Date?) -> String {
        guard let date else { return Bundle.main.localizedString(forKey: "jamais", value: "jamais", table: nil) }
        return date.formatted(.relative(presentation: .named))
    }
}
