import Foundation

/// Lit une page de série publiée en HTML par un site de cours.
///
/// CS-107 (Introduction à la programmation) publie chaque série sur
/// `proginsc.epfl.ch` : une page par série, avec pour chaque exercice son
/// numéro (« 3.4 »), son titre, son niveau (« Niv. 2 »), un résumé d'une ligne,
/// l'énoncé et le corrigé. Tout y est structuré : pas besoin de PDF ni d'IA.
enum SeriesPageParser {

    struct Page: Equatable {
        var exercises: [ContentExerciseDraft]
        /// « Tous les exercices sur une page » : énoncé et corrigé complets.
        var statementURL: String
        var solutionURL: String
    }

    /// Reconnaît une page de série de proginsc (ou de même gabarit).
    static func parseProginsc(html: String, baseURL: URL) -> Page? {
        guard let marker = try? NSRegularExpression(pattern: #"<font size="\+1">\s*(\d+\.\d+)\s*</font>"#) else { return nil }
        let matches = marker.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var exercises: [ContentExerciseDraft] = []
        // Un exercice va de son numéro jusqu'au numéro suivant.
        for (position, match) in matches.enumerated() {
            guard let numberRange = Range(match.range(at: 1), in: html),
                  let start = Range(match.range, in: html)?.lowerBound else { continue }
            let end = position + 1 < matches.count ? (Range(matches[position + 1].range, in: html)?.lowerBound ?? html.endIndex) : html.endIndex
            let block = String(html[start..<end])
            let number = String(html[numberRange])
            let task = capture(block, #"<a href="([^"]*task\.html)">"#)
            let title = capture(block, #"<a href="[^"]*task\.html">([^<]+)</a>"#).map(clean) ?? ""
            let level = capture(block, #"Niv\.\s*(\d)"#)
            let summary = capture(block, #"<div align="justify">(.*?)</div>"#).map(clean) ?? ""
            var exercise = ContentExerciseDraft(number: number)
            exercise.title = title
            exercise.statement = [summary.isEmpty ? nil : summary, level.map { "Niveau \($0)" }].compactMap { $0 }.joined(separator: " · ")
            exercise.url = task.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteString } ?? ""
            if !exercises.contains(where: { $0.number == number }) { exercises.append(exercise) }
        }
        guard !exercises.isEmpty else { return nil }
        let statement = capture(html, #"href="([^"]*serie_print\.html)""#).flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteString } ?? baseURL.absoluteString
        let solution = capture(html, #"href="([^"]*solution_print\.html)""#).flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteString } ?? ""
        return Page(exercises: exercises, statementURL: statement, solutionURL: solution)
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Balises retirées, entités décodées, espaces normalisés.
    static func clean(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&eacute;": "é", "&egrave;": "è", "&ecirc;": "ê", "&agrave;": "à", "&acirc;": "â",
                        "&ocirc;": "ô", "&icirc;": "î", "&ucirc;": "û", "&ugrave;": "ù", "&ccedil;": "ç",
                        "&Eacute;": "É", "&euml;": "ë", "&iuml;": "ï", "&nbsp;": " ", "&laquo;": "«", "&raquo;": "»",
                        "&rsquo;": "'", "&lsquo;": "'", "&hellip;": "…", "&oelig;": "œ"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = BotafogoParser.decode(text)
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
