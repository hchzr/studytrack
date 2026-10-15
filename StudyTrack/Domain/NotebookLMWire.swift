import Foundation

/// Le protocole de NotebookLM, sans réseau : écrire une requête, lire une réponse.
///
/// NotebookLM n'a pas d'API publique pour un compte personnel. Son site parle à Google par
/// `batchexecute` (un format maison : des tableaux JSON imbriqués, identifiés par un code court
/// comme `CCqFvf` = créer un carnet). On fait comme le site — avec ta session Google, depuis ton
/// appareil. Les formes ci-dessous viennent des clients open source (notebooklm-py) et **peuvent
/// changer sans préavis** : tout ce qui dépend d'elles est ici, isolé et testé, pour qu'un
/// changement de Google se répare en un seul fichier.
enum NotebookLMWire {

    /// L'adresse du site. Google l'a déplacé de `notebooklm.google.com` à `notebook.google.com`.
    static let hosts = ["https://notebook.google.com", "https://notebooklm.google.com"]

    /// L'app elle-même — pas la page de connexion de Google, ni la vitrine `notebooklm.google`.
    static func isApp(host: String) -> Bool {
        hosts.contains { URL(string: $0)?.host == host }
    }

    enum RPC: String {
        case listNotebooks = "wXbhsf"
        case createNotebook = "CCqFvf"
        case addSource = "izAoDd"
        case createArtifact = "R7cb6c"
        case listArtifacts = "gArtLc"
        case deleteNotebook = "WWINqb"
    }

    // MARK: Requête

    /// Le bloc d'options que toutes les requêtes d'écriture portent.
    static func options() -> [Any] {
        [2, NSNull(), NSNull(), [1, NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), [1]]]
    }

    static func createNotebookParams(title: String) -> [Any] {
        [title, NSNull(), NSNull(), options()]
    }

    /// Un texte comme source (les fichiers Markdown de `NotebookExport`).
    static func addTextSourceParams(notebookID: String, title: String, text: String) -> [Any] {
        [[[NSNull(), [title, text], NSNull(), 2, NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), 1]], notebookID, options()]
    }

    enum AudioFormat: Int { case deepDive = 1, brief = 2, critique = 3, debate = 4 }
    enum AudioLength: Int { case short = 1, standard = 2, long = 3 }

    /// Le résumé audio (« podcast ») : les sources à utiliser, la consigne, la langue, le format.
    static func createAudioParams(notebookID: String, sourceIDs: [String], instructions: String,
                                  language: String, format: AudioFormat, length: AudioLength) -> [Any] {
        let triple: [Any] = sourceIDs.map { [[$0]] }
        let double: [Any] = sourceIDs.map { [$0] }
        let config: [Any] = [NSNull(), [instructions, length.rawValue, NSNull(), double, language, NSNull(), format.rawValue]]
        var descriptor: [Any] = [NSNull(), NSNull(), 1, triple]
        while descriptor.count < 6 { descriptor.append(NSNull()) }
        descriptor.append(config)
        return [options(), notebookID, descriptor]
    }

    static func listArtifactsParams(notebookID: String) -> [Any] {
        [[2], notebookID, "NOT artifact.status = \"ARTIFACT_STATUS_SUGGESTED\""]
    }

    static func deleteNotebookParams(notebookID: String) -> [Any] { [[notebookID], [2]] }

    /// `f.req=` + `at=` : le corps d'une requête (le jeton `at` vient de la page du site).
    static func body(rpc: RPC, params: [Any], token: String) -> String {
        let inner: [Any] = [rpc.rawValue, json(params), NSNull(), "generic"]
        return "f.req=\(encode(json([[inner]])))&at=\(encode(token))&"
    }

    /// L'adresse d'un appel.
    static func url(host: String, rpc: RPC, sourcePath: String, session: String, language: String = "fr") -> URL? {
        var parts = URLComponents(string: host + "/_/LabsTailwindUi/data/batchexecute")
        parts?.queryItems = [
            .init(name: "rpcids", value: rpc.rawValue),
            .init(name: "source-path", value: sourcePath),
            .init(name: "f.sid", value: session),
            .init(name: "hl", value: language),
            .init(name: "rt", value: "c"),
        ]
        return parts?.url
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    // MARK: Réponse

    enum ParseError: Error, Equatable {
        /// Google a répondu, mais pas à cet appel (session expirée : la page de connexion).
        case notAnswer
        /// Google a refusé l'appel (code d'erreur dans la réponse).
        case refused(code: Int?)
    }

    /// Le résultat d'un appel : la réponse est `)]}'`, puis des blocs `<longueur>\n<json>` ; celui
    /// qui porte `wrb.fr` et notre code a le résultat, en texte JSON, à l'indice 2.
    static func result(of response: String, rpc: RPC) throws -> Any? {
        var text = response
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)) }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
                  let blocks = try? JSONSerialization.jsonObject(with: data) as? [Any] else { continue }
            for block in blocks {
                guard let row = block as? [Any], row.count >= 3, (row[0] as? String) == "wrb.fr", (row[1] as? String) == rpc.rawValue else { continue }
                if let payload = row[2] as? String, let data = payload.data(using: .utf8) {
                    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                }
                // Pas de résultat : un code d'erreur à l'indice 5 (`[3]` = paramètres refusés, etc.).
                if row.count > 5, let error = row[5] as? [Any], let code = error.first as? Int { throw ParseError.refused(code: code) }
                return nil
            }
        }
        throw ParseError.notAnswer
    }

    // MARK: Lire les formes

    /// Les jetons de la page du site : `"SNlM0e":"…"` (le jeton `at`) et `"FdrFJe":"…"` (la session).
    static func field(_ key: String, inPage html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        for pattern in ["\"\(escaped)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", "&quot;\(escaped)&quot;\\s*:\\s*&quot;((?:(?!&quot;).)*)&quot;"] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[range]).replacingOccurrences(of: "\\u003d", with: "=").replacingOccurrences(of: "\\/", with: "/")
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Le premier identifiant (UUID) trouvé dans une réponse : celui du carnet ou de la source
    /// créée. On le cherche plutôt que de compter des indices : la forme exacte bouge, l'UUID non.
    static func firstID(in value: Any?) -> String? { ids(in: value).first }

    static func ids(in value: Any?) -> [String] {
        var out: [String] = []
        func walk(_ node: Any?) {
            if let text = node as? String {
                if UUID(uuidString: text) != nil { out.append(text) }
            } else if let list = node as? [Any] {
                list.forEach { walk($0) }
            }
        }
        walk(value)
        return out
    }

    /// L'identifiant d'un carnet dans son adresse : `…/notebook/<uuid>`.
    static func notebookID(fromURL address: String) -> String? {
        guard let url = URL(string: address) else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "notebook"), parts.indices.contains(index + 1) else { return nil }
        return UUID(uuidString: parts[index + 1]) != nil ? parts[index + 1] : nil
    }

    static func notebookURL(id: String, host: String = hosts[0]) -> String { "\(host)/notebook/\(id)" }

    struct Artifact: Equatable {
        enum State: Equatable { case waiting, working, ready, failed }
        var id: String
        var title: String
        /// 1 = résumé audio.
        var type: Int
        var state: State
        var audioURL: URL?
    }

    /// Les lignes d'une réponse `gArtLc` : `[[ [id, titre, type, …, état, …, [… audio …]], … ]]`.
    static func artifacts(from result: Any?) -> [Artifact] {
        guard var rows = result as? [Any] else { return [] }
        // Enveloppé (`[[ligne, ligne]]`) ou déjà à plat.
        if let first = rows.first as? [Any], let inner = first.first, inner is [Any] { rows = first }
        return rows.compactMap { item in
            guard let row = item as? [Any], row.count > 4, let id = row[0] as? String else { return nil }
            let state: Artifact.State
            switch row[4] as? Int {
            case 3: state = .ready
            case 4: state = .failed
            case 2: state = .working
            default: state = .waiting
            }
            return Artifact(id: id, title: (row[1] as? String) ?? "", type: (row[2] as? Int) ?? 0, state: state, audioURL: audioURL(in: row))
        }
    }

    /// `row[6][5]` : la liste des médias, `[url, …, "audio/mp4"]` ; on préfère `audio/mp4`.
    private static func audioURL(in row: [Any]) -> URL? {
        guard row.count > 6, let block = row[6] as? [Any], block.count > 5, let media = block[5] as? [Any] else { return nil }
        var fallback: URL?
        for case let item as [Any] in media {
            guard let address = item.first as? String, address.hasPrefix("http"), let url = URL(string: address) else { continue }
            if fallback == nil { fallback = url }
            if item.count > 2, (item[2] as? String) == "audio/mp4" { return url }
        }
        return fallback
    }

    /// La consigne du podcast : en français, centrée sur les liens et les prérequis.
    static func podcastInstructions(courseName: String) -> String {
        "Un podcast en français pour réviser « \(courseName) ». Concentre-toi sur les liens entre les notions et sur ce qu'il faut comprendre avant chaque résultat. Explique d'abord l'intuition, puis l'énoncé ; signale les pièges et les confusions fréquentes."
    }
}
