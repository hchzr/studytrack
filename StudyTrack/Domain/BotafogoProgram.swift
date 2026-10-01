import Foundation

// MARK: - Le programme d'un site de cours Botafogo

/// Un nœud du programme d'un site de cours Botafogo (Analyse I GM, classe
/// inversée) : une semaine, un cours filmé, une séance, une série, un exercice.
///
/// Le programme n'est ni dans le HTML ni dans une API : il est **écrit dans le
/// code** du site, un littéral JavaScript que la barre latérale déplie
/// (« Semaine 03 · 22-26 sept » → Cours 05, Série 3, Cours 06). On le retrouve
/// dans le bon fichier `_nuxt/*.js` et on le relit (`BotafogoProgram.extract`).
struct BotafogoNode: Decodable, Equatable {
    var type: String
    var name: String?
    var url: String?
    var metadata: [String: String]?
    var children: [BotafogoNode]?

    enum CodingKeys: String, CodingKey { case type, name, url, metadata, children }

    init(type: String, name: String? = nil, url: String? = nil,
         metadata: [String: String]? = nil, children: [BotafogoNode]? = nil) {
        self.type = type
        self.name = name
        self.url = url
        self.metadata = metadata
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        name = try? container.decode(String.self, forKey: .name)
        url = try? container.decode(String.self, forKey: .url)
        // Les métadonnées mêlent chaînes et nombres : on garde les chaînes.
        if let raw = try? container.decode([String: AnyCodableScalar].self, forKey: .metadata) {
            metadata = raw.compactMapValues(\.text)
        }
        children = try? container.decode([BotafogoNode].self, forKey: .children)
    }

    func meta(_ key: String) -> String? { metadata?[key] }
}

/// Une valeur scalaire de JSON, lue comme texte.
struct AnyCodableScalar: Decodable {
    var text: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { text = value }
        else if let value = try? container.decode(Int.self) { text = String(value) }
        else if let value = try? container.decode(Double.self) { text = String(value) }
        else if let value = try? container.decode(Bool.self) { text = String(value) }
        else { text = nil }
    }
}

enum BotafogoProgram {

    // MARK: Le littéral JavaScript

    /// Le programme contenu dans un fichier JavaScript du site, s'il y est.
    static func extract(fromScript script: String) -> [BotafogoNode]? {
        let chars = Array(script.utf8)
        let weekMarker = Array("type:`week`".utf8)
        let arrayMarker = Array("[{type:`".utf8)
        let weeks = occurrences(of: weekMarker, in: chars)
        guard let firstWeek = weeks.first, let lastWeek = weeks.last else { return nil }
        // Le plus petit tableau qui contient **toutes** les semaines.
        for start in occurrences(of: arrayMarker, in: chars) where start < firstWeek {
            guard let end = matchingEnd(chars, from: start), end > lastWeek else { continue }
            let literal = String(decoding: chars[start...end], as: UTF8.self)
            guard let json = jsonFromLiteral(literal),
                  let nodes = try? JSONDecoder().decode([BotafogoNode].self, from: Data(json.utf8)),
                  nodes.contains(where: { $0.type == "week" }) else { continue }
            return nodes
        }
        return nil
    }

    private static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard needle.count <= haystack.count, let first = needle.first else { return [] }
        var result: [Int] = []
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first, Array(haystack[index..<index + needle.count]) == needle {
                result.append(index)
            }
            index += 1
        }
        return result
    }

    /// La fin du tableau ouvert en `start`, en sautant les chaînes `…`.
    private static func matchingEnd(_ chars: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var index = start
        while index < chars.count {
            let c = chars[index]
            if inString {
                if c == UInt8(ascii: "\\") { index += 2; continue }
                if c == UInt8(ascii: "`") { inString = false }
            } else {
                switch c {
                case UInt8(ascii: "`"): inString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"), UInt8(ascii: "("): depth += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"), UInt8(ascii: ")"):
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    /// Un littéral d'objet JavaScript minifié → JSON : clés sans guillemets,
    /// chaînes entre accents graves, `!0` / `!1`, `void 0`.
    static func jsonFromLiteral(_ literal: String) -> String? {
        let chars = Array(literal)
        var out = ""
        out.reserveCapacity(chars.count + chars.count / 4)
        var index = 0
        func quote(_ text: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let array = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        }
        while index < chars.count {
            let c = chars[index]
            if c == "`" {
                var buffer = ""
                index += 1
                while index < chars.count, chars[index] != "`" {
                    if chars[index] == "\\", index + 1 < chars.count {
                        buffer.append(chars[index + 1])
                        index += 2
                        continue
                    }
                    buffer.append(chars[index])
                    index += 1
                }
                out += quote(buffer)
                index += 1
                continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var end = index
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" || chars[end] == "$" { end += 1 }
                let word = String(chars[index..<end])
                if end < chars.count, chars[end] == ":" {
                    out += quote(word)
                } else if word == "void" {
                    out += "null"
                    end += 2 // « void 0 »
                } else if ["true", "false", "null"].contains(word) {
                    out += word
                } else {
                    out += quote(word)
                }
                index = end
                continue
            }
            if c == "!", index + 1 < chars.count, chars[index + 1] == "0" || chars[index + 1] == "1" {
                out += chars[index + 1] == "0" ? "true" : "false"
                index += 2
                continue
            }
            out.append(c)
            index += 1
        }
        return out
    }

    // MARK: Chemins

    /// `series/AN_serie_03` → `/course_material/series/an_serie_03` (l'API des
    /// contenus attend le chemin en minuscules).
    static func contentPath(_ url: String) -> String {
        "/course_material/" + url.lowercased()
    }

    /// La page d'un élément du site : `…/analyse-1-GM/?cours=series/AN_serie_03`.
    static func pageURL(root: URL, url: String) -> String {
        BotafogoLinks.coursURL(root: root, path: url)
    }

    /// Une section du polycopié : `…/?polycopie=matiere/m_suites_gendarmes`.
    static func handoutURL(root: URL, target: String) -> String {
        BotafogoLinks.polycopieURL(root: root, path: "matiere/" + target)
    }

    /// `series/AN_serie_03` → 3.
    static func seriesNumber(url: String) -> Int? {
        guard let range = url.range(of: #"(\d+)\s*$"#, options: .regularExpression) else { return nil }
        return Int(url[range])
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

// MARK: - Les documents du site

/// Ce qu'une page de cours (ou de semaine) annonce : les sections du
/// polycopié couvertes et les vidéos.
struct BotafogoLectureContent: Equatable {
    struct Reference: Equatable { var target: String; var title: String }
    struct Video: Equatable { var id: String; var title: String }
    var references: [Reference] = []
    var videos: [Video] = []
}

/// Un exercice lu dans le document d'une série.
struct BotafogoExercise: Equatable {
    /// « 3.1 ».
    var number: String
    var statement: String
    var hint: String
    var solution: String
    var questions: [DetectedSubQuestion]
}

/// Lit les documents du site (arbre HTML en JSON, format « minimark » de Nuxt
/// Content) : les pages de cours et les séries.
enum BotafogoDocument {

    /// Le corps d'une réponse de `/api/content/node`.
    static func body(fromNodeJSON data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let body = object["body"] as? [String: Any] { return body }
        if let text = object["body"] as? String,
           let body = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return body }
        return nil
    }

    // MARK: Pages de cours

    static func lecture(fromNodeJSON data: Data) -> BotafogoLectureContent {
        guard let body = body(fromNodeJSON: data) else { return BotafogoLectureContent() }
        var content = BotafogoLectureContent()
        var seenTargets = Set<String>()
        var seenVideos = Set<String>()
        walk(body) { node in
            let tag = node["tagName"] as? String
            let properties = node["properties"] as? [String: Any] ?? [:]
            if tag == "latex-ref", let target = properties["target"] as? String, target.hasPrefix("m_"),
               seenTargets.insert(target).inserted {
                content.references.append(.init(target: target, title: text(of: node)))
            }
            if tag == "videokaltura", let id = properties["entryId"] as? String, seenVideos.insert(id).inserted {
                content.videos.append(.init(id: id, title: (properties["title"] as? String) ?? "Vidéo"))
            }
        }
        return content
    }

    // MARK: Séries

    /// Les exercices d'une série, dans l'ordre : énoncé, questions, indication,
    /// solution.
    static func exercises(fromNodeJSON data: Data) -> [BotafogoExercise] {
        guard let body = body(fromNodeJSON: data) else { return [] }
        var elements: [[String: Any]] = []
        collect(body, tag: "exercise", into: &elements)
        return elements.compactMap(exercise)
    }

    private static func exercise(_ element: [String: Any]) -> BotafogoExercise? {
        guard let root = contentRoot(of: element) else { return nil }
        var number = ""
        var statement: [String] = []
        var hint = ""
        var solution = ""
        var questions: [DetectedSubQuestion] = []

        func visit(_ children: [[String: Any]]) {
            for child in children {
                let tag = child["tagName"] as? String
                switch tag {
                case "b" where number.isEmpty:
                    let label = text(of: child)
                    if let range = label.range(of: #"\d+\s*[-.]\s*\d+"#, options: .regularExpression) {
                        number = label[range].replacingOccurrences(of: "-", with: ".")
                            .replacingOccurrences(of: " ", with: "")
                            .split(separator: ".").map { String(Int($0) ?? 0) }.joined(separator: ".")
                    } else {
                        statement.append(label)
                    }
                case "indication":
                    hint = contentRoot(of: child).map(text(of:)) ?? text(of: child)
                case "solution":
                    solution = contentRoot(of: child).map(text(of:)) ?? text(of: child)
                case "ol" where questions.isEmpty:
                    questions = list(child, depth: 0)
                case "multicols", "template":
                    if let inner = contentRoot(of: child) { visit(nodes(inner)) } else { visit(nodes(child)) }
                case "br", "img", "div" where text(of: child).isEmpty:
                    continue
                default:
                    let value = text(of: child)
                    if !value.trimmingCharacters(in: .whitespaces).isEmpty { statement.append(value) }
                }
            }
        }
        visit(nodes(root))
        guard !number.isEmpty else { return nil }
        return BotafogoExercise(number: number,
                                statement: tidy(statement.joined(separator: " "), limit: 700),
                                hint: tidy(hint, limit: 1500),
                                solution: tidy(solution, limit: 4000),
                                questions: questions)
    }

    /// Une liste numérotée : « 1. 2. 3. », et dedans « (a) (b) ».
    private static func list(_ element: [String: Any], depth: Int) -> [DetectedSubQuestion] {
        let items = nodes(element).filter { ($0["tagName"] as? String) == "li" }
        return items.enumerated().map { index, item in
            var ownText: [String] = []
            var children: [DetectedSubQuestion] = []
            for child in nodes(item) {
                if (child["tagName"] as? String) == "ol", depth == 0, children.isEmpty {
                    children = list(child, depth: 1)
                } else {
                    ownText.append(text(of: child))
                }
            }
            let label = depth == 0 ? String(index + 1) : String(UnicodeScalar(UInt8(97 + min(index, 25))))
            return DetectedSubQuestion(label: label, text: tidy(ownText.joined(separator: " "), limit: 280),
                                       children: children)
        }
    }

    // MARK: Arbre

    private static func nodes(_ node: [String: Any]) -> [[String: Any]] {
        (node["children"] as? [[String: Any]]) ?? []
    }

    /// Le contenu d'un élément à gabarit : `exercise` → `template` → `content`.
    private static func contentRoot(of element: [String: Any]) -> [String: Any]? {
        if let content = element["content"] as? [String: Any] { return content }
        for child in nodes(element) where (child["tagName"] as? String) == "template" {
            if let content = child["content"] as? [String: Any] { return content }
        }
        return nil
    }

    private static func walk(_ node: [String: Any], _ visit: ([String: Any]) -> Void) {
        visit(node)
        for child in nodes(node) { walk(child, visit) }
        if let content = node["content"] as? [String: Any] { walk(content, visit) }
    }

    private static func collect(_ node: [String: Any], tag: String, into result: inout [[String: Any]]) {
        if (node["tagName"] as? String) == tag {
            result.append(node)
            return
        }
        for child in nodes(node) { collect(child, tag: tag, into: &result) }
        if let content = node["content"] as? [String: Any] { collect(content, tag: tag, into: &result) }
    }

    /// Le texte d'un nœud ; les formules gardent leur LaTeX entre `$…$`.
    static func text(of node: [String: Any]) -> String {
        if (node["type"] as? String) == "text" { return node["value"] as? String ?? "" }
        let tag = node["tagName"] as? String
        if tag == "katex-renderer" {
            let properties = node["properties"] as? [String: Any] ?? [:]
            return "$" + simplifyMath(properties["content"] as? String ?? "") + "$"
        }
        if tag == "img" || tag == "jsxgraph" || tag == "videokaltura" { return "" }
        if tag == "br" { return " " }
        var parts = nodes(node).map(text(of:))
        if let content = node["content"] as? [String: Any] { parts.append(text(of: content)) }
        let joined = parts.joined()
        if tag == "p" || tag == "li" || tag == "div" { return joined + " " }
        return joined
    }

    /// `\begin{align*} a &= b \\ c \end{align*}` → `a = b ; c` : ce que
    /// `MathText` sait afficher sur une ligne.
    static func simplifyMath(_ latex: String) -> String {
        var text = latex
        text = text.replacingOccurrences(of: #"\\(begin|end)\{[a-z*]+\}(\{[^}]*\})?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\\\"#, with: " ; ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Espaces normalisés, longueur bornée à un mot près.
    static func tidy(_ text: String, limit: Int) -> String {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        // Ne pas couper une formule en deux : on recule avant un `$` ouvert.
        var prefix = String(cut)
        if prefix.filter({ $0 == "$" }).count % 2 == 1, let last = prefix.lastIndex(of: "$") {
            prefix = String(prefix[..<last])
        }
        if let space = prefix.lastIndex(of: " ") { prefix = String(prefix[..<space]) }
        return prefix + "…"
    }
}

// MARK: - Le brouillon d'import

/// Un exercice prêt à écrire, venu d'une source qui publie les exercices.
struct ContentExerciseDraft: Equatable {
    var number: String
    var title: String = ""
    var statement: String = ""
    var hint: String = ""
    var solution: String = ""
    var url: String = ""
    var isBonus = false
    var questions: [DetectedSubQuestion] = []
}

enum BotafogoProgramBuilder {

    /// Le programme, semaine par semaine, en brouillon d'import.
    ///
    /// - Parameters:
    ///   - program: le programme lu dans le code du site.
    ///   - root: la racine du site (`…/analyse-1-GM/`).
    ///   - handout: le sommaire du polycopié (chapitres → sections).
    ///   - lectures: le contenu de chaque page de cours ou de semaine, par `url`.
    ///   - series: les exercices de chaque série, par `url`.
    static func draft(title: String,
                      program: [BotafogoNode],
                      root: URL,
                      handout: [NuxtPayload.NavNode],
                      lectures: [String: BotafogoLectureContent],
                      series: [String: [BotafogoExercise]],
                      calendar: Calendar = .current) -> ContentDraft {
        // Titre complet de chaque section du polycopié, par identifiant `m_…`.
        var sectionTitles: [String: String] = [:]
        for chapter in handout {
            for section in chapter.children {
                // Les références d'un cours et le sommaire n'écrivent pas
                // l'identifiant avec la même casse (« m_reels_R_est… » et
                // « m_reels_r_est… ») : on compare en minuscules.
                if let target = section.path.split(separator: "/").last.map({ $0.lowercased() }), target.hasPrefix("m_") {
                    sectionTitles[target] = section.title
                }
            }
        }

        var sections: [ContentDraftSection] = []
        var placed = Set<String>()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "fr_CH")
        dayFormatter.dateFormat = "EEEE d MMM"

        for week in program where week.type == "week" {
            guard let number = week.meta("number").flatMap({ Int($0) }) else { continue }
            var items: [ContentDraftItem] = []
            for child in week.children ?? [] {
                switch child.type {
                case "lecture", "weekContent", "session":
                    let content = child.url.flatMap { lectures[$0] } ?? BotafogoLectureContent()
                    if child.type == "lecture" {
                        let date = BotafogoProgram.date(child.meta("date"))
                        let index = child.name.flatMap { name in name.split(separator: " ").last.flatMap { Int($0) } }
                        let videoID = child.meta("videoId").flatMap { $0.count > 5 ? $0 : nil } ?? content.videos.first?.id
                        let subtitle = date.map { dayFormatter.string(from: $0) } ?? ""
                        items.append(ContentDraftItem(kind: .theory,
                                                      number: "C\(index ?? items.count + 1)",
                                                      title: "\(child.name ?? "Cours")\(subtitle.isEmpty ? "" : " · " + subtitle)",
                                                      url: videoID.map { "https://mediaspace.epfl.ch/media/\($0)" }
                                                          ?? BotafogoProgram.pageURL(root: root, url: child.url ?? ""),
                                                      videoCount: 1,
                                                      seriesNumber: nil,
                                                      theoryKind: .video,
                                                      week: number))
                    }
                    for reference in content.references where placed.insert(reference.target.lowercased()).inserted {
                        let full = sectionTitles[reference.target.lowercased()] ?? reference.title
                        let lead = ContentDraftBuilder.leadingNumber(in: ContentDraftBuilder.cleanTitle(full))
                        items.append(ContentDraftItem(kind: .theory,
                                                      number: lead?.number ?? reference.target,
                                                      title: lead?.rest ?? ContentDraftBuilder.cleanTitle(full),
                                                      url: BotafogoProgram.handoutURL(root: root, target: reference.target.lowercased()),
                                                      videoCount: 0,
                                                      seriesNumber: nil,
                                                      theoryKind: .reading,
                                                      week: number))
                    }
                case "series":
                    guard let url = child.url, let seriesNumber = BotafogoProgram.seriesNumber(url: url) else { continue }
                    let read = series[url] ?? []
                    let listed = (child.children ?? []).filter { $0.type == "exercise" }
                    var exercises: [ContentExerciseDraft] = []
                    for (index, node) in listed.enumerated() {
                        let fallback = "\(seriesNumber).\(index + 1)"
                        let parsed = read.indices.contains(index) ? read[index] : nil
                        exercises.append(ContentExerciseDraft(number: fallback,
                                                              statement: parsed?.statement ?? "",
                                                              hint: parsed?.hint ?? "",
                                                              solution: parsed?.solution ?? "",
                                                              url: node.url.map { BotafogoProgram.pageURL(root: root, url: $0) } ?? "",
                                                              questions: parsed?.questions ?? []))
                    }
                    if exercises.isEmpty {
                        exercises = read.map { ContentExerciseDraft(number: $0.number, statement: $0.statement,
                                                                   hint: $0.hint, solution: $0.solution,
                                                                   questions: $0.questions) }
                    }
                    var item = ContentDraftItem(kind: .series,
                                                number: String(seriesNumber),
                                                title: ContentDraftBuilder.cleanTitle(child.name ?? "Série \(seriesNumber)"),
                                                url: BotafogoProgram.pageURL(root: root, url: url),
                                                videoCount: 0,
                                                seriesNumber: seriesNumber,
                                                theoryKind: .reading,
                                                week: number)
                    item.exercises = exercises
                    item.solutionsAt = BotafogoProgram.date(child.meta("solutionsDate"))
                    item.solutionURL = item.url
                    items.append(item)
                default:
                    continue
                }
            }
            guard !items.isEmpty else { continue }
            let label = [week.name.map(ContentDraftBuilder.cleanTitle), week.meta("dates")].compactMap { $0 }.joined(separator: " · ")
            sections.append(ContentDraftSection(title: "Semaine \(number) · \(label)",
                                                week: number,
                                                weekIsInferred: false,
                                                isIncluded: true,
                                                items: items))
        }

        // Ce que le programme ne cite pas : proposé à part, décoché.
        var leftovers: [ContentDraftItem] = []
        for chapter in handout {
            let chapterTitle = ContentDraftBuilder.cleanTitle(chapter.title)
            guard !ContentDraftBuilder.isFrontMatter(chapterTitle) else { continue }
            for section in chapter.children {
                guard let target = section.path.split(separator: "/").last.map(String.init),
                      target.hasPrefix("m_"), !placed.contains(target.lowercased()) else { continue }
                let clean = ContentDraftBuilder.cleanTitle(section.title)
                let lead = ContentDraftBuilder.leadingNumber(in: clean)
                leftovers.append(ContentDraftItem(kind: .theory, number: lead?.number ?? target,
                                                  title: lead?.rest ?? clean,
                                                  url: BotafogoProgram.handoutURL(root: root, target: target),
                                                  videoCount: 0, seriesNumber: nil, theoryKind: .reading))
            }
        }
        if !leftovers.isEmpty {
            sections.append(ContentDraftSection(title: "Polycopié : sections hors du programme hebdomadaire",
                                                week: 0, weekIsInferred: true, isIncluded: false, items: leftovers))
        }

        return ContentDraft(source: .botafogo, courseTitle: title, url: root.absoluteString, sections: sections)
    }
}

// MARK: - Quel site Botafogo pour quel cours

/// Le site Botafogo d'un cours EPFL, quand il en a un.
///
/// Certains cours n'ont (presque) rien sur Moodle : leur programme vit sur
/// Botafogo. Le site se trouve sans table écrite à la main : un lien Botafogo
/// cité dans le cours, sinon le polycopié du catalogue dont le titre
/// correspond au cours (« Mon cours d'analyse classe inversée » ↔ « Analyse I
/// classe inversée »).
enum BotafogoCatalog {

    /// Un lien Botafogo cité par le cours (activité, texte d'une section).
    static func site(in snapshot: MoodleCourseSnapshot) -> URL? {
        let links = snapshot.sections.flatMap { $0.activities.map(\.link) + $0.links.map(\.url) }
        return links.lazy.compactMap(URL.init(string:)).first { $0.host?.contains("botafogo") == true }
            .map(BotafogoParser.courseRoot(of:))
    }

    /// L'entrée du catalogue qui correspond au cours : tous ses mots
    /// significatifs se retrouvent dans le nom du cours, et le plus possible.
    static func match(courseName: String, in catalog: [(title: String, url: URL)]) -> URL? {
        let stop: Set<String> = ["mon", "ma", "cours", "course", "de", "du", "d", "la", "le", "l", "les", "pour", "for",
                                 "polycopie", "the", "my", "et", "and", "en", "a"]
        func words(_ text: String) -> Set<String> {
            Set(ContentDraftBuilder.fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { !stop.contains($0) && $0.count > 1 })
        }
        let course = words(courseName)
        var best: (url: URL, score: Int)?
        for entry in catalog {
            let wanted = words(entry.title)
            guard !wanted.isEmpty, wanted.isSubset(of: course) else { continue }
            if wanted.count > (best?.score ?? 0) { best = (entry.url, wanted.count) }
        }
        return best?.url
    }
}


/// Les adresses des sites Botafogo, telles que le site les lit.
///
/// Le site a deux onglets, « Cours » et « Polycopié », chacun piloté par un
/// paramètre : `?cours=series/AN_serie_03` ouvre une série,
/// `?polycopie=matiere/m_reels_intro` une section du polycopié. Deux pièges,
/// vérifiés dans le navigateur de l'app :
///   • `?cours=&polycopie=/handout/…` (ce que l'app écrivait) affiche l'onglet
///     Cours **vide** — « Sélectionnez une section depuis la barre latérale » —
///     et le polycopié ne trouve pas la section : le site préfixe lui-même
///     `/handout/` ;
///   • sans la barre finale (`…/analyse-1-flipped?cours=…`), le serveur
///     redirige vers l'accueil et la requête est perdue.
enum BotafogoLinks {
    static func coursURL(root: URL, path: String) -> String {
        base(root) + "?cours=" + path
    }

    static func polycopieURL(root: URL, path: String) -> String {
        base(root) + "?polycopie=" + handoutID(path)
    }

    /// `/handout/matiere/m_x` → `matiere/m_x`.
    static func handoutID(_ path: String) -> String {
        var id = path
        while id.hasPrefix("/") { id.removeFirst() }
        if id.lowercased().hasPrefix("handout/") { id.removeFirst("handout/".count) }
        return id
    }

    private static func base(_ root: URL) -> String {
        root.absoluteString.hasSuffix("/") ? root.absoluteString : root.absoluteString + "/"
    }

    /// Répare une adresse enregistrée par une version précédente de l'app.
    static func normalize(_ url: URL) -> URL {
        guard url.host?.contains("botafogo") == true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return url }
        var fixed: [URLQueryItem] = []
        for item in items {
            guard let value = item.value?.removingPercentEncoding ?? item.value, !value.isEmpty else { continue }
            fixed.append(URLQueryItem(name: item.name, value: item.name == "polycopie" ? handoutID(value) : value))
        }
        components.queryItems = fixed.isEmpty ? nil : fixed
        if !components.path.hasSuffix("/"), !(components.path.split(separator: "/").last?.contains(".") ?? false) {
            components.path += "/"
        }
        return components.url ?? url
    }
}

/// Les liens enregistrés, réparés avant d'être ouverts.
enum SiteLinks {
    static func normalize(_ url: URL) -> URL {
        MoodleLinks.normalize(BotafogoLinks.normalize(url))
    }
}

/// Un document Moodle s'ouvre sur le document, pas sur la page d'activité.
///
/// `mod/resource/view.php?id=…` est la page « Cliquer sur … pour ouvrir la
/// ressource » ; avec `redirect=1`, Moodle redirige vers `pluginfile.php`,
/// que le navigateur de l'app affiche directement. Même chose pour une
/// activité « lien » (`mod/url`), qui redirige alors vers sa cible. Les imports
/// lisent désormais l'adresse finale ; ceci répare les liens enregistrés avant.
///
/// Une **page** ou un **dossier** Moodle (`mod/page`, `mod/folder`) n'a pas de
/// redirection : le PDF de la série y est un lien parmi d'autres. C'est le cas
/// d'AICC, dont les séries s'ouvraient sur la page Moodle qui porte le lien.
/// `statementLink(inHTML:)` le retrouve dans la page.
enum MoodleLinks {
    /// Les activités dont la page n'est qu'un intermédiaire vers un document.
    static let activityModules = ["resource", "url", "page", "folder"]

    /// `mod/page/view.php?id=…` → `page` ; `nil` hors d'une activité Moodle.
    static func activityModule(of url: URL) -> String? {
        guard url.host?.contains("moodle") == true else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[parts.count - 3] == "mod", parts.last == "view.php",
              activityModules.contains(parts[parts.count - 2]) else { return nil }
        return parts[parts.count - 2]
    }

    static func normalize(_ url: URL) -> URL {
        guard let module = activityModule(of: url), module == "resource" || module == "url",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "redirect" || $0.name == "forceview" }) else { return url }
        items.append(URLQueryItem(name: "redirect", value: "1"))
        components.queryItems = items
        return components.url ?? url
    }

    /// La page « intermédiaire » d'une activité, celle qui porte le lien :
    /// `forceview=1` empêche la redirection d'un fichier ou d'un lien.
    static func workaroundPage(_ url: URL) -> URL {
        guard let module = activityModule(of: url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "redirect" && $0.name != "forceview" }
        if module == "resource" || module == "url" { items.append(URLQueryItem(name: "forceview", value: "1")) }
        components.queryItems = items
        return components.url ?? url
    }

    /// Un lien d'une page HTML : son adresse (absolue) et son texte.
    struct Anchor: Equatable {
        var href: String
        var text: String
    }

    /// Les liens et documents intégrés d'une page HTML, dans l'ordre.
    ///
    /// Une analyse par motifs suffit ici : on ne cherche que des `href`/`src`,
    /// sur des pages produites par Moodle.
    static func anchors(inHTML html: String, baseURL: URL?) -> [Anchor] {
        var result: [Anchor] = []
        let anchor = #"<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        let embedded = #"<(?:iframe|embed|object)\b[^>]*?\b(?:src|data)\s*=\s*["']([^"']+)["']"#
        for (pattern, hasText) in [(anchor, true), (embedded, false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let raw = decodeEntities(String(html[range]))
                guard let absolute = URL(string: raw, relativeTo: baseURL)?.absoluteURL, absolute.scheme?.hasPrefix("http") == true else { continue }
                var text = ""
                if hasText, let textRange = Range(match.range(at: 2), in: html) {
                    text = decodeEntities(String(html[textRange])
                        .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
                result.append(Anchor(href: absolute.absoluteString, text: text))
            }
        }
        return result
    }

    /// Le document qu'une page d'activité Moodle désigne.
    ///
    /// Dans l'ordre : le lien « cliquez ici » d'un fichier ou d'un lien
    /// (`urlworkaround`, `resourceworkaround`) ; un PDF déposé sur Moodle
    /// (`pluginfile.php`) ou ailleurs, **énoncé** de préférence au corrigé ; un
    /// document intégré. `nil` si la page ne désigne rien de tel.
    static func statementLink(inHTML html: String, baseURL: URL?) -> (statement: String?, solution: String?) {
        if let range = html.range(of: #"class\s*=\s*["'][^"']*\b(url|resource)workaround\b[^"']*["'][^>]*>[\s\S]{0,400}?href\s*=\s*["']([^"']+)["']"#,
                                  options: [.regularExpression, .caseInsensitive]),
           let href = html[range].range(of: #"href\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
            let raw = html[href].replacingOccurrences(of: #"^href\s*=\s*["']|["']$"#, with: "", options: .regularExpression)
            if let url = URL(string: decodeEntities(raw), relativeTo: baseURL)?.absoluteURL {
                return (url.absoluteString, nil)
            }
        }
        let documents = anchors(inHTML: html, baseURL: baseURL).filter { isDocument($0.href) }
        let solution = documents.first { isSolution($0) }
        let statement = documents.first { !isSolution($0) }
        return (statement?.href, solution?.href)
    }

    /// Un PDF, ou un fichier déposé sur Moodle.
    static func isDocument(_ href: String) -> Bool {
        guard let url = URL(string: href) else { return false }
        return url.path.contains("/pluginfile.php/") || url.pathExtension.lowercased() == "pdf"
    }

    private static func isSolution(_ anchor: Anchor) -> Bool {
        let haystack = ContentDraftBuilder.fold(anchor.text + " " + (URL(string: anchor.href)?.lastPathComponent ?? ""))
        return haystack.range(of: #"(corrig|solution|\bsol\b|_sol\b|-sol\b|loesung|answers?\b|reponses)"#,
                              options: .regularExpression) != nil
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
