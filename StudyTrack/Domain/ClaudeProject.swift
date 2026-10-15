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
    /// Un exercice de la file de reprise, pour le `CLAUDE.md`.
    struct RedoLine: Equatable {
        var code: String
        var exercise: String
        var step: String
        var due: String?
        var why: String
    }

    static func context(courses: [CourseLine], week: Int?, date: String, redo: [RedoLine] = [],
                        features: SeriesReview.Features? = nil) -> String {
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
        if !redo.isEmpty {
            lines += ["", "File de reprise de StudyTrack (à refaire sur papier ; l'amorce reste dans l'app, à montrer seulement après une tentative) :"]
            lines += redo.map { line in
                "- \(line.code) \(line.exercise) · \(line.step)\(line.due.map { " · le \($0)" } ?? "") · \(line.why)"
            }
        }
        if let features {
            lines += ["", "Après une série (post-mortem) ou un indice, StudyTrack lit le bloc de fin de ta réponse :",
                      SeriesReview.instruction(features: features)]
            if features.hints { lines += [SeriesReview.hintInstruction] }
            lines += ["Si ta compétence tient aussi un carnet ailleurs (Notion…), fais-le comme d'habitude : le bloc est en plus."]
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

            init(id: String, label: String, icon: String = "sparkle", prompt: String, scope: Scope = .system,
                 model: String? = nil, capture: Bool? = nil, attach: Bool? = nil, verdicts: Bool? = nil) {
                self.id = id
                self.label = label
                self.icon = icon
                self.prompt = prompt
                self.scope = scope
                self.model = model
                self.capture = capture
                self.attach = attach
                self.verdicts = verdicts
            }

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
        /// La file de reprise de l'étudiant·e : paliers, plafonds (sinon ceux
        /// de StudyTrack : J+7, J+21, pré-examen ; 2 par série).
        var redo: RedoLadder.Config?

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
            redo = try? c.decodeIfPresent(RedoLadder.Config.self, forKey: .redo)
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

    /// Les boutons et les modèles réécrits dans `studytrack.json` (l'éditeur des
    /// Réglages) : le reste du fichier — compétences, serveurs, permis, et toute
    /// clé inconnue — est gardé tel quel. `nil` si le fichier n'est pas un objet JSON.
    static func updating(_ json: Data?, commands: [File.Command], models: File.Models) -> Data? {
        var object: [String: Any] = [:]
        if let json, !json.isEmpty {
            guard let existing = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
            object = existing
        }
        let encoder = JSONEncoder()
        guard let commandData = try? encoder.encode(commands),
              let commandList = try? JSONSerialization.jsonObject(with: commandData) else { return nil }
        object["commands"] = commandList
        var modelObject: [String: Any] = [:]
        modelObject["tutor"] = models.tutor.map { $0 as Any } ?? NSNull()
        modelObject["system"] = models.system.map { $0 as Any } ?? NSNull()
        object["models"] = modelObject
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Un identifiant de bouton tiré de son libellé (« Où j'en suis » → `ou-j-en-suis`),
    /// unique parmi `taken`.
    static func commandID(for label: String, taken: [String]) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr"))
        let base = folded.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        let root = base.isEmpty ? "bouton" : base
        var candidate = root
        var index = 2
        while taken.contains(candidate) { candidate = "\(root)-\(index)"; index += 1 }
        return candidate
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

    // MARK: Les connecteurs du compte

    /// `claude mcp list` → les connecteurs de claude.ai du compte connecté
    /// (« claude.ai Notion ») et les serveurs locaux de l'utilisateur·rice
    /// (« rea »). Les premiers servent tels quels ; les seconds sont écartés
    /// (`deniedMcpServers`) : un seul serveur d'outils de rétro-ingénierie
    /// portait le contexte de 15 000 à 215 000 jetons (mesuré).
    static func servers(mcpList output: String) -> (connectors: [String], local: [String]) {
        var connectors: [String] = []
        var local: [String] = []
        for line in output.components(separatedBy: .newlines) {
            guard let colon = line.range(of: ": "), line.contains(" - ") else { continue }
            let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("…") else { continue }
            if name.hasPrefix("claude.ai ") { connectors.append(name) } else { local.append(name) }
        }
        return (connectors, local)
    }

    /// Le préfixe des outils d'un serveur : « claude.ai Claude Docs » →
    /// `mcp__claude_ai_Claude_Docs` (observé : `mcp__claude_ai_Claude_Docs__guide`).
    /// Les jokers (`mcp__claude_ai_*`) ne sont pas acceptés par Claude Code (vérifié).
    static func toolPrefix(server: String) -> String {
        "mcp__" + String(server.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

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

    /// Les règles `--allowedTools` : la base, les connecteurs du compte, les
    /// serveurs du fichier, ses règles.
    static func allowedTools(file: File, studyTrack: Bool, connectors: [String] = []) -> [String] {
        var result = baseTools + connectors.map(toolPrefix(server:))
            + file.mcpServers.keys.sorted().map { "mcp__" + $0 } + (studyTrack ? ["mcp__studytrack"] : [])
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
    static func permissionSummary(file: File, studyTrack: Bool, connectors: [String] = []) -> String {
        var parts = ["lecture", "compétences"]
        if file.allowedTools.contains(where: { $0.hasPrefix("Write") || $0.hasPrefix("Edit") }) { parts.append("écriture limitée") }
        parts += connectors.map { String($0.dropFirst("claude.ai ".count)) }
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
