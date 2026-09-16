import Foundation

/// La partie **pure** de l'extraction assistée par un modèle de langage :
/// préparer le texte, relire la réponse JSON, fusionner avec l'heuristique.
///
/// Rien ici ne touche au réseau ni au modèle : tout est testable sur des chaînes.
enum SeriesAIParsing {

    // MARK: Préparation

    /// Limite de texte envoyée au modèle. Le modèle embarqué a un contexte court ;
    /// un polycopié de dix pages le dépasse largement.
    static let maxCharacters = 7_000

    /// Réduit le texte d'un PDF à ce qui peut porter une structure : les lignes qui
    /// ressemblent à un en-tête de série ou d'exercice, avec leur voisine
    /// suivante (où vit souvent l'intitulé). Le reste — énoncés, formules,
    /// consignes — n'apprend rien au modèle et lui coûte son contexte.
    static func prepare(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r", with: "")
        guard cleaned.count > maxCharacters else { return cleaned }

        let lines = cleaned.components(separatedBy: "\n")
        var keep = Set<Int>()
        for (index, line) in lines.enumerated() where looksStructural(line) {
            keep.insert(index)
            if index + 1 < lines.count { keep.insert(index + 1) }
        }
        var result = keep.sorted().map { lines[$0].trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if result.count > maxCharacters {
            result = String(result.prefix(maxCharacters))
        }
        return result.isEmpty ? String(cleaned.prefix(maxCharacters)) : result
    }

    private static let structural = try! NSRegularExpression(
        pattern: #"(?i)\b(s[ée]rie|exercice|exo|ex[ .\-]?\d|probl[eè]me|question|bonus|facultatif|optionnel)\b|^\s*\d{1,2}[.\-·]\d{1,2}\b"#,
        options: []
    )

    static func looksStructural(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return structural.firstMatch(in: line, options: [], range: range) != nil
    }

    // MARK: Consigne

    /// La consigne donnée au modèle. Elle demande du JSON strict et interdit
    /// d'inventer : un numéro absent du texte ne doit pas apparaître.
    static let instructions = """
    Tu extrais la structure d'une série d'exercices d'un cours EPFL à partir du texte brut d'un PDF.
    Réponds UNIQUEMENT avec un objet JSON de la forme :
    {"series":[{"number":3,"title":"Récurrences","exercises":[{"number":"3.1","title":"Tri fusion","isBonus":false}]}]}
    Règles : n'invente aucun exercice ni numéro absent du texte ; le numéro d'un exercice s'écrit « série.exercice » (ex. « 3.2 ») ; si le PDF ne numérote que « Exercice 2 » dans la Série 3, écris « 3.2 » ; « title » est l'intitulé court s'il existe, sinon une chaîne vide (jamais l'énoncé) ; « isBonus » vaut true si l'exercice est marqué bonus, facultatif, optionnel ou étoilé ; s'il n'y a aucune série, renvoie {"series":[]}.
    """

    // MARK: Lecture de la réponse

    private struct Payload: Decodable {
        struct Series: Decodable {
            var number: Int?
            var title: String?
            var exercises: [Exercise]?
        }
        struct Exercise: Decodable {
            var number: String?
            var title: String?
            var isBonus: Bool?
        }
        var series: [Series]?
    }

    /// Lit la réponse du modèle, tolérante aux bavardages autour du JSON.
    ///
    /// Un modèle répond parfois « Voici le JSON : {…} » ou entoure de ```json.
    /// On isole le premier objet, et on refuse tout ce qui n'a pas la forme
    /// attendue plutôt que de deviner.
    static func parse(_ raw: String) -> [DetectedSeries] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") , start < end else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return normalize(payload)
    }

    private static func normalize(_ payload: Payload) -> [DetectedSeries] {
        var result: [DetectedSeries] = []
        for series in payload.series ?? [] {
            guard let number = series.number, (1...60).contains(number) else { continue }
            var seen = Set<String>()
            var exercises: [DetectedExercise] = []
            for exercise in series.exercises ?? [] {
                guard let candidate = normalizeNumber(exercise.number, series: number),
                      seen.insert(candidate).inserted else { continue }
                let title = (exercise.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                exercises.append(DetectedExercise(number: candidate,
                                                  title: SeriesPDFParser.looksLikeTitle(title) ? title : "",
                                                  isBonus: exercise.isBonus ?? false))
            }
            exercises.sort { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
            if let existing = result.firstIndex(where: { $0.number == number }) {
                let known = Set(result[existing].exercises.map(\.number))
                result[existing].exercises += exercises.filter { !known.contains($0.number) }
            } else {
                result.append(DetectedSeries(number: number,
                                             title: (series.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                             exercises: exercises))
            }
        }
        return result.sorted { $0.number < $1.number }
    }

    /// « 2 » dans la série 3 → « 3.2 » ; « 3.2 » reste ; « Ex 3.2 » → « 3.2 ».
    static func normalizeNumber(_ raw: String?, series: Int) -> String? {
        guard let raw else { return nil }
        let digits = raw.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !digits.isEmpty else { return nil }
        let parts = digits.split(separator: ".").map(String.init)
        switch parts.count {
        case 1:
            guard let value = Int(parts[0]), (1...99).contains(value) else { return nil }
            return "\(series).\(value)"
        case 2:
            guard let major = Int(parts[0]), let minor = Int(parts[1]), (1...99).contains(minor) else { return nil }
            // Le modèle peut avoir mis le numéro dans une autre série : on suit la
            // série annoncée par l'objet parent, qui fait foi.
            return "\(major == series ? major : series).\(minor)"
        default:
            return nil
        }
    }

    // MARK: Fusion

    /// Fusionne l'heuristique et la réponse du modèle.
    ///
    /// Le modèle **complète** : il apporte les exercices que les motifs ont ratés
    /// et les intitulés qu'ils ne savent pas isoler. Il ne **retire** rien de ce
    /// que l'heuristique a lu — un numéro présent dans le texte ne disparaît pas
    /// parce qu'un modèle l'a oublié. Sur un bonus, le modèle l'emporte s'il dit
    /// oui (il lit « ⋆ » et « facultatif » mieux qu'un motif).
    static func merge(heuristic: [DetectedSeries], ai: [DetectedSeries]) -> [DetectedSeries] {
        guard !ai.isEmpty else { return heuristic }
        var result = heuristic
        for series in ai {
            if let index = result.firstIndex(where: { $0.number == series.number }) {
                if result[index].title.isEmpty, !series.title.isEmpty {
                    result[index].title = series.title
                }
                for exercise in series.exercises {
                    if let existing = result[index].exercises.firstIndex(where: { $0.number == exercise.number }) {
                        if result[index].exercises[existing].title.isEmpty, !exercise.title.isEmpty {
                            result[index].exercises[existing].title = exercise.title
                        }
                        if exercise.isBonus { result[index].exercises[existing].isBonus = true }
                    } else {
                        result[index].exercises.append(exercise)
                    }
                }
                result[index].exercises.sort { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
            } else {
                result.append(series)
            }
        }
        return result.sorted { $0.number < $1.number }
    }
}
