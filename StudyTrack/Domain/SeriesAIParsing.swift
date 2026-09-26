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

    /// Limite du texte **mis en forme** envoyé à la fonction partagée, qui coupe
    /// au-delà de 6 000 caractères. Couper nous-mêmes, en gardant la structure de
    /// tout le document, vaut mieux que de laisser le serveur tronquer la fin :
    /// c'est ce qui faisait disparaître les derniers exercices, un import sur deux.
    static let layoutBudget = 5_800

    /// Le texte d'un PDF **avec sa mise en page**, pour le modèle.
    ///
    /// Le modèle recevait un texte aplati alors que sa consigne lui demande de
    /// juger l'indentation : il devinait. Ici chaque titre est préfixé de « # »,
    /// chaque ligne garde son retrait (deux espaces par cran), et les pages sont
    /// séparées. Les lignes de corps sont raccourcies avant les lignes de
    /// structure, pour que **tout** le document tienne dans le budget.
    static func prepareLayout(_ lines: [PDFLayoutLine], seriesHint: Int?) -> String {
        let body = SeriesLayoutParser.bodyFontSize(lines)
        let boldBody = SeriesLayoutParser.bodyIsBold(lines)
        let margin = lines.filter { !$0.isEmpty && $0.indent > 0 }.map(\.indent).min() ?? 0

        struct Entry { var text: String; var structural: Bool; var page: Int }
        var entries: [Entry] = []
        // Pieds et en-têtes de page répétés (« Compilation : … », numéro de page)
        // n'apprennent rien au modèle et mangent son budget.
        var pagesByText: [String: Set<Int>] = [:]
        for line in lines where !line.isEmpty { pagesByText[line.trimmed, default: []].insert(line.pageIndex) }
        for line in lines where !line.isEmpty {
            let isPageNumber = line.trimmed.count <= 3 && line.trimmed.allSatisfy(\.isNumber)
                && isFooterOrHeader(line, in: lines)
            // Une ligne répétée sur plusieurs pages est un pied ou un en-tête — sauf
            // si elle porte le numéro de série, qui reste un repère utile.
            let isRunning = (pagesByText[line.trimmed]?.count ?? 0) >= 2
                && isFooterOrHeader(line, in: lines)
                && SeriesDocumentInference.seriesNumberInDocument([line]) == nil
            if isRunning || isPageNumber { continue }
            let heading = SeriesLayoutParser.isHeading(line, body: body, boldBody: boldBody)
                || (!boldBody && line.startsBold)
            // Arrondi par défaut, avec une tolérance : 104,6 et 105,9 pt sont le
            // même retrait. `rounded()` les mettait de part et d'autre d'un cran.
            let level = min(8, max(0, Int((line.indent - margin + 4) / 14)))
            let indent = String(repeating: "  ", count: level)
            let text = line.trimmed.replacingOccurrences(of: "\u{00A0}", with: " ")
            let structural = heading || looksStructural(text)
                || SeriesLayoutParser.questionLabel(text, allowNumbers: true) != nil
            entries.append(Entry(text: indent + (heading ? "# " : "") + text,
                                 structural: structural, page: line.pageIndex))
        }

        func render(bodyLimit: Int?) -> String {
            var output: [String] = []
            if let seriesHint { output.append("[Indice : ce document semble être la série \(seriesHint)]") }
            var page = -1
            var bodyRun = 0
            for entry in entries {
                if entry.page != page {
                    page = entry.page
                    output.append("--- page \(page + 1) ---")
                }
                if entry.structural {
                    output.append(entry.text)
                    bodyRun = 0
                    continue
                }
                guard let bodyLimit else { output.append(entry.text); continue }
                // Au plus deux lignes d'énoncé par bloc : de quoi voir « Calculer : »
                // ou « (facultatif) », pas de quoi noyer la structure.
                bodyRun += 1
                if bodyLimit == 0 || bodyRun > 2 { continue }
                output.append(entry.text.count > bodyLimit ? String(entry.text.prefix(bodyLimit)) + "…" : entry.text)
            }
            return output.joined(separator: "\n")
        }

        for limit in [nil, 90, 50, 0] as [Int?] {
            let rendered = render(bodyLimit: limit)
            if rendered.count <= layoutBudget { return rendered }
        }
        return String(render(bodyLimit: 0).prefix(layoutBudget))
    }

    /// Une ligne isolée tout en haut ou tout en bas de sa page.
    private static func isFooterOrHeader(_ line: PDFLayoutLine, in lines: [PDFLayoutLine]) -> Bool {
        if let position = line.verticalPosition { return position < 0.1 || position > 0.9 }
        let page = lines.filter { $0.pageIndex == line.pageIndex && !$0.isEmpty }
        guard let index = page.firstIndex(of: line) else { return false }
        return index < 2 || index >= page.count - 2
    }

    private static let structural = try! NSRegularExpression(
        pattern: #"(?i)\b(s[ée]ries?|exercices?|exercises?|exo|ex[ .\-]?\d|probl[eè]mes?|problems?|aufgabe|question|bonus|facultatif|optionnel|optional)\b|^\s*\d{1,2}[.\-·]\d{1,2}\b"#,
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
    {"series":[{"number":3,"title":"Récurrences","exercises":[{"number":"3.1","title":"Tri fusion","isBonus":false,"questions":[{"label":"1","text":"Montrer la borne"},{"label":"2","text":"Cas d'égalité"}]}]}]}
    Format du texte : « # » en début de ligne marque un titre du PDF ; les espaces de tête reproduisent le retrait (une question est décalée sous son exercice) ; « --- page N --- » sépare les pages ; « [Indice : … série N] » donne le numéro de série à utiliser.
    Langue : écris « title » et le texte des questions dans la même langue que le PDF.
    Exercices et questions : « exercises » contient les EXERCICES, pas les questions. Un exercice peut poser plusieurs questions — elles vont dans « questions ». Si le PDF introduit une liste par une phrase suivie de deux points (« Calculer : », « Déterminer : ») puis numérote 1., 2., ce sont les questions d'un même exercice. Si chaque numéro est une consigne autonome, ce sont des exercices distincts.
    Numérotation : « number » de la série est un entier (« Série 02a » donne 2) ; le numéro d'un exercice s'écrit toujours « série.exercice » (« 3.2 »), même si le PDF recommence à 1 dans chaque section ; sans numéro, prends le numéro suivant dans l'ordre. N'invente aucun exercice absent du texte.
    Titre : « title » est TOUJOURS rempli, jamais vide. Reprends l'intitulé court s'il existe ; sinon écris toi-même 2 à 6 mots qui nomment la tâche, en t'appuyant sur le titre de la section ou sur l'objet de l'exercice. Ne recopie jamais l'énoncé complet.
    « isBonus » vaut true si l'exercice est marqué bonus, facultatif, optionnel ou étoilé. S'il n'y a aucune série, renvoie {"series":[]}.
    """

    // MARK: Lecture de la réponse

    /// Une valeur que le modèle peut écrire de plusieurs façons.
    ///
    /// Le JSON d'un modèle de langage **n'est pas un contrat** : il écrit `2` là où
    /// on attend `"2"`, `"02a"` là où on attend un entier, `"oui"` là où on attend
    /// un booléen. Un décodeur strict rejette alors **toute** la réponse pour un
    /// seul champ — et l'utilisateur voit une extraction vide sans savoir pourquoi.
    /// On lit donc souplement, et on ne refuse que ce qui n'a vraiment aucun sens.
    private enum Flexible {

        static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>,
                                      _ key: K) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
            guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            return leadingInt(text)
        }

        static func string<K: CodingKey>(_ container: KeyedDecodingContainer<K>,
                                         _ key: K) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return String(value) }
            return nil
        }

        static func bool<K: CodingKey>(_ container: KeyedDecodingContainer<K>,
                                       _ key: K) -> Bool? {
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
            guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "oui", "yes", "vrai", "1": return true
            case "false", "non", "no", "faux", "0": return false
            default: return nil
            }
        }

        /// Le premier entier d'un texte : « 02a » → 2, « Série 3 » → 3.
        static func leadingInt(_ text: String) -> Int? {
            let digits = text.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
            return digits.isEmpty ? nil : Int(digits)
        }
    }

    private struct Payload: Decodable {
        struct Series: Decodable {
            var number: Int?
            var title: String?
            var exercises: [Exercise]?

            enum Keys: String, CodingKey { case number, title, exercises }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                number = Flexible.int(container, Keys.number)
                title = Flexible.string(container, Keys.title)
                // Une liste absente ou d'un type inattendu ne doit pas faire perdre
                // la série : on la remplace par une liste vide.
                exercises = (try? container.decodeIfPresent([Exercise].self, forKey: .exercises)) ?? []
            }
        }

        /// Une question, écrite de deux façons selon le modèle.
        ///
        /// On demande une simple étiquette — `"questions":["1","2"]` — parce que
        /// recopier un énoncé mathématique dans une chaîne JSON produit souvent du
        /// JSON invalide. Mais un modèle bavard répond parfois
        /// `[{"label":"1","text":"…"}]` : on accepte les deux plutôt que de perdre
        /// la structure pour une question de forme.
        ///
        /// Le chemin « vision » répond avec un arbre : `{"label":"1","kind":"question",
        /// "text":"…","children":[{"label":"a",…}]}`, et `"label": null` pour une
        /// partie sans numéro (`"kind":"part"`).
        struct Question: Decodable {
            var label: String?
            var text: String?
            var kind: String?
            var children: [Question]?

            enum Keys: String, CodingKey { case label, text, kind, children, parts, questions }

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let text = try? single.decode(String.self) {
                    label = text
                    self.text = ""
                    return
                }
                let container = try decoder.container(keyedBy: Keys.self)
                label = Flexible.string(container, Keys.label)
                text = Flexible.string(container, Keys.text)
                kind = Flexible.string(container, Keys.kind)
                children = (try? container.decodeIfPresent([Question].self, forKey: .children))
                    ?? (try? container.decodeIfPresent([Question].self, forKey: .parts))
                    ?? (try? container.decodeIfPresent([Question].self, forKey: .questions))
            }
        }

        struct Exercise: Decodable {
            var number: String?
            var title: String?
            var isBonus: Bool?
            var questions: [Question]?
            var page: Int?
            var statement: String?

            enum Keys: String, CodingKey { case number, title, isBonus, questions, parts, page, statement }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                number = Flexible.string(container, Keys.number)
                title = Flexible.string(container, Keys.title)
                isBonus = Flexible.bool(container, Keys.isBonus)
                page = Flexible.int(container, Keys.page)
                statement = Flexible.string(container, Keys.statement)
                questions = (try? container.decodeIfPresent([Question].self, forKey: .parts))
                    ?? (try? container.decodeIfPresent([Question].self, forKey: .questions)) ?? []
            }
        }

        var series: [Series]?

        enum Keys: String, CodingKey { case series }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            series = (try? container.decodeIfPresent([Series].self, forKey: .series)) ?? []
        }
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
            var nextIndex = 1
            for exercise in series.exercises ?? [] {
                // Un exercice sans numéro n'est pas jeté : beaucoup de polycopiés
                // numérotent leurs exercices 1, 2, 3 **dans chaque section**, et
                // certains n'en donnent aucun. On prend alors le premier numéro
                // libre, ce qui laisse à l'étudiant·e une ligne à cocher plutôt
                // qu'un exercice invisible.
                var candidate = normalizeNumber(exercise.number, series: number)
                if candidate == nil {
                    while seen.contains("\(number).\(nextIndex)") { nextIndex += 1 }
                    candidate = "\(number).\(nextIndex)"
                }
                guard let candidate, seen.insert(candidate).inserted else { continue }
                nextIndex += 1
                let title = (exercise.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                exercises.append(DetectedExercise(number: candidate,
                                                  title: SeriesPDFParser.looksLikeTitle(title) ? title : "",
                                                  isBonus: exercise.isBonus ?? false,
                                                  statement: (exercise.statement ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                                  subQuestions: subQuestions(exercise.questions),
                                                  pageIndex: exercise.page.map { max(0, $0 - 1) }))
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

    /// Les sous-questions d'un exercice, étiquetées et dédoublonnées, sur deux
    /// niveaux au plus.
    ///
    /// Une sous-question sans étiquette reçoit son rang — sauf une **partie**
    /// (`"kind":"part"`), qui n'a pas de numéro dans le polycopié et n'en reçoit pas.
    private static func subQuestions(_ raw: [Payload.Question]?, depth: Int = 0) -> [DetectedSubQuestion] {
        guard let raw else { return [] }
        let hasTree = raw.contains { !($0.children ?? []).isEmpty || $0.kind == "part" }
        // Une seule « question », c'est l'exercice lui-même : pas de case à part.
        guard raw.count >= 2 || hasTree else { return [] }
        var seen = Set<String>()
        var result: [DetectedSubQuestion] = []
        var rank = 0
        for question in raw {
            let isPart = question.kind?.lowercased() == "part"
            let label = (question.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "().:"))
            let text = (question.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if isPart {
                guard !text.isEmpty else { continue }
                result.append(DetectedSubQuestion(label: "", text: text, kind: .part))
                continue
            }
            rank += 1
            let resolved = label.isEmpty ? String(rank) : label
            guard seen.insert(resolved).inserted else { continue }
            let children = depth == 0 ? subQuestions(question.children, depth: 1).filter { $0.kind == .question } : []
            result.append(DetectedSubQuestion(label: resolved, text: text, children: children.count >= 2 ? children : []))
        }
        // Des parties seules, sans question numérotée : c'est l'exercice lui-même.
        return result.contains { $0.kind == .question } ? result : []
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
    /// Trois règles, dans l'ordre :
    ///   1. **Un seul numéro de série.** Quand chaque côté ne voit qu'une série
    ///      mais pas la même — l'heuristique rangeait tout en série 1 faute
    ///      d'en-tête, le modèle lisait 4 —, les deux sont ramenés au numéro que le
    ///      document annonce (`preferredSeries`), à défaut à celui du modèle.
    ///      Sans ça, l'écran proposait deux séries pour un seul PDF.
    ///   2. **Le modèle complète**, il n'efface pas ce qui est sûr : un exercice
    ///      repéré par un mot-clé (« Exercice 3 ») reste, même oublié par le modèle.
    ///   3. **Un repère douteux doit être confirmé.** Un numéro nu (« 1.5 ») que
    ///      le modèle ne retrouve pas est écarté : c'était, le plus souvent, une
    ///      ligne de démonstration.
    static func merge(heuristic: [DetectedSeries], ai: [DetectedSeries],
                      preferredSeries: Int? = nil, aiReadsLayout: Bool = false) -> [DetectedSeries] {
        guard !ai.isEmpty, ai.contains(where: { !$0.exercises.isEmpty }) else { return heuristic }
        var heuristic = heuristic
        var ai = ai

        if heuristic.count <= 1, ai.count == 1 {
            let target = preferredSeries ?? ai[0].number
            ai = ai.map { renumber($0, to: target) }
            heuristic = heuristic.map { renumber($0, to: target) }
        } else if let preferredSeries, heuristic.count == 1, ai.count > 1,
                  !ai.contains(where: { $0.number == heuristic[0].number }) {
            heuristic = heuristic.map { renumber($0, to: preferredSeries) }
        }

        var result = ai
        let aiSeriesNumbers = Set(ai.map(\.number))
        for series in heuristic {
            guard let index = result.firstIndex(where: { $0.number == series.number }) else {
                // Série que le modèle n'a pas vue : on la garde si elle repose sur
                // des repères sûrs.
                let kept = series.exercises.filter(\.isConfident)
                if !kept.isEmpty || (series.exercises.isEmpty && !aiSeriesNumbers.contains(series.number) && !series.title.isEmpty) {
                    result.append(DetectedSeries(number: series.number, title: series.title, exercises: kept))
                }
                continue
            }
            if result[index].title.isEmpty, !series.title.isEmpty {
                result[index].title = series.title
            }
            for exercise in series.exercises {
                if let existing = result[index].exercises.firstIndex(where: { $0.number == exercise.number }) {
                    var merged = result[index].exercises[existing]
                    if merged.title.isEmpty { merged.title = exercise.title }
                    if merged.statement.isEmpty { merged.statement = exercise.statement }
                    merged.isBonus = merged.isBonus || exercise.isBonus
                    merged.isConfident = true
                    // Les sous-questions ne s'additionnent pas : c'est le même
                    // exercice, décrit deux fois. Un modèle de **texte** se trompe
                    // sur les listes en deux colonnes : la lecture de la mise en
                    // page l'emporte alors quand elle a trouvé quelque chose. Un
                    // modèle qui **voit** les pages (`aiReadsLayout`) lit les
                    // colonnes, les points imbriqués et les formules : il l'emporte,
                    // et la lecture locale ne comble que son silence.
                    if aiReadsLayout {
                        if merged.subQuestions.isEmpty {
                            merged.subQuestions = exercise.subQuestions
                        } else if !merged.subQuestions.contains(where: { $0.kind == .part }) {
                            // Le modèle voit les questions, mais oublie parfois la
                            // consigne sans numéro (« Calculer lim aₙ. Ensuite… ») que
                            // la lecture locale a trouvée : on la remet à sa place.
                            let local = exercise.subQuestions
                            let leading = local.prefix { $0.kind == .part }
                            let trailing = local.reversed().prefix { $0.kind == .part }.reversed()
                            if leading.count < local.count {
                                merged.subQuestions = Array(leading) + merged.subQuestions + Array(trailing)
                            }
                        }
                    } else if !exercise.subQuestions.isEmpty {
                        merged.subQuestions = exercise.subQuestions
                    }
                    // La position vient de la mise en page lue localement : page et
                    // hauteur vont ensemble, le modèle ne donne que la page.
                    if exercise.verticalPosition != nil {
                        merged.pageIndex = exercise.pageIndex
                        merged.verticalPosition = exercise.verticalPosition
                    } else if merged.pageIndex == nil {
                        merged.pageIndex = exercise.pageIndex
                    }
                    result[index].exercises[existing] = merged
                } else if exercise.isConfident {
                    result[index].exercises.append(exercise)
                }
            }
            result[index].exercises.sort { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
        }
        return result.sorted { $0.number < $1.number }
    }

    /// La même série sous un autre numéro : « 1.3 » devient « 4.3 ».
    static func renumber(_ series: DetectedSeries, to number: Int) -> DetectedSeries {
        guard series.number != number else { return series }
        var copy = series
        copy.number = number
        copy.exercises = series.exercises.map { exercise in
            var moved = exercise
            let minor = exercise.number.split(separator: ".").last.map(String.init) ?? exercise.number
            moved.number = "\(number).\(minor)"
            return moved
        }
        return copy
    }
}
