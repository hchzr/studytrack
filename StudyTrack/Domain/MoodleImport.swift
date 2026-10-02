import Foundation

/// Un cours tel que Moodle le décrit : son identifiant et ses noms.
///
/// EPFL ouvre un cours Moodle **par section d'étudiant·e·s** : « Analyse I »
/// existe en MATH-101(a), (d), (e), (f), (g)… C'est le nom court qui porte le
/// code, et c'est lui qui relie un cours de l'app à son cours Moodle.
struct MoodleCourseRef: Codable, Equatable, Identifiable, Hashable {
    var id: Int
    var fullname: String
    var shortname: String

    var url: URL { URL(string: "https://moodle.epfl.ch/course/view.php?id=\(id)")! }

    /// « MATH-101(e) » → « MATH-101 ».
    var baseCode: String { MoodleCourseMatcher.baseCode(shortname) }
    /// « (e) », la section Moodle, quand il y en a une.
    var variant: String? {
        guard let open = shortname.firstIndex(of: "("), let close = shortname.lastIndex(of: ")"), open < close else { return nil }
        return String(shortname[shortname.index(after: open)..<close])
    }
}

/// Relie les cours de l'app aux cours Moodle.
enum MoodleCourseMatcher {

    /// Le code EPFL d'un nom court ou d'un titre : « MATH-101(e) » → « MATH-101 ».
    static func baseCode(_ text: String) -> String {
        guard let range = text.range(of: #"[A-Z]{2,6}-\d{3}[A-Z]?"#, options: .regularExpression) else {
            return text.trimmingCharacters(in: .whitespaces).uppercased()
        }
        return String(text[range])
    }

    /// Le cours Moodle d'un cours de l'app, parmi des candidats.
    ///
    /// - Parameters:
    ///   - code: le code du cours dans l'app (« MATH-101 » ou « MATH-101(e) »).
    ///   - candidates: ce que la recherche Moodle a trouvé.
    ///   - enrolled: les cours où l'étudiant·e est inscrit·e, s'ils sont connus.
    ///     Ce sont eux qui départagent les sections : on est inscrit·e à
    ///     MATH-101(e), pas aux six autres.
    /// - Returns: `.unique` quand il n'y a pas à demander, `.ambiguous` avec les
    ///   sections à proposer, `.none` sinon.
    static func match(code: String, candidates: [MoodleCourseRef], enrolled: [MoodleCourseRef] = []) -> Match {
        let wanted = code.trimmingCharacters(in: .whitespaces).uppercased()
        let base = baseCode(wanted)
        // Le code exact (« MATH-101(e) ») l'emporte, s'il est écrit ainsi dans l'app.
        if let exact = (enrolled + candidates).first(where: { $0.shortname.uppercased() == wanted }) {
            return .unique(exact)
        }
        let enrolledHits = enrolled.filter { $0.baseCode == base }
        if enrolledHits.count == 1 { return .unique(enrolledHits[0]) }
        let hits = candidates.filter { $0.baseCode == base }
        if hits.count == 1 { return .unique(hits[0]) }
        if !enrolledHits.isEmpty { return .ambiguous(enrolledHits) }
        return hits.isEmpty ? .none : .ambiguous(hits.sorted { $0.shortname < $1.shortname })
    }

    enum Match: Equatable {
        case unique(MoodleCourseRef)
        case ambiguous([MoodleCourseRef])
        case none
    }

    /// L'identifiant Moodle retenu pour un cours, s'il a déjà été importé :
    /// `https://moodle.epfl.ch/course/view.php?id=14840` → 14840.
    static func linkedID(in sources: [String]) -> Int? {
        for source in sources {
            guard source.contains("moodle"), let components = URLComponents(string: source),
                  components.path.contains("/course/view.php"),
                  let id = components.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init) else { continue }
            return id
        }
        return nil
    }
}

/// Lit la réponse de `core_courseformat_get_state` — le plan d'un cours que
/// Moodle 4 envoie à sa propre page.
///
/// C'est l'appel que fait la page du cours elle-même, avec la session de
/// l'étudiant·e : pas de jeton de service web, que l'EPFL ne donne pas. Le JSON
/// est bien plus sûr que le HTML, dont les classes changent d'une version de
/// thème à l'autre.
enum MoodleStateParser {

    private struct State: Decodable {
        struct Section: Decodable {
            var id: String
            var number: Int?
            var title: String
            var cmlist: [String]
            var visible: Bool?
            var component: String?
            var itemid: String?

            enum CodingKeys: String, CodingKey { case id, number, title, cmlist, visible, component, itemid }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeFlexibleString(.id)
                number = try? container.decode(Int.self, forKey: .number)
                title = (try? container.decode(String.self, forKey: .title)) ?? ""
                cmlist = (try? container.decode([String].self, forKey: .cmlist))
                    ?? ((try? container.decode([Int].self, forKey: .cmlist))?.map(String.init) ?? [])
                visible = try? container.decode(Bool.self, forKey: .visible)
                component = try? container.decode(String.self, forKey: .component)
                itemid = try? container.decodeFlexibleString(.itemid)
            }
        }
        struct Module: Decodable {
            var id: String
            var name: String
            var module: String?
            var url: String?
            var uservisible: Bool?

            enum CodingKeys: String, CodingKey { case id, name, module, url, uservisible }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeFlexibleString(.id)
                name = (try? container.decode(String.self, forKey: .name)) ?? ""
                module = try? container.decode(String.self, forKey: .module)
                url = try? container.decode(String.self, forKey: .url)
                uservisible = try? container.decode(Bool.self, forKey: .uservisible)
            }
        }
        var section: [Section]
        var cm: [Module]
    }

    /// Le plan du cours, dans la forme commune aux trois sources.
    ///
    /// Les sous-sections (Moodle 4.5) sont des sections **déléguées** à une
    /// activité `subsection` : leurs activités sont rangées dans la section qui
    /// les contient, là où l'étudiant·e les voit.
    static func course(fromStateJSON json: String, title: String, url: String) -> ScrapedCourse? {
        guard let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        let modules = Dictionary(state.cm.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let delegated = Dictionary(state.section.compactMap { section -> (String, State.Section)? in
            guard section.component == "mod_subsection", let item = section.itemid else { return nil }
            return (item, section)
        }, uniquingKeysWith: { first, _ in first })

        func items(of section: State.Section, depth: Int) -> [ScrapedItem] {
            section.cmlist.flatMap { id -> [ScrapedItem] in
                guard let module = modules[id], module.uservisible != false else { return [] }
                if module.module == "subsection", let inner = delegated[id], depth < 2 {
                    return items(of: inner, depth: depth + 1)
                }
                return [ScrapedItem(title: module.name, url: module.url ?? "", type: module.module ?? "")]
            }
        }

        let sections = state.section
            .filter { $0.component != "mod_subsection" && $0.visible != false }
            .map { ScrapedSection(title: $0.title, items: items(of: $0, depth: 0)) }
        guard sections.contains(where: { !$0.items.isEmpty }) else { return nil }
        return ScrapedCourse(source: ContentSource.moodle.rawValue, title: title, url: url, sections: sections)
    }

    /// Le cours, activité par activité, pour `MoodleCourseAnalyzer` : les
    /// cibles des liens et les échéances des devoirs sont ajoutées ensuite,
    /// lues sur les pages des activités.
    static func snapshot(fromStateJSON json: String, title: String, url: String) -> MoodleCourseSnapshot? {
        guard let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        let modules = Dictionary(state.cm.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let delegated = Dictionary(state.section.compactMap { section -> (String, State.Section)? in
            guard section.component == "mod_subsection", let item = section.itemid else { return nil }
            return (item, section)
        }, uniquingKeysWith: { first, _ in first })

        func activities(of section: State.Section, depth: Int) -> [MoodleActivity] {
            section.cmlist.flatMap { id -> [MoodleActivity] in
                guard let module = modules[id] else { return [] }
                if module.module == "subsection", let inner = delegated[id], depth < 2 {
                    return activities(of: inner, depth: depth + 1)
                }
                let kind = module.module ?? ""
                return [MoodleActivity(id: module.id, name: BotafogoParser.decode(module.name), module: kind,
                                       url: module.url ?? "https://moodle.epfl.ch/mod/\(kind)/view.php?id=\(module.id)",
                                       isVisible: module.uservisible != false)]
            }
        }

        let sections = state.section
            .filter { $0.component != "mod_subsection" && $0.visible != false }
            .enumerated()
            .map { index, section in
                MoodleSection(number: section.number ?? index,
                              title: BotafogoParser.decode(section.title),
                              activities: activities(of: section, depth: 0))
            }
        return MoodleCourseSnapshot(title: title, url: url, sections: sections)
    }

    /// La réponse d'une recherche ou de la liste des inscriptions.
    static func courses(fromJSON json: String) -> [MoodleCourseRef] {
        struct Envelope: Decodable {
            struct Course: Decodable {
                var id: Int
                var fullname: String?
                var shortname: String?
                var displayname: String?
            }
            var courses: [Course]
        }
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return envelope.courses.map { course in
            MoodleCourseRef(id: course.id,
                            fullname: BotafogoParser.decode(course.fullname ?? course.displayname ?? ""),
                            shortname: BotafogoParser.decode(course.shortname ?? ""))
        }
    }
}

private extension KeyedDecodingContainer {
    /// Moodle écrit ses identifiants tantôt en nombre, tantôt en chaîne.
    func decodeFlexibleString(_ key: Key) throws -> String {
        if let text = try? decode(String.self, forKey: key) { return text }
        return String(try decode(Int.self, forKey: key))
    }
}

// MARK: - Accueil : les cours de l'étudiant·e, tels que Moodle les connaît

/// Les cours à créer à l'accueil, d'après les inscriptions Moodle du semestre.
///
/// L'accueil demandait la section, puis l'horaire ou chaque cours à la main,
/// puis de relier Moodle, puis d'importer : quatre écrans pour une information
/// que Moodle a déjà. Ici, une connexion suffit. Pur, donc testé : on écarte ce
/// qui n'est pas un cours (aide, bac à sable, espaces de section), on ne garde
/// qu'une fois un cours suivi dans deux sections Moodle, et on nettoie le nom.
enum MoodleOnboarding {

    struct PlannedCourse: Equatable {
        var code: String
        var name: String
        var ref: MoodleCourseRef
    }

    static func courses(from refs: [MoodleCourseRef]) -> [PlannedCourse] {
        var seen = Set<String>()
        return refs.compactMap { ref -> PlannedCourse? in
            guard let code = courseCode(ref) else { return nil }
            guard seen.insert(code).inserted else { return nil }
            return PlannedCourse(code: code, name: cleanName(ref.fullname, code: code), ref: ref)
        }
    }

    /// « MATH-101(pi) » → « MATH-101 » ; rien sans code de cours EPFL.
    static func courseCode(_ ref: MoodleCourseRef) -> String? {
        for text in [ref.shortname, ref.fullname] {
            if let range = text.range(of: #"\b[A-Z]{2,5}-\d{3}(?:\([a-z]+\))?"#, options: .regularExpression) {
                return MoodleCourseMatcher.baseCode(String(text[range]))
            }
        }
        return nil
    }

    /// « Analyse I (classe inversée) (MATH-101(pi)) » → « Analyse I (classe inversée) ».
    static func cleanName(_ fullname: String, code: String) -> String {
        var name = fullname
        if let range = name.range(of: #"\s*[\(\[]?\s*\#(NSRegularExpression.escapedPattern(for: code))(\([a-z]+\))?\s*[\)\]]?\s*$"#,
                                  options: .regularExpression) {
            name.removeSubrange(range)
        }
        name = name.replacingOccurrences(of: code, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–·|:").union(.whitespaces))
        return name.isEmpty ? code : name
    }
}
