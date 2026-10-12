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

    // MARK: Le fichier du projet

    /// `studytrack.json`, dans le dossier du projet : **la façon de travailler
    /// de l'étudiant·e**, pas celle de l'app. Ses compétences, ses serveurs MCP,
    /// ses outils permis, ses modèles et ses boutons (« brief », « post-mortem »…).
    /// Sans fichier, le projet n'a ni bouton ni serveur : chacun écrit le sien.
    struct File: Codable, Equatable {
        struct Server: Codable, Equatable {
            var type: String = "http"
            var url: String?
            var command: String?
            var args: [String]?

            init(type: String = "http", url: String? = nil, command: String? = nil, args: [String]? = nil) {
                self.type = type
                self.url = url
                self.command = command
                self.args = args
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                command = try c.decodeIfPresent(String.self, forKey: .command)
                args = try c.decodeIfPresent([String].self, forKey: .args)
                url = try c.decodeIfPresent(String.self, forKey: .url)
                type = try c.decodeIfPresent(String.self, forKey: .type) ?? (command == nil ? "http" : "stdio")
            }
        }

        struct Command: Codable, Equatable, Identifiable {
            enum Scope: String, Codable { case series, system }
            var id: String
            var label: String
            var icon: String = "sparkle"
            /// Ce qui est envoyé. `{code}`, `{cours}`, `{serie}`, `{titre}`,
            /// `{exercice}` sont remplacés par la session en cours.
            var prompt: String
            /// `series` : dans la conversation de la série ; `system` : dans la
            /// conversation « EPFL » (le système entier).
            var scope: Scope = .system
            /// `tutor` ou `system` (les modèles du fichier), ou un nom de modèle.
            var model: String?
            /// Proposer d'abord une capture de l'écran (« bloqué » + photo).
            var capture: Bool?
            /// Joindre un fichier choisi (« capture » + PDF).
            var attach: Bool?
            /// Les résultats peuvent proposer des verdicts à noter (post-mortem).
            var verdicts: Bool?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
                icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkle"
                prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? id
                scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .system
                model = try c.decodeIfPresent(String.self, forKey: .model)
                capture = try c.decodeIfPresent(Bool.self, forKey: .capture)
                attach = try c.decodeIfPresent(Bool.self, forKey: .attach)
                verdicts = try c.decodeIfPresent(Bool.self, forKey: .verdicts)
            }
        }

        struct Models: Codable, Equatable {
            /// Les indices, la conversation d'une série.
            var tutor: String?
            /// Le système : post-mortem, brief, plan, revue, synchronisation.
            var system: String?
        }

        /// Les compétences à relier depuis `~/.claude/skills/synced/…`.
        var skills: [String] = []
        /// La compétence lancée au premier message d'une série.
        var seriesSkill: String?
        var models: Models = Models()
        var mcpServers: [String: Server] = [:]
        /// En plus de la lecture et des compétences (`Read`, `Glob`, `Skill`).
        var allowedTools: [String] = []
        var commands: [Command] = []

        init(skills: [String] = [], seriesSkill: String? = nil, models: Models = Models(),
             mcpServers: [String: Server] = [:], allowedTools: [String] = [], commands: [Command] = []) {
            self.skills = skills
            self.seriesSkill = seriesSkill
            self.models = models
            self.mcpServers = mcpServers
            self.allowedTools = allowedTools
            self.commands = commands
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
            seriesSkill = try c.decodeIfPresent(String.self, forKey: .seriesSkill)
            models = try c.decodeIfPresent(Models.self, forKey: .models) ?? Models()
            mcpServers = try c.decodeIfPresent([String: Server].self, forKey: .mcpServers) ?? [:]
            allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
            commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
        }

        static func decode(_ data: Data) -> File? { try? JSONDecoder().decode(File.self, from: data) }

        func commands(_ scope: Command.Scope) -> [Command] { commands.filter { $0.scope == scope } }

        /// Le modèle d'un bouton : `tutor` / `system` renvoient aux modèles du fichier.
        func model(for command: Command?, scope: Command.Scope) -> String? {
            let name = command?.model ?? (scope == .series ? "tutor" : "system")
            switch name {
            case "tutor": return models.tutor
            case "system": return models.system
            default: return name
            }
        }
    }

    /// Le fichier qu'on crée depuis les Réglages : la forme, sans rien dedans.
    static let emptyFileTemplate = """
    {
      "skills": [],
      "seriesSkill": null,
      "models": { "tutor": null, "system": null },
      "mcpServers": {},
      "allowedTools": [],
      "commands": []
    }

    """

    /// Les outils toujours là en projet : lire et lancer une compétence.
    static let baseTools = ["Read", "Glob", "Skill"]

    /// Les outils que Claude Code charge (`--tools`) : la base, plus ceux que
    /// les règles du fichier nomment (`Write(./memoire/**)` → `Write`), hors MCP.
    static func tools(file: File) -> [String] {
        var result = baseTools
        for rule in file.allowedTools where !rule.hasPrefix("mcp__") {
            let name = String(rule.prefix { $0 != "(" })
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    /// Les règles `--allowedTools` : la base, les serveurs du fichier, ses règles.
    static func allowedTools(file: File, studyTrack: Bool) -> [String] {
        var result = baseTools + file.mcpServers.keys.sorted().map { "mcp__" + $0 } + (studyTrack ? ["mcp__studytrack"] : [])
        for rule in file.allowedTools where !result.contains(rule) { result.append(rule) }
        return result
    }

    /// Le fichier `--mcp-config` : les serveurs du fichier du projet, et celui
    /// de StudyTrack s'il est relié. Rien d'autre (`--strict-mcp-config`).
    static func mcpConfig(file: File, studyTrackURL: String?) -> String {
        var servers: [String: Any] = [:]
        for (name, server) in file.mcpServers {
            var entry: [String: Any] = ["type": server.type]
            if let url = server.url { entry["url"] = url }
            if let command = server.command { entry["command"] = command }
            if let args = server.args { entry["args"] = args }
            servers[name] = entry
        }
        if let address = studyTrackURL?.trimmingCharacters(in: .whitespacesAndNewlines), address.hasPrefix("https://") {
            servers["studytrack"] = ["type": "http", "url": address]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Ce que Claude a le droit de faire, en clair (affiché dans la conversation).
    static func permissionSummary(file: File, studyTrack: Bool) -> String {
        var parts = ["lecture", "compétences"]
        if file.allowedTools.contains(where: { $0.hasPrefix("Write") || $0.hasPrefix("Edit") }) { parts.append("écriture limitée") }
        parts += file.mcpServers.keys.sorted().map { ClaudeTutor.toolLabel("mcp__" + $0) }
        if studyTrack { parts.append("StudyTrack") }
        return parts.joined(separator: ", ")
    }

    /// Un bouton → le message, avec la session en cours.
    struct Placeholders: Equatable {
        var code = ""
        var course = ""
        var seriesNumber = ""
        var seriesTitle = ""
        var exercise = ""
    }

    static func expand(_ prompt: String, _ values: Placeholders) -> String {
        var text = prompt
        for (key, value) in [("{code}", values.code), ("{cours}", values.course), ("{serie}", values.seriesNumber),
                             ("{titre}", values.seriesTitle), ("{exercice}", values.exercise)] {
            text = text.replacingOccurrences(of: key, with: value)
        }
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Le nom court d'un cours pour une commande (« Analyse I classe inversée » → « analyse »).
    static func shortCourseName(_ name: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return first.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr"))
    }
}
