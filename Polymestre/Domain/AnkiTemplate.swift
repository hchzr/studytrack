import Foundation

/// Le rendu d'une carte Anki : son modèle (`qfmt`/`afmt`) rempli avec les
/// champs de la note — ce que montre Anki, en HTML.
///
/// Couvre ce qu'utilisent les types de notes courants : `{{Champ}}`,
/// `{{FrontSide}}`, les sections `{{#Champ}}…{{/Champ}}` et
/// `{{^Champ}}…{{/Champ}}`, les filtres `text:`, `hint:`, `cloze:`, `type:`,
/// et les trous `{{c1::réponse::indice}}`. Un filtre inconnu laisse le champ
/// tel quel.
enum AnkiTemplate {

    struct Context {
        var fields: [String: String]
        /// Numéro du modèle (0…) ; pour une note à trous, le trou est `ord + 1`.
        var ordinal: Int
        var isCloze: Bool
        var tags: String = ""
        var deck: String = ""
        var cardName: String = ""
    }

    static func question(_ template: String, _ context: Context) -> String {
        render(template, context, answer: false, frontSide: "")
    }

    static func answer(_ template: String, front: String, _ context: Context) -> String {
        render(template, context, answer: true, frontSide: front)
    }

    // MARK: Rendu

    private static func render(_ template: String, _ context: Context, answer: Bool, frontSide: String) -> String {
        let sectioned = sections(template, context)
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#) else { return sectioned }
        var output = ""
        var cursor = sectioned.startIndex
        for match in regex.matches(in: sectioned, range: NSRange(sectioned.startIndex..., in: sectioned)) {
            guard let range = Range(match.range, in: sectioned), let inner = Range(match.range(at: 1), in: sectioned) else { continue }
            output += sectioned[cursor..<range.lowerBound]
            output += replacement(for: String(sectioned[inner]).trimmingCharacters(in: .whitespaces),
                                  context, answer: answer, frontSide: frontSide)
            cursor = range.upperBound
        }
        output += sectioned[cursor...]
        return output
    }

    /// `{{#Champ}}…{{/Champ}}` gardé si le champ est rempli ; `{{^Champ}}` l'inverse.
    private static func sections(_ template: String, _ context: Context) -> String {
        var text = template
        let pattern = #"\{\{([#^])([^{}]+)\}\}(.*?)\{\{/\2\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        // Les sections imbriquées se résolvent de l'intérieur : on repasse
        // tant qu'il en reste.
        for _ in 0..<8 {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard !matches.isEmpty else { break }
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: text),
                      let kind = Range(match.range(at: 1), in: text),
                      let name = Range(match.range(at: 2), in: text),
                      let body = Range(match.range(at: 3), in: text) else { continue }
                let field = String(text[name]).trimmingCharacters(in: .whitespaces)
                let filled = isFilled(field, context)
                let keep = text[kind] == "#" ? filled : !filled
                text.replaceSubrange(whole, with: keep ? String(text[body]) : "")
            }
        }
        return text
    }

    private static func isFilled(_ name: String, _ context: Context) -> Bool {
        let field = name.split(separator: ":").last.map(String.init) ?? name
        if field.hasPrefix("c"), context.isCloze, let number = Int(field.dropFirst()) {
            return number == context.ordinal + 1
        }
        return !stripHTML(context.fields[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func replacement(for tag: String, _ context: Context, answer: Bool, frontSide: String) -> String {
        if tag == "FrontSide" { return frontSide }
        // Les commentaires et balises spéciales d'Anki (`{{!…}}`, `{{=…=}}`).
        if tag.hasPrefix("!") || tag.hasPrefix("=") { return "" }
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let name = parts.last ?? tag
        let filters = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var value: String
        switch name {
        case "Tags": value = context.tags.trimmingCharacters(in: .whitespaces)
        case "Deck": value = context.deck
        case "Subdeck": value = context.deck.components(separatedBy: "::").last ?? context.deck
        case "Card": value = context.cardName
        default: value = context.fields[name] ?? ""
        }
        // Les filtres s'appliquent de droite à gauche (« text:cloze:Texte »).
        for filter in filters.reversed() {
            switch filter {
            case "cloze": value = cloze(value, number: context.ordinal + 1, answer: answer)
            case "text": value = stripHTML(value)
            case "hint":
                value = value.isEmpty ? "" : "<details class=\"hint\"><summary>Indice</summary>\(value)</details>"
            case "type":
                // Saisie de la réponse : sur l'app, on la montre au verso.
                value = answer ? "<div class=\"typed\">\(value)</div>" : ""
            default: break
            }
        }
        return value
    }

    /// Les trous : le trou demandé masqué (recto) ou surligné (verso), les autres
    /// en clair.
    static func cloze(_ text: String, number: Int, answer: Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}"#,
                                                   options: [.dotMatchesLineSeparators]) else { return text }
        var output = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let numberRange = Range(match.range(at: 1), in: text),
                  let contentRange = Range(match.range(at: 2), in: text) else { continue }
            output += text[cursor..<whole.lowerBound]
            let content = String(text[contentRange])
            let hint = Range(match.range(at: 3), in: text).map { String(text[$0]) }
            if Int(text[numberRange]) == number {
                output += answer ? "<span class=\"cloze\">\(content)</span>"
                                 : "<span class=\"cloze\">[\(hint ?? "…")]</span>"
            } else {
                output += content
            }
            cursor = whole.upperBound
        }
        output += text[cursor...]
        return output
    }

    /// Le texte d'un champ HTML : balises retirées, entités courantes décodées.
    static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>|</div>|</p>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Le champ de tri et la somme de contrôle d'une note (`sfld`, `csum`) :
    /// les huit premiers chiffres hexadécimaux du SHA-1 du premier champ, sans HTML.
    static func checksum(sha1Hex: String) -> Int64 {
        Int64(sha1Hex.prefix(8), radix: 16) ?? 0
    }
}
