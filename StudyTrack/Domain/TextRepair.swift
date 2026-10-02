import Foundation

/// Répare les accents d'un texte venu d'ailleurs, **avant** qu'il ne soit rangé.
///
/// Trois sources les abîmaient, chacune à sa façon :
///   • un PDF compilé par LaTeX (police Type 1) dessine « é » comme un « e »
///     plus un accent posé dessus : PDFKit rend « e´ » ou « ´e », parfois avec
///     une espace — « s´erie », « ´equation » ;
///   • une page Moodle encode certains caractères en entités (`&eacute;`,
///     `&#233;`, `&#039;`) que le décodage d'origine ne connaissait pas toutes ;
///   • un texte UTF-8 relu comme Latin-1 en route (« SÃ©rie », « Ã  rendre »).
///
/// Pur et testé (`validate.sh`). Idempotent : un texte propre ressort intact.
enum TextRepair {

    /// Tout, dans l'ordre : entités, double encodage, accents détachés, forme
    /// composée (NFC — « é » en un seul caractère, comme le clavier le tape).
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = decodeEntities(text)
        result = fixMojibake(result)
        result = composeAccents(result)
        return result.precomposedStringWithCanonicalMapping
    }

    // MARK: Entités HTML

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "laquo": "«", "raquo": "»",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "deg": "°", "euro": "€",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "Eacute": "É", "Egrave": "È", "Ecirc": "Ê",
        "agrave": "à", "acirc": "â", "auml": "ä", "Agrave": "À", "Acirc": "Â",
        "icirc": "î", "iuml": "ï", "ocirc": "ô", "ouml": "ö", "Ocirc": "Ô",
        "ugrave": "ù", "ucirc": "û", "uuml": "ü", "Uuml": "Ü", "ccedil": "ç", "Ccedil": "Ç",
        "oelig": "œ", "OElig": "Œ", "aelig": "æ", "szlig": "ß", "ntilde": "ñ", "times": "×"
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let pattern = try? NSRegularExpression(pattern: #"&(#[xX]?[0-9A-Fa-f]{1,6}|[A-Za-z]{2,8});"#)
        let ns = text as NSString
        let matches = pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            if body.hasPrefix("#") {
                let hex = body.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = body.dropFirst(hex ? 2 : 1)
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += ns.substring(with: match.range)
                }
            } else if let value = named[body] {
                result += value
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }

    // MARK: Double encodage

    /// « SÃ©rie » → « Série ». Ne touche qu'un texte qui en porte la marque
    /// (« Ã » ou « Â » suivi d'un caractère de continuation), et seulement si
    /// la relecture en UTF-8 réussit : « Ãle » (rare, mais français) reste.
    static func fixMojibake(_ text: String) -> String {
        guard text.range(of: #"[ÃÂ][\u0080-¿‘-„†-…ŒœŠšŸŽžˆ˜‰‹›€™]"#,
                         options: .regularExpression) != nil else { return text }
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1] {
            if let bytes = text.data(using: encoding), let fixed = String(data: bytes, encoding: .utf8) {
                return fixed
            }
        }
        return text
    }

    // MARK: Accents détachés (PDF LaTeX)

    /// Accent d'espacement → accent combinant : le même signe, posé sur la lettre.
    private static let combining: [Character: Character] = [
        // Pas de `^` : dans un énoncé, `x^y` et `ℝ^n` sont des exposants. Un
        // PDF LaTeX rend le circonflexe en « ˆ » (U+02C6), lui sans ambiguïté.
        "´": "\u{0301}", "`": "\u{0300}", "ˆ": "\u{0302}",
        "¨": "\u{0308}", "˜": "\u{0303}", "¸": "\u{0327}", "ˇ": "\u{030C}"
    ]
    /// Les lettres qui portent ces accents en français (et en allemand).
    private static let carriers = Set("aeiouyAEIOUYcCnN")

    /// « s´erie » → « série », « ´equation » → « équation », « e´te´ » → « été ».
    ///
    /// LaTeX dessine l'accent **avant** la lettre dans le flux du PDF ; certains
    /// extracteurs le rendent après. On l'attache à la lettre qui suit, sinon à
    /// celle qui précède. `` ` `` n'est touché qu'entre deux lettres : ailleurs,
    /// c'est un guillemet de code.
    static func composeAccents(_ text: String) -> String {
        guard text.contains(where: { combining[$0] != nil }) else { return text }
        let chars = Array(text)
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            guard let mark = combining[char] else {
                out.append(char)
                index += 1
                continue
            }
            let isAmbiguous = char == "`"
            // La cédille ne va que sous un « c » : celui d'avant (« garc¸on »),
            // sinon celui d'après (« ¸c »).
            if char == "¸" {
                if let last = out.last, "cC".contains(last) {
                    out.removeLast()
                    out.append(contentsOf: String([last, mark]).precomposedStringWithCanonicalMapping)
                } else if index + 1 < chars.count, "cC".contains(chars[index + 1]) {
                    out.append(contentsOf: String([chars[index + 1], mark]).precomposedStringWithCanonicalMapping)
                    index += 1
                } else {
                    out.append(char)
                }
                index += 1
                continue
            }
            // « l´analyse », « qu´il » : l'accent aigu tapé pour une apostrophe.
            // Jamais devant un « e » : en français l'aigu n'existe que sur lui,
            // et « s´erie », « d´efinition » sont des « é » de PDF LaTeX.
            if char == "´", index + 1 < chars.count, chars[index + 1].isLetter,
               !"eE".contains(chars[index + 1]), isElision(out) {
                out.append("’")
                index += 1
                continue
            }
            // Une espace parasite entre l'accent et sa lettre : « ´ e ».
            var next = index + 1
            if next < chars.count, chars[next] == " ", !isAmbiguous { next += 1 }
            let previousIsLetter = out.last.map(\.isLetter) ?? false
            if next < chars.count, carriers.contains(chars[next]),
               !isAmbiguous || previousIsLetter {
                out.append(contentsOf: String([chars[next], mark]).precomposedStringWithCanonicalMapping)
                index = next + 1
                continue
            }
            if !isAmbiguous, let last = out.last, carriers.contains(last) {
                // « e´ » en fin de mot : l'accent va sur la lettre d'avant.
                out.removeLast()
                out.append(contentsOf: String([last, mark]).precomposedStringWithCanonicalMapping)
                index += 1
                continue
            }
            out.append(char)
            index += 1
        }
        return String(out)
    }

    /// Le texte se termine-t-il par un mot élidé (« l », « d », « qu », « jusqu ») ?
    private static func isElision(_ out: [Character]) -> Bool {
        var word: [Character] = []
        for char in out.reversed() {
            guard char.isLetter else { break }
            word.insert(char, at: 0)
        }
        let lower = String(word).lowercased()
        return ["l", "d", "j", "n", "s", "c", "m", "t", "qu", "jusqu", "lorsqu", "puisqu", "quoiqu"].contains(lower)
    }
}
