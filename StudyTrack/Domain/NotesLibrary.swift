import Foundation

/// Les notes de l'étudiant·e, là où son app les sauvegarde : GoodNotes
/// (sauvegarde automatique en PDF vers Google Drive, iCloud Drive, Dropbox),
/// Notability… Observé sur le Mac d'Hugo : `Google Drive/GoodNotes/EPFL BA1/
/// <cahier>/Semaine N/<document>.pdf`, des cahiers nommés « MATH-111 Algèbre
/// linéaire » ou seulement « Mécanique », « AICC ».
///
/// Ici, ce qui est pur : à quel cours va un cahier, de quelle semaine est un
/// document, et s'il s'agit d'une série (ou de son corrigé). Testé.
enum NotesLibrary {

    struct Document: Equatable, Identifiable {
        var id: String { path }
        /// Le chemin relatif à la racine des notes.
        var path: String
        var notebook: String
        var title: String
        var week: Int?
        var seriesNumber: Int?
        var isSolution: Bool
        var modified: Date
    }

    struct CourseKey: Equatable {
        var code: String
        var name: String
    }

    /// La façon de nommer de l'étudiant·e : les mots d'une série (« Série »,
    /// « PS », « TD », « Übung »…), d'une semaine, et les cahiers déjà rangés à
    /// la main (cahier → code du cours), qui l'emportent sur les devinettes.
    struct Rules: Codable, Equatable {
        var seriesWords: [String] = ["serie", "ps", "problem set", "exercice", "exercices"]
        var weekWords: [String] = ["semaine", "week", "sem"]
        var notebooks: [String: String] = [:]

        static let standard = Rules()

        init(seriesWords: [String] = ["serie", "ps", "problem set", "exercice", "exercices"],
             weekWords: [String] = ["semaine", "week", "sem"], notebooks: [String: String] = [:]) {
            self.seriesWords = seriesWords
            self.weekWords = weekWords
            self.notebooks = notebooks
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seriesWords = try c.decodeIfPresent([String].self, forKey: .seriesWords) ?? Rules.standard.seriesWords
            weekWords = try c.decodeIfPresent([String].self, forKey: .weekWords) ?? Rules.standard.weekWords
            notebooks = try c.decodeIfPresent([String: String].self, forKey: .notebooks) ?? [:]
        }
    }

    // MARK: Cahier → cours

    /// Le cours d'un cahier, s'il y en a un clairement : son code d'abord
    /// (« MATH-111 … »), sinon les mots du nom (« Mécanique » ↔ « Physique
    /// générale : mécanique »), sinon l'acronyme (« AICC » ↔ « Advanced
    /// Information, Computation, Communication »).
    static func course(forNotebook notebook: String, among courses: [CourseKey], rules: Rules = .standard) -> CourseKey? {
        // Un cahier rangé à la main l'emporte.
        if let code = rules.notebooks[notebook] {
            return code.isEmpty ? nil : courses.first { $0.code == code }
        }
        let folder = normalize(notebook)
        let compact = folder.replacingOccurrences(of: " ", with: "")
        if let byCode = courses.first(where: { compact.contains(normalize(base($0.code)).replacingOccurrences(of: " ", with: "")) }) {
            return byCode
        }
        let words = significant(folder)
        guard !words.isEmpty else { return nil }
        var best: (CourseKey, Double)?
        for course in courses {
            let name = significant(normalize(course.name))
            var score = Double(words.intersection(name).count) / Double(words.count)
            let initials = normalize(course.name).split(separator: " ")
                .filter { !stopwords.contains(String($0)) && $0.first?.isLetter == true }.compactMap(\.first)
            let acronym = String(initials)
            if words.contains(where: { $0.count >= 3 && acronym.hasPrefix($0) }) { score = max(score, 0.9) }
            if score > (best?.1 ?? 0) { best = (course, score) }
        }
        guard let best, best.1 >= 0.5 else { return nil }
        // Deux cours à égalité (« Analyse I » et « Analyse II ») : pas de choix au hasard.
        let ties = courses.filter { course in
            Double(words.intersection(significant(normalize(course.name))).count) / Double(words.count) == best.1
        }
        return ties.count > 1 && best.1 < 0.9 ? ties.first { $0.code.contains("101") || $0.code.contains("111") } ?? best.0 : best.0
    }

    // MARK: Un document

    /// `EPFL BA1/Algèbre Linéaire/Semaine 3/Série 3.pdf` → cahier, semaine, série.
    static func document(path: String, modified: Date, rules: Rules = .standard) -> Document? {
        let parts = path.split(separator: "/").map(String.init)
        guard let file = parts.last, file.lowercased().hasSuffix(".pdf") else { return nil }
        let title = String(file.dropLast(4))
        let folders = parts.dropLast()
        let week = folders.reversed().lazy.compactMap { weekNumber($0, rules: rules) }.first
        let notebook = folders.last { weekNumber($0, rules: rules) == nil && normalize($0) != "s4s" } ?? folders.last ?? ""
        let lower = normalize(title)
        let solution = ["corrige", "solution", "sol "].contains { lower.contains($0) } || lower.hasSuffix(" sol")
        return Document(path: path, notebook: notebook, title: title, week: week, seriesNumber: seriesNumber(title, rules: rules),
                        isSolution: solution, modified: modified)
    }

    static func weekNumber(_ folder: String, rules: Rules = .standard) -> Int? {
        let text = normalize(folder)
        let words = rules.weekWords.map { NSRegularExpression.escapedPattern(for: normalize($0)) }.joined(separator: "|")
        guard !words.isEmpty, let match = text.range(of: "^(\(words))\\s*(\\d{1,2})", options: .regularExpression) else { return nil }
        return Int(text[match].filter(\.isNumber))
    }

    /// « Série 3 », « Serie 04 », « PS5 », « Problem Set 6 », « Séance et série 4 ».
    static func seriesNumber(_ title: String, rules: Rules = .standard) -> Int? {
        let text = normalize(title)
        let patterns = rules.seriesWords.map { word -> String in
            let escaped = NSRegularExpression.escapedPattern(for: normalize(word))
            // Un mot court (« ps », « td ») doit commencer un mot : pas « laps 3 ».
            return (word.count <= 3 ? "\\b" : "") + escaped + "\\s*0*(\\d{1,2})"
        }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return Int(text[range])
        }
        return nil
    }

    /// La copie de l'étudiant·e pour une série : même numéro, pas un corrigé,
    /// la plus récente ; sinon un document de la semaine de la série.
    static func copy(seriesNumber: Int, week: Int?, in documents: [Document]) -> Document? {
        let own = documents.filter { !$0.isSolution }
        if let exact = own.filter({ $0.seriesNumber == seriesNumber }).max(by: { $0.modified < $1.modified }) { return exact }
        guard let week else { return nil }
        return own.filter { $0.week == week && ($0.seriesNumber != nil || normalize($0.title).contains("serie")) }
            .max { $0.modified < $1.modified }
    }

    // MARK: Texte

    static let stopwords: Set<String> = ["de", "la", "le", "les", "des", "du", "et", "a", "l", "d", "en", "i", "ii", "1", "2",
                                         "classe", "inversee", "introduction", "generale", "of", "the", "and", "to", "pi", "en"]

    static func normalize(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr"))
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    static func significant(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map(String.init).filter { $0.count > 1 && !stopwords.contains($0) && !$0.contains("-") })
    }

    /// « PHYS-101(c) » → « PHYS-101 ».
    static func base(_ code: String) -> String { String(code.prefix { $0 != "(" }) }
}
