import Foundation

/// Le protocole de synchronisation d'AnkiWeb, côté client — comme AnkiMobile ou
/// AnkiDroid, sans ordinateur.
///
/// Version **10** du protocole (formulaire `multipart`, JSON non compressé) :
/// le serveur de référence d'Anki l'accepte toujours (`SYNC_VERSION_MIN = 8`), et
/// elle évite le zstd de la version 11, qu'iOS ne sait pas décoder. Les
/// réponses de la version 10 ne sont pas compressées.
///
/// Méthodes : `hostKey` (connexion), `meta`, `download` (collection entière,
/// SQLite au schéma 11), puis la synchronisation normale — `start`,
/// `applyGraves`, `applyChanges`, `chunk`, `applyChunk`, `sanityCheck2`,
/// `finish`, `abort`. Voir `rslib/src/sync` dans le dépôt d'Anki.
///
/// **Jamais d'envoi complet** (`upload`) : l'app n'écrase jamais la collection
/// d'AnkiWeb. Elle ne fait qu'y ajouter des notes, par une synchronisation
/// normale que le serveur annule entièrement si quoi que ce soit ne concorde.
final class AnkiWebClient {
    static let syncVersion = 10
    static let clientVersion = "studytrack,1.0,ios"
    static let defaultEndpoint = URL(string: "https://sync.ankiweb.net/")!

    private(set) var endpoint: URL
    var hostKey: String
    /// Clé de session : la même pour toutes les requêtes d'une synchronisation.
    private let sessionKey: String
    private let session: URLSession

    init(hostKey: String = "", endpoint: URL? = nil, session: URLSession = .shared) {
        self.hostKey = hostKey
        self.endpoint = endpoint ?? Self.defaultEndpoint
        self.sessionKey = Self.randomKey(8)
        self.session = session
    }

    enum Failure: LocalizedError {
        case badCredentials
        case server(Int, String)
        case decoding(String)
        case unsupported(String)
        case sanity(String)
        case fullSyncRequired

        var errorDescription: String? {
            switch self {
            case .badCredentials: return "Identifiant ou mot de passe AnkiWeb incorrect."
            case .server(let code, let body): return "AnkiWeb a répondu \(code)\(body.isEmpty ? "" : " : \(body.prefix(120))")."
            case .decoding(let what): return "Réponse d'AnkiWeb illisible (\(what))."
            case .unsupported(let message): return message
            case .sanity(let detail): return "AnkiWeb a refusé l'envoi (contrôle de cohérence) — rien n'a été modifié. \(detail)"
            case .fullSyncRequired: return "Ta collection AnkiWeb demande une synchronisation complète : synchronise d'abord Anki sur ton ordinateur ou ton téléphone."
            }
        }
    }

    // MARK: Transport

    /// Une requête : `c=0` (pas de gzip), `k` (clé d'hôte), `s` (session), `data`.
    @discardableResult
    func call(_ method: String, json: Any = [String: Any](), timeout: TimeInterval = 60) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await post(method, data: body, timeout: timeout)
    }

    private func post(_ method: String, data: Data, timeout: TimeInterval) async throws -> Data {
        let boundary = "StudyTrack-\(Self.randomKey(16))"
        var request = URLRequest(url: endpoint.appendingPathComponent("sync").appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var form = Data()
        func field(_ name: String, _ value: Data, file: Bool = false) {
            form.append("--\(boundary)\r\n".data(using: .utf8)!)
            if file {
                form.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"data\"\r\n".data(using: .utf8)!)
                form.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            } else {
                form.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            }
            form.append(value)
            form.append("\r\n".data(using: .utf8)!)
        }
        field("c", Data("0".utf8))
        if !hostKey.isEmpty { field("k", Data(hostKey.utf8)) }
        field("s", Data(sessionKey.utf8))
        field("data", data, file: true)
        form.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = form

        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.server(0, "") }
        switch http.statusCode {
        case 200..<300:
            return payload
        case 308, 301, 302:
            // Le compte vit sur un autre serveur : on y passe, et on rejoue.
            if let location = http.value(forHTTPHeaderField: "Location") ?? String(data: payload, encoding: .utf8),
               let url = URL(string: location.trimmingCharacters(in: .whitespacesAndNewlines)) {
                endpoint = url
                return try await post(method, data: data, timeout: timeout)
            }
            throw Failure.server(http.statusCode, "redirection sans adresse")
        case 403:
            throw Failure.badCredentials
        case 501:
            throw Failure.unsupported("AnkiWeb n'accepte plus ce protocole de synchronisation.")
        default:
            throw Failure.server(http.statusCode, String(data: payload, encoding: .utf8) ?? "")
        }
    }

    private func object(_ data: Data, _ what: String) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.decoding(what)
        }
        return value
    }

    // MARK: Connexion et métadonnées

    /// Échange identifiant et mot de passe contre une clé d'hôte, seule gardée.
    func login(username: String, password: String) async throws -> String {
        let reply = try object(try await call("hostKey", json: ["u": username, "p": password]), "hostKey")
        guard let key = reply["key"] as? String, !key.isEmpty else { throw Failure.badCredentials }
        hostKey = key
        return key
    }

    struct Meta {
        var modified: Int64
        var schema: Int64
        var usn: Int
        var hostNumber: Int
        var message: String
        var shouldContinue: Bool
        var empty: Bool
    }

    func meta() async throws -> Meta {
        let reply = try object(try await call("meta", json: ["v": Self.syncVersion, "cv": Self.clientVersion]), "meta")
        let meta = Meta(modified: (reply["mod"] as? NSNumber)?.int64Value ?? 0,
                        schema: (reply["scm"] as? NSNumber)?.int64Value ?? 0,
                        usn: (reply["usn"] as? NSNumber)?.intValue ?? 0,
                        hostNumber: (reply["hostNum"] as? NSNumber)?.intValue ?? 0,
                        message: reply["msg"] as? String ?? "",
                        shouldContinue: reply["cont"] as? Bool ?? true,
                        empty: reply["empty"] as? Bool ?? false)
        // Anciens clients : le numéro d'hôte désigne le serveur du compte.
        if meta.hostNumber > 0, endpoint == Self.defaultEndpoint,
           let url = URL(string: "https://sync\(meta.hostNumber).ankiweb.net/") {
            endpoint = url
            return try await self.meta()
        }
        guard meta.shouldContinue else { throw Failure.unsupported(meta.message.isEmpty ? "AnkiWeb refuse la synchronisation." : meta.message) }
        return meta
    }

    /// La collection entière, un fichier SQLite (schéma 11).
    func download() async throws -> Data {
        let data = try await call("download", timeout: 300)
        guard data.starts(with: Data("SQLite format 3".utf8)) else {
            throw Failure.decoding(String(data: data.prefix(80), encoding: .utf8) ?? "download")
        }
        return data
    }

    // MARK: Synchronisation normale

    func start(minUsn: Int, localIsNewer: Bool) async throws -> [String: Any] {
        try object(try await call("start", json: ["minUsn": minUsn, "lnewer": localIsNewer]), "start")
    }

    func applyGraves(cards: [Int64] = [], notes: [Int64] = [], decks: [Int64] = []) async throws {
        try await call("applyGraves", json: ["chunk": ["cards": cards, "notes": notes, "decks": decks]])
    }

    func applyChanges(models: [Any] = [], decks: [Any] = [], deckConfig: [Any] = [], tags: [String] = []) async throws -> [String: Any] {
        try object(try await call("applyChanges", json: ["changes": ["models": models,
                                                                     "decks": [decks, deckConfig],
                                                                     "tags": tags]]), "applyChanges")
    }

    func chunk() async throws -> [String: Any] {
        try object(try await call("chunk"), "chunk")
    }

    func applyChunk(notes: [[Any]], cards: [[Any]], done: Bool) async throws {
        var chunk: [String: Any] = ["done": done]
        if !notes.isEmpty { chunk["notes"] = notes }
        if !cards.isEmpty { chunk["cards"] = cards }
        try await call("applyChunk", json: ["chunk": chunk])
    }

    /// `[[new, learn, review], cards, notes, revlog, graves, models, decks, deckConfig]`.
    func sanityCheck(_ counts: [Any]) async throws -> [String: Any] {
        try object(try await call("sanityCheck2", json: ["client": counts]), "sanityCheck2")
    }

    func finish() async throws -> Int64 {
        let data = try await call("finish")
        if let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? NSNumber {
            return value.int64Value
        }
        throw Failure.decoding("finish")
    }

    func abort() async {
        _ = try? await call("abort")
    }

    static func randomKey(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
