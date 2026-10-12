import Foundation

/// Le « projet EPFL » de Claude Code : un dossier à soi (`~/EPFL` par défaut)
/// où Claude tourne avec les compétences de l'étudiant·e (`epfl-serie`,
/// `epfl-memoire`…), un `CLAUDE.md` qui dit où on en est, et seulement les
/// serveurs MCP dont ces compétences ont besoin.
///
/// Claude Code n'ouvre pas les « Projets » de claude.ai : ce dossier les
/// remplace. Ici, ce qui est pur (le texte du `CLAUDE.md`, le fichier MCP,
/// les outils permis) ; testé dans `validate.sh`.
enum ClaudeProject {

    // MARK: CLAUDE.md

    /// La partie écrite par StudyTrack est entre ces deux lignes : le reste du
    /// fichier appartient à l'étudiant·e et n'est jamais touché.
    static let beginMarker = "<!-- studytrack:début -->"
    static let endMarker = "<!-- studytrack:fin -->"

    struct CourseLine: Equatable {
        var code: String
        var name: String
        var week: Int?
        /// « Série 3 : 2/5 faits ».
        var progress: String?
    }

    /// Le contexte que StudyTrack tient à jour dans le `CLAUDE.md`.
    static func context(courses: [CourseLine], week: Int?, date: String) -> String {
        var lines = [
            "## StudyTrack (mis à jour par l'app, le \(date))",
            "",
            "Étudiant en première année à l'EPFL. StudyTrack range chaque cours en semaines : la théorie " +
            "(vidéos, chapitres), les séries d'exercices (questions cochées, correction juste / moyen / faux), " +
            "le temps d'étude. Dans le mode étude, une conversation suit une série ; le contexte envoyé par " +
            "l'app est entre [StudyTrack] et [/StudyTrack].",
        ]
        if let week { lines += ["", "Semaine du semestre : \(week)."] }
        if !courses.isEmpty {
            lines += ["", "Cours suivis :"]
            lines += courses.map { course in
                var line = "- \(course.code) — \(course.name)"
                if let week = course.week { line += " (semaine \(week))" }
                if let progress = course.progress { line += " · \(progress)" }
                return line
            }
        }
        lines += ["", "Ne modifie rien dans StudyTrack toi-même : propose, l'étudiant confirme dans l'app."]
        return lines.joined(separator: "\n")
    }

    /// Le `CLAUDE.md` avec la partie de StudyTrack à jour : remplacée si elle
    /// existe, ajoutée à la fin sinon.
    static func claudeMD(existing: String?, context: String) -> String {
        let block = beginMarker + "\n" + context + "\n" + endMarker
        guard let existing, !existing.isEmpty else { return block + "\n" }
        if let begin = existing.range(of: beginMarker),
           let end = existing.range(of: endMarker, range: begin.upperBound..<existing.endIndex) {
            var copy = existing
            copy.replaceSubrange(begin.lowerBound..<end.upperBound, with: block)
            return copy
        }
        return existing + (existing.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
    }

    // MARK: Serveurs MCP

    /// Le serveur MCP officiel de Notion (le carnet d'erreurs, la file de reprise).
    static let notionURL = "https://mcp.notion.com/mcp"

    /// Le fichier `--mcp-config` : Notion et le serveur de StudyTrack, s'ils sont
    /// choisis. Rien d'autre (`--strict-mcp-config`).
    static func mcpConfig(notion: Bool, studyTrackURL: String?) -> String {
        var servers: [String: Any] = [:]
        if notion { servers["notion"] = ["type": "http", "url": notionURL] }
        if let address = studyTrackURL?.trimmingCharacters(in: .whitespacesAndNewlines), address.hasPrefix("https://") {
            servers["studytrack"] = ["type": "http", "url": address]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Les outils permis sans demander : lire, lancer une compétence, et les
    /// outils des serveurs choisis. Le reste est refusé.
    static func allowedTools(notion: Bool, studyTrack: Bool) -> [String] {
        ClaudeTutor.projectTools + (notion ? ["mcp__notion"] : []) + (studyTrack ? ["mcp__studytrack"] : [])
    }

    /// Ce que Claude a le droit de faire, en clair (affiché dans la conversation).
    static func permissionSummary(notion: Bool, studyTrack: Bool) -> String {
        (["lecture", "compétences"] + (notion ? ["Notion"] : []) + (studyTrack ? ["StudyTrack"] : []))
            .joined(separator: ", ")
    }

    // MARK: Compétences

    /// Les compétences de claude.ai qu'utilise le mode étude.
    static let skills = ["epfl-serie", "epfl-memoire"]

    /// La compétence qui conduit une série.
    static let seriesSkill = "epfl-serie"
}
