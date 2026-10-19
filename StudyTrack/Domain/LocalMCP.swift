import Foundation
import Network
import Security

/// Un serveur MCP **local** : HTTP sur 127.0.0.1, JSON-RPC, réponses JSON.
///
/// Le serveur en ligne (`supabase/functions/mcp`) ne peut pas tout donner : il ne
/// voit que ce que l'iPhone lui envoie, une réponse MCP plafonne à 16 Mo, et il
/// n'a pas la session Moodle. Celui-ci tourne **dans l'app du Mac**, qui a les
/// données, la session et le dossier de notes : il rend des **chemins** de
/// fichiers plutôt que des octets, donc sans plafond.
///
/// Rien ne tourne tant que le réglage est éteint ; allumé, c'est une prise
/// en écoute (aucune interrogation périodique).
///
/// Sécurité — une page web ouverte dans le navigateur peut viser 127.0.0.1 :
/// - l'adresse porte un **jeton** de 256 bits (comme celle du serveur en ligne) ;
/// - un en-tête `Origin` (toute requête d'un navigateur) est refusé ;
/// - l'en-tête `Host` doit être 127.0.0.1 ou localhost (contre le « DNS rebinding ») ;
/// - l'écoute est limitée à la boucle locale.
protocol LocalMCPProvider: AnyObject, Sendable {
    var serverName: String { get }
    var instructions: String { get }
    var tools: [[String: Any]] { get }
    /// Le résultat d'un outil, au format MCP (`content`, `isError`).
    func call(_ name: String, arguments: [String: Any]) async -> [String: Any]
}

enum LocalMCPRPC {
    static let protocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func textResult(_ value: Any, isError: Bool = false) -> [String: Any] {
        var text: String
        if let string = value as? String {
            text = string
        } else if JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = String(describing: value)
        }
        var result: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { result["isError"] = true }
        return result
    }

    /// Une requête JSON-RPC → sa réponse (`nil` pour une notification).
    static func handle(_ message: [String: Any], provider: LocalMCPProvider) async -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }
        func reply(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return reply([
                "protocolVersion": protocols.contains(asked) ? asked : protocols[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": provider.serverName, "title": "StudyTrack (fichiers, Mac)", "version": "1.0.0"],
                "instructions": provider.instructions,
            ])
        case "ping": return reply([String: Any]())
        case "tools/list": return reply(["tools": provider.tools])
        case "resources/list": return reply(["resources": [Any]()])
        case "prompts/list": return reply(["prompts": [Any]()])
        case "tools/call":
            guard let name = params["name"] as? String, provider.tools.contains(where: { $0["name"] as? String == name }) else {
                return fail(-32602, "Outil inconnu : \(params["name"] as? String ?? "")")
            }
            return reply(await provider.call(name, arguments: params["arguments"] as? [String: Any] ?? [:]))
        default:
            return fail(-32601, "Méthode inconnue : \(message["method"] as? String ?? "")")
        }
    }

    /// Un jeton de 256 bits, en base64url.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// La requête HTTP, lue à la main : une ligne, des en-têtes, un corps.
struct LocalHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]   // clés en minuscules
    var body: Data

    /// `nil` tant que la requête n'est pas complète ; `.failure` si elle est
    /// invalide ou trop grosse.
    static func parse(_ data: Data, limit: Int = 8 * 1024 * 1024) -> Result<LocalHTTPRequest, ParseError>? {
        if data.count > limit { return .failure(.tooLarge) }
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else { return data.count > 64 * 1024 ? .failure(.invalid) : nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .failure(.invalid) }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard first.count >= 2 else { return .failure(.invalid) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { return .failure(.chunked) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .failure(.invalid) }
        if length > limit { return .failure(.tooLarge) }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return .success(LocalHTTPRequest(method: String(first[0]).uppercased(), path: String(first[1]), headers: headers,
                                         body: data[bodyStart..<(bodyStart + length)]))
    }

    enum ParseError: Error { case invalid, tooLarge, chunked }
}

final class LocalMCPServer: @unchecked Sendable {
    private let token: String
    private let provider: LocalMCPProvider
    private let queue = DispatchQueue(label: "studytrack.localmcp")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(token: String, provider: LocalMCPProvider) {
        self.token = token
        self.provider = provider
    }

    var isRunning: Bool { listener != nil }

    /// L'adresse à donner à un client MCP.
    var url: URL? { port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)/\(token)") }

    /// Démarre l'écoute (`port` 0 : un port libre). Renvoie le port choisi, ou
    /// `nil` s'il est pris.
    @discardableResult
    func start(port requested: UInt16 = 0) async -> UInt16? {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let wanted = requested == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: requested) ?? .any)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: wanted)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let bound: UInt16? = await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled: once.run { continuation.resume(returning: nil) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let bound else { listener.cancel(); return nil }
        self.listener = listener
        self.port = bound
        return bound
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    // MARK: Connexions

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch LocalHTTPRequest.parse(buffer) {
            case .success(let request)?:
                Task {
                    let response = await self.respond(to: request)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            case .failure(let error)?:
                let status = error == .tooLarge ? 413 : (error == .chunked ? 411 : 400)
                connection.send(content: Self.http(status, ["error": "requête refusée"]), completion: .contentProcessed { _ in connection.cancel() })
            case nil:
                if error != nil || isComplete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            }
        }
    }

    // MARK: Routage

    /// Le contrôle d'accès puis le JSON-RPC.
    func respond(to request: LocalHTTPRequest) async -> Data {
        // Un navigateur envoie toujours `Origin` ; un client MCP en ligne de commande, jamais.
        if request.headers["origin"] != nil { return Self.http(403, ["error": "origine refusée"]) }
        let host = (request.headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "127.0.0.1" || host == "localhost" else {
            return Self.http(403, ["error": "hôte refusé"])
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        guard Self.constantTimeEqual(last, token) else {
            return Self.http(401, ["error": "adresse incomplète : copie l'adresse complète depuis StudyTrack (Réglages › Claude)."])
        }
        switch request.method {
        case "POST":
            guard let object = try? JSONSerialization.jsonObject(with: request.body) else {
                return Self.http(400, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "JSON illisible"]])
            }
            if let batch = object as? [[String: Any]] {
                var replies: [[String: Any]] = []
                for message in batch { if let reply = await LocalMCPRPC.handle(message, provider: provider) { replies.append(reply) } }
                return replies.isEmpty ? Self.http(202, nil) : Self.http(200, replies)
            }
            guard let message = object as? [String: Any] else { return Self.http(400, ["error": "message invalide"]) }
            if let reply = await LocalMCPRPC.handle(message, provider: provider) { return Self.http(200, reply) }
            return Self.http(202, nil)
        case "DELETE": return Self.http(200, [String: Any]())
        default: return Self.http(405, ["error": "ce serveur répond en POST"], extra: ["Allow": "POST, DELETE"])
        }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for (p, q) in zip(x, y) { difference |= p ^ q }
        return difference == 0
    }

    static func http(_ status: Int, _ body: Any?, extra: [String: String] = [:]) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 405: "Method Not Allowed",
                       411: "Length Required", 413: "Payload Too Large"]
        let payload = body.flatMap { JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil } ?? Data()
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n"
        if !payload.isEmpty { head += "Content-Type: application/json\r\n" }
        for (key, value) in extra { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + payload
    }
}
