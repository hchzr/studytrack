import Foundation
import SwiftData
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Le transport du moteur de synchronisation vers les tables `sync_*` de Supabase
/// (PostgREST) : le pendant de `windows/src/sync/supabaseTransport.ts`.
final class SupabaseSyncTransport: SyncTransport {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func push(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
        guard !rows.isEmpty else { return [] }
        // Upsert : la garde du serveur (sync_guard) garde la plus récente, et
        // return=representation renvoie la version gardée, la nôtre ou la sienne.
        let data = try await client.upsert(table, rows: rows, onConflict: "id", returning: true)
        return Self.rows(from: data)
    }

    func pull(table: String, since: String?, afterID: String?, limit: Int) async throws -> [[String: Any]] {
        var query = [URLQueryItem(name: "select", value: "*"),
                     URLQueryItem(name: "order", value: "server_updated_at.asc,id.asc"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let since, let afterID {
            query.append(URLQueryItem(name: "or", value: Self.keysetFilter(since: since, afterID: afterID)))
        } else if let since {
            query.append(URLQueryItem(name: "server_updated_at", value: "gt.\(since)"))
        }
        return Self.rows(from: try await client.select(table, query: query))
    }

    static func keysetFilter(since: String, afterID: String) -> String {
        "(server_updated_at.gt.\(since),and(server_updated_at.eq.\(since),id.gt.\(afterID)))"
    }

    private static func rows(from data: Data?) -> [[String: Any]] {
        guard let data, !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return json
    }
}

/// La synchronisation des données personnelles vers Supabase (iPhone, Mac, Windows).
///
/// **Désactivée par défaut** : personne n'envoie ses données sans l'avoir demandé,
/// et il faut un compte (le même que les groupes). Elle s'ajoute à iCloud sans le
/// remplacer : iCloud relie les appareils Apple, Supabase y ajoute Windows.
///
/// Coût au repos nul : aucune minuterie tant que rien ne change. Elle réagit aux
/// enregistrements SwiftData (regroupés 3 s), à l'arrivée de données iCloud, au
/// retour de l'app au premier plan, et relit toutes les 5 min **seulement app
/// active**. Un enregistrement qui ne touche aucune table synchronisée, ou qu'elle
/// fait elle-même, est ignoré.
@MainActor
@Observable
final class SupabaseSync {

    /// Le drapeau, propre à l'appareil.
    static let enabledKey = "sync.supabase.enabled"
    private static let lastSyncKey = "sync.supabase.lastSync"
    private static let lastErrorKey = "sync.supabase.lastError"
    private static let lastReportKey = "sync.supabase.lastReport"

    /// Attente après un enregistrement : grouper les saisies en une passe.
    static let writeDebounce: Duration = .seconds(3)
    /// Période du rattrapage (app active seulement).
    static let periodic: Duration = .seconds(5 * 60)
    /// Pas de relecture complète plus souvent que ça au retour au premier plan.
    static let minimumPullInterval: TimeInterval = 60

    private(set) var isEnabled: Bool
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var lastReport: String?
    /// Une suppression massive attend ta confirmation.
    private(set) var awaitingMassDeletion = false
    /// Le compte connecté (courriel), pour l'affichage.
    private(set) var accountEmail: String?
    private(set) var isSignedIn = false
    /// Fournisseurs de connexion du compte (« apple », « email »…), lus sur le serveur ; vide tant qu'inconnus.
    private(set) var accountProviders: [String] = []

    @ObservationIgnored let client: SupabaseClient?
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let stateURL: URL?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var store: SyncStateStore?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var lastPull: Date?
    @ObservationIgnored private var rerun: (pull: Bool, accept: Bool)?

    /// L'instance de l'app (posée au lancement) : les réglages la retrouvent ici.
    nonisolated(unsafe) static var shared: SupabaseSync?

    var isConfigured: Bool { client != nil }

    init(container: ModelContainer, client: SupabaseClient?, stateURL: URL? = SyncStateStore.defaultURL,
         defaults: UserDefaults = .standard) {
        self.container = container
        self.client = client
        self.stateURL = stateURL
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.lastSyncAt = defaults.object(forKey: Self.lastSyncKey) as? Date
        self.lastError = defaults.string(forKey: Self.lastErrorKey)
        self.lastReport = defaults.string(forKey: Self.lastReportKey)
        refreshAccount()
    }

    // MARK: - Compte

    /// Relit la session du client (après une connexion, une déconnexion, un jeton refusé).
    func refreshAccount() {
        isSignedIn = client?.isSignedIn ?? false
        accountEmail = client?.userEmail
    }

    func signIn(email: String, password: String) async -> Bool {
        await authenticate { try await $0.signIn(email: email, password: password) }
    }

    func signUp(email: String, password: String) async -> Bool {
        await authenticate { try await $0.signUp(email: email, password: password) }
    }

    /// Relit les fournisseurs du compte (pour dire s'il a déjà un mot de passe).
    func refreshProviders() async {
        guard let client, client.isSignedIn else { accountProviders = []; return }
        if let list = try? await client.fetchProviders() { accountProviders = list }
    }

    /// Définit un mot de passe pour les autres appareils. Rend `nil` si c'est fait, sinon le message d'échec.
    func setPassword(_ password: String, confirmation: String) async -> String? {
        if let problem = SupabasePasswordUpdate.validate(password, confirmation: confirmation) { return problem.message }
        guard let client, client.isSignedIn else { return "Connecte-toi d'abord." }
        do {
            try await client.updatePassword(password)
            return nil
        } catch SupabaseError.server(let status, let message) {
            return SupabasePasswordUpdate.message(forStatus: status, body: message)
        } catch {
            return Self.message(for: error)
        }
    }

    func signOut() async {
        await client?.signOut()
        refreshAccount()
    }

    private func authenticate(_ body: (SupabaseClient) async throws -> Void) async -> Bool {
        guard let client else { return false }
        do {
            try await body(client)
            lastError = nil
            refreshAccount()
            if isEnabled { requestSync(pull: true) }
            return isSignedIn
        } catch {
            lastError = Self.message(for: error)
            refreshAccount()
            return false
        }
    }

    // MARK: - Réglage

    /// L'opt-in. L'allumer part une passe : l'appareil qui décide de synchroniser y
    /// envoie ce qu'il a déjà (l'« envoi initial »), pas seulement ce qui vient.
    func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        guard value != isEnabled else { return }
        isEnabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value {
            lastError = nil
            start()
            requestSync(pull: true)
            startPeriodicIfNeeded()
        } else {
            debounce?.cancel()
            periodicTask?.cancel()
            periodicTask = nil
        }
    }

    // MARK: - Déclencheurs

    /// Branche les observateurs (une fois). Sans effet tant que la synchronisation est éteinte.
    func start() {
        guard !started else { return }
        started = true
        let synced = Set(SyncSchema.tables.map(\.entityName))
        let center = NotificationCenter.default
        // `queue: nil` : l'observateur s'exécute chez l'émetteur, donc pendant que
        // `SyncSaveGate` est encore levé pour les enregistrements de la synchronisation.
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] note in
            if SyncSaveGate.shared.isActive { return }
            let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            let ids = keys.flatMap { (note.userInfo?[$0.rawValue] as? [PersistentIdentifier]) ?? [] }
            // Un enregistrement qui ne touche aucune table synchronisée ne coûte rien.
            if !ids.isEmpty, !ids.contains(where: { synced.contains($0.entityName) }) { return }
            Task { @MainActor in self?.noteLocalChange() }
        })
        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.noteLocalChange() }
        })
        #if canImport(UIKit)
        let active = UIApplication.didBecomeActiveNotification, resign = UIApplication.willResignActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification, resign = NSApplication.willResignActiveNotification
        #endif
        observers.append(center.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
        observers.append(center.addObserver(forName: resign, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignedActive() }
        })
        #if canImport(UIKit)
        isActive = UIApplication.shared.applicationState == .active
        #else
        isActive = NSApplication.shared.isActive
        #endif
        if isEnabled {
            // Le lancement : rattraper ce qu'un appareil resté fermé a manqué.
            requestSync(pull: true)
            startPeriodicIfNeeded()
        }
    }

    private func becameActive() {
        isActive = true
        guard isEnabled else { return }
        refreshAccount()
        if lastPull.map({ Date().timeIntervalSince($0) > Self.minimumPullInterval }) ?? true {
            requestSync(pull: true)
        }
        startPeriodicIfNeeded()
    }

    private func resignedActive() {
        isActive = false
        periodicTask?.cancel()
        periodicTask = nil
        // Ce qui attend le délai part tout de suite : l'app va dormir.
        if isEnabled, debounce != nil {
            debounce?.cancel()
            debounce = nil
            requestSync(pull: false)
        }
    }

    private func startPeriodicIfNeeded() {
        guard isEnabled, isActive, periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodic)
                guard !Task.isCancelled else { return }
                await self?.run(pull: true, accept: false)
            }
        }
    }

    /// Un enregistrement a eu lieu (ici, ou iCloud) : une passe d'envoi, dans trois secondes.
    func noteLocalChange() {
        guard isEnabled else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDebounce)
            guard !Task.isCancelled else { return }
            self?.debounce = nil
            await self?.run(pull: false, accept: false)
        }
    }

    /// « Synchroniser maintenant ».
    func syncNow(acceptMassDeletion: Bool = false) async {
        await run(pull: true, accept: acceptMassDeletion)
    }

    private func requestSync(pull: Bool) {
        Task { await run(pull: pull, accept: false) }
    }

    // MARK: - Une passe

    private func run(pull: Bool, accept: Bool) async {
        guard isEnabled else { return }
        guard let client else {
            lastError = "La synchronisation n'est pas configurée dans cette version."
            return
        }
        guard client.isSignedIn, let userID = client.userID else {
            refreshAccount()
            lastError = "Connecte-toi pour synchroniser."
            return
        }
        if isSyncing {
            // Une passe tourne : celle-ci repart juste après (la plus complète l'emporte).
            let previous = rerun
            rerun = (pull: (previous?.pull ?? false) || pull, accept: (previous?.accept ?? false) || accept)
            return
        }
        isSyncing = true
        awaitingMassDeletion = false
        defer { isSyncing = false }

        let engine = prepareEngine(userID: userID, client: client)
        do {
            let report = try await engine.sync(pull: pull, acceptMassDeletion: accept)
            if pull { lastPull = Date() }
            lastError = nil
            lastSyncAt = Date()
            lastReport = report.summary
            persistStatus()
        } catch let failure as SyncEngine.Failure {
            if case .massDeletion = failure { awaitingMassDeletion = true }
            lastError = failure.localizedDescription
            persistStatus()
        } catch {
            lastError = Self.message(for: error)
            persistStatus()
        }
        refreshAccount()
        if let next = rerun {
            rerun = nil
            await run(pull: next.pull, accept: next.accept)
        }
    }

    private func prepareEngine(userID: String, client: SupabaseClient) -> SyncEngine {
        let store = self.store ?? SyncStateStore(url: stateURL)
        self.store = store
        // Un autre compte : l'état de l'ancien (curseurs, empreintes) ne vaut rien pour le nouveau.
        if store.state.userID != userID.lowercased() {
            store.reset(userID: userID.lowercased())
            engine = nil
        }
        if let engine { return engine }
        let created = SyncEngine(container: container, transport: SupabaseSyncTransport(client: client), store: store)
        engine = created
        return created
    }

    private func persistStatus(defaults: UserDefaults = .standard) {
        defaults.set(lastSyncAt, forKey: Self.lastSyncKey)
        defaults.set(lastError, forKey: Self.lastErrorKey)
        defaults.set(lastReport, forKey: Self.lastReportKey)
    }

    static func message(for error: Error) -> String {
        if let error = error as? SupabaseError {
            switch error {
            case .server(let status, let message):
                if status == 404 || message.contains("PGRST205") {
                    return "Le serveur n'a pas encore les tables de synchronisation."
                }
                if status >= 500 { return "Le serveur a un problème (\(status)) : réessaie dans un instant." }
                if status == 400 || status == 401 || status == 403, message.lowercased().contains("invalid") || message.lowercased().contains("credentials") {
                    return "Adresse e-mail ou mot de passe refusé."
                }
                return "Erreur serveur (\(status)) : \(message.prefix(160))"
            default:
                return error.localizedDescription
            }
        }
        if error is URLError { return "Réseau indisponible : vérifie ta connexion." }
        return error.localizedDescription
    }
}
