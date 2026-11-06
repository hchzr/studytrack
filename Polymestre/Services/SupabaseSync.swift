import CryptoKit
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

    /// Où en est le chiffrement de bout en bout du compte connecté (docs/sync-e2ee.md) :
    /// pas de compte ; coffre pas encore lu ; aucun coffre (personne n'a activé) ; le compte
    /// est chiffré mais cet appareil n'a pas la clé ; la clé d'ici n'est pas celle du coffre
    /// (réinitialisé ailleurs) ; tout est en place.
    enum EncryptionState: Equatable { case signedOut, unknown, noVault, needsKey, keyMismatch, ready }
    private(set) var encryption: EncryptionState = .signedOut
    /// Lignes laissées de côté à la dernière passe : autre clé, illisibles.
    private(set) var skippedForeignKey = 0
    private(set) var skippedUnreadable = 0
    /// Le build connaît le relais : l'appairage est possible (sinon, la clé de secours).
    var pairingAvailable: Bool { relayHost != nil }

    enum VaultInfo: Equatable { case unknown, none, exists(String) }
    @ObservationIgnored private var vault: VaultInfo = .unknown
    @ObservationIgnored private var vaultUserID: String?
    @ObservationIgnored let relayHost: String?
    @ObservationIgnored private var pairingHost: SyncPairingHost?

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
         defaults: UserDefaults = .standard, relayHost: String? = RelayPairSocket.configuredHost) {
        self.relayHost = relayHost
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
        updateEncryption()
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

    /// « Continuer avec Google », ou lier Google au compte connecté.
    func signInWithGoogle(link: Bool = false) async -> Bool {
        let ok = await authenticate { try await $0.continueWithGoogle(link: link) }
        await refreshProviders()
        return ok
    }

    func signOut() async {
        await pairingHost?.cancel()
        pairingHost = nil
        await client?.signOut()
        refreshAccount()
    }

    private func authenticate(_ body: (SupabaseClient) async throws -> Void) async -> Bool {
        guard let client else { return false }
        do {
            try await body(client)
            lastError = nil
            refreshAccount()
            Task { await refreshVault() }
            if isEnabled { requestSync(pull: true) }
            return isSignedIn
        } catch {
            lastError = Self.message(for: error)
            refreshAccount()
            return false
        }
    }


    // MARK: - Chiffrement de bout en bout

    /// Un message d'erreur destiné à l'écran.
    struct EncryptionFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func updateEncryption() {
        guard isSignedIn, let uid = client?.userID?.lowercased() else {
            encryption = .signedOut
            return
        }
        if vaultUserID != uid { vault = .unknown; vaultUserID = uid }
        switch vault {
        case .unknown: encryption = .unknown
        case .none: encryption = .noVault
        case .exists(let keyID):
            if let ak = SyncKeyStore.load(userID: uid), let keys = try? SyncCrypto.keys(for: ak) {
                encryption = keys.keyID == keyID ? .ready : .keyMismatch
            } else {
                encryption = .needsKey
            }
        }
    }

    /// Lit le coffre du compte (`sync_vault`) : il dit si un coffre existe et quelle clé il attend.
    private func loadVault() async throws {
        guard let client, client.isSignedIn else { vault = .unknown; updateEncryption(); return }
        let data = try await client.select("sync_vault", query: [URLQueryItem(name: "select", value: "key_id")])
        let rows = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }) ?? []
        vaultUserID = client.userID?.lowercased()
        vault = (rows.first?["key_id"] as? String).map(VaultInfo.exists) ?? .none
        updateEncryption()
    }

    /// Relit le coffre ; une panne laisse l'état tel quel (l'écran réessaiera).
    func refreshVault() async {
        try? await loadVault()
    }

    /// Les clés d'une passe, ou la raison (en français) pour laquelle il n'y en a pas.
    private func keysForPass(userID: String) async throws -> SyncCrypto.Keys {
        try await loadVault() // une petite requête : un coffre réinitialisé ailleurs se voit ici
        switch vault {
        case .unknown, .none:
            throw EncryptionFailure(message: "Active d'abord la synchronisation chiffrée.")
        case .exists(let keyID):
            guard let ak = SyncKeyStore.load(userID: userID), let keys = try? SyncCrypto.keys(for: ak) else {
                throw EncryptionFailure(message: "Ce compte est chiffré : ajoute cet appareil depuis un appareil déjà connecté.")
            }
            guard keys.keyID == keyID else { throw EncryptionFailure(message: SyncMessages.foreignKey) }
            return keys
        }
    }

    private func requireUser() throws -> (client: SupabaseClient, userID: String) {
        guard let client, client.isSignedIn, let userID = client.userID else { throw EncryptionFailure(message: "Connecte-toi d'abord.") }
        return (client, userID.lowercased())
    }

    /// Une clé vient d'arriver ou de changer : allume la synchronisation, ou relance une passe si elle l'est déjà.
    private func kickAfterKeyChange() {
        if isEnabled { lastError = nil; requestSync(pull: true) } else { setEnabled(true) }
    }

    private func storeKey(_ ak: Data, userID: String) throws {
        guard SyncKeyStore.save(ak, userID: userID) else {
            throw EncryptionFailure(message: "Impossible de ranger la clé dans le trousseau de cet appareil.")
        }
    }

    /// Après un changement de clé : `full` repart de zéro (coffre neuf : tout est à renvoyer) ;
    /// sinon seuls les curseurs repartent (on relit tout avec la clé reçue).
    private func resetSyncState(userID: String, full: Bool) {
        let store = syncStore()
        if full {
            store.reset(userID: userID)
        } else {
            store.state.cursors = [:]
            store.markChanged()
            store.save()
        }
    }

    /// Crée le coffre du compte : une clé neuve, rangée ici seulement, et son identifiant public.
    /// Rend la clé de secours, à montrer une fois. Allume la synchronisation.
    func enableEncryption() async throws -> String {
        let (client, userID) = try requireUser()
        try await loadVault()
        guard vault == .none else {
            throw EncryptionFailure(message: "Ce compte est déjà chiffré : ajoute cet appareil par un code ou la clé de secours.")
        }
        let recovery = try await createVault(client: client, userID: userID)
        kickAfterKeyChange()
        return recovery
    }

    private func createVault(client: SupabaseClient, userID: String) async throws -> String {
        let ak = SyncCrypto.newAccountKey()
        let keys = try SyncCrypto.keys(for: ak)
        do {
            try await client.insert("sync_vault", values: ["key_id": keys.keyID], returning: false)
        } catch SupabaseError.server(let status, _) where status == 409 {
            await refreshVault()
            throw EncryptionFailure(message: "Un autre appareil vient d'activer le chiffrement sur ce compte : ajoute cet appareil par un code.")
        }
        try storeKey(ak, userID: userID)
        vault = .exists(keys.keyID)
        resetSyncState(userID: userID, full: true)
        updateEncryption()
        return SyncCrypto.encodeRecoveryKey(ak)
    }

    /// La clé de secours de ce compte, pour l'afficher (l'écran demande confirmation avant).
    func recoveryKey() -> String? {
        guard let userID = client?.userID?.lowercased(), let ak = SyncKeyStore.load(userID: userID) else { return nil }
        return SyncCrypto.encodeRecoveryKey(ak)
    }

    /// « Restaurer avec la clé de secours » : vérifiée contre le coffre avant d'être rangée.
    func restore(recoveryKey text: String) async throws {
        let (_, userID) = try requireUser()
        let ak: Data
        do {
            ak = try SyncCrypto.decodeRecoveryKey(text)
        } catch SyncCrypto.RecoveryFailure.checksum {
            throw EncryptionFailure(message: "Une faute s'est glissée dans la clé : relis-la caractère par caractère.")
        } catch {
            throw EncryptionFailure(message: "Cette clé de secours n'est pas valide : 54 caractères, par groupes de 4.")
        }
        try await loadVault()
        guard case .exists(let keyID) = vault else {
            throw EncryptionFailure(message: "Ce compte n'a pas encore de coffre : active d'abord le chiffrement.")
        }
        guard (try? SyncCrypto.keys(for: ak))?.keyID == keyID else {
            throw EncryptionFailure(message: "Cette clé de secours n'est pas celle de ce compte.")
        }
        try storeKey(ak, userID: userID)
        resetSyncState(userID: userID, full: false)
        updateEncryption()
        kickAfterKeyChange()
    }

    /// « Ajouter un appareil » : ouvre le salon d'appairage (la WebSocket ne vit que tant que l'écran l'attend).
    func startPairing(onState: @escaping @Sendable (SyncPairingHost.State) -> Void) async throws -> SyncPairingHost {
        let (_, userID) = try requireUser()
        guard let ak = SyncKeyStore.load(userID: userID) else { throw EncryptionFailure(message: "Cet appareil n'a pas la clé du compte.") }
        guard let relayHost else { throw EncryptionFailure(message: "Cette version ne connaît pas le relais : utilise la clé de secours.") }
        await pairingHost?.cancel()
        let host = try SyncPairingHost(accountKey: ak, makeSocket: RelayPairSocket.factory(host: relayHost), onState: onState)
        pairingHost = host
        await host.start()
        return host
    }

    /// « Entrer un code d'appairage » sur le nouvel appareil.
    func joinPairing(code: String) async throws {
        let (_, userID) = try requireUser()
        try await loadVault()
        guard case .exists(let keyID) = vault else { throw EncryptionFailure(message: "Ce compte n'a pas encore de coffre.") }
        guard let relayHost else { throw EncryptionFailure(message: "Cette version ne connaît pas le relais : utilise la clé de secours.") }
        let ak = try await SyncPairingJoiner.join(code: code, expectedKeyID: keyID, makeSocket: RelayPairSocket.factory(host: relayHost))
        try storeKey(ak, userID: userID)
        resetSyncState(userID: userID, full: false)
        updateEncryption()
        kickAfterKeyChange()
    }

    /// « Réinitialiser le coffre » : le dernier recours quand ni les appareils ni la clé de secours ne
    /// sont plus là. Efface les lignes chiffrées du compte et son coffre sur le serveur (une
    /// transaction), puis cet appareil crée un coffre neuf et renvoie ses données.
    func resetVault() async throws -> String {
        let (client, userID) = try requireUser()
        try await client.rpc("sync_reset_vault", params: [:])
        vault = .none
        let recovery = try await createVault(client: client, userID: userID)
        kickAfterKeyChange()
        return recovery
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
        // La reprise des données de StudyTrack d'abord (bornée à quelques jours).
        guard !IdentityMigration.holdsBackSync else { return }
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

        do {
            let keys = try await keysForPass(userID: userID)
            let stats = SyncSkipStats()
            let engine = prepareEngine(userID: userID, client: client, keys: keys, stats: stats)
            let report = try await engine.sync(pull: pull, acceptMassDeletion: accept)
            if pull { lastPull = Date() }
            skippedForeignKey = stats.foreignKey
            skippedUnreadable = stats.unreadableCount
            lastError = stats.foreignKey > 0 ? SyncMessages.foreignKey : nil
            lastSyncAt = Date()
            lastReport = report.summary
            persistStatus()
            await publishDeviceLink(client: client, keys: keys)
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

    /// Le lien du chrono pour Windows (`sync_device_link`) : l'identité iCloud qui donne son canal au
    /// chrono relié, chiffrée avec la clé de données du compte. Écrite quand elle change (ou la clé).
    private func publishDeviceLink(client: SupabaseClient, keys: SyncCrypto.Keys) async {
        guard let identity = UserDefaults.standard.string(forKey: "timerLink.identity"), !identity.isEmpty,
              let userID = client.userID?.lowercased() else { return }
        let marker = keys.keyID + ":" + SyncCrypto.hex(Data(SHA256.hash(data: Data(identity.utf8))))
        guard UserDefaults.standard.string(forKey: "deviceLink.published") != marker else { return }
        do {
            let box = try SyncCrypto.sealRow(dataKey: keys.dataKey, table: "sync_device_link", id: userID,
                                             fields: ["timerIdentity": identity])
            try await client.upsert("sync_device_link", rows: [["user_id": userID, "key_id": keys.keyID, "payload": SyncCrypto.bytea(box)]],
                                    onConflict: "user_id", returning: false)
            UserDefaults.standard.set(marker, forKey: "deviceLink.published")
        } catch {
            // Sans la table (migration pas encore passée) : on réessaiera à la passe suivante.
        }
    }

    /// Un moteur par passe : les clés peuvent avoir changé (appairage, coffre réinitialisé), et il ne
    /// garde rien d'autre que l'état (`SyncStateStore`) qui, lui, persiste.
    private func prepareEngine(userID: String, client: SupabaseClient, keys: SyncCrypto.Keys, stats: SyncSkipStats) -> SyncEngine {
        let store = syncStore()
        // Un autre compte : l'état de l'ancien (curseurs, empreintes) ne vaut rien pour le nouveau.
        if store.state.userID != userID.lowercased() {
            store.reset(userID: userID.lowercased())
        }
        let transport = EncryptingSyncTransport(inner: SupabaseSyncTransport(client: client), keys: keys, stats: stats)
        let created = SyncEngine(container: container, transport: transport, store: store)
        engine = created
        return created
    }

    private func syncStore() -> SyncStateStore {
        let store = self.store ?? SyncStateStore(url: stateURL)
        self.store = store
        return store
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
