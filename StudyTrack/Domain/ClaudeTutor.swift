import Foundation

/// Claude dans le mode étude — **avec l'abonnement Claude**, pas une clé d'API.
///
/// Le Mac fait parler Claude Code (`claude -p`, connecté une fois avec le
/// compte Claude de l'étudiant·e) en mode « flux » : un processus par
/// conversation, des lignes JSON en entrée (les messages, avec le PDF de la
/// série ou une capture de GoodNotes) et en sortie (le texte qui s'écrit).
/// Claude Code tourne **dépouillé** : ni outils, ni serveurs MCP, ni réglages
/// ou compétences de l'utilisateur·rice (`arguments`) — sinon chaque question
/// emportait des centaines de milliers de jetons de configuration.
///
/// Ici, ce qui est pur : les arguments, le message à envoyer, la lecture du
/// flux, la consigne du tuteur. Testé dans `validate.sh`.
enum ClaudeTutor {

    // MARK: Lancer

    /// Les arguments de `claude` pour une conversation de tuteur.
    static func arguments(systemPrompt: String, model: String? = nil) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--tools", "",
            "--no-session-persistence",
            "--safe-mode",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--setting-sources", "",
            "--system-prompt", systemPrompt,
        ]
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
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

    enum Event: Equatable {
        /// Du texte de la réponse en cours.
        case text(String)
        /// Claude réfléchit (avant d'écrire).
        case thinking
        /// La réponse est finie ; `error` si elle a échoué.
        case finished(error: String?)
        /// Où en est la fenêtre de l'abonnement (0 → 1).
        case usage(Double)
    }

    /// Une ligne de la sortie de `claude` → ce qu'elle dit, ou `nil` (bruit).
    static func parse(line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return nil }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any] {
                if delta["type"] as? String == "text_delta", let text = delta["text"] as? String { return .text(text) }
                if delta["type"] as? String == "thinking_delta" { return .thinking }
            }
            if event["type"] as? String == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "thinking" {
                return .thinking
            }
            return nil
        case "result":
            let failed = (object["is_error"] as? Bool) == true || (object["subtype"] as? String).map { $0 != "success" } == true
            guard failed else { return .finished(error: nil) }
            let message = (object["result"] as? String) ?? (object["error"] as? String) ?? (object["subtype"] as? String) ?? "erreur"
            return .finished(error: message)
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
        Le contexte de l'exercice (énoncé, questions, PDF de la série) t'est donné : appuie-toi dessus, \
        et dis-le si une information te manque plutôt que de l'inventer.
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

    /// Le premier message d'une conversation : le contexte, avant la question.
    static func contextPreamble(_ context: Context) -> String {
        var lines: [String] = ["[Contexte de la session]"]
        if let code = context.courseCode { lines.append("Cours : \(code)\(context.courseName.map { " — \($0)" } ?? "")") }
        if let exercise = context.exercise { lines.append("Exercice : \(exercise)") }
        if let statement = context.statement, !statement.isEmpty { lines.append("Énoncé : \(statement)") }
        if !context.questions.isEmpty {
            lines.append("Questions (\(context.doneQuestions)/\(context.questions.count) faites) :")
            lines += context.questions.map { "- \($0)" }
        }
        if let hint = context.hint, !hint.isEmpty { lines.append("Indication de l'énoncé : \(hint)") }
        if let correction = context.correction { lines.append("Correction déjà notée : \(correction)") }
        return lines.count == 1 ? "" : lines.joined(separator: "\n") + "\n\n"
    }

    /// Les gestes rapides sous la conversation.
    enum QuickAction: String, CaseIterable, Identifiable {
        case hint, check, explain, nextStep, solution
        var id: String { rawValue }

        var label: String {
            switch self {
            case .hint: return "Un indice"
            case .check: return "Vérifie mon raisonnement"
            case .explain: return "Explique la notion"
            case .nextStep: return "Étape suivante"
            case .solution: return "Solution complète"
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
