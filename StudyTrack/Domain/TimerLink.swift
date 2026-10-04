import Foundation
import CryptoKit
import os
#if !NO_CLOUDKIT
import CloudKit
#endif

/// La voie **instantanée** du chrono partagé : une diffusion Supabase Realtime
/// entre les appareils ouverts du même compte iCloud.
///
/// Pourquoi : la base iCloud ne pousse ses changements que quand le système
/// le décide (de quelques secondes à plusieurs minutes), et le magasin
/// clé-valeur met jusqu'à une minute. Un « play » sur l'iPhone doit se voir
/// sur le Mac **tout de suite**. Ici, une WebSocket : moins d'une seconde.
///
/// - Le canal se déduit de l'identifiant iCloud de l'utilisateur·rice (le même
///   sur ses appareils, opaque, propre au conteneur) : rien à appairer.
/// - Le contenu est chiffré (AES-GCM, clé déduite du même identifiant) : le
///   serveur relaie des octets illisibles.
/// - Les autres voies (clé-valeur, base) restent : un appareil fermé ou hors
///   ligne rattrape par elles.
@MainActor
final class TimerLink {
    static let shared = TimerLink()

    private let log = Logger(subsystem: "com.hczr.studytrack", category: "timerlink")
    private var endpoint: URL?
    private var topic = ""
    private var key: SymmetricKey?
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var attempts = 0
    private var ref = 0
    private var joined = false
    private var pending: [CloudRelay.TimerSnapshot] = []
    /// Le dernier état publié ici : renvoyé à un appareil qui arrive.
    private var lastSent: CloudRelay.TimerSnapshot?

    // MARK: Démarrage

    /// Démarre avec la configuration de l'app (Info.plist) et l'identité
    /// iCloud — retenue, pour ne pas attendre CloudKit à chaque lancement.
    func startFromBundle(containerID: String) {
        let info = Bundle.main
        let host = info.object(forInfoDictionaryKey: "SupabaseHost") as? String ?? ""
        let anon = info.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String ?? ""
        guard !host.isEmpty, !host.hasPrefix("$("), !anon.isEmpty, !anon.hasPrefix("$(") else {
            log.notice("lien du chrono : pas de configuration Supabase")
            return
        }
        let cacheKey = "timerLink.identity"
        if let cached = UserDefaults.standard.string(forKey: cacheKey) {
            start(host: host, anonKey: anon, identity: cached)
            return
        }
        #if !NO_CLOUDKIT
        Task { @MainActor in
            do {
                let record = try await CKContainer(identifier: containerID).userRecordID()
                UserDefaults.standard.set(record.recordName, forKey: cacheKey)
                self.start(host: host, anonKey: anon, identity: record.recordName)
            } catch {
                self.log.error("lien du chrono : identité iCloud introuvable (\(error.localizedDescription, privacy: .public))")
            }
        }
        #endif
    }

    /// - Parameters:
    ///   - host: le domaine du projet Supabase.
    ///   - anonKey: la clé publique du projet.
    ///   - identity: l'identifiant iCloud de l'utilisateur·rice.
    func start(host: String, anonKey: String, identity: String) {
        guard endpoint == nil, !host.isEmpty, !anonKey.isEmpty, !identity.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: anonKey), URLQueryItem(name: "vsn", value: "1.0.0")]
        endpoint = components.url
        topic = "realtime:" + Self.channel(for: identity)
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
        lastSent = snapshot
        guard joined else {
            pending = [snapshot]
            if socket == nil { connect() }
            return
        }
        broadcast(event: "timer", snapshot: snapshot)
    }

    private func broadcast(event: String, snapshot: CloudRelay.TimerSnapshot?) {
        var inner: [String: Any] = [:]
        if let snapshot, let key, let sealed = Self.seal(snapshot, key: key) { inner["d"] = sealed }
        write(["topic": topic, "event": "broadcast", "ref": nextRef(),
               "payload": ["type": "broadcast", "event": event, "payload": inner]])
    }

    // MARK: Connexion

    /// À l'app qui revient au premier plan : la socket a pu mourir en veille.
    func resume() {
        guard endpoint != nil else { return }
        if socket == nil || !joined {
            reconnect?.cancel()
            attempts = 0
            connect()
        } else {
            // Demander l'état des autres : on a pu manquer un geste.
            broadcast(event: "hello", snapshot: nil)
        }
    }

    private func connect() {
        guard let endpoint else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        joined = false
        let task = URLSession.shared.webSocketTask(with: endpoint)
        socket = task
        task.resume()
        listen(task)
        write(["topic": topic, "event": "phx_join", "ref": nextRef(),
               "payload": ["config": ["broadcast": ["self": false], "private": false]]])
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled else { return }
                self.write(["topic": "phoenix", "event": "heartbeat", "payload": [:], "ref": self.nextRef()])
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
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = message["event"] as? String else { return }
        switch event {
        case "phx_reply":
            guard !joined, (message["topic"] as? String) == topic,
                  let payload = message["payload"] as? [String: Any], payload["status"] as? String == "ok" else { return }
            joined = true
            attempts = 0
            log.notice("lien du chrono ouvert")
            for snapshot in pending { broadcast(event: "timer", snapshot: snapshot) }
            pending = []
            broadcast(event: "hello", snapshot: nil)
        case "broadcast":
            guard let payload = message["payload"] as? [String: Any],
                  let kind = payload["event"] as? String else { return }
            let inner = payload["payload"] as? [String: Any]
            if kind == "hello" {
                // Un appareil arrive : il reçoit notre dernier état, daté d'origine.
                if let lastSent { broadcast(event: "timer", snapshot: lastSent) }
                return
            }
            guard kind == "timer", let sealed = inner?["d"] as? String, let key,
                  let snapshot = Self.open(sealed, key: key) else { return }
            CloudRelay.receivedFromLink(snapshot)
        case "phx_error", "phx_close":
            scheduleReconnect()
        default:
            break
        }
    }

    private func scheduleReconnect() {
        joined = false
        socket = nil
        heartbeat?.cancel()
        reconnect?.cancel()
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

    private func nextRef() -> String {
        ref += 1
        return String(ref)
    }
}
