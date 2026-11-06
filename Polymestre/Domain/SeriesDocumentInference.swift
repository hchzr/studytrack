import Foundation
import NaturalLanguage

/// Ce qu'un PDF de série dit de lui-même **en dehors** de ses exercices : son
/// numéro de série et le cours auquel il appartient.
///
/// Deux causes directes d'imports « au hasard » :
///   • la série n'était lue qu'en **début de ligne**. Un en-tête « Analyse I —
///     Série 4 », un « Exercise Set 4 » ou un fichier `serie04.pdf` laissaient tout
///     en série 1 — et l'IA, qui lisait 4, créait une seconde série à côté ;
///   • l'import lancé depuis l'accueil prenait **le premier cours** de la liste,
///     sans rien demander. Le PDF porte presque toujours le code du cours.
///
/// Fonctions pures : texte et nom de fichier en entrée, rien d'autre.
enum SeriesDocumentInference {

    enum Source: Equatable {
        /// Lu dans le document.
        case document
        /// Lu dans le nom du fichier.
        case filename
    }

    // MARK: Langue

    /// La langue du document, **nommée en français** pour la consigne du modèle
    /// (« anglais »), ou `nil` quand elle n'est pas sûre.
    ///
    /// La consigne est en français et donne des exemples français : sans langue
    /// explicite, un modèle traduisait les séries de PHYS-101(en) — « Banked
    /// turn » devenait « Virage relevé ». Lui dire la langue coupe court.
    static func languageName(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.french, .english, .german, .italian]
        recognizer.processString(String(text.prefix(4000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              confidence >= 0.6 else { return nil }
        switch language {
        case .french: return "français"
        case .english: return "anglais"
        case .german: return "allemand"
        case .italian: return "italien"
        default: return nil
        }
    }

    /// La ligne d'indice que le modèle lit en tête du texte.
    static func languageHint(_ language: String?) -> String? {
        language.map { "[Langue du document : \($0). Écris tout dans cette langue, ne traduis rien.]" }
    }

    // MARK: Numéro de série

    /// Les mots qui annoncent une **feuille** d'exercices, n'importe où dans une ligne.
    private static let documentPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[^\p{L}])(?:s[ée]ries?(?:[ \t]+d['’][ \t]*exercices)?|exercise[ \t]*(?:set|sheet)|problem[ \t]*(?:set|sheet)|feuille(?:[ \t]+d['’][ \t]*exercices)?|homework|assignment|übungsblatt|übungsserie|blatt)[ \t]*(?:n[°o]\.?[ \t]*|#[ \t]*)?0*(\d{1,2})(?![\d.,])"#,
        options: [])

    /// Même idée dans un nom de fichier : `serie03`, `Series_4_sol`, `ex3`, `hw2`.
    private static let filenamePattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[^a-z])(?:s[ée]ries?|serie|sheet|set|exercises?|exercices?|exos?|ex|hw|homework|td|tp|blatt|assignment|week|semaine|sol(?:ution)?s?|corr(?:ig[ée])?)[ _\-.]*0*(\d{1,2})(?!\d)"#,
        options: [])

    /// Le numéro de série annoncé par le document, ou par son nom de fichier.
    ///
    /// Le document fait foi : le nom d'un fichier se renomme, un en-tête non. On
    /// retient le numéro **le plus souvent cité** en tête de page — un rappel
    /// « voir série 2 » dans un énoncé ne l'emporte pas sur l'en-tête de chaque page.
    static func seriesNumber(lines: [PDFLayoutLine], filename: String?) -> (number: Int, source: Source)? {
        if let number = seriesNumberInDocument(lines) { return (number, .document) }
        if let filename, let number = seriesNumber(inFilename: filename) { return (number, .filename) }
        return nil
    }

    static func seriesNumberInDocument(_ lines: [PDFLayoutLine]) -> Int? {
        var votes: [Int: Int] = [:]
        var firstSeen: [Int: Int] = [:]
        // Les premières lignes de chaque page portent l'en-tête courant.
        var linesSeenOnPage: [Int: Int] = [:]
        for (index, line) in lines.enumerated() {
            let position = linesSeenOnPage[line.pageIndex, default: 0]
            linesSeenOnPage[line.pageIndex] = position + 1
            guard position < 8 || line.pageIndex == 0 && position < 25 else { continue }
            let text = line.trimmed
            guard !text.isEmpty else { continue }
            let ns = text as NSString
            for match in documentPattern.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                guard let number = Int(ns.substring(with: match.range(at: 1))), (1...60).contains(number) else { continue }
                // Un en-tête en tête de page compte davantage qu'une mention au fil du texte.
                votes[number, default: 0] += position < 4 ? 3 : 1
                if firstSeen[number] == nil { firstSeen[number] = index }
            }
        }
        return votes.max { lhs, rhs in
            lhs.value == rhs.value
                ? (firstSeen[lhs.key] ?? .max) > (firstSeen[rhs.key] ?? .max)
                : lhs.value < rhs.value
        }?.key
    }

    static func seriesNumber(inFilename filename: String) -> Int? {
        let base = (filename as NSString).deletingPathExtension
        let ns = base as NSString
        guard let match = filenamePattern.firstMatch(in: base, options: [], range: NSRange(location: 0, length: ns.length)),
              let number = Int(ns.substring(with: match.range(at: 1))),
              (1...60).contains(number) else { return nil }
        return number
    }

    // MARK: Cours

    struct CourseCandidate: Equatable {
        var id: UUID
        var code: String
        var name: String
    }

    /// Le cours que le document désigne, s'il en désigne **un seul**.
    ///
    /// Le code (« CS-250 », « cs250 », « CS 250 ») est cherché dans les premières
    /// pages et le nom du fichier ; à défaut, le nom complet du cours. Deux cours
    /// cités à égalité : on ne choisit pas, l'écran demande.
    static func course(in lines: [PDFLayoutLine], filename: String?,
                       candidates: [CourseCandidate]) -> UUID? {
        guard !candidates.isEmpty else { return nil }
        let head = lines.filter { $0.pageIndex <= 1 }.prefix(200).map(\.text).joined(separator: " ")
        let haystack = " " + normalize(head + " " + (filename ?? "")) + " "
        let compact = haystack.replacingOccurrences(of: " ", with: "")

        var scores: [UUID: Int] = [:]
        for candidate in candidates {
            let code = normalize(candidate.code)
            let codeCompact = code.replacingOccurrences(of: " ", with: "")
            // Un code d'au moins une lettre et un chiffre : « CS-250 », pas « ANALYSE ».
            if codeCompact.count >= 4,
               codeCompact.contains(where: \.isNumber), codeCompact.contains(where: \.isLetter),
               haystack.contains(" \(code) ") || compact.contains(codeCompact) {
                scores[candidate.id, default: 0] += 10
            }
            let name = normalize(candidate.name)
            if name.count >= 6, haystack.contains(" \(name) ") {
                scores[candidate.id, default: 0] += 5
            }
        }
        guard let best = scores.max(by: { $0.value < $1.value }) else { return nil }
        let ties = scores.values.filter { $0 == best.value }.count
        return ties == 1 ? best.key : nil
    }

    /// Un intitulé de série qui n'est que le nom ou le code du cours n'apprend
    /// rien (« Série 4 · Analyse I » dans le cours Analyse I) : on l'efface.
    static func seriesTitle(_ title: String, courseName: String, courseCode: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalize(trimmed)
        guard !key.isEmpty else { return "" }
        let redundant = [normalize(courseName), normalize(courseCode), "epfl"].filter { !$0.isEmpty }
        return redundant.contains(key) ? "" : trimmed
    }

    /// Minuscules, sans accents, ponctuation remplacée par des espaces.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_CH"))
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}
