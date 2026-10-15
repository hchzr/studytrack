import Foundation
import CryptoKit
import os
#if !NO_CLOUDKIT
import CloudKit
#endif

/// La voie **instantanée** du chrono partagé : le relais Cloudflare (`relay/`)
/// entre les appareils ouverts du même compte iCloud.
///
/// Pourquoi : la base iCloud ne pousse ses changements que quand le système
/// le décide (de quelques secondes à plusieurs minutes), et le magasin
/// clé-valeur met jusqu'à une minute. Un « play » sur l'iPhone doit se voir
/// sur le Mac **tout de suite** : ici, une WebSocket, ~70 ms.
///
/// - Le canal se déduit de l'identifiant iCloud de l'utilisateur·rice (le même
///   sur ses appareils, opaque, propre au conteneur) : rien à appairer.
/// - Le contenu est chiffré (AES-GCM, clé déduite du même identifiant) : le
///   relais transporte des octets illisibles. Seul l'état de l'îlot, joint par
///   le Mac pour l'écran verrouillé de l'iPhone, voyage en clair jusqu'à Apple.
/// - Le relais garde le dernier état : un appareil qui se connecte le reçoit.
/// - Les autres voies (clé-valeur, base) restent : un appareil fermé ou hors
///   ligne rattrape par elles.
@MainActor
final class TimerLink {
    static let shared = TimerLink()

    /// `update`, `start` : l'îlot (Live Activity). `device` : l'appareil lui-même,
    /// pour le réveiller quand un verrou du mode étude commence ou finit ailleurs.
    enum TokenKind: String { case update, start, device }

    /// Un message de musique reçu d'un autre appareil (`MusicLink`).
    var onMusic: ((MusicLink.Message) -> Void)?
    /// Une photo, un « je bloque », une question venus de l'iPhone (`DeskDrop`).
    var onDrop: ((DeskDrop) -> Void)?
    /// Le lien vient de s'ouvrir (la musique redemande l'état des autres).
    var onConnect: (() -> Void)?

    /// Construit l'état de l'îlot à joindre à une publication (le Mac) :
    /// le relais le pousse aux iPhone verrouillés.
    var livePayload: ((CloudRelay.TimerSnapshot) -> Data?)?

    private let log = Logger(subsystem: "com.hczr.studytrack", category: "timerlink")
    private var endpoint: URL?
    private var key: SymmetricKey?
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var attempts = 0
    private var connected = false
    private var suspended = false
    private var pending: CloudRelay.TimerSnapshot?
    /// Les jetons APNs de l'îlot, renvoyés à chaque connexion.
    private var tokens: [TokenKind: String?] = [:]
    /// Le verrou tel qu'on l'a annoncé en dernier (réveiller les autres appareils
    /// seulement quand il change).
    private var lastAnnouncedLock: Bool?

    // MARK: Démarrage

    /// Démarre avec la configuration de l'app (Info.plist) et l'identité
    /// iCloud — retenue, pour ne pas attendre CloudKit à chaque lancement.
    func startFromBundle(containerID: String) {
        let host = Bundle.main.object(forInfoDictionaryKey: "TimerRelayHost") as? String ?? ""
        guard !host.isEmpty, !host.hasPrefix("$(") else {
            log.notice("lien du chrono : pas de relais configuré")
            return
        }
        let cacheKey = "timerLink.identity"
        if let cached = UserDefaults.standard.string(forKey: cacheKey) {
            start(host: host, identity: cached)
            return
        }
        #if !NO_CLOUDKIT
        Task { @MainActor in
            do {
                let record = try await CKContainer(identifier: containerID).userRecordID()
                UserDefaults.standard.set(record.recordName, forKey: cacheKey)
                self.start(host: host, identity: record.recordName)
            } catch {
                self.log.error("lien du chrono : identité iCloud introuvable (\(error.localizedDescription, privacy: .public))")
            }
        }
        #endif
    }

    func start(host: String, identity: String) {
        guard endpoint == nil, !host.isEmpty, !identity.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/v1/" + Self.channel(for: identity)
        components.queryItems = [URLQueryItem(name: "device", value: CloudRelay.deviceID)]
        endpoint = components.url
        key = Self.key(for: identity)
        CloudRelay.onPublish = { [weak self] snapshot in self?.send(snapshot) }
        connect()
    }

    /// Le nom du canal : une empreinte de l'identité, rien de lisible.
    nonisolated static func channel(for identity: String) -> String {
        let digest = SHA256.hash(data: Data("studytrack.timer.channel.v1:\(identity)".utf8))
        return "st-timer-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func key(for identity: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("studytrack.timer.key.v1:\(identity)".utf8)))
    }

    // MARK: Chiffrement (pur, testé)

    nonisolated static func seal(_ snapshot: CloudRelay.TimerSnapshot, key: SymmetricKey) -> String? {
        guard let data = try? JSONEncoder().encode(snapshot),
              let box = try? AES.GCM.seal(data, using: key), let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    nonisolated static func open(_ text: String, key: SymmetricKey) -> CloudRelay.TimerSnapshot? {
        guard let data = Data(base64Encoded: text), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(CloudRelay.TimerSnapshot.self, from: plain)
    }

    // MARK: Envoi

    func send(_ snapshot: CloudRelay.TimerSnapshot) {
        guard connected else {
            pending = snapshot
            if socket == nil, !suspended { connect() }
            return
        }
        guard let key, let sealed = Self.seal(snapshot, key: key) else { return }
        var message: [String: Any] = ["t": "timer", "d": sealed, "u": snapshot.updatedAt.timeIntervalSince1970]
        if let data = livePayload?(snapshot), let live = try? JSONSerialization.jsonObject(with: data) {
            message["live"] = live
        }
        // Un verrou qui commence ou finit : le relais réveille l'iPhone et
        // l'iPad endormis (notification silencieuse), qui posent ou lèvent leur
        // bouclier sans attendre qu'on les ouvre.
        let locked = StudyMode.blocks(snapshot.state)
        if Self.shouldWake(previous: lastAnnouncedLock, now: locked) { message["wake"] = true }
        lastAnnouncedLock = locked
        write(message)
    }

    /// Un message de musique : un état (gardé par le relais, un par appareil)
    /// ou une commande. `wake` : réveiller l'iPhone endormi (une musique qu'on
    /// lui passe).
    func sendMusic(_ message: MusicLink.Message, wake: Bool = false) {
        guard connected, let key, let sealed = MusicLink.seal(message, key: key) else { return }
        var payload: [String: Any] = ["t": "music", "d": sealed]
        if case .state = message { payload["keep"] = true }
        if wake { payload["wake"] = true }
        write(payload)
    }

    var isConnected: Bool { connected }

    /// Envoie au bureau du Mac ; `false` si le lien est fermé ou la pièce trop lourde.
    @discardableResult
    func sendDrop(_ drop: DeskDrop) -> Bool {
        guard connected, let key, let sealed = DeskDrop.seal(drop, key: key) else { return false }
        write(["t": "drop", "d": sealed])
        return true
    }

    /// Réveiller les autres appareils : quand le verrou change (pas au premier
    /// état, sauf s'il verrouille).
    nonisolated static func shouldWake(previous: Bool?, now: Bool) -> Bool {
        guard let previous else { return now }
        return previous != now
    }

    /// Un état reçu par notification silencieuse (`st.d`, chiffré comme sur la
    /// WebSocket). L'app peut avoir été lancée en arrière-plan pour ça : la clé
    /// se déduit de l'identité retenue.
    func openWake(_ sealed: String) -> CloudRelay.TimerSnapshot? {
        let identity = UserDefaults.standard.string(forKey: "timerLink.identity")
        guard let key = key ?? identity.map(Self.key(for:)) else { return nil }
        return Self.open(sealed, key: key)
    }

    /// Le jeton APNs de l'îlot de cet iPhone (`nil` : l'activité est finie).
    func registerAPNs(kind: TokenKind, token: String?) {
        tokens[kind] = .some(token)
        if connected { writeToken(kind, token) }
    }

    private func writeToken(_ kind: TokenKind, _ token: String?) {
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        write(["t": "apns", "kind": kind.rawValue, "token": token ?? NSNull(), "sandbox": sandbox])
    }

    // MARK: Connexion

    /// L'app passe en arrière-plan : on ferme proprement, sans se reconnecter.
    func suspend() {
        suspended = true
        reconnect?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
    }

    /// L'app revient au premier plan (ou le Mac sort de veille).
    func resume() {
        suspended = false
        guard endpoint != nil else { return }
        reconnect?.cancel()
        attempts = 0
        connect()
    }

    private func connect() {
        guard let endpoint, !suspended else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        connected = false
        let task = URLSession.shared.webSocketTask(with: endpoint)
        socket = task
        task.resume()
        listen(task)
        // La connexion est prête quand le premier ping revient.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                if let error {
                    self.log.notice("lien du chrono : connexion impossible (\(error.localizedDescription, privacy: .public))")
                    self.scheduleReconnect()
                } else {
                    self.didConnect()
                }
            }
        }
    }

    private func didConnect() {
        connected = true
        attempts = 0
        log.notice("lien du chrono ouvert")
        for (kind, token) in tokens { writeToken(kind, token ?? nil) }
        onConnect?()
        if let pending {
            self.pending = nil
            send(pending)
        }
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                // « ping » texte : le relais répond « pong » sans se réveiller.
                self.socket?.send(.string("ping")) { _ in }
            }
        }
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.listen(task)
                case .failure(let error):
                    self.log.notice("lien du chrono coupé : \(error.localizedDescription, privacy: .public)")
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard text != "pong", let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sealed = message["d"] as? String, let key else { return }
        switch message["t"] as? String {
        case "timer":
            if let snapshot = Self.open(sealed, key: key) { CloudRelay.receivedFromLink(snapshot) }
        case "music":
            if let music = MusicLink.open(sealed, key: key) { onMusic?(music) }
        case "drop":
            if let drop = DeskDrop.open(sealed, key: key) { onDrop?(drop) }
        default:
            break
        }
    }

    /// Une commande de musique reçue par notification silencieuse (`st.m`).
    func openMusicWake(_ sealed: String) -> MusicLink.Message? {
        let identity = UserDefaults.standard.string(forKey: "timerLink.identity")
        guard let key = key ?? identity.map(Self.key(for:)) else { return nil }
        return MusicLink.open(sealed, key: key)
    }

    private func scheduleReconnect() {
        connected = false
        socket = nil
        heartbeat?.cancel()
        reconnect?.cancel()
        guard !suspended else { return }
        attempts += 1
        let delay = min(30.0, pow(2.0, Double(min(attempts, 5))))
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func write(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }
}
