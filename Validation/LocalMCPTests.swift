import Foundation

/// Le serveur MCP local, essayé pour de vrai : une écoute sur la boucle locale,
/// de vraies requêtes HTTP, un faux fournisseur d'outils. Rend (réussi, libellé).
final class FakeFilesProvider: LocalMCPProvider, @unchecked Sendable {
    let serverName = "polymestre-files"
    let instructions = "essai"
    var tools: [[String: Any]] { [["name": "list_files", "inputSchema": ["type": "object"]], ["name": "read_file", "inputSchema": ["type": "object"]]] }
    func call(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        LocalMCPRPC.textResult("\(name):\(arguments["id"] as? String ?? "-")" + (arguments["inline"] as? Bool == true ? "+inline" : ""))
    }
}

func localMCPResults() -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    func note(_ ok: Bool, _ label: String) { results.append((ok, label)) }
    let semaphore = DispatchSemaphore(value: 0)
    let token = LocalMCPRPC.makeToken()
    note(token.count >= 43 && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, "jeton local : 256 bits en base64url")

    Task {
        let server = LocalMCPServer(token: token, provider: FakeFilesProvider())
        guard let port = await server.start(port: 0) else { note(false, "le serveur local démarre"); semaphore.signal(); return }
        note(port > 0 && server.url?.absoluteString == "http://127.0.0.1:\(port)/\(token)", "le serveur local écoute sur 127.0.0.1 avec son jeton dans l'adresse")

        func send(_ path: String, method: String = "POST", body: Any? = nil, headers: [String: String] = [:]) async -> (Int, Any?) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.timeoutInterval = 10
            if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (-1, nil) }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
        }
        func result(_ body: [String: Any]) async -> [String: Any]? {
            let (status, json) = await send("/\(token)", body: body)
            return status == 200 ? (json as? [String: Any])?["result"] as? [String: Any] : nil
        }

        let initialize = await result(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        note(initialize?["protocolVersion"] as? String == "2025-06-18" && (initialize?["serverInfo"] as? [String: Any])?["name"] as? String == "polymestre-files",
             "initialize : version et nom du serveur")
        note(initialize?["instructions"] as? String == "essai", "…et les instructions pour l'assistant")
        let list = await result(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        note((list?["tools"] as? [[String: Any]])?.count == 2, "tools/list rend les outils")
        let called = await result(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "read_file", "arguments": ["id": "serie:1"]]])
        note(((called?["content"] as? [[String: Any]])?.first?["text"] as? String) == "read_file:serie:1", "tools/call transmet l'outil et ses arguments")
        let (unknownStatus, unknown) = await send("/\(token)", body: ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "rm_rf"]])
        note(unknownStatus == 200 && ((unknown as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int == -32602, "un outil inconnu est refusé")
        let (notificationStatus, _) = await send("/\(token)", body: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        note(notificationStatus == 202, "une notification reçoit 202")
        let (batchStatus, batch) = await send("/\(token)", body: [["jsonrpc": "2.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "id": 2, "method": "ping"]])
        note(batchStatus == 200 && (batch as? [[String: Any]])?.count == 2, "un lot de requêtes est répondu en lot")

        // Contrôle d'accès : un jeton faux, une page web (Origin), un autre hôte (DNS rebinding), une autre méthode.
        let (wrongStatus, _) = await send("/\(String(repeating: "x", count: token.count))", body: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        note(wrongStatus == 401, "un mauvais jeton est refusé (401)")
        let (emptyStatus, _) = await send("/", body: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        note(emptyStatus == 401, "sans jeton : refusé (401)")
        let (originStatus, _) = await send("/\(token)", body: ["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["Origin": "https://evil.example"])
        note(originStatus == 403, "une requête de navigateur (en-tête Origin) est refusée, même avec le bon jeton")
        let (hostStatus, _) = await send("/\(token)", body: ["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["Host": "evil.example"])
        note(hostStatus == 403, "un autre hôte (DNS rebinding) est refusé")
        let (getStatus, _) = await send("/\(token)", method: "GET")
        note(getStatus == 405, "GET : 405 (pas de flux SSE)")
        let (badStatus, _) = await send("/\(token)", body: nil)
        note(badStatus == 400, "un corps illisible : 400")

        // L'analyse HTTP à la main.
        let partial = Data("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)
        note(LocalHTTPRequest.parse(partial) == nil, "analyse : un corps incomplet attend la suite")
        if case .success(let request)? = LocalHTTPRequest.parse(Data("POST /x?y=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\nab".utf8)) {
            note(request.method == "POST" && request.path == "/x?y=1" && request.headers["host"] == "a" && request.body == Data("ab".utf8), "analyse : méthode, chemin, en-têtes, corps")
        } else { note(false, "analyse : une requête complète") }
        if case .failure(let error)? = LocalHTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) {
            note(error == .tooLarge, "analyse : un corps démesuré est refusé")
        } else { note(false, "analyse : corps démesuré") }
        if case .failure(let error)? = LocalHTTPRequest.parse(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) {
            note(error == .chunked, "analyse : l'encodage par morceaux est refusé")
        } else { note(false, "analyse : chunked") }
        note(LocalMCPServer.constantTimeEqual("abc", "abc") && !LocalMCPServer.constantTimeEqual("abc", "abd") && !LocalMCPServer.constantTimeEqual("abc", "ab"),
             "comparaison du jeton à temps constant")

        server.stop()
        let (stoppedStatus, _) = await send("/\(token)", body: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        note(stoppedStatus == -1, "arrêté, plus rien n'écoute")
        semaphore.signal()
    }
    semaphore.wait()
    return results
}


/// Le pont de l'app Claude : le vrai script, avec le vrai Node, contre un vrai serveur local.
func desktopBridgeResults() -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    func note(_ ok: Bool, _ label: String) { results.append((ok, label)) }

    let manifestData = Data(ClaudeDesktopExtension.manifest().utf8)
    let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any]
    let server = manifest?["server"] as? [String: Any]
    note(manifest?["name"] as? String == "polymestre-files" && manifest?["manifest_version"] as? String == "0.4"
         && server?["type"] as? String == "node" && server?["entry_point"] as? String == "server/index.js",
         "extension : manifeste (nom, version, point d'entrée Node)")
    let files = ClaudeDesktopExtension.files(appID: "com.exemple.app")
    note(Set(files.keys) == ["manifest.json", "server/index.js"], "extension : deux fichiers, manifeste et pont")
    let script = String(decoding: files["server/index.js"] ?? Data(), as: UTF8.self)
    note(script.contains("com.exemple.app") && !script.contains("__APP_ID__"), "extension : l'identifiant de l'app est inscrit dans le pont")
    note(ClaudeDesktopExtension.infoFile(home: URL(fileURLWithPath: "/h")).path == "/h/Library/Application Support/Polymestre/local-mcp.json",
         "extension : le pont lit l'adresse dans local-mcp.json")

    // Node : celui de la machine (l'app Claude a le sien).
    let nodePaths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    guard let node = nodePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        note(true, "pont : Node absent de cette machine, essai du script sauté")
        return results
    }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: work) }
    for (path, data) in files {
        let file = work.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
    }
    let entry = work.appendingPathComponent("server/index.js").path

    func run(_ arguments: [String], env: [String: String], input: [String], expecting count: Int, timeout: TimeInterval = 15) -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        let lock = NSLock()
        var collected = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); collected.append(chunk); lock.unlock()
        }
        guard (try? process.run()) != nil else { return [] }
        for line in input { stdin.fileHandleForWriting.write(Data((line + "\n").utf8)) }
        let deadline = Date().addingTimeInterval(timeout)
        func replies() -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: collected, as: UTF8.self).split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        while replies().count < count, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        stdin.fileHandleForWriting.closeFile()
        process.terminate()
        stdout.fileHandleForReading.readabilityHandler = nil
        return replies()
    }

    let check = Process()
    check.executableURL = URL(fileURLWithPath: node)
    check.arguments = ["--check", entry]
    check.standardError = Pipe()
    try? check.run(); check.waitUntilExit()
    note(check.terminationStatus == 0, "pont : le script est du JavaScript valide")

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let token = LocalMCPRPC.makeToken()
        let server = LocalMCPServer(token: token, provider: FakeFilesProvider())
        guard let port = await server.start(port: 0), let url = server.url else { note(false, "pont : serveur d'essai"); semaphore.signal(); return }
        let info = work.appendingPathComponent("local-mcp.json")
        try? JSONSerialization.data(withJSONObject: ["url": url.absoluteString]).write(to: info)
        let env = ["POLYMESTRE_MCP_INFO": info.path, "POLYMESTRE_MCP_NO_LAUNCH": "1", "POLYMESTRE_MCP_WAIT_MS": "1500"]
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"id":"serie:1"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_files","arguments":{"id":"x"}}}"#,
        ]
        let replies = await Task.detached { run([entry], env: env, input: lines, expecting: 4) }.value
        func reply(_ id: Int) -> [String: Any]? { replies.first { $0["id"] as? Int == id }?["result"] as? [String: Any] }
        note(replies.count == 4, "pont : quatre réponses pour quatre requêtes (la notification n'en a pas) — \(replies.count)")
        note(reply(1)?["protocolVersion"] as? String == "2025-06-18", "pont : initialize relayé")
        note((reply(2)?["tools"] as? [[String: Any]])?.count == 2, "pont : tools/list relayé")
        note(((reply(3)?["content"] as? [[String: Any]])?.first?["text"] as? String) == "read_file:serie:1+inline", "pont : read_file est demandé en mode inline")
        note(((reply(4)?["content"] as? [[String: Any]])?.first?["text"] as? String) == "list_files:x", "pont : les autres outils passent tels quels")

        // L'adresse change (nouveau port) : le pont relit le fichier, rien n'est figé.
        server.stop()
        let second = LocalMCPServer(token: token, provider: FakeFilesProvider())
        if await second.start(port: 0) != nil, let newURL = second.url {
            try? JSONSerialization.data(withJSONObject: ["url": newURL.absoluteString]).write(to: info)
            let again = await Task.detached { run([entry], env: env, input: [lines[2]], expecting: 1) }.value
            note((again.first?["result"] as? [String: Any])?["tools"] != nil, "pont : une nouvelle adresse est reprise sans réinstaller")
            second.stop()
        } else { note(false, "pont : second serveur d'essai") }

        // Rien n'écoute : un message clair, pas un blocage.
        let down = await Task.detached { run([entry], env: env, input: [lines[3], lines[2]], expecting: 2, timeout: 20) }.value
        let callError = down.first { $0["id"] as? Int == 3 }?["result"] as? [String: Any]
        note(callError?["isError"] as? Bool == true && ((callError?["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("Polymestre") == true,
             "pont : serveur éteint → un outil répond par un message clair")
        note(((down.first { $0["id"] as? Int == 2 }?["error"] as? [String: Any])?["message"] as? String)?.contains("Polymestre") == true,
             "pont : serveur éteint → une erreur JSON-RPC lisible")
        _ = port
        semaphore.signal()
    }
    semaphore.wait()
    return results
}
