import Foundation

/// Un exercice repéré dans le texte d'un PDF de série.
struct DetectedExercise: Equatable, Identifiable {
    /// Numéro tel qu'il sera créé : « 2.1 ».
    var number: String
    /// Ce qui suit le numéro sur la même ligne, s'il y a quelque chose.
    var title: String
    var isBonus: Bool

    var id: String { number }
}

/// Une série repérée, avec ses exercices.
struct DetectedSeries: Equatable, Identifiable {
    var number: Int
    /// Intitulé trouvé après « Série 3 », s'il y en a un.
    var title: String
    var exercises: [DetectedExercise]

    var id: Int { number }
}

/// Repère les séries et les exercices dans le texte d'un PDF EPFL.
///
/// Fonction **pure** : elle ne lit aucun fichier et ne touche à aucun modèle, donc
/// elle se teste sur de vrais extraits de texte sans PDF ni simulateur.
///
/// Trois formats réels sont reconnus, relevés sur des polycopiés de l'EPFL :
///   • `Ex-02-01:` — Analyse 1 inversée, série et exercice dans le numéro ;
///   • `Exercice 3 Type : … Défi : ⋆⋆` — Algèbre linéaire inversée ;
///   • `1.2` ou `Exercice 1.2` — le format historique du projet.
///
/// La détection ne sera jamais parfaite — un PDF scanné ne contient aucun texte, et
/// l'extraction aplatit la mise en page, collant parfois deux exercices sur une
/// ligne. C'est pourquoi l'import passe **toujours** par un écran de relecture :
/// le parseur propose, l'étudiant·e dispose.
enum SeriesPDFParser {

    // MARK: Motifs

    /// `Ex-02-01:` — le numéro porte la série **et** l'exercice.
    ///
    /// Le titre s'arrête avant l'exercice suivant : l'extraction aplatit la mise en
    /// page et colle parfois deux exercices sur une ligne
    /// (« Ex-02-08: Ex-02-09: Montrer que… »). Sans la borne, le premier match
    /// consommait toute la ligne et le second n'était jamais vu.
    private static let dashed = try! NSRegularExpression(
        pattern: #"(?m)\bEx[ .\-]?(\d{1,2})[.\-](\d{1,2})\b[ \t]*[:.\-–—]?[ \t]*([^\n]*?)(?=\s*Ex[ .\-]?\d{1,2}[.\-]\d{1,2}\b|$)"#,
        options: []
    )

    /// « Exercice 1.2 », ou simplement « 1.2 », avec un intitulé facultatif.
    private static let numbered = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:(?:exercice|exo|ex|probl[eè]me|question)[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?)?(\d{1,2})[.\-·](\d{1,2})\b[ \t]*[–—:.\-)]?[ \t]*(.*)$"#,
        options: [.caseInsensitive]
    )

    /// « Exercice 3 » — seul, ou suivi d'un intitulé sur la même ligne.
    ///
    /// `(?!\.\d)` est essentiel : sans lui, « Exercice 3.1 » serait aussi lu comme
    /// l'exercice « 3 », et un exercice fantôme apparaîtrait dans la série.
    private static let bare = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:exercice|exo|ex|probl[eè]me|question)[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*[:.\-–—]?[ \t]*(.*)$"#,
        options: [.caseInsensitive]
    )

    /// « Série 3 », « Série n° 3 », « Série 02 (Nombres R) ».
    private static let header = try! NSRegularExpression(
        pattern: #"(?im)^[ \t]*s[ée]rie[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b[ \t]*[–—:.\-]?[ \t]*(.*)$"#,
        options: []
    )

    private static let bonus = try! NSRegularExpression(
        pattern: #"(?i)\bbonus\b|\bétoile\b|\bfacultatif\b|\boptionnel\b"#,
        options: []
    )

    /// Métadonnées de mise en page EPFL qui se retrouvent collées au titre.
    private static let metadata = try! NSRegularExpression(
        pattern: #"(?i)\s*(?:Type|Défi|Objectifs?|Rubrique)\s*:"#,
        options: []
    )

    /// Un exercice suivant, sur la même ligne (l'extraction aplatit la mise en page).
    /// `\s*` et non `\s+` : le séparateur a déjà été consommé par le motif appelant.
    private static let nextExercise = try! NSRegularExpression(
        pattern: #"\s*Ex[ .\-]?\d{1,2}[.\-]\d{1,2}\b"#,
        options: []
    )

    // MARK: Analyse

    static func parse(_ text: String) -> [DetectedSeries] {
        let normalized = normalize(text)
        let ns = normalized as NSString
        let full = NSRange(location: 0, length: ns.length)

        var headers: [(location: Int, number: Int)] = []
        var titles: [Int: String] = [:]
        for match in header.matches(in: normalized, options: [], range: full) {
            guard let number = intValue(ns, match.range(at: 1)) else { continue }
            headers.append((match.range.location, number))
            if titles[number] == nil {
                titles[number] = cleanTitle(ns.substring(with: match.range(at: 2)))
            }
        }

        // L'ordre du document compte : c'est lui qui donne l'ordre des exercices.
        // `series` vaut `nil` quand le numéro ne dit pas la série (voir plus bas).
        var entries: [(location: Int, exercise: DetectedExercise, series: Int?)] = []
        var seen = Set<String>()

        /// Ajoute un exercice si son numéro n'a pas déjà été vu.
        func append(number: String, title: String, context: String, series: Int?, at location: Int) {
            guard seen.insert(number).inserted else { return }
            entries.append((location,
                            DetectedExercise(number: number,
                                             title: exerciseTitle(title),
                                             isBonus: isBonus(context)),
                            series))
        }

        // 1. « Ex-02-01: » — série et exercice dans le numéro.
        for match in dashed.matches(in: normalized, options: [], range: full) {
            guard let major = intValue(ns, match.range(at: 1)),
                  let minor = intValue(ns, match.range(at: 2)) else { continue }
            let number = "\(major).\(minor)"
            append(number: number,
                   title: ns.substring(with: match.range(at: 3)),
                   context: lineContext(ns, around: match.range),
                   series: major,
                   at: match.range.location)
        }

        // 2. « 1.2 » ou « Exercice 1.2 ».
        for match in numbered.matches(in: normalized, options: [], range: full) {
            let major = ns.substring(with: match.range(at: 1))
            let minor = ns.substring(with: match.range(at: 2))
            let number = "\(major).\(minor)"
            append(number: number,
                   title: ns.substring(with: match.range(at: 3)),
                   context: lineContext(ns, around: match.range),
                   series: majorComponent(of: number),
                   at: match.range.location)
        }

        // 3. « Exercice 3 » — un numéro simple est un numéro d'**exercice**, pas de
        //    série : « Exercice 1 » et « Exercice 2 » appartiennent à la même série.
        //    C'est l'en-tête précédent qui la donne, à défaut la série 1.
        for match in bare.matches(in: normalized, options: [], range: full) {
            let number = ns.substring(with: match.range(at: 1))
            append(number: number,
                   title: ns.substring(with: match.range(at: 2)),
                   context: lineContext(ns, around: match.range),
                   series: nil,
                   at: match.range.location)
        }

        var groups: [Int: [DetectedExercise]] = [:]
        for entry in entries.sorted(by: { $0.location < $1.location }) {
            let series = entry.series
                ?? headers.last(where: { $0.location < entry.location })?.number
                ?? 1
            groups[series, default: []].append(entry.exercise)
        }

        var result = groups.keys.sorted().map { series in
            DetectedSeries(number: series,
                           title: titles[series] ?? "",
                           exercises: sorted(groups[series] ?? []))
        }

        // Une série **annoncée** mais dont aucun exercice n'a été reconnu est
        // conservée, avec une liste vide. C'est ce qui rend le parseur robuste à une
        // mise en page inconnue : au lieu d'un import qui ne trouve rien et laisse
        // l'étudiant·e sans recours, la série apparaît dans l'écran de relecture et
        // les exercices s'ajoutent à la main.
        for (number, title) in titles where groups[number] == nil {
            result.append(DetectedSeries(number: number, title: title, exercises: []))
        }
        return result.sorted { $0.number < $1.number }
    }

    // MARK: Outils

    /// Numéro de série d'un numéro d'exercice : « 2.3 » → 2.
    static func majorComponent(of number: String) -> Int? {
        guard let first = number.split(separator: ".").first else { return nil }
        return Int(first)
    }

    private static func sorted(_ exercises: [DetectedExercise]) -> [DetectedExercise] {
        exercises.sorted { lhs, rhs in
            lhs.number.localizedStandardCompare(rhs.number) == .orderedAscending
        }
    }

    /// L'intitulé d'un exercice, ou rien.
    ///
    /// L'extraction d'un PDF aplatit la mise en page : « Exercice 1 solution
    /// générale. » n'est presque jamais « l'exercice 1, intitulé *solution
    /// générale* » — c'est le numéro suivi de la **première phrase de l'énoncé**.
    /// Afficher ça sous l'exercice invente une information, et c'est exactement ce
    /// que l'étudiant·e voit de travers dans l'écran de relecture.
    ///
    /// On ne garde donc que ce qui a la forme d'un intitulé. Dans le doute, on
    /// préfère **rien** : le numéro suffit à identifier l'exercice, et un titre
    /// absent ne trompe personne.
    static func exerciseTitle(_ raw: String) -> String {
        let value = cleanTitle(raw)
        guard !value.isEmpty else { return "" }
        return looksLikeTitle(value) ? value : ""
    }

    /// Un intitulé est court, ne ponctue pas comme une phrase, et commence par une
    /// majuscule — un fragment coupé au milieu d'un mot commence par une minuscule.
    static func looksLikeTitle(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        // Au-delà, c'est une phrase d'énoncé recopiée sur une seule ligne.
        guard value.count <= 60 else { return false }
        // Ponctuation finale de phrase.
        guard !value.hasSuffix("."), !value.hasSuffix(";"), !value.hasSuffix(":") else { return false }
        // Un fragment de mot (« tions change. »), une suite d'énoncé
        // (« ou contre-exemple. ») ou une énumération (« 1) Si x alors y ») ne
        // commence pas par une majuscule.
        guard let first = value.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return false }
        return true
    }

    private static func intValue(_ ns: NSString, _ range: NSRange) -> Int? {
        guard range.location != NSNotFound else { return nil }
        return Int(ns.substring(with: range))
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// La ligne du numéro **et la suivante** : « (bonus) » ou « facultatif » est
    /// souvent en dessous.
    private static func lineContext(_ ns: NSString, around range: NSRange) -> String {
        let lineRange = ns.lineRange(for: range)
        let after = lineRange.location + lineRange.length
        let nextRange = after < ns.length ? ns.lineRange(for: NSRange(location: after, length: 0)) : nil
        guard let nextRange else { return ns.substring(with: lineRange) }
        return ns.substring(with: lineRange) + "\n" + ns.substring(with: nextRange)
    }

    private static func isBonus(_ context: String) -> Bool {
        bonus.firstMatch(in: context, options: [],
                         range: NSRange(location: 0, length: (context as NSString).length)) != nil
    }

    /// Nettoie un titre : séparateurs de tête, parenthèses d'en-tête, métadonnées
    /// EPFL, et l'exercice suivant quand l'extraction les a collés.
    private static func cleanTitle(_ raw: String) -> String {        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // « (Nombres R) » → « Nombres R »
        if value.hasPrefix("("), value.hasSuffix(")"), value.count > 2 {
            value = String(value.dropFirst().dropLast())
        }
        // Retirer les séparateurs de tête.
        while let first = value.first, "–—:-.·)»".contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }

        let ns = value as NSString
        // Couper avant l'exercice suivant collé sur la même ligne.
        if let match = nextExercise.firstMatch(in: value, options: [],
                                               range: NSRange(location: 0, length: ns.length)) {
            value = ns.substring(to: match.range.location)
        }
        // Couper avant les métadonnées de mise en page (« Type : Technique »).
        let trimmed = value as NSString
        if let match = metadata.firstMatch(in: value, options: [],
                                           range: NSRange(location: 0, length: trimmed.length)) {
            value = trimmed.substring(to: match.range.location)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
