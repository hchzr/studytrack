import Foundation

/// Une ligne de PDF, avec ce que sa **mise en page** dit d'elle.
///
/// L'extraction précédente faisait `page.string` : tout le document devenait un
/// seul bloc de texte, et la distinction entre un titre et un énoncé disparaissait.
/// C'est de là que venaient « solution générale. » sous l'exercice 1 ou
/// « tions change. » sous le 3 — des morceaux de phrase pris pour des intitulés.
struct PDFLayoutLine: Equatable {
    var text: String
    /// Taille de police dominante de la ligne. `0` quand le PDF n'en expose pas.
    var fontSize: Double
    var isBold: Bool
    var pageIndex: Int
    /// Retrait depuis le bord gauche de la page, en points. `0` quand inconnu.
    ///
    /// C'est le signal qui distingue un exercice (aligné à gauche) de ses
    /// questions (décalées vers la droite) — et que l'IA ne pouvait pas voir tant
    /// que le texte lui arrivait aplati.
    var indent: Double
    /// La ligne **commence** en gras : un titre « en ligne », typique de LaTeX
    /// (« **Exercice 1.** Soit f… »), dont la police dominante reste celle du corps.
    var startsBold: Bool
    /// Position verticale sur la page, de 0 (haut) à 1 (bas). `nil` quand inconnue.
    ///
    /// L'ordre des lignes ne suffit pas à reconnaître un pied de page : PDFKit
    /// rend une seconde colonne **après** lui.
    var verticalPosition: Double?

    init(text: String, fontSize: Double = 0, isBold: Bool = false, pageIndex: Int = 0,
         indent: Double = 0, startsBold: Bool = false, verticalPosition: Double? = nil) {
        self.text = text
        self.fontSize = fontSize
        self.isBold = isBold
        self.pageIndex = pageIndex
        self.indent = indent
        self.startsBold = startsBold
        self.verticalPosition = verticalPosition
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmed.isEmpty }
}

/// Repère séries et exercices en s'appuyant sur la **taille de police**.
///
/// Le principe : dans un polycopié, un titre est plus gros que le corps du texte.
/// Un énoncé, non. C'est le signal qui manquait — les motifs seuls ne peuvent pas
/// distinguer « Exercice 1 » (titre) de « Exercice 1 solution générale. » (titre
/// suivi de la première phrase de l'énoncé).
///
/// Fonction **pure** : elle reçoit des lignes déjà extraites, donc elle se teste
/// sans PDF.
enum SeriesLayoutParser {

    /// Nombre de lignes explorées après un titre pour trouver « bonus », « facultatif ».
    static let bonusLookahead = 12

    // MARK: Corps de texte

    /// Taille du corps : la plus fréquente, **pondérée par le nombre de caractères**.
    ///
    /// Compter les lignes ne suffit pas — un document peut avoir trente titres
    /// courts et dix paragraphes longs. Ce qu'on lit, ce sont les caractères.
    static func bodyFontSize(_ lines: [PDFLayoutLine]) -> Double? {
        var weight: [Double: Int] = [:]
        for line in lines where line.fontSize > 0 {
            weight[line.fontSize, default: 0] += max(1, line.trimmed.count)
        }
        return weight.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    /// Le corps est-il en gras ? Sur un jeu de diapositives, tout l'est : le gras
    /// ne distingue alors plus rien et ne doit pas servir de signal.
    static func bodyIsBold(_ lines: [PDFLayoutLine]) -> Bool {
        let body = lines.filter { !$0.isEmpty }
        guard !body.isEmpty else { return false }
        let bold = body.filter(\.isBold).count
        return bold * 2 > body.count
    }

    /// La ligne se détache-t-elle du corps du texte ?
    static func isHeading(_ line: PDFLayoutLine, body: Double?, boldBody: Bool) -> Bool {
        guard !line.isEmpty else { return false }
        if let body, line.fontSize > 0 {
            if line.fontSize >= body * 1.06 { return true }
            // Tailles identiques : le gras prend le relais, s'il est rare.
            if !boldBody, line.isBold, line.fontSize >= body * 0.98 { return true }
            return false
        }
        return false
    }

    /// Un titre, ou un titre « en ligne » qui commence en gras.
    private static func isMarkedUp(_ line: PDFLayoutLine, body: Double?, boldBody: Bool) -> Bool {
        isHeading(line, body: body, boldBody: boldBody) || (!boldBody && line.startsBold)
    }

    // MARK: Analyse

    /// Repère les séries et leurs exercices.
    ///
    /// `defaultSeries` est la série que le **document** annonce ailleurs qu'en
    /// tête de ligne — un en-tête « Analyse I — Série 4 », le nom du fichier.
    /// Sans lui, un polycopié sans « Série N » en début de ligne rangeait tous ses
    /// exercices dans la série 1, et l'IA, qui lisait bien 4, en créait une seconde.
    ///
    /// Quand aucun PDF n'expose de police (texte collé, PDF sans fontes), on
    /// retombe sur `SeriesPDFParser` : le comportement précédent, sans régression.
    static func parse(_ lines: [PDFLayoutLine], defaultSeries: Int? = nil) -> [DetectedSeries] {
        guard lines.contains(where: { $0.fontSize > 0 }) else {
            return SeriesPDFParser.parse(lines.map(\.text).joined(separator: "\n"),
                                         defaultSeries: defaultSeries)
        }

        let body = bodyFontSize(lines)
        let boldBody = bodyIsBold(lines)
        let fallback = defaultSeries ?? 1
        // Le document écrit-il « Exercice » (ou « Exercise », « Problème »…) ?
        // Alors « Question 2 » ou un « 1. » en gras sont des **questions** de
        // l'exercice courant, pas des exercices.
        let usesKeywords = lines.contains { line in
            guard let marker = exerciseMarker(line.trimmed, fallbackSeries: 1) else { return false }
            return marker.kind == .keyword || marker.kind == .dashed
        }
        let leftMargin = lines.filter { !$0.isEmpty && $0.indent > 0 }.map(\.indent).min() ?? 0

        var seriesTitles: [Int: String] = [:]
        var groups: [Int: [DetectedExercise]] = [:]
        var seen = Set<String>()
        var currentSeries: Int?
        var order: [Int] = []
        /// Position de l'exercice en cours, pour y rattacher ses questions.
        var current: (series: Int, index: Int)?
        var labels: [QuestionMark] = []

        func closeExercise() {
            let top = topLevelQuestions(labels)
            if let current, isQuestionSequence(top) {
                groups[current.series]?[current.index].subQuestions =
                    top.map { DetectedSubQuestion(label: $0, text: "") }
            }
            current = nil
            labels = []
        }

        for (index, line) in lines.enumerated() {
            let text = line.trimmed
            guard !text.isEmpty else { continue }

            // 1. En-tête de série.
            if let (number, remainder) = seriesHeader(text) {
                closeExercise()
                currentSeries = number
                if order.contains(number) == false { order.append(number) }
                if seriesTitles[number] == nil {
                    var title = SeriesPDFParser.cleanTitle(remainder)
                    // Un titre de série peut tenir sur la ligne suivante quand
                    // celle-ci est **du même niveau** que l'en-tête.
                    if title.isEmpty,
                       index + 1 < lines.count,
                       isHeading(lines[index + 1], body: body, boldBody: boldBody),
                       seriesHeader(lines[index + 1].trimmed) == nil,
                       exerciseMarker(lines[index + 1].trimmed, fallbackSeries: 1) == nil {
                        title = SeriesPDFParser.cleanTitle(lines[index + 1].trimmed)
                    }
                    seriesTitles[number] = SeriesPDFParser.looksLikeTitle(title) ? title : ""
                }
                continue
            }

            let markedUp = isMarkedUp(line, body: body, boldBody: boldBody)
            let nearMargin = line.indent <= leftMargin + 18

            // 2. Exercice.
            if let marker = exerciseMarker(text, fallbackSeries: currentSeries ?? fallback),
               accepts(marker, markedUp: markedUp, nearMargin: nearMargin, usesKeywords: usesKeywords) {
                guard seen.insert(marker.number).inserted else {
                    // Un doublon (corrigé à la suite de l'énoncé, rappel en pied de
                    // page) clôt l'exercice précédent sans en créer un nouveau.
                    closeExercise()
                    continue
                }
                closeExercise()
                let resolvedSeries = marker.series ?? currentSeries ?? fallback
                if order.contains(resolvedSeries) == false { order.append(resolvedSeries) }

                groups[resolvedSeries, default: []].append(
                    DetectedExercise(number: marker.number,
                                     title: title(for: marker, line: line, next: nextLine(lines, after: index),
                                                  body: body, boldBody: boldBody),
                                     isBonus: bonus(lines, from: index, body: body, boldBody: boldBody),
                                     isConfident: marker.kind != .numeric))
                current = (resolvedSeries, groups[resolvedSeries]!.count - 1)
                continue
            }

            // 3. Question d'un exercice : « a) », « (b) », « 1. » décalé.
            if current != nil, let label = questionLabel(text, allowNumbers: usesKeywords) {
                labels.append(QuestionMark(label: label, indent: line.indent))
            }
        }
        closeExercise()

        var result = order.sorted().map { number in
            DetectedSeries(number: number,
                           title: seriesTitles[number] ?? "",
                           exercises: (groups[number] ?? []).sorted {
                               $0.number.localizedStandardCompare($1.number) == .orderedAscending
                           })
        }

        // Une série annoncée sans exercice reconnu est **conservée** : mieux vaut
        // une carte vide à compléter à la main qu'un import qui ne trouve rien.
        for (number, title) in seriesTitles where groups[number] == nil && !order.contains(number) {
            result.append(DetectedSeries(number: number, title: title, exercises: []))
        }
        return result.sorted { $0.number < $1.number }
    }

    /// Un repère est-il crédible **à cet endroit** de la mise en page ?
    ///
    /// Un mot-clé (« Exercice 3 ») est presque toujours un titre, sauf quand il
    /// est cité (« Exercice 2 de la série précédente… »). Un numéro nu (« 1.5 »,
    /// « 2. ») ne l'est que s'il est **mis en forme** comme un titre : sans cette
    /// règle, la première ligne d'une démonstration numérotée devenait un
    /// exercice fantôme.
    private static func accepts(_ marker: ExerciseMarker, markedUp: Bool,
                                nearMargin: Bool, usesKeywords: Bool) -> Bool {
        switch marker.kind {
        case .dashed:
            return true
        case .keyword:
            return markedUp || !isReference(marker.remainder)
        case .question:
            // « Question 1 » n'est un exercice que dans un document qui n'en
            // nomme aucun autrement.
            return !usesKeywords && (markedUp || !isReference(marker.remainder))
        case .numeric:
            return markedUp && nearMargin && !usesKeywords
        }
    }

    /// « Exercice 2 **de la série** précédente » : une citation, pas un titre.
    static func isReference(_ remainder: String) -> Bool {
        let value = remainder.trimmingCharacters(in: .whitespaces).lowercased()
        let prefixes = ["de la ", "du ", "de l'", "de l’", "des ", "et ", "à ", ", ", "ci-dessus", "précédent",
                        "of ", "from ", "in ", "and ", "above", "der ", "aus ", "und "]
        return prefixes.contains { value.hasPrefix($0) }
    }

    // MARK: Questions

    private static let questionPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:\(([a-hA-H]|[ivx]{1,4}|\d{1,2})\)|([a-hA-H]|[ivx]{1,4})\)|([a-h])\.[ \t]|(\d{1,2})[.)][ \t])"#,
        options: [])

    /// L'étiquette d'une question en tête de ligne : « a) », « (ii) », « 3. ».
    static func questionLabel(_ text: String, allowNumbers: Bool) -> String? {
        let ns = text as NSString
        guard let match = questionPattern.firstMatch(in: text, options: [],
                                                     range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 1...4 {
            let range = match.range(at: group)
            guard range.location != NSNotFound else { continue }
            let label = ns.substring(with: range).lowercased()
            if label.first?.isNumber == true, !allowNumbers, group == 4 { return nil }
            return label
        }
        return nil
    }

    /// Une étiquette de question, avec le retrait de sa ligne.
    struct QuestionMark: Equatable {
        var label: String
        var indent: Double
    }

    enum LabelStyle { case number, letter, roman }

    static func style(of label: String) -> LabelStyle {
        if label.allSatisfy(\.isNumber) { return .number }
        if label.count > 1 || ["i", "v", "x"].contains(label), label.allSatisfy({ "ivx".contains($0) }) {
            // « i » seul est ambigu : c'est un romain s'il ouvre la liste, une
            // lettre s'il suit « h ». On tranche au niveau de la liste.
            return .roman
        }
        return .letter
    }

    /// Les questions **du premier niveau**, dans l'ordre de leur numéro.
    ///
    /// Un polycopié imbrique souvent deux niveaux — « 1) … (a) (b) (c) 2) … (a)
    /// (b) » — et les lire à plat mélangeait tout (« 1, a, b, c, d, 2, e ») : les
    /// sous-points du second bloc disparaissaient même, pris pour des doublons.
    /// Le premier niveau est le plus à gauche ; à retrait égal, le style de la
    /// première étiquette. Deux colonnes (« 1) … 3) » sur une ligne, puis « 2) …
    /// 4) ») arrivent dans le désordre : on trie.
    static func topLevelQuestions(_ marks: [QuestionMark]) -> [String] {
        guard let first = marks.first else { return [] }
        let hasLayout = marks.contains { $0.indent > 0 }
        let minIndent = marks.map(\.indent).min() ?? 0
        let anchor = hasLayout ? (marks.first { $0.indent <= minIndent + 6 } ?? first) : first
        var anchorStyle = style(of: anchor.label)
        // « i) » qui ouvre une liste de lettres (a, b, … h, i) reste une lettre.
        if anchorStyle == .roman, marks.contains(where: { style(of: $0.label) == .letter && $0.label != "i" }) {
            anchorStyle = .letter
        }

        var seen = Set<String>()
        var result: [String] = []
        for mark in marks {
            // La deuxième colonne est plus à droite, mais au même niveau : le
            // style suffit à la reconnaître. Le retrait ne sert qu'à écarter un
            // niveau imbriqué **du même style** (rare, mais « 1. » sous « 1) »).
            let markStyle: LabelStyle = style(of: mark.label) == .roman && anchorStyle == .letter ? .letter : style(of: mark.label)
            guard markStyle == anchorStyle else { continue }
            guard seen.insert(mark.label).inserted else { continue }
            result.append(mark.label)
        }
        return result.sorted { order(of: $0, style: anchorStyle) < order(of: $1, style: anchorStyle) }
    }

    private static func order(of label: String, style: LabelStyle) -> Int {
        switch style {
        case .number: return Int(label) ?? 0
        case .letter: return Int(label.unicodeScalars.first?.value ?? 0)
        case .roman:
            let values: [Character: Int] = ["i": 1, "v": 5, "x": 10]
            var total = 0
            var previous = 0
            for character in label.reversed() {
                let value = values[character] ?? 0
                total += value < previous ? -value : value
                previous = max(previous, value)
            }
            return total
        }
    }

    /// Des étiquettes forment-elles une vraie liste de questions ?
    ///
    /// Deux au moins, et une liste qui **commence** au début (a, 1 ou i) : une
    /// ligne isolée « c) » au milieu d'un énoncé n'est pas une question.
    static func isQuestionSequence(_ labels: [String]) -> Bool {
        guard labels.count >= 2, let first = labels.first else { return false }
        return ["a", "1", "i"].contains(first)
    }

    // MARK: Titres

    /// L'intitulé d'un exercice — **jamais** la première ligne de l'énoncé.
    ///
    /// Deux sources seulement : la fin de la ligne du titre, et la ligne suivante
    /// **si et seulement si** elle est du même niveau typographique que le titre
    /// (un intitulé sur deux lignes). Une ligne de corps de texte n'est jamais un
    /// intitulé, c'est ce qui produisait les faux titres.
    private static func title(for marker: ExerciseMarker,
                              line: PDFLayoutLine,
                              next: PDFLayoutLine?,
                              body: Double?,
                              boldBody: Bool) -> String {
        let sameLine = SeriesPDFParser.cleanTitle(marker.remainder)
        if SeriesPDFParser.looksLikeTitle(sameLine) { return sameLine }

        guard let next, !next.isEmpty,
              isHeading(next, body: body, boldBody: boldBody),
              next.fontSize <= line.fontSize * 1.02,
              exerciseMarker(next.trimmed, fallbackSeries: 1) == nil,
              seriesHeader(next.trimmed) == nil else { return "" }
        let continuation = SeriesPDFParser.cleanTitle(next.trimmed)
        return SeriesPDFParser.looksLikeTitle(continuation) ? continuation : ""
    }

    private static func nextLine(_ lines: [PDFLayoutLine], after index: Int) -> PDFLayoutLine? {
        guard index + 1 < lines.count else { return nil }
        return lines[index + 1]
    }

    // MARK: Bonus

    /// Cherche « bonus », « facultatif », « optionnel » ou une étoile **dans le
    /// corps de l'exercice**.
    ///
    /// L'ancienne version ne regardait que la ligne du titre et la suivante. Sur un
    /// vrai polycopié, la mention est souvent deux ou trois lignes plus bas, après
    /// l'énoncé — elle était donc manquée.
    private static func bonus(_ lines: [PDFLayoutLine], from index: Int,
                              body: Double?, boldBody: Bool) -> Bool {
        for offset in 0...bonusLookahead {
            let position = index + offset
            guard position < lines.count else { break }
            let line = lines[position]
            // Un nouveau titre clôt l'exercice : au-delà, la mention appartient à
            // quelqu'un d'autre.
            if offset > 0, isHeading(line, body: body, boldBody: boldBody) { break }
            if offset > 0, exerciseMarker(line.trimmed, fallbackSeries: 1)?.kind == .keyword { break }
            if SeriesPDFParser.containsBonusMarker(line.trimmed) { return true }
        }
        return false
    }

    // MARK: Motifs

    /// Les mots qui annoncent un exercice, en français, anglais et allemand : les
    /// cours de master sont souvent en anglais, et un polycopié « Exercise 3 »
    /// n'était tout simplement pas vu.
    static let exerciseKeywords = #"exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe"#

    private static let seriesPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*s[ée]rie[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b[ \t]*[–—:.\-]?[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    private static let dashedPattern = try! NSRegularExpression(
        pattern: #"\bEx[ .\-]?(\d{1,2})[.\-](\d{1,2})\b[ \t]*[:.\-–—]?[ \t]*(.*)$"#,
        options: [])

    private static let barePattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:"# + exerciseKeywords + #")[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*\*?[ \t]*[:.\-–—]?[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    private static let keywordNumberedPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:"# + exerciseKeywords + #")[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})[.\-·](\d{1,2})\b[ \t]*\*?[ \t]*[–—:.\-)]?[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    private static let questionHeadingPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*question[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*[:.\-–—]?[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    private static let numberedPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(\d{1,2})[.\-·](\d{1,2})\b(?![.,]\d)[ \t]*[–—:.\-)]?[ \t]*(.*)$"#,
        options: [])

    /// « 3. Titre » ou « 3) » : un numéro seul, qui n'est un exercice que mis en forme.
    private static let singleNumberPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(\d{1,2})[.)](?!\d)[ \t]*(.*)$"#,
        options: [])

    struct ExerciseMarker {
        enum Kind { case dashed, keyword, question, numeric }
        var number: String
        /// Série déduite du numéro lui-même (« Ex-02-04 » → 2), sinon `nil`.
        var series: Int?
        var remainder: String
        var kind: Kind
    }

    static func seriesHeader(_ text: String) -> (number: Int, remainder: String)? {
        let ns = text as NSString
        guard let match = seriesPattern.firstMatch(in: text, options: [],
                                                   range: NSRange(location: 0, length: ns.length)),
              let number = Int(ns.substring(with: match.range(at: 1))), (1...60).contains(number) else { return nil }
        return (number, ns.substring(with: match.range(at: 2)))
    }

    static func exerciseMarker(_ text: String, fallbackSeries: Int) -> ExerciseMarker? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        func int(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = match.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return Int(ns.substring(with: range))
        }
        func string(_ match: NSTextCheckingResult, _ group: Int) -> String {
            let range = match.range(at: group)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }

        if let match = dashedPattern.firstMatch(in: text, options: [], range: full),
           let major = int(match, 1), let minor = int(match, 2), minor > 0 {
            return ExerciseMarker(number: "\(major).\(minor)", series: major,
                                  remainder: string(match, 3), kind: .dashed)
        }
        if let match = keywordNumberedPattern.firstMatch(in: text, options: [], range: full),
           let major = int(match, 1), let minor = int(match, 2), minor > 0 {
            return ExerciseMarker(number: "\(major).\(minor)", series: major,
                                  remainder: string(match, 3), kind: .keyword)
        }
        if let match = barePattern.firstMatch(in: text, options: [], range: full),
           let value = int(match, 1), value > 0 {
            return ExerciseMarker(number: "\(fallbackSeries).\(value)", series: nil,
                                  remainder: string(match, 2), kind: .keyword)
        }
        if let match = questionHeadingPattern.firstMatch(in: text, options: [], range: full),
           let value = int(match, 1), value > 0 {
            return ExerciseMarker(number: "\(fallbackSeries).\(value)", series: nil,
                                  remainder: string(match, 2), kind: .question)
        }
        if let match = numberedPattern.firstMatch(in: text, options: [], range: full),
           let major = int(match, 1), let minor = int(match, 2), minor > 0, major > 0 {
            return ExerciseMarker(number: "\(major).\(minor)", series: major,
                                  remainder: string(match, 3), kind: .numeric)
        }
        if let match = singleNumberPattern.firstMatch(in: text, options: [], range: full),
           let value = int(match, 1), value > 0 {
            return ExerciseMarker(number: "\(fallbackSeries).\(value)", series: nil,
                                  remainder: string(match, 2), kind: .numeric)
        }
        return nil
    }
}
