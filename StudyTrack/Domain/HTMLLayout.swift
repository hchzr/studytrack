import Foundation

/// Une page web d'exercices, vue comme une mise en page.
///
/// Les énoncés en PDF sont lus d'après leur mise en page (titres plus grands,
/// « **Exercice 1.** » en gras, questions en retrait). Une page web porte les
/// mêmes signaux, autrement : titres `<h2>`, `<strong>`, listes imbriquées.
/// Les traduire en lignes de mise en page permet de lire **n'importe quelle**
/// page de série — site d'un cours, page Moodle, GitHub — avec la même chaîne
/// que les PDF (règles, puis modèle), sans lecteur écrit pour un site.
enum HTMLLayout {

    static func lines(fromHTML html: String) -> [PDFLayoutLine] {
        var source = html.replacingOccurrences(of: #"(?is)<(script|style|nav|header|footer|noscript)[^>]*>.*?</\1>"#,
                                               with: " ", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: " ", options: .regularExpression)
        // Les éléments qui ouvrent ou ferment un bloc de texte.
        guard let tag = try? NSRegularExpression(pattern: #"<(/?)(h[1-6]|p|li|div|tr|pre|blockquote|ul|ol|dt|dd|section|article|br|td|th)\b[^>]*>"#,
                                                 options: .caseInsensitive) else { return [] }
        var result: [PDFLayoutLine] = []
        var depth = 0
        var heading: Int?
        var cursor = source.startIndex
        let full = NSRange(source.startIndex..., in: source)

        func flush(_ raw: Substring) {
            let startsBold = raw.range(of: #"^\s*<(b|strong)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            let text = MoodleLinks.decodeEntities(raw.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { return }
            let size: Double = heading.map { [1: 22, 2: 18, 3: 15, 4: 13, 5: 12, 6: 12][$0] ?? 12 } ?? 11
            result.append(PDFLayoutLine(text: text, fontSize: size, isBold: heading != nil, pageIndex: 0,
                                        indent: 40 + Double(depth) * 18, startsBold: startsBold))
        }

        for match in tag.matches(in: source, range: full) {
            guard let range = Range(match.range, in: source),
                  let nameRange = Range(match.range(at: 2), in: source),
                  let slashRange = Range(match.range(at: 1), in: source) else { continue }
            flush(source[cursor..<range.lowerBound])
            cursor = range.upperBound
            let name = source[nameRange].lowercased()
            let closing = !source[slashRange].isEmpty
            if name == "ul" || name == "ol" || name == "blockquote" || name == "dd" {
                depth = max(0, depth + (closing ? -1 : 1))
            }
            if name.hasPrefix("h"), let level = Int(name.dropFirst()) {
                heading = closing ? nil : level
            }
        }
        flush(source[cursor...])
        return result
    }
}
