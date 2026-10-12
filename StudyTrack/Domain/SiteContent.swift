import Foundation

/// Les sites du cours lus **en natif** dans le mode étude : une page Moodle,
/// un texte de Courseware, une vidéo MediaSpace. Ici, ce qui est pur — le HTML
/// découpé en blocs, l'aiguillage d'un lien, l'adresse d'une vidéo Kaltura ou
/// edX, les réponses des scripts Moodle. Testé dans `validate.sh`.

// MARK: - Blocs

/// Un morceau de page à afficher : du texte (Markdown léger, que `RichMarkup`
/// sait mettre en page, formules comprises), une image, un fichier, une vidéo,
/// un lien.
enum SiteBlock: Equatable {
    case markdown(String)
    case image(String)
    case file(title: String, url: String)
    case video(title: String, url: String)
    case link(title: String, url: String)
}

enum SiteHTML {

    /// Une page HTML → des blocs. `base` résout les adresses relatives.
    static func blocks(_ html: String, base: URL? = nil) -> [SiteBlock] {
        var parser = Parser(base: base)
        parser.run(html)
        return parser.finish()
    }

    private struct Parser {
        let base: URL?
        var blocks: [SiteBlock] = []
        var paragraph = ""
        /// Les éléments ouverts dont on ignore le contenu (script, style…).
        var skipping: [String] = []
        var lists: [(ordered: Bool, count: Int)] = []
        var link: (href: String, text: String)?
        var pendingLinks: [SiteBlock] = []
        var pre: String?
        var cells: [String]?
        var cell: String?
        var heading: Int?

        init(base: URL?) { self.base = base }

        mutating func run(_ html: String) {
            var index = html.startIndex
            while index < html.endIndex {
                if html[index] == "<" {
                    // Commentaire.
                    if html[index...].hasPrefix("<!--") {
                        if let end = html.range(of: "-->", range: index..<html.endIndex) { index = end.upperBound } else { break }
                        continue
                    }
                    guard let close = html[index...].firstIndex(of: ">") else { text(String(html[index...])); break }
                    tag(String(html[html.index(after: index)..<close]))
                    index = html.index(after: close)
                } else {
                    let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                    text(String(html[index..<next]))
                    index = next
                }
            }
        }

        mutating func finish() -> [SiteBlock] {
            flush()
            return blocks
        }

        // MARK: Texte

        mutating func text(_ raw: String) {
            guard skipping.isEmpty else { return }
            let decoded = BotafogoParser.decode(raw)
            if pre != nil { pre! += decoded; return }
            let collapsed = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if cell != nil { cell! += collapsed; return }
            if link != nil { link!.text += collapsed }
            append(collapsed)
        }

        mutating func append(_ piece: String) {
            if paragraph.isEmpty || paragraph.hasSuffix(" ") || paragraph.hasSuffix("\n") {
                paragraph += piece.drop { $0 == " " }
            } else {
                paragraph += piece
            }
        }

        /// Le paragraphe en cours devient un bloc (avec ses liens, après lui).
        mutating func flush() {
            let lines = paragraph.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "**" && $0 != "*" }
            if !lines.isEmpty {
                let text = lines.joined(separator: "\n")
                if case .markdown(let previous)? = blocks.last, isListLine(previous), isListLine(text) {
                    blocks[blocks.count - 1] = .markdown(previous + "\n" + text)
                } else {
                    blocks.append(.markdown(text))
                }
            }
            paragraph = ""
            blocks += pendingLinks
            pendingLinks = []
        }

        private func isListLine(_ text: String) -> Bool {
            let first = text.trimmingCharacters(in: .whitespaces)
            return first.hasPrefix("- ") || first.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        }

        // MARK: Balises

        mutating func tag(_ raw: String) {
            let closing = raw.hasPrefix("/")
            let body = closing ? String(raw.dropFirst()) : raw
            let name = body.prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }.lowercased()
            guard !name.isEmpty else { return }
            let attributes = closing ? [:] : Self.attributes(body)
            let ignored: Set<String> = ["script", "style", "head", "noscript", "button", "select", "textarea", "svg", "nav"]
            if ignored.contains(name) {
                if closing { if let last = skipping.lastIndex(of: name) { skipping.remove(at: last) } }
                else if !raw.hasSuffix("/") { skipping.append(name) }
                return
            }
            guard skipping.isEmpty else { return }
            // Les formules MathJax rendues : on garde le TeX de la balise script, déjà ignorée ;
            // les spans de MathJax n'ajoutent que du texte en double.
            if !closing, (attributes["class"] ?? "").contains("MathJax") || attributes["aria-hidden"] == "true" {
                return
            }
            switch name {
            case "p", "div", "section", "article", "blockquote", "dl", "dt", "dd", "figure", "figcaption", "center", "main", "header", "footer":
                // `<li><p>texte</p></li>` : la puce attend son texte.
                if cell == nil, !paragraph.trimmingCharacters(in: .whitespaces).isBareListMarker { flush() }
            case "br":
                if pre != nil { pre! += "\n" } else if cell != nil { cell! += " " } else { paragraph += "\n" }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !closing {
                    let level = min(4, (Int(name.dropFirst()) ?? 2) + 1)
                    paragraph = String(repeating: "#", count: level) + " "
                    heading = level
                } else {
                    heading = nil
                    flush()
                }
            case "strong", "b":
                if heading == nil, cell == nil { paragraph += "**" }
            case "em", "i":
                if heading == nil, cell == nil, !(attributes["class"] ?? "").contains("icon"), !(attributes["class"] ?? "").contains("fa") {
                    paragraph += "*"
                }
            case "ul", "ol":
                flush()
                if closing { _ = lists.popLast() } else { lists.append((name == "ol", 0)) }
            case "li":
                flush()
                if !closing, !lists.isEmpty {
                    lists[lists.count - 1].count += 1
                    let current = lists[lists.count - 1]
                    paragraph = String(repeating: "  ", count: max(0, lists.count - 1)) + (current.ordered ? "\(current.count). " : "- ")
                }
            case "a":
                if closing {
                    if let open = link { finishLink(open) }
                    link = nil
                } else if let href = attributes["href"] {
                    link = (href, "")
                }
            case "img":
                guard !closing, let source = attributes["src"].flatMap(resolve) else { return }
                if (attributes["class"] ?? "").contains("icon") || source.contains("/theme/image.php") { return }
                flush()
                blocks.append(.image(source))
            case "iframe", "video", "source", "embed":
                guard !closing, let source = attributes["src"].flatMap(resolve) else { return }
                let route = SiteRouter.route(source)
                flush()
                switch route {
                case .mediaspace, .youtube, .video:
                    blocks.append(.video(title: attributes["title"] ?? "Vidéo", url: source))
                default:
                    blocks.append(.link(title: attributes["title"] ?? "Contenu intégré", url: source))
                }
            case "pre":
                if closing {
                    let code = (pre ?? "").trimmingCharacters(in: .newlines)
                    pre = nil
                    if !code.isEmpty { flush(); blocks.append(.markdown("```\n" + code + "\n```")) }
                } else {
                    flush()
                    pre = ""
                }
            case "tr":
                if closing {
                    if let row = cells, !row.isEmpty {
                        flush()
                        let line = "- " + row.joined(separator: " · ")
                        if case .markdown(let previous)? = blocks.last, previous.hasPrefix("- ") {
                            blocks[blocks.count - 1] = .markdown(previous + "\n" + line)
                        } else {
                            blocks.append(.markdown(line))
                        }
                    }
                    cells = nil
                } else {
                    flush()
                    cells = []
                }
            case "td", "th":
                if closing {
                    let value = (cell ?? "").trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { cells?.append(value) }
                    cell = nil
                } else {
                    cell = ""
                }
            default:
                break
            }
        }

        mutating func finishLink(_ open: (href: String, text: String)) {
            guard let url = resolve(open.href) else { return }
            let title = open.text.trimmingCharacters(in: .whitespaces)
            switch SiteRouter.route(url) {
            case .pdf, .file:
                pendingLinks.append(.file(title: title.isEmpty ? "Document" : title, url: url))
            case .mediaspace, .youtube, .video:
                pendingLinks.append(.video(title: title.isEmpty ? "Vidéo" : title, url: url))
            case .web where title.isEmpty:
                break
            default:
                pendingLinks.append(.link(title: title.isEmpty ? url : title, url: url))
            }
        }

        func resolve(_ raw: String) -> String? {
            let value = BotafogoParser.decode(raw.trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty, !value.hasPrefix("#"), !value.lowercased().hasPrefix("javascript:"),
                  !value.lowercased().hasPrefix("mailto:"), !value.hasPrefix("data:") else { return nil }
            if let base, let url = URL(string: value, relativeTo: base) { return url.absoluteString }
            return URL(string: value)?.scheme == nil ? nil : value
        }

        static func attributes(_ body: String) -> [String: String] {
            var result: [String: String] = [:]
            guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return result }
            let range = NSRange(body.startIndex..., in: body)
            for match in regex.matches(in: body, range: range) {
                guard let name = Range(match.range(at: 1), in: body) else { continue }
                let value = [2, 3, 4].compactMap { Range(match.range(at: $0), in: body) }.first.map { String(body[$0]) } ?? ""
                result[body[name].lowercased()] = value
            }
            return result
        }
    }
}

// MARK: - Aiguillage

/// Où mène un lien, pour l'ouvrir en natif.
enum SiteRouter {
    enum Destination: Equatable {
        case pdf
        /// Un autre fichier (diapositives, archive, code) : aperçu natif.
        case file
        case moodle(module: String, id: Int)
        case botafogo
        /// Une vidéo MediaSpace (Kaltura), par son identifiant.
        case mediaspace(entryID: String)
        case courseware(courseKey: String)
        case youtube(id: String)
        /// Un fichier vidéo ou un flux (mp4, m3u8).
        case video
        case geogebra
        case web
    }

    static func route(_ address: String) -> Destination {
        guard let url = URL(string: address), let host = url.host?.lowercased() else { return .web }
        let path = url.path.lowercased()
        if path.hasSuffix(".pdf") { return .pdf }
        if path.hasSuffix(".mp4") || path.hasSuffix(".m3u8") || path.hasSuffix(".mov") || path.hasSuffix(".webm") { return .video }
        if host.hasSuffix("moodle.epfl.ch") {
            if path.contains("/pluginfile.php/") { return path.hasSuffix(".pdf") || !path.contains(".") ? .pdf : .file }
            if let module = path.range(of: #"/mod/([a-z]+)/view\.php"#, options: .regularExpression).map({ String(path[$0]) })?
                .split(separator: "/").dropFirst().first.map(String.init),
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init) {
                return module == "resource" ? .pdf : .moodle(module: module, id: id)
            }
            return .web
        }
        if host.hasSuffix("botafogo.epfl.ch") { return .botafogo }
        if host.hasSuffix("mediaspace.epfl.ch") || host.contains("kaltura") || host.hasSuffix("cast.switch.ch") {
            if let id = kalturaEntry(in: address) { return .mediaspace(entryID: id) }
            return .web
        }
        if host.hasSuffix("courseware.epfl.ch") || host.hasSuffix("learning.edx.org") {
            if let key = MoocReference.courseKey(in: address) { return .courseware(courseKey: key) }
            return .web
        }
        if host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix("youtube-nocookie.com") {
            if let id = youTubeID(url) { return .youtube(id: id) }
            return .web
        }
        if host.hasSuffix("geogebra.org") { return .geogebra }
        let documents = [".pptx", ".ppt", ".docx", ".doc", ".xlsx", ".zip", ".ipynb", ".py", ".m", ".txt", ".csv", ".key", ".pages"]
        if documents.contains(where: { path.hasSuffix($0) }) { return .file }
        return .web
    }

    /// L'identifiant Kaltura d'une adresse (« 0_6y8w1d2s »), le dernier trouvé.
    static func kalturaEntry(in link: String) -> String? {
        let decoded = link.removingPercentEncoding ?? link
        guard let regex = try? NSRegularExpression(pattern: #"(?:[/=]|entry_?id[/=])([01]_[a-z0-9]{8})(?=[/?#&]|$)"#,
                                                   options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        return matches.last.flatMap { Range($0.range(at: 1), in: decoded).map { String(decoded[$0]) } }
    }

    static func youTubeID(_ url: URL) -> String? {
        if url.host == "youtu.be" { return url.pathComponents.dropFirst().first }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = url.pathComponents
        if let index = parts.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "v" }), index + 1 < parts.count { return parts[index + 1] }
        return nil
    }
}

// MARK: - Kaltura (MediaSpace)

/// MediaSpace EPFL est un Kaltura hébergé par SWITCH (`api.cast.switch.ch`,
/// partenaire 113). Une vidéo publique se lit par son manifeste HLS ; une vidéo
/// réservée demande en plus la clé de session (`ks`) de la page MediaSpace,
/// lue dans la session de l'étudiant·e. Vérifié : le manifeste d'une vidéo
/// publique répond `#EXTM3U` sans clé.
enum Kaltura {
    static let defaultPartner = 113
    static let host = "https://api.cast.switch.ch"

    static func manifestURL(entryID: String, partnerID: Int = defaultPartner, ks: String? = nil) -> URL? {
        var path = "\(host)/p/\(partnerID)/sp/\(partnerID)00/playManifest/entryId/\(entryID)/format/applehttp/protocol/https"
        if let ks, !ks.isEmpty { path += "/ks/\(ks)" }
        return URL(string: path + "/a.m3u8")
    }

    /// Le partenaire et la clé de session d'une page MediaSpace.
    static func config(html: String) -> (partnerID: Int?, ks: String?) {
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        let partner = first(#""partnerId"\s*:\s*"?(\d+)"#) ?? first(#"partnerId=(\d+)"#) ?? first(#"/p/(\d+)/"#)
        let ks = first(#""ks"\s*:\s*"([A-Za-z0-9_\-=]{20,})""#)
        return (partner.flatMap(Int.init), ks)
    }

    /// Un manifeste HLS lisible (et pas une page d'erreur).
    static func isPlayableManifest(_ text: String) -> Bool {
        text.hasPrefix("#EXTM3U") && text.contains("#EXT-X-")
    }
}

// MARK: - Courseware (Open edX)

/// Le plan d'un cours Open edX (`/api/courses/v2/blocks/`) : chapitres,
/// séquences, unités, et dans chaque unité ses blocs (vidéo, texte, problème).
struct EdXOutline: Equatable {
    struct Unit: Equatable, Identifiable {
        var id: String
        var title: String
        var blocks: [Block]
    }
    struct Sequence: Equatable, Identifiable {
        var id: String
        var title: String
        var units: [Unit]
    }
    struct Chapter: Equatable, Identifiable {
        var id: String
        var title: String
        var sequences: [Sequence]
    }
    struct Block: Equatable, Identifiable {
        enum Kind: Equatable { case video, html, problem, other(String) }
        var id: String
        var title: String
        var kind: Kind
        /// Le contenu seul du bloc (`student_view_url`).
        var viewURL: String?
        /// Vidéo : la meilleure source (HLS, puis mp4), ou YouTube.
        var videoURL: String?
        var youTubeID: String?
    }

    var chapters: [Chapter]

    static func parse(json: Data) -> EdXOutline? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let root = object["root"] as? String,
              let blocks = object["blocks"] as? [String: [String: Any]] else { return nil }
        func children(_ id: String) -> [String] { blocks[id]?["children"] as? [String] ?? [] }
        func title(_ id: String) -> String { BotafogoParser.decode(blocks[id]?["display_name"] as? String ?? "") }
        func block(_ id: String) -> Block {
            let raw = blocks[id] ?? [:]
            let type = raw["type"] as? String ?? ""
            let kind: Block.Kind = type == "video" ? .video : type == "html" ? .html : type == "problem" ? .problem : .other(type)
            var video: String?
            var youTube: String?
            if let data = raw["student_view_data"] as? [String: Any] {
                video = bestVideo(data)
                youTube = (data["encoded_videos"] as? [String: Any])?["youtube"].flatMap { ($0 as? [String: Any])?["url"] as? String }
                    .flatMap(URL.init(string:)).flatMap(SiteRouter.youTubeID)
            }
            return Block(id: id, title: title(id), kind: kind, viewURL: raw["student_view_url"] as? String, videoURL: video, youTubeID: youTube)
        }
        let chapters = children(root).map { chapterID in
            Chapter(id: chapterID, title: title(chapterID), sequences: children(chapterID).map { sequenceID in
                Sequence(id: sequenceID, title: title(sequenceID), units: children(sequenceID).map { unitID in
                    Unit(id: unitID, title: title(unitID), blocks: children(unitID).map(block))
                })
            })
        }
        return EdXOutline(chapters: chapters)
    }

    /// HLS d'abord (qualité adaptée), puis le mp4 le plus grand, puis le reste.
    static func bestVideo(_ data: [String: Any]) -> String? {
        let encoded = data["encoded_videos"] as? [String: Any] ?? [:]
        for key in ["hls", "desktop_mp4", "fallback", "mobile_high", "mobile_low"] {
            if let url = (encoded[key] as? [String: Any])?["url"] as? String, !url.isEmpty { return url }
        }
        let sources = data["all_sources"] as? [String] ?? []
        return sources.first { $0.contains(".m3u8") } ?? sources.first { $0.contains(".mp4") } ?? sources.first
    }
}

// MARK: - Moodle

/// Ce que les scripts de lecture d'une activité Moodle rendent (JSON).
struct MoodleActivityContent: Codable, Equatable {
    struct File: Codable, Equatable {
        var name: String
        var url: String
    }
    struct Post: Codable, Equatable {
        var subject: String
        var author: String
        var date: String
        var html: String
    }
    struct Discussion: Codable, Equatable {
        var id: Int
        var title: String
        var author: String
        var date: String
    }

    var module: String
    var title: String
    /// Le corps (page, consignes d'un devoir, description d'un dossier).
    var html: String = ""
    var files: [File] = []
    /// Devoir : « Ouvert le… », « À rendre le… ».
    var dates: [String] = []
    /// Devoir : l'état de la remise, ligne par ligne (« Statut : Aucune remise »).
    var status: [String] = []
    /// Lien : où il mène vraiment.
    var target: String?
    var discussions: [Discussion] = []
    var posts: [Post] = []
    /// Le script est tombé sur la page de connexion.
    var needsLogin: Bool = false

    static func decode(_ json: String) -> MoodleActivityContent? {
        try? JSONDecoder().decode(MoodleActivityContent.self, from: Data(json.utf8))
    }

    init(module: String, title: String, html: String = "", files: [File] = [], dates: [String] = [], status: [String] = [],
         target: String? = nil, discussions: [Discussion] = [], posts: [Post] = [], needsLogin: Bool = false) {
        self.module = module
        self.title = title
        self.html = html
        self.files = files
        self.dates = dates
        self.status = status
        self.target = target
        self.discussions = discussions
        self.posts = posts
        self.needsLogin = needsLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = try c.decodeIfPresent(String.self, forKey: .module) ?? ""
        title = BotafogoParser.decode(try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        html = try c.decodeIfPresent(String.self, forKey: .html) ?? ""
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        dates = try c.decodeIfPresent([String].self, forKey: .dates) ?? []
        status = try c.decodeIfPresent([String].self, forKey: .status) ?? []
        target = try c.decodeIfPresent(String.self, forKey: .target)
        discussions = try c.decodeIfPresent([Discussion].self, forKey: .discussions) ?? []
        posts = try c.decodeIfPresent([Post].self, forKey: .posts) ?? []
        needsLogin = try c.decodeIfPresent(Bool.self, forKey: .needsLogin) ?? false
    }
}

// MARK: - Botafogo

/// Les figures interactives de Botafogo (JSXGraph) : le site publie une image
/// fixe à côté de chaque script (`/media/jsxgraph/jsx_suite.js` →
/// `…/jsx_suite.png`, vérifié sur analyse-1-GM). On montre l'image, sans web.
enum BotafogoFigure {
    static func imagePath(script: String) -> String {
        let trimmed = script.split(separator: "?").first.map(String.init) ?? script
        guard trimmed.lowercased().hasSuffix(".js") else { return trimmed + ".png" }
        return String(trimmed.dropLast(3)) + ".png"
    }
}

// MARK: - Ed Discussion

/// Ed Discussion (edstem.org, région EU), lu en natif. Observé dans le code de
/// la page (`edcdn.net`) : l'API est `https://eu.edstem.org/api`, le jeton est
/// gardé dans le `localStorage` de la page (`authToken`) et envoyé dans l'en-tête
/// `X-Token` ; sans lui, `/api/user` répond 401. Les routes des fils
/// (`courses/<id>/threads`, `threads/<id>?view=1`) sont celles du client
/// public `edapi` — déduites, pas observées dans le code chargé à la connexion.
enum EdDiscussion {
    struct Course: Codable, Equatable, Identifiable {
        var id: Int
        var code: String
        var name: String
    }

    struct Thread: Codable, Equatable, Identifiable {
        var id: Int
        var number: Int?
        var title: String
        var category: String?
        var type: String?
        var isPinned: Bool?
        var isAnswered: Bool?
        var replyCount: Int?
        var createdAt: String?
        /// Le texte en clair (aperçu), sans mise en forme.
        var document: String?

        enum CodingKeys: String, CodingKey {
            case id, number, title, category, type, document
            case isPinned = "is_pinned", isAnswered = "is_answered", replyCount = "reply_count", createdAt = "created_at"
        }
    }

    /// Un message (le fil lui-même, une réponse, un commentaire), avec ses réponses.
    struct Post: Equatable {
        var author: String
        var date: String
        /// Le contenu au format d'Ed (XML `<document>`).
        var content: String
        var isAnswer: Bool
        var isEndorsed: Bool
        var replies: [Post]
    }

    /// `GET /api/user` → les cours où l'on est inscrit·e.
    static func courses(userJSON: Data) -> [Course] {
        guard let object = try? JSONSerialization.jsonObject(with: userJSON) as? [String: Any],
              let rows = object["courses"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let course = row["course"] as? [String: Any] ?? row
            guard let id = course["id"] as? Int else { return nil }
            return Course(id: id, code: course["code"] as? String ?? "", name: course["name"] as? String ?? "")
        }
    }

    /// `GET /api/courses/<id>/threads` → les fils.
    static func threads(json: Data) -> [Thread] {
        struct Reply: Decodable { var threads: [Thread] }
        return (try? JSONDecoder().decode(Reply.self, from: json))?.threads ?? []
    }

    /// `GET /api/threads/<id>?view=1` → le fil, ses réponses et leurs
    /// commentaires, avec le nom des auteurs (`users`).
    static func thread(json: Data) -> Post? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let thread = object["thread"] as? [String: Any] else { return nil }
        var names: [Int: String] = [:]
        for user in object["users"] as? [[String: Any]] ?? [] {
            if let id = user["id"] as? Int { names[id] = user["name"] as? String ?? "" }
        }
        func post(_ raw: [String: Any], answer: Bool) -> Post {
            let author = (raw["user_id"] as? Int).flatMap { names[$0] } ?? ((raw["is_anonymous"] as? Bool) == true ? "Anonyme" : "")
            let replies = (raw["comments"] as? [[String: Any]] ?? []).map { post($0, answer: false) }
            return Post(author: author.isEmpty ? "Anonyme" : author, date: raw["created_at"] as? String ?? "",
                        content: raw["content"] as? String ?? "", isAnswer: answer,
                        isEndorsed: (raw["is_endorsed"] as? Bool) == true, replies: replies)
        }
        var root = post(thread, answer: false)
        let answers = (thread["answers"] as? [[String: Any]] ?? []).map { post($0, answer: true) }
        root.replies = answers + root.replies
        return root
    }

    /// Le cours Ed d'un cours de l'app : le code (« CS-101 ») dans le code Ed
    /// (« CS-101 Fall 2026 », « cs101 »), le plus récent s'il y en a plusieurs.
    static func match(code: String, in courses: [Course]) -> Course? {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let base = key(code.split(separator: "(").first.map(String.init) ?? code)
        guard !base.isEmpty else { return nil }
        return courses.filter { key($0.code).hasPrefix(base) || key($0.name).contains(base) }.max { $0.id < $1.id }
    }

    /// Le format des messages d'Ed (`<document><paragraph>…<math>…</math>`) →
    /// des blocs, par le même chemin que le HTML (formules gardées en `\( \)`).
    static func blocks(_ document: String) -> [SiteBlock] {
        var text = document
        // Les formules d'abord : leur contenu ne doit pas passer pour des balises.
        text = replace(text, #"<math>(.*?)</math>"#) { "\\(" + $0[1] + "\\)" }
        text = replace(text, #"<heading level="(\d)">"#) { "<h\($0[1])>" }
        text = replace(text, #"</heading>"#) { _ in "</h3>" }
        text = replace(text, #"<list style="number"[^>]*>"#) { _ in "<ol>" }
        text = replace(text, #"<list(\s[^>]*)?>"#) { _ in "<ul>" }
        text = replace(text, #"</list>"#) { _ in "</ul>" }
        text = replace(text, #"<snippet[^>]*>"#) { _ in "<pre>" }
        text = replace(text, #"</snippet>"#) { _ in "</pre>" }
        text = replace(text, #"<web-snippet[^>]*>.*?</web-snippet>"#) { _ in "" }
        let tags = [("paragraph", "p"), ("bold", "b"), ("italic", "i"), ("underline", "span"), ("list-item", "li"),
                    ("callout", "blockquote"), ("spoiler", "div"), ("document", "div"), ("pre", "pre")]
        for (ed, html) in tags {
            text = replace(text, "<\(ed)(\\s[^>]*)?>") { _ in "<\(html)>" }
            text = text.replacingOccurrences(of: "</\(ed)>", with: "</\(html)>")
        }
        return SiteHTML.blocks(text, base: URL(string: "https://edstem.org/"))
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            result += transform(groups)
            cursor = range.upperBound
        }
        return result + text[cursor...]
    }
}

private extension String {
    /// « - » ou « 3. » seuls : une puce sans encore de texte.
    var isBareListMarker: Bool {
        self == "-" || range(of: #"^\d+\.$"#, options: .regularExpression) != nil
    }
}
