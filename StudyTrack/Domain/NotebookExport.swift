import Foundation

/// Les sources à donner à NotebookLM : la fiche, ses liens, ses schémas et ses questions, en
/// Markdown — le format que NotebookLM lit le mieux. NotebookLM n'a pas d'interface pour une
/// app tierce (l'API officielle est réservée à l'offre entreprise de Google Cloud) : on **prépare**
/// les sources, l'étudiant·e les dépose dans son carnet, puis rapporte le podcast ici.
enum NotebookExport {

    struct File: Equatable {
        var name: String
        var text: String
    }

    /// Les fichiers à déposer dans NotebookLM.
    static func files(courseName: String, code: String, sheet: RevisionSheet, map: StudyMap) -> [File] {
        [
            File(name: "01 Fiche · \(code).md", text: sheetText(courseName: courseName, sheet: sheet, map: map)),
            File(name: "02 Liens entre les notions · \(code).md", text: linksText(courseName: courseName, sheet: sheet, map: map)),
            File(name: "03 Schémas · \(code).md", text: schemasText(courseName: courseName, map: map, sheet: sheet)),
            File(name: "04 Questions pour se tester · \(code).md", text: questionsText(courseName: courseName, sheet: sheet, map: map)),
            File(name: "00 Lis-moi · \(code).md", text: readme(courseName: courseName)),
        ].filter { !$0.text.isEmpty }
    }

    private static func title(_ key: String, _ sheet: RevisionSheet) -> String {
        sheet.entry(forKey: key)?.entry.title ?? key
    }

    static func sheetText(courseName: String, sheet: RevisionSheet, map: StudyMap) -> String {
        var lines = ["# Fiche de révision — \(courseName)", ""]
        for chapter in sheet.chapters where !chapter.entries.isEmpty {
            lines.append("## \(chapter.title)")
            lines.append("")
            for item in sheet.keyed where item.chapterID == chapter.id {
                lines.append("### \(item.entry.title) (\(item.entry.kind.label))")
                if let gist = map.enrichment[item.key]?.gist { lines.append("En clair : \(gist)") }
                if let why = map.enrichment[item.key]?.why { lines.append("À quoi ça sert : \(why)") }
                lines.append("")
                lines.append(item.entry.body)
                if let example = map.enrichment[item.key]?.example { lines.append(""); lines.append("Exemple : \(example)") }
                let near = StudyLinks.neighbourhood(of: item.key, in: map, among: Set(sheet.keyed.map(\.key)))
                if !near.before.isEmpty { lines.append(""); lines.append("À comprendre avant : " + near.before.map { title($0.key, sheet) }.joined(separator: " ; ")) }
                if !near.after.isEmpty { lines.append("En découle : " + near.after.map { title($0.key, sheet) }.joined(separator: " ; ")) }
                if !near.aside.isEmpty { lines.append("À ne pas confondre avec : " + near.aside.map { title($0.key, sheet) }.joined(separator: " ; ")) }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func linksText(courseName: String, sheet: RevisionSheet, map: StudyMap) -> String {
        guard !map.links.isEmpty else { return "" }
        var lines = ["# Comment les notions de \(courseName) s'enchaînent", "",
                     "Chaque ligne dit une dépendance réelle du cours : ce qu'il faut comprendre pour comprendre autre chose.", ""]
        for link in map.links {
            var line = "- **\(title(link.from, sheet))** \(link.relation.label) **\(title(link.to, sheet))**"
            if let note = link.note { line += " — \(note)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func schemasText(courseName: String, map: StudyMap, sheet: RevisionSheet) -> String {
        guard !map.diagrams.isEmpty else { return "" }
        var lines = ["# Schémas de \(courseName)", ""]
        for schema in map.diagrams {
            lines.append("## \(schema.title) (\(schema.kind.label))")
            if let summary = schema.summary { lines.append(summary) }
            lines.append("")
            if schema.kind == .comparison, let columns = schema.columns, let rows = schema.rows {
                lines.append("| |" + columns.joined(separator: " | ") + " |")
                lines.append("|" + String(repeating: " --- |", count: columns.count + 1))
                for row in rows { lines.append("| " + row.joined(separator: " | ") + " |") }
            } else {
                let label = Dictionary(schema.nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
                for edge in schema.edges {
                    let name = edge.label.map { " (\($0))" } ?? ""
                    lines.append("- \(label[edge.from] ?? edge.from) →\(name) \(label[edge.to] ?? edge.to)")
                }
                for node in schema.nodes where !schema.edges.contains(where: { $0.from == node.id || $0.to == node.id }) {
                    lines.append("- \(node.label)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func questionsText(courseName: String, sheet: RevisionSheet, map: StudyMap) -> String {
        let items = sheet.keyed.compactMap { item in map.enrichment[item.key]?.check.map { (item, $0) } }
        guard !items.isEmpty else { return "" }
        var lines = ["# Pour se tester — \(courseName)", ""]
        for (item, check) in items {
            lines.append("**\(item.entry.title)** — \(check.question)")
            lines.append("Réponse : \(check.answer)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func readme(courseName: String) -> String {
        """
        # \(courseName) — sources pour NotebookLM

        Dépose ces fichiers dans un nouveau carnet NotebookLM (« Ajouter des sources »). Ajoute aussi, si tu les as, les PDF du cours et tes notes.

        Pour le podcast (Résumé audio → « Personnaliser ») :
        - « Concentre-toi sur les liens entre les notions et sur ce qu'il faut comprendre avant chaque résultat. »
        - « Explique d'abord l'intuition, puis l'énoncé ; signale les pièges. »

        Puis reviens dans StudyTrack : colle l'adresse du carnet, et glisse le podcast téléchargé pour l'écouter pendant que tu révises.
        """
    }
}
