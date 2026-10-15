import Foundation

/// Ce qu'on demande à Claude pour **comprendre** la fiche : une phrase en clair par notion, ses
/// liens avec les autres, des schémas, une question pour se tester. Le message dit tout de la
/// fiche (titres et début des énoncés) ; la réponse se lit ici, sans rien croire sur parole —
/// un lien vers une notion qui n'existe pas, un schéma sans nœuds, tout cela tombe.
enum StudyMapAI {

    static let instructions = """
    Tu aides un·e étudiant·e de l'EPFL à COMPRENDRE sa fiche de révision, pas seulement à la relire. Tu reçois toutes les notions de la fiche (chacune a un identifiant entre crochets, comme [e12]).
    Réponds UNIQUEMENT avec un objet JSON :
    {"entries":[{"id":"e12","gist":"…","why":"…","example":"…","question":"…","answer":"…"}],
     "links":[{"from":"e12","to":"e5","relation":"needs","note":"…"}],
     "schemas":[{"title":"…","kind":"flow","summary":"…","nodes":[{"id":"n1","label":"…","entry":"e12"}],"edges":[{"from":"n1","to":"n2","label":"…"}]}]}

    • entries — pour les notions importantes (pas toutes ; les plus utiles pour comprendre le cours) :
      – gist : l'idée en une phrase, dite avec des mots, SANS formule (« Le noyau, c'est tout ce que l'application écrase sur zéro. »).
      – why : à quoi ça sert, ou pourquoi on en a besoin (une phrase).
      – example : un exemple concret et court (formules en LaTeX entre $…$ permises).
      – question + answer : UNE question qui teste la compréhension (pas la récitation), et sa réponse courte.
    • links — les vraies dépendances, peu nombreuses (3 au plus par notion) :
      – needs : « from » a besoin de « to » pour être compris ; implies : « from » implique « to » ;
        uses : « from » se sert de « to » (preuve, méthode) ; contrast : à ne pas confondre ; example : « from » est un exemple de « to ».
      – note : pourquoi, en quelques mots. N'invente pas de lien qui n'est pas dans le cours.
    • schemas — 4 à 8 au total, chacun utile pour comprendre un chapitre :
      – kind : flow (les étapes d'une méthode), dependencies (qui découle de quoi), tree (arbre de décision : quelle méthode choisir, avec des étiquettes « oui »/« non » sur les flèches) ou comparison (au lieu de nodes/edges : "columns":["A","B"], "rows":[["Critère","valeur A","valeur B"]]).
      – 12 nœuds au plus, des libellés courts. « entry » : l'identifiant de la notion de la fiche, si le nœud en est une.
    Écris dans la langue de la fiche. N'invente rien qui ne soit pas dans la fiche.
    """

    /// La même consigne pour **un seul chapitre** : des schémas qui l'éclairent, des liens entre ses notions.
    static var chapterInstructions: String {
        instructions
            .replacingOccurrences(of: "4 à 8 au total, chacun utile pour comprendre un chapitre", with: "1 à 3 au total, tous pour CE chapitre (la fiche reçue n'est que ce chapitre)")
            .replacingOccurrences(of: "toutes les notions de la fiche", with: "toutes les notions d'UN chapitre de la fiche")
    }

    /// Le message : la fiche, notion par notion, avec les identifiants `e1`, `e2`… (rendus à part
    /// pour relire la réponse).
    /// Avec `chapter` : seulement ses notions (les identifiants restent ceux de la fiche entière).
    static func prompt(course: String, sheet: RevisionSheet, bodyLimit: Int = 220, entryLimit: Int = 400, chapter: String? = nil) -> (text: String, ids: [String: String]) {
        var lines = ["COURS : \(course)"]
        if let title = sheet.chapter(chapter)?.title { lines.append("CHAPITRE : \(title)") }
        lines.append("")
        var ids: [String: String] = [:]
        var current = ""
        for item in sheet.keyed(in: chapter).prefix(entryLimit) {
            if item.chapterID != current {
                current = item.chapterID
                lines.append("")
                lines.append("## \(item.chapterTitle)")
            }
            let id = "e\(item.index + 1)"
            ids[id] = item.key
            let body = item.entry.body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            lines.append("[\(id)] (\(item.entry.kind.rawValue)) \(item.entry.title) — \(String(body.prefix(bodyLimit)))")
        }
        return (lines.joined(separator: "\n"), ids)
    }

    // MARK: Lire la réponse

    private static func parseRelation(_ raw: String) -> StudyMap.Relation? {
        let value = RevisionText.fold(raw).trimmingCharacters(in: .whitespaces)
        if let exact = StudyMap.Relation(rawValue: value) { return exact }
        if value.hasPrefix("besoin") || value.hasPrefix("necessit") || value.hasPrefix("requi") || value.hasPrefix("prerequ") { return .needs }
        if value.hasPrefix("impl") { return .implies }
        if value.hasPrefix("util") || value.hasPrefix("sert") || value.hasPrefix("use") { return .uses }
        if value.hasPrefix("contr") || value.hasPrefix("confond") || value.hasPrefix("oppo") { return .contrast }
        if value.hasPrefix("exem") || value.hasPrefix("exam") { return .example }
        return nil
    }

    /// Les clés de la fiche retrouvées d'après l'identifiant de la réponse (« e12 »), la clé
    /// elle-même ou le titre.
    private static func resolver(sheet: RevisionSheet, ids: [String: String]) -> (Any?) -> String? {
        let keyed = sheet.keyed
        let keys = Set(keyed.map(\.key))
        let byTitle = Dictionary(keyed.map { (RevisionText.fold($0.entry.title), $0.key) }, uniquingKeysWith: { first, _ in first })
        return { raw in
            guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            if let key = ids[text] ?? ids[text.lowercased()] { return key }
            if keys.contains(text) { return text }
            return byTitle[RevisionText.fold(text)]
        }
    }

    private static func clean(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// La carte d'avant, complétée par la réponse de Claude : ses phrases en clair, ses liens (avec
    /// ceux qu'on déduit des citations, et **sans toucher à ceux posés à la main**), ses schémas.
    /// `nil` si la réponse n'est pas lisible.
    /// Avec `chapter` : ce qui est écrit ne touche que ce chapitre — les liens et les schémas des autres restent.
    static func apply(answer: String, sheet: RevisionSheet, ids: [String: String], to map: StudyMap, now: Date = Date(), chapter: String? = nil) -> StudyMap? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any] else { return nil }
        let resolve = resolver(sheet: sheet, ids: ids)
        var result = map

        for entry in object["entries"] as? [[String: Any]] ?? [] {
            guard let key = resolve(entry["id"]) else { continue }
            var item = StudyMap.Enrichment()
            item.gist = clean(entry["gist"])
            item.why = clean(entry["why"])
            item.example = clean(entry["example"])
            if let question = clean(entry["question"]), let answer = clean(entry["answer"]) {
                item.check = StudyMap.Check(question: question, answer: answer)
            }
            if item.gist != nil || item.why != nil || item.example != nil || item.check != nil { result.enrichment[key] = item }
        }

        var generated = StudyLinks.cited(in: sheet)
        if let chapter {
            // Les liens que Claude avait posés ailleurs restent ; ceux entre notions de ce chapitre sont refaits.
            let mine = Set(sheet.keyed(in: chapter).map(\.key))
            generated += map.links.filter { !$0.userMade && !(mine.contains($0.from) && mine.contains($0.to)) }
        }
        for link in object["links"] as? [[String: Any]] ?? [] {
            guard let from = resolve(link["from"]), let to = resolve(link["to"]),
                  let relation = parseRelation(link["relation"] as? String ?? "") else { continue }
            generated.append(StudyMap.Link(from: from, to: to, relation: relation, note: clean(link["note"])))
        }
        result.links = StudyLinks.merged(existing: map.links, generated: generated, keys: Set(sheet.keyed.map(\.key)))

        var diagrams: [Diagram] = []
        for (index, raw) in (object["schemas"] as? [[String: Any]] ?? []).enumerated() {
            guard let title = clean(raw["title"]) else { continue }
            let kind = Diagram.Kind(rawValue: RevisionText.fold(raw["kind"] as? String ?? "")) ?? .flow
            var schema = Diagram(id: "\(chapter.map { $0 + "/" } ?? "")s\(index)-\(String(RevisionText.fold(title).filter(\.isLetter).prefix(16)))", title: title,
                                summary: clean(raw["summary"]), kind: kind)
            schema.chapter = chapter
            if kind == .comparison {
                schema.columns = (raw["columns"] as? [Any])?.compactMap(clean)
                schema.rows = (raw["rows"] as? [[Any]])?.map { $0.map { clean($0) ?? "" } }
                guard let columns = schema.columns, !columns.isEmpty, let rows = schema.rows, !rows.isEmpty else { continue }
            } else {
                var seen = Set<String>()
                for node in raw["nodes"] as? [[String: Any]] ?? [] {
                    guard let id = clean(node["id"]), let label = clean(node["label"]), seen.insert(id).inserted else { continue }
                    schema.nodes.append(Diagram.Node(id: id, label: label, detail: clean(node["detail"]), entry: resolve(node["entry"])))
                }
                for edge in raw["edges"] as? [[String: Any]] ?? [] {
                    guard let from = clean(edge["from"]), let to = clean(edge["to"]), seen.contains(from), seen.contains(to), from != to else { continue }
                    schema.edges.append(Diagram.Edge(from: from, to: to, label: clean(edge["label"])))
                }
                guard schema.nodes.count >= 2 else { continue }
            }
            diagrams.append(schema)
        }
        if !diagrams.isEmpty {
            // Seuls les schémas de la même portée sont remplacés.
            result.diagrams = map.diagrams.filter { $0.chapter != chapter } + diagrams
        }
        if let chapter {
            var done = result.enrichedChapters ?? [:]
            done[chapter] = now
            result.enrichedChapters = done
        } else {
            result.enrichedAt = now
        }
        return result
    }

    /// Une nouvelle fiche : ce qui était à l'étudiant·e reste, ce qui ne désigne plus rien tombe.
    static func rebased(_ map: StudyMap, onto sheet: RevisionSheet) -> StudyMap {
        let keys = Set(sheet.keyed.map(\.key))
        var result = map
        result.progress = map.progress.filter { keys.contains($0.key) }
        result.notes = map.notes.filter { keys.contains($0.key) }
        result.enrichment = map.enrichment.filter { keys.contains($0.key) }
        result.links = map.links.filter { keys.contains($0.from) && keys.contains($0.to) }
        result.layout = map.layout.filter { keys.contains($0.key) || $0.key == MindGraph.rootID || $0.key.hasPrefix("chap:") || $0.key.hasPrefix("custom:") || $0.key.hasPrefix("◆") }
        result.customNodes = map.customNodes
        let chapterIDs = Set(sheet.chapters.map(\.id))
        result.chapterNotebooks = map.chapterNotebooks?.filter { chapterIDs.contains($0.key) }
        result.enrichedChapters = map.enrichedChapters?.filter { chapterIDs.contains($0.key) }
        result.resources = map.resources.map { resource in
            var copy = resource
            if let chapter = resource.chapter, !chapterIDs.contains(chapter) { copy.chapter = nil }
            return copy
        }
        result.diagrams = map.diagrams.map { schema in
            var copy = schema
            if let chapter = schema.chapter, !chapterIDs.contains(chapter) { copy.chapter = nil }
            copy.nodes = schema.nodes.map { node in
                var n = node
                if let entry = node.entry, !keys.contains(entry) { n.entry = nil }
                return n
            }
            return copy
        }
        return result
    }
}
