import Foundation
import os

private let realtimeTrace = Logger(subsystem: "com.hczr.studytrack", category: "realtime")

/// Supabase Realtime, sans dépendance : une WebSocket (protocole Phoenix v1),
/// un canal par groupe, et les écrans qui s'y abonnent.
///
/// Pourquoi : l'entraide et le direct étaient **relus toutes les 30 s** (une
/// minute pour la liste). Un message mettait donc jusqu'à une demi-minute à
/// arriver, et un membre qui lançait son chrono restait invisible autant.
/// Ici, Postgres prévient : chaque changement d'une table suivie
/// (`group_posts`, `presence`, `group_members`, `group_key_shares`) arrive
/// à l'instant, filtré par groupe **et** par les politiques RLS — Realtime lit
/// avec le jeton de l'utilisateur, comme PostgREST.
///
/// L'événement ne transporte pas la donnée utile : l'écran relit ce qui a
/// changé par PostgREST. C'est volontaire — la lecture déchiffre, décode et
/// applique les mêmes règles qu'au chargement, et un message chiffré n'a de
/// toute façon rien de lisible dans l'événement.
@MainActor
final class RealtimeClient {

    /// Les tables qu'un canal de groupe suit.
    enum Table: String, CaseIterable {
        case posts = "group_posts"
        case presence = "presence"
        case members = "group_members"
        case keyShares = "group_key_shares"
    }

    typealias Handler = (Table) -> Void

    private let endpoint: URL
    private let tokenProvider: () -> String?

    private var socket: URLSessionWebSocketTask?
    private var listeners: [String: [UUID: Handler]] = [:]
    private var joinedTopics: Set<String> = []
    private var ref = 0
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var attempts = 0

    /// - Parameters:
    ///   - baseURL: l'URL du projet (`https://<ref>.supabase.co`).
    ///   - tokenProvider: le jeton d'accès **courant** — relu à chaque
    ///     connexion, parce qu'il change toutes les heures.
    init?(baseURL: URL, anonKey: String, tokenProvider: @escaping () -> String?) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: anonKey),
                                 URLQueryItem(name: "vsn", value: "1.0.0")]
        guard let url = components.url else { return nil }
        self.endpoint = url
        self.tokenProvider = tokenProvider
    }

    // MARK: Abonnements

    /// S'abonne aux changements d'un groupe. Garder le jeton rendu et le passer
    /// à `unsubscribe` quand l'écran disparaît.
    func subscribe(groupID: String, handler: @escaping Handler) -> UUID {
        let id = UUID()
        let topic = Self.topic(groupID)
        listeners[topic, default: [:]][id] = handler
        if socket == nil {
            connect()
        } else if !joinedTopics.contains(topic) {
            join(topic, groupID: groupID)
        }
        return id
    }

    func unsubscribe(_ id: UUID) {
        for (topic, var handlers) in listeners where handlers[id] != nil {
            handlers[id] = nil
            if handlers.isEmpty {
                listeners[topic] = nil
                if joinedTopics.remove(topic) != nil {
                    send(topic: topic, event: "phx_leave", payload: [:])
                }
            } else {
                listeners[topic] = handlers
            }
        }
        if listeners.isEmpty { disconnect() }
    }

    /// Un nouveau jeton (rafraîchissement, reconnexion) : les canaux ouverts
    /// doivent le recevoir, sinon Realtime les ferme à l'expiration de l'ancien.
    func tokenDidChange() {
        guard socket != nil else { return }
        guard let token = tokenProvider() else {
            disconnect()
            return
        }
        for topic in joinedTopics {
            send(topic: topic, event: "access_token", payload: ["access_token": token])
        }
    }

    /// Retour au premier plan : iOS a pu couper la socket pendant la veille.
    func resume() {
        guard !listeners.isEmpty else { return }
        if socket == nil || socket?.state != .running {
            disconnect(keepListeners: true)
            connect()
        }
    }

    // MARK: Connexion

    private static func topic(_ groupID: String) -> String { "realtime:group-\(groupID.lowercased())" }

    private func connect() {
        guard tokenProvider() != nil else { return }
        reconnect?.cancel()
        reconnect = nil
        let task = URLSession.shared.webSocketTask(with: endpoint)
        socket = task
        joinedTopics = []
        task.resume()
        receive(on: task)
        for topic in listeners.keys {
            join(topic, groupID: String(topic.dropFirst("realtime:group-".count)))
        }
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled else { return }
                self.send(topic: "phoenix", event: "heartbeat", payload: [:])
            }
        }
    }

    private func disconnect(keepListeners: Bool = false) {
        heartbeat?.cancel()
        heartbeat = nil
        reconnect?.cancel()
        reconnect = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        joinedTopics = []
        if !keepListeners { listeners = [:] }
    }

    private func join(_ topic: String, groupID: String) {
        guard let token = tokenProvider() else { return }
        let filter = "group_id=eq.\(groupID)"
        let changes = Table.allCases.map { table -> [String: Any] in
            ["event": "*", "schema": "public", "table": table.rawValue, "filter": filter]
        }
        let payload: [String: Any] = [
            "config": [
                "broadcast": ["self": false, "ack": false],
                "presence": ["key": ""],
                "postgres_changes": changes,
                "private": false
            ],
            "access_token": token
        ]
        joinedTopics.insert(topic)
        send(topic: topic, event: "phx_join", payload: payload, joinRef: true)
    }

    private func send(topic: String, event: String, payload: [String: Any], joinRef: Bool = false) {
        guard let socket else { return }
        ref += 1
        var message: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": String(ref)]
        if joinRef { message["join_ref"] = String(ref) }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            if let error { realtimeTrace.error("envoi \(event, privacy: .public) : \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    self.attempts = 0
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task)
                case .failure(let error):
                    realtimeTrace.notice("socket fermée : \(error.localizedDescription, privacy: .public)")
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// Reprise après une coupure (métro, veille, serveur redémarré) : 1, 2, 4…
    /// jusqu'à 30 s. Tant qu'un écran écoute, on finit par revenir.
    private func scheduleReconnect() {
        disconnect(keepListeners: true)
        guard !listeners.isEmpty else { return }
        attempts += 1
        let delay = min(30.0, pow(2.0, Double(attempts - 1)))
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = message["topic"] as? String,
              let event = message["event"] as? String else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]

        switch event {
        case "postgres_changes":
            let data = payload["data"] as? [String: Any]
            guard let name = data?["table"] as? String, let table = Table(rawValue: name) else { return }
            for handler in (listeners[topic] ?? [:]).values { handler(table) }
        case "phx_reply":
            if payload["status"] as? String == "error" {
                realtimeTrace.error("canal refusé \(topic, privacy: .public) : \(String(describing: payload["response"]), privacy: .public)")
            }
        case "phx_close", "phx_error":
            // Le serveur a fermé le canal (jeton expiré, redémarrage) : on le
            // rouvre au lieu de rester sourd jusqu'à la prochaine ouverture.
            guard joinedTopics.remove(topic) != nil, listeners[topic] != nil else { return }
            join(topic, groupID: String(topic.dropFirst("realtime:group-".count)))
        case "system":
            if payload["status"] as? String == "error" {
                realtimeTrace.error("realtime \(topic, privacy: .public) : \(payload["message"] as? String ?? "", privacy: .public)")
            }
        default:
            break
        }
    }
}
