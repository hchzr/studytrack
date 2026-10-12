import CryptoKit
import Foundation

/// Claude dans le mode étude — **avec l'abonnement Claude**, pas une clé d'API.
///
/// Le Mac fait parler Claude Code (`claude -p`, connecté une fois avec le
/// compte Claude de l'étudiant·e) en mode « flux » : un processus par
/// conversation, des lignes JSON en entrée (les messages, avec le PDF de la
/// série ou une capture de GoodNotes) et en sortie (le texte qui s'écrit).
///
/// Une conversation **par série** : son identifiant de session est tiré de
/// celui de la série (`sessionID`), Claude Code la garde sur le disque, et on la
/// reprend (`--resume`) d'un lancement de l'app à l'autre.
///
/// Deux façons de lancer Claude Code (`Profile`) :
/// - **isolé** (par défaut) : ni outils, ni serveurs MCP, ni réglages ou
///   compétences de l'utilisateur·rice — sinon chaque question emportait des
///   centaines de milliers de jetons de configuration ;
/// - **projet EPFL** : dans un dossier à soi (`CLAUDE.md`, compétences
///   `epfl-serie`…), avec seulement les serveurs MCP qu'elles utilisent
///   (Notion, StudyTrack) et seulement les outils permis d'avance.
///
/// Ici, ce qui est pur : les arguments, le message à envoyer, la lecture du
/// flux, la consigne du tuteur. Testé dans `validate.sh`.
enum ClaudeTutor {

    // MARK: Lancer

    enum Profile: String, Equatable {
        case isolated, project
    }

    /// Tout ce qu'il faut pour lancer `claude` sur une conversation.
    struct Launch: Equatable {
        var profile: Profile = .isolated
        /// L'identifiant de la session Claude Code (un UUID).
        var sessionID: String
        /// La session existe déjà : on la reprend (`--resume`), sinon on la crée
        /// sous cet identifiant (`--session-id`).
        var resume = false
        var systemPrompt: String
        /// Projet : le fichier des serveurs MCP permis (`--mcp-config`).
        var mcpConfigPath: String?
        /// Projet : les outils utilisables sans demander (`--allowedTools`).
        var allowedTools: [String] = []
        /// Projet : les outils chargés (`--tools`).
        var tools: [String] = ClaudeProject.baseTools
        var model: String?
    }

    /// Les arguments de `claude` pour une conversation de tuteur.
    static func arguments(_ launch: Launch) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        args += launch.resume ? ["--resume", launch.sessionID] : ["--session-id", launch.sessionID]
        switch launch.profile {
        case .isolated:
            args += [
                "--tools", "",
                "--safe-mode",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--setting-sources", "",
                "--system-prompt", launch.systemPrompt,
            ]
        case .project:
            // Les réglages et compétences **du projet** (`.claude/skills` du
            // dossier : epfl-serie, epfl-memoire) ; ni plugins, ni crochets, ni
            // compétences de l'utilisateur·rice — mesuré : ~8 000 jetons de
            // contexte au lieu de ~15 000. Les serveurs MCP : seulement ceux du
            // fichier (`--strict-mcp-config`).
            args += ["--setting-sources", "project,local", "--strict-mcp-config"]
            if let path = launch.mcpConfigPath { args += ["--mcp-config", path] }
            // Ni terminal ni web : lire, lancer une compétence, et l'écriture
            // que le fichier du projet permet (ses fichiers de mémoire).
            args += ["--tools", launch.tools.joined(separator: ",")]
            if !launch.allowedTools.isEmpty { args += ["--allowedTools", launch.allowedTools.joined(separator: ",")] }
            // Ce qui n'est pas permis d'avance est refusé : en `-p`, personne
            // ne peut répondre à une demande d'autorisation.
            args += ["--permission-mode", "default"]
            args += ["--append-system-prompt", launch.systemPrompt]
        }
        if let model = launch.model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    /// L'identifiant de session d'une série : toujours le même pour une série,
    /// un profil et une « génération » (une nouvelle conversation l'incrémente).
    /// Un UUID de forme v5, tiré d'un SHA-256.
    static func sessionID(seriesID: UUID, profile: Profile, generation: Int = 0) -> UUID {
        let seed = "studytrack.claude.series:\(seriesID.uuidString):\(profile.rawValue):\(generation)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Que faire quand `claude` s'arrête d'emblée sur une session : la reprise
    /// d'une session perdue (fichier effacé) repart à neuf ; une création sur
    /// un identifiant déjà pris devient une reprise.
    enum SessionRecovery: Equatable { case startFresh, resume }

    static func sessionRecovery(stderr: String) -> SessionRecovery? {
        let text = stderr.lowercased()
        if text.contains("no conversation found") || text.contains("session not found") { return .startFresh }
        if text.contains("already in use") || text.contains("already exists") { return .resume }
        return nil
    }

    /// Le dossier où Claude Code range les sessions d'un dossier de travail :
    /// `~/.claude/projects/<chemin, tout ce qui n'est ni lettre ni chiffre
    /// remplacé par « - »>`.
    static func sessionFolderName(workingDirectory: String) -> String {
        String(workingDirectory.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Où chercher `claude` : une app ne voit pas le `PATH` du terminal.
    static func candidatePaths(home: String) -> [String] {
        [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude",
         "/usr/local/bin/claude", home + "/.npm-global/bin/claude", home + "/.bun/bin/claude"]
    }

    // MARK: Envoyer

    /// Une pièce jointe : le PDF d'une série, une capture, une photo de copie.
    struct Attachment: Equatable {
        enum Kind: Equatable { case pdf, image(mime: String) }
        var kind: Kind
        var data: Data
        var name: String
    }

    /// La ligne JSON d'un message de l'étudiant·e (`--input-format stream-json`).
    static func userLine(text: String, attachments: [Attachment] = []) -> String {
        var content: [[String: Any]] = attachments.map { attachment in
            switch attachment.kind {
            case .pdf:
                return ["type": "document", "title": attachment.name,
                        "source": ["type": "base64", "media_type": "application/pdf",
                                   "data": attachment.data.base64EncodedString()]]
            case .image(let mime):
                return ["type": "image",
                        "source": ["type": "base64", "media_type": mime, "data": attachment.data.base64EncodedString()]]
            }
        }
        content.append(["type": "text", "text": text])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Lire

    /// Ce que Claude Code annonce au début d'un processus.
    struct SessionInfo: Equatable {
        var sessionID: String
        var model: String
        var permissionMode: String
        /// Les serveurs MCP et leur état (`connected`, `needs-auth`, `failed`).
        var mcpServers: [MCPServer] = []
        var skills: [String] = []
        var tools: [String] = []

        struct MCPServer: Equatable {
            var name: String
            var status: String
        }

        /// La compétence est-elle chargée (« epfl-serie », ou « …:epfl-serie »
        /// quand elle vient d'un plugin) ?
        func hasSkill(_ name: String) -> Bool {
            skills.contains { $0 == name || $0.hasSuffix(":" + name) }
        }
    }

    enum Event: Equatable {
        /// Le processus a démarré : la session, le modèle, ce qui est chargé.
        case started(SessionInfo)
        /// Du texte de la réponse en cours.
        case text(String)
        /// Claude réfléchit (avant d'écrire).
        case thinking
        /// Claude utilise un outil (une compétence, Notion, StudyTrack).
        case tool(String)
        /// La réponse est finie ; `error` si elle a échoué. `contextTokens` :
        /// la taille du contexte envoyé (jetons d'entrée, cache compris).
        case finished(error: String?, contextTokens: Int? = nil)
        /// Où en est la fenêtre de l'abonnement (0 → 1).
        case usage(Double)
    }

    /// Une ligne de la sortie de `claude` → ce qu'elle dit, ou `nil` (bruit).
    static func parse(line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let session = object["session_id"] as? String else { return nil }
            let servers = (object["mcp_servers"] as? [[String: Any]] ?? []).compactMap { server -> SessionInfo.MCPServer? in
                guard let name = server["name"] as? String else { return nil }
                return .init(name: name, status: server["status"] as? String ?? "")
            }
            return .started(SessionInfo(sessionID: session, model: object["model"] as? String ?? "",
                                        permissionMode: object["permissionMode"] as? String ?? "",
                                        mcpServers: servers, skills: object["skills"] as? [String] ?? [],
                                        tools: object["tools"] as? [String] ?? []))
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return nil }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any] {
                if delta["type"] as? String == "text_delta", let text = delta["text"] as? String { return .text(text) }
                if delta["type"] as? String == "thinking_delta" { return .thinking }
            }
            if event["type"] as? String == "content_block_start", let block = event["content_block"] as? [String: Any] {
                if block["type"] as? String == "thinking" { return .thinking }
                if block["type"] as? String == "tool_use", let name = block["name"] as? String { return .tool(name) }
            }
            return nil
        case "result":
            var tokens: Int?
            if let usage = object["usage"] as? [String: Any] {
                let parts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0] as? Int }
                tokens = parts.isEmpty ? nil : parts.reduce(0, +)
            }
            let failed = (object["is_error"] as? Bool) == true || (object["subtype"] as? String).map { $0 != "success" } == true
            guard failed else { return .finished(error: nil, contextTokens: tokens) }
            let message = (object["result"] as? String) ?? (object["error"] as? String) ?? (object["subtype"] as? String) ?? "erreur"
            return .finished(error: message, contextTokens: tokens)
        case "rate_limit_event":
            guard let info = object["rate_limit_info"] as? [String: Any],
                  let windows = info["unifiedWindows"] as? [String: Any],
                  let five = windows["five_hour"] as? [String: Any],
                  let utilization = five["utilization"] as? Double else { return nil }
            return .usage(utilization)
        default:
            return nil
        }
    }

    /// Un outil, dit simplement (« mcp__notion__notion-search » → « Notion »).
    static func toolLabel(_ name: String) -> String {
        if name == "Skill" { return "compétence" }
        if name == "Read" { return "lecture" }
        if name.hasPrefix("mcp__") {
            let server = name.dropFirst(5).split(separator: "_").first.map(String.init) ?? name
            return server == "studytrack" ? "StudyTrack" : server.prefix(1).uppercased() + server.dropFirst()
        }
        return name
    }

    // MARK: Reprendre l'affichage

    /// Un message relu dans le fichier de la session (`<id>.jsonl`).
    struct HistoryMessage: Equatable {
        var fromStudent: Bool
        var text: String
    }

    /// Le fichier d'une session Claude Code → les messages à réafficher : le
    /// texte de l'étudiant·e (sans le contexte ajouté par l'app) et les
    /// réponses de Claude. Les appels d'outils, leurs résultats et le texte
    /// d'une compétence chargée ne s'affichent pas.
    static func history(jsonl: String) -> [HistoryMessage] {
        var result: [HistoryMessage] = []
        for line in jsonl.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  (object["isMeta"] as? Bool) != true, (object["isSidechain"] as? Bool) != true,
                  let message = object["message"] as? [String: Any] else { continue }
            var text = ""
            if let plain = message["content"] as? String {
                text = plain
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            if type == "user" {
                if text.contains("<command-name>") {
                    // Une compétence lancée : « <command-message>…<command-name>/epfl-serie
                    // </command-name><command-args>la question</command-args> ».
                    func between(_ open: String, _ close: String) -> String {
                        text.components(separatedBy: open).dropFirst().first?.components(separatedBy: close).first ?? ""
                    }
                    let name = between("<command-name>", "</command-name>")
                    let question = displayText(between("<command-args>", "</command-args>"))
                    text = question.isEmpty ? name : name + " " + question
                } else if text.hasPrefix("<") {
                    continue
                }
                text = displayText(text)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let fromStudent = type == "user"
            // Une réponse en plusieurs morceaux (texte, outil, texte) : un seul message.
            if let last = result.last, last.fromStudent == fromStudent, !fromStudent {
                result[result.count - 1].text += "\n\n" + text
            } else {
                result.append(HistoryMessage(fromStudent: fromStudent, text: text))
            }
        }
        return result
    }

    // MARK: La consigne

    /// Ce que Claude sait de la session : le cours, l'exercice, où on en est.
    struct Context: Equatable {
        var courseCode: String?
        var courseName: String?
        var exercise: String?
        var statement: String?
        var questions: [String] = []
        var doneQuestions: Int = 0
        var correction: String?
        var hint: String?
    }

    /// Le tuteur : socratique d'abord, la solution seulement si on la demande.
    static func systemPrompt(mode: Mode) -> String {
        let common = """
        Tu es le tuteur d'un·e étudiant·e de première année à l'EPFL, dans l'app StudyTrack, en mode étude. \
        Réponds en français, tutoie, sois bref et précis. Écris les mathématiques en LaTeX léger entre dollars \
        ($x_n = \\frac{1}{n}$, $\\sum_{k=1}^n k$) ; une formule importante seule sur sa ligne entre $$…$$. \
        Utilise le Markdown simple : paragraphes courts, listes, **gras** pour l'idée clé. \
        La conversation couvre toute une série d'exercices ; l'app ajoute le contexte entre [StudyTrack] et \
        [/StudyTrack] (la série, l'exercice en cours quand il change, les questions cochées). Appuie-toi dessus \
        et sur le PDF de la série, et dis-le si une information te manque plutôt que de l'inventer.
        """
        switch mode {
        case .tutor:
            return common + "\n\n" + """
            Mode tuteur. Ne donne pas la solution d'emblée. Procède par indices gradués : d'abord une question \
            qui oriente, puis un indice plus précis si l'étudiant·e bloque encore, puis l'étape suivante seulement. \
            Quand on te montre un raisonnement, dis exactement ce qui est juste et où est la première erreur, sans \
            la corriger à sa place. Donne la solution complète seulement si on te la demande explicitement.
            """
        case .explain:
            return common + "\n\n" + """
            Mode explication. Explique les notions demandées clairement, avec un exemple simple et l'intuition, \
            puis le lien avec l'exercice en cours. Donne des solutions complètes si on les demande.
            """
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case tutor, explain
        var id: String { rawValue }
        var label: String { self == .tutor ? "Tuteur" : "Explications" }
    }

    /// Le contexte ajouté par l'app est entre ces deux lignes : on le retire à
    /// l'affichage d'une conversation reprise.
    static let contextOpen = "[StudyTrack]"
    static let contextClose = "[/StudyTrack]"

    /// Le contexte d'un exercice, avant la question.
    static func contextPreamble(_ context: Context) -> String {
        var lines: [String] = []
        if let code = context.courseCode { lines.append("Cours : \(code)\(context.courseName.map { " — \($0)" } ?? "")") }
        if let exercise = context.exercise { lines.append("Exercice : \(exercise)") }
        if let statement = context.statement, !statement.isEmpty { lines.append("Énoncé : \(statement)") }
        if !context.questions.isEmpty {
            lines.append("Questions (\(context.doneQuestions)/\(context.questions.count) faites) :")
            lines += context.questions.map { "- \($0)" }
        }
        if let hint = context.hint, !hint.isEmpty { lines.append("Indication de l'énoncé : \(hint)") }
        if let correction = context.correction { lines.append("Correction déjà notée : \(correction)") }
        return lines.isEmpty ? "" : wrap(lines)
    }

    private static func wrap(_ lines: [String]) -> String {
        ([contextOpen] + lines + [contextClose]).joined(separator: "\n") + "\n\n"
    }

    /// Une série : ce que Claude sait au début de la conversation.
    struct SeriesContext: Equatable {
        struct Line: Equatable {
            var number: String
            var title: String = ""
            /// « à faire », « fait », « juste », « faux »…
            var status: String
        }
        var courseCode: String?
        var courseName: String?
        var title: String
        var week: Int?
        var due: String?
        var exercises: [Line] = []
        /// Le PDF de la série est joint au message.
        var pdfAttached = false
    }

    static func seriesPreamble(_ series: SeriesContext) -> String {
        var lines: [String] = []
        if let code = series.courseCode { lines.append("Cours : \(code)\(series.courseName.map { " — \($0)" } ?? "")") }
        lines.append("Série : \(series.title)\(series.week.map { " (semaine \($0))" } ?? "")")
        if let due = series.due { lines.append("À rendre : \(due)") }
        if series.pdfAttached { lines.append("L'énoncé complet est le PDF joint.") }
        if !series.exercises.isEmpty {
            lines.append("Exercices :")
            lines += series.exercises.map { "- \($0.number)\($0.title.isEmpty ? "" : " — \($0.title)") : \($0.status)" }
        }
        return wrap(lines)
    }

    /// Le premier message de la conversation d'une série. Avec la compétence
    /// `epfl-serie`, il la lance (« /epfl-serie … ») ; sinon, le contexte suffit.
    static func openingMessage(series: SeriesContext, exercise: Context?, skill: String?) -> String {
        let intro = "On attaque « \(series.title) »\(series.courseCode.map { " (\($0))" } ?? "")."
        let context = seriesPreamble(series) + (exercise.map(contextPreamble) ?? "")
        if let skill { return "/\(skill) \(intro)\n\n" + context }
        return context + intro
    }

    /// Quand on change d'exercice dans la même conversation.
    static func exerciseSwitch(_ context: Context) -> String {
        let preamble = contextPreamble(context)
        guard !preamble.isEmpty else { return "" }
        return preamble.replacingOccurrences(of: contextOpen + "\n", with: contextOpen + "\nOn passe à un autre exercice.\n")
    }

    /// Ce que l'étudiant·e a écrit, sans le contexte ajouté par l'app.
    static func displayText(_ sent: String) -> String {
        var text = sent
        while let open = text.range(of: contextOpen), let close = text.range(of: contextClose, range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Post-mortem et rapport

    /// Le bloc qui termine un post-mortem : un verdict par exercice, que l'app
    /// propose de noter (rien n'est écrit sans confirmation).
    static let verdictFence = "studytrack"

    static let verdictInstruction = """
    Termine par un bloc de code ```\(verdictFence) avec une ligne par exercice corrigé, au format \
    « numéro : juste », « numéro : moyen » ou « numéro : faux » (par exemple « 2 : faux »). \
    StudyTrack le propose à l'étudiant·e, qui confirme avant que rien ne soit noté.
    """

    /// « Post-mortem de la série » (quand la série est finie).
    static func postMortemPrompt(useSkill: Bool) -> String {
        (useSkill
            ? "Post-mortem de la série, comme le prévoit epfl-serie : compare ce que j'ai fait à la correction, exercice par exercice, et remplis le carnet d'erreurs. "
            : "Post-mortem de la série : reprends exercice par exercice ce que j'ai fait et où je me suis trompé, avec le type de chaque erreur (calcul, méthode, compréhension, étourderie, lacune de cours). ")
            + verdictInstruction
    }

    /// « Rapport » : les erreurs et ce qu'il faut revoir.
    static let reportPrompt = """
    Fais-moi le rapport de la série : mes erreurs, regroupées par type, les notions à revoir \
    (avec où les revoir dans le cours), et les exercices à refaire. Court, en listes.
    """

    struct Verdict: Equatable {
        var exercise: String
        var result: Correctness
    }

    /// Les verdicts du bloc ```studytrack d'une réponse.
    static func verdicts(in text: String) -> [Verdict] {
        guard let block = verdictBlock(in: text) else { return [] }
        return block.text.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            let word = parts[1].lowercased().folding(options: .diacriticInsensitive, locale: nil)
            let result: Correctness
            if word.hasPrefix("juste") || word.hasPrefix("correct") { result = .correct }
            else if word.hasPrefix("moy") || word.hasPrefix("partiel") { result = .partial }
            else if word.hasPrefix("faux") || word.hasPrefix("fausse") { result = .wrong }
            else { return nil }
            var number = parts[0]
            for prefix in ["exercice", "ex.", "ex"] where number.lowercased().hasPrefix(prefix) {
                number = String(number.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return Verdict(exercise: number, result: result)
        }
    }

    /// La réponse sans son bloc de verdicts (il s'affiche en carte à part).
    static func withoutVerdicts(_ text: String) -> String {
        guard let block = verdictBlock(in: text) else { return text }
        var copy = text
        copy.removeSubrange(block.range)
        return copy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func verdictBlock(in text: String) -> (range: Range<String.Index>, text: String)? {
        guard let open = text.range(of: "```" + verdictFence) else { return nil }
        let end = text.range(of: "```", range: open.upperBound..<text.endIndex)
        let inner = String(text[open.upperBound..<(end?.lowerBound ?? text.endIndex)])
        return (open.lowerBound..<(end?.upperBound ?? text.endIndex), inner)
    }

    /// L'exercice que désigne un verdict (« 2 », « 1.3 », « Ex 2 ») parmi les
    /// numéros de la série ; `nil` si aucun ou plusieurs.
    static func matchExercise(_ label: String, numbers: [String]) -> Int? {
        func key(_ text: String) -> String {
            text.lowercased().filter { $0.isNumber || $0 == "." || $0.isLetter }
                .replacingOccurrences(of: "exercice", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        let wanted = key(label)
        guard !wanted.isEmpty else { return nil }
        let exact = numbers.indices.filter { key(numbers[$0]) == wanted }
        if exact.count == 1 { return exact[0] }
        // « 3 » pour « Ex-03-03 » : le dernier nombre.
        let tail = numbers.indices.filter { index in
            let digits = numbers[index].split { !$0.isNumber }.last.map { String(Int($0) ?? -1) }
            return digits == String(Int(wanted) ?? -2)
        }
        return tail.count == 1 ? tail[0] : nil
    }

    /// Les gestes rapides sous la conversation.
    enum QuickAction: String, CaseIterable, Identifiable {
        case hint, check, explain, nextStep, solution
        var id: String { rawValue }

        var label: String {
            switch self {
            case .hint: return "Un indice"
            case .check: return "Vérifie-moi"
            case .explain: return "La notion"
            case .nextStep: return "Étape suivante"
            case .solution: return "La solution"
            }
        }

        var icon: String {
            switch self {
            case .hint: return "lightbulb"
            case .check: return "checkmark.circle"
            case .explain: return "book"
            case .nextStep: return "arrow.right.circle"
            case .solution: return "eye"
            }
        }

        var prompt: String {
            switch self {
            case .hint: return "Donne-moi un indice pour avancer, sans la solution."
            case .check: return "Voici où j'en suis. Vérifie mon raisonnement et dis-moi où est la première erreur, s'il y en a une."
            case .explain: return "Explique-moi la notion clé derrière cet exercice, avec un exemple simple."
            case .nextStep: return "Quelle est l'étape suivante ? Seulement celle-là."
            case .solution: return "Donne-moi la solution complète et rédigée, puis les points où on se trompe souvent."
            }
        }
    }
}

// MARK: - Mise en page des réponses

/// Une réponse de Claude, découpée en blocs à afficher nativement : titres,
/// paragraphes, listes, formules isolées, code. Pur, testé.
enum RichMarkup {
    enum Block: Equatable {
        case heading(String, level: Int)
        case paragraph(String)
        case bullet(String, depth: Int)
        case numbered(String, number: Int)
        case math(String)
        case code(String)
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var math: [String]?

        func flush() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraph = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line.hasPrefix("```") { result.append(.code(open.joined(separator: "\n"))); code = nil }
                else { open.append(rawLine); code = open }
                continue
            }
            if var open = math {
                if line.hasSuffix("$$") || line.hasSuffix("\\]") {
                    let last = line.replacingOccurrences(of: "$$", with: "").replacingOccurrences(of: "\\]", with: "")
                    if !last.isEmpty { open.append(last) }
                    result.append(.math(open.joined(separator: " ")))
                    math = nil
                } else { open.append(line); math = open }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.hasPrefix("$$") || line.hasPrefix("\\[") {
                flush()
                let inner = String(line.dropFirst(2))
                if inner.hasSuffix("$$") || inner.hasSuffix("\\]"), inner.count >= 2 {
                    result.append(.math(String(inner.dropLast(2)).trimmingCharacters(in: .whitespaces)))
                } else {
                    math = inner.isEmpty ? [] : [inner]
                }
                continue
            }
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" { flush(); result.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                if level <= 6, line.dropFirst(level).first == " " {
                    flush()
                    result.append(.heading(String(line.dropFirst(level + 1)), level: level))
                    continue
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                let indent = rawLine.prefix { $0 == " " }.count
                result.append(.bullet(String(line.dropFirst(2)), depth: indent >= 2 ? 1 : 0))
                continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), let number = Int(line[..<dot]),
               line[line.index(after: dot)...].first == " " {
                flush()
                result.append(.numbered(String(line[line.index(dot, offsetBy: 2)...]), number: number))
                continue
            }
            paragraph.append(line)
        }
        flush()
        if let open = code { result.append(.code(open.joined(separator: "\n"))) }
        if let open = math { result.append(.math(open.joined(separator: " "))) }
        return result
    }

    /// Un morceau de texte en ligne : normal, gras, italique, code, formule.
    enum Inline: Equatable {
        case text(String)
        case bold(String)
        case italic(String)
        case code(String)
        case math(String)
    }

    /// `Le **point** est $x_n$ et `code`` → morceaux.
    static func inlines(_ text: String) -> [Inline] {
        var result: [Inline] = []
        var buffer = ""
        let chars = Array(text)
        var i = 0
        func flush() {
            if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" }
        }
        func closing(_ marker: String, from start: Int) -> Int? {
            let m = Array(marker)
            var j = start
            while j + m.count <= chars.count {
                if Array(chars[j..<j + m.count]) == m { return j }
                j += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                buffer.append("$"); i += 2; continue
            }
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*", let end = closing("**", from: i + 2), end > i + 2 {
                flush(); result.append(.bold(String(chars[i + 2..<end]))); i = end + 2; continue
            }
            if c == "`", let end = closing("`", from: i + 1), end > i + 1 {
                flush(); result.append(.code(String(chars[i + 1..<end]))); i = end + 1; continue
            }
            if c == "$", let end = closing("$", from: i + 1), end > i + 1 {
                flush(); result.append(.math(String(chars[i + 1..<end]))); i = end + 1; continue
            }
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "(", let end = closing("\\)", from: i + 2) {
                flush(); result.append(.math(String(chars[i + 2..<end]))); i = end + 2; continue
            }
            if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] != " ",
               let end = closing(String(c), from: i + 1), end > i + 1, chars[end - 1] != " " {
                // `_` au milieu d'un mot (nom_de_variable) n'est pas de l'italique.
                if c == "_", i > 0, chars[i - 1].isLetter { buffer.append(c); i += 1; continue }
                flush(); result.append(.italic(String(chars[i + 1..<end]))); i = end + 1; continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return result
    }
}
