import Foundation

/// Le cadre du tuteur : ce que Claude doit savoir à **chaque** tour, et la façon de répondre.
///
/// Une conversation de série dure des jours ; Claude n'a, de lui-même, ni la mémoire de ce qui a été
/// donné ni l'idée de qui a écrit quoi. Les défauts vus en vrai (un indice redonné au lieu d'un
/// niveau de plus, une page de *ta* copie prise pour un corrigé et refusée, des listes que personne
/// n'avait demandées) venaient tous de là. On ne les corrige pas en gonflant la consigne, mais en
/// donnant à Claude, à chaque message, un état court et exact — et en lui disant quoi en faire.
///
/// Tout est pur (du texte et des règles), testé dans `validate.sh`. L'état vient de l'app : l'exercice,
/// l'échelle d'indices déjà montée (`Exercise.hints`), les questions cochées, les pages de la copie
/// que Claude a reçues. Le texte libre de l'étudiant·e n'est **pas** classé par mots-clés : une
/// consigne mal devinée irait contre la personne. Seuls les gestes de l'app (un bouton, une pièce
/// jointe, un numéro de page) déclenchent une consigne.
enum TutorFramework {

    // MARK: Les règles du tuteur

    /// Les règles, communes aux deux façons de répondre.
    static let contract = """
    Façon de répondre :
    - Réponds à ce qui est demandé, rien d'autre. En mode tuteur, une centaine de mots au plus. Ne \
    dresse jamais l'inventaire d'une pièce jointe, ni un « ordre suggéré », ni un rappel d'autres \
    exercices, sauf si on te le demande.
    - Finis par une seule question, ou une seule chose à faire. Jamais deux.
    - Ce que l'étudiant·e t'envoie est à elle ou lui : sa copie GoodNotes (son écriture : ses tentatives \
    et ses notes prises en séance), ses photos, ses captures. Ce n'est pas un corrigé, même si une page \
    ressemble à une rédaction complète. Ne refuse jamais de lire une page qu'on te montre ou dont on \
    te donne le numéro : dis ce que tu y vois. Si une page contient la solution entière de l'exercice \
    en cours, demande une fois : « Tu veux que j'explique cette rédaction, ou tu préfères la refaire \
    sans ? » — sans sermon.
    - « pas encore marqué fait » dans l'app veut dire « pas coché », pas « pas essayé » : regarde la \
    copie avant de dire que quelque chose n'a pas été tenté.
    - Les numéros de page sont ceux du cahier. Le PDF joint peut ne contenir que certaines pages ; le \
    message dit lesquelles.
    - À chaque message, l'app te donne l'état entre [StudyTrack] et [/StudyTrack] : fie-toi à lui, \
    pas à ta mémoire.
    """

    /// Le tuteur : les indices montent d'un cran à la fois.
    static let tutor = """
    Mode tuteur. Ne donne pas la solution d'emblée.
    Échelle d'indices : 1 orientation (où regarder, quelle question se poser) · 2 outil (la \
    définition, le théorème ou la propriété à utiliser) · 3 amorce (le premier geste concret, sans \
    finir) · 4 solution rédigée.
    - L'état te dit le niveau déjà donné. Si l'étudiant·e redemande de l'aide, dit qu'elle ou il \
    bloque, ou écrit seulement « et maintenant ? », sans nouvelle tentative : donne le niveau \
    **suivant**. Ne répète jamais un indice, ne renvoie pas à l'indice précédent.
    - Si elle ou il montre une tentative (texte, photo, copie) : dis ce qui est juste, désigne la \
    **première** erreur seulement, sans la corriger, et pose une question qui la fait voir.
    - Une question de compréhension (« je ne comprends pas l'idée ») appelle une explication de \
    l'idée, avec l'intuition, pas un nouvel indice sur la preuve.
    - La solution complète seulement si on la demande explicitement.
    """

    static let explain = """
    Mode explications. Explique clairement ce qui est demandé, avec l'intuition et un exemple simple, \
    puis le lien avec l'exercice en cours. Donne des solutions complètes si on les demande.
    """

    // MARK: L'état

    /// Ce qui est vrai de l'exercice, à ce message.
    struct State: Equatable {
        /// « Série 6 · Exercice 6.3 » (`nil` : pas d'exercice choisi).
        var exercise: String?
        /// Où l'exercice en est dans l'app : le mot est choisi pour ne pas dire « pas essayé ».
        var marked: Marked = .notMarked
        /// Le niveau d'indice le plus haut déjà donné (0 : aucun).
        var hintLevel = 0
        var questionsDone = 0
        var questionsTotal = 0
        var copy: Copy?
        var tutor = true

        enum Marked: Equatable {
            case notMarked, done
            /// « juste », « moyen », « faux ».
            case corrected(String)
        }
    }

    /// Ta copie : le cahier, et les pages que cette conversation a déjà reçues.
    struct Copy: Equatable {
        var notebook: String
        var pagesSeen: [Int]
        var total: Int
    }

    static func markedWords(_ marked: State.Marked) -> String {
        switch marked {
        case .notMarked: return "pas encore marqué fait dans l'app (ça ne dit pas si j'ai essayé)"
        case .done: return "marqué fait, pas encore corrigé"
        case .corrected(let word): return "corrigé : \(word)"
        }
    }

    static func levelName(_ level: Int) -> String {
        switch level {
        case 1: return "orientation"
        case 2: return "outil"
        case 3: return "amorce"
        case 4: return "solution"
        default: return "aucun"
        }
    }

    /// Les pièces jointes de ce message, décrites : ce qu'elles sont, et d'où viennent leurs pages.
    enum Origin: Equatable {
        case series(String)
        case copy(notebook: String, pages: [Int], total: Int, requested: Bool)
        case photo
        case file(String)
    }

    /// Ce que la pièce jointe est, en une phrase — pour Claude.
    static func describe(_ origin: Origin) -> String {
        switch origin {
        case .series(let title):
            return "« \(title) » : l'énoncé officiel de la série (PDF)."
        case .copy(let notebook, let pages, let total, let requested):
            let list = ranges(pages)
            var line = "ma copie : mon cahier GoodNotes « \(notebook) » — c'est mon écriture (mes tentatives et mes notes de séance), pas un corrigé. Pages du cahier jointes : \(list) sur \(total)"
            if requested { line += " (celles que je te demande de regarder)" }
            if pages.count > 1 || pages.first != 1 {
                line += ". Le PDF joint ne contient que ces pages, dans l'ordre : sa 1re page est la page \(pages.sorted().first ?? 1) du cahier"
            }
            return line + "."
        case .photo:
            return "une photo ou une capture de mon travail."
        case .file(let name):
            return "« \(name) »."
        }
    }

    /// Le nom court d'une pièce jointe dans la bulle de l'étudiant·e.
    static func chip(_ origin: Origin) -> String {
        switch origin {
        case .series(let title): return title
        case .copy(_, let pages, _, _):
            return pages.count == 1 ? "Ma copie · p. \(pages[0])" : "Ma copie · p. \(ranges(pages))"
        case .photo: return String(localized: "Photo")
        case .file(let name): return name
        }
    }

    /// L'état tel que Claude le reçoit : court (6 lignes au plus), exact, dans le bloc que l'app retire à l'affichage.
    static func card(_ state: State, attached: [Origin] = []) -> String {
        var lines: [String] = []
        if let exercise = state.exercise {
            lines.append("État : \(exercise) — \(markedWords(state.marked))")
            if state.hintLevel > 0 {
                let next = min(state.hintLevel + 1, 4)
                lines.append("Indices déjà donnés : jusqu'au niveau \(state.hintLevel)/4 (\(levelName(state.hintLevel)))."
                             + (state.tutor && state.hintLevel < 4 ? " Si je redemande de l'aide sans nouvelle tentative : niveau \(next) (\(levelName(next)))." : ""))
            } else if state.tutor {
                lines.append("Indices déjà donnés : aucun. Un premier indice est de niveau 1 (orientation).")
            }
            if state.questionsTotal > 0 { lines.append("Questions cochées : \(state.questionsDone)/\(state.questionsTotal).") }
        } else {
            lines.append("État : pas d'exercice choisi.")
        }
        if let copy = state.copy {
            let seen = copy.pagesSeen.isEmpty ? "aucune page reçue pour l'instant" : "pages que tu as déjà reçues : \(ranges(copy.pagesSeen)) sur \(copy.total)"
            lines.append("Ma copie : cahier GoodNotes « \(copy.notebook) » (mon écriture) ; \(seen).")
        }
        if !attached.isEmpty {
            lines.append("En pièce jointe, cette fois : " + attached.map(describe).joined(separator: " "))
        }
        lines.append("Façon de répondre : \(state.tutor ? "tuteur" : "explications").")
        return ClaudeTutor.contextOpen + "\n" + lines.joined(separator: "\n") + "\n" + ClaudeTutor.contextClose + "\n\n"
    }

    /// L'exercice d'un message déjà envoyé, relu dans son état (pour les séparateurs d'une conversation reprise).
    static func exercise(inSent text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("État : ") {
            let body = line.dropFirst("État : ".count)
            guard let exercise = body.components(separatedBy: " — ").first, !exercise.hasPrefix("pas d'exercice") else { return nil }
            return exercise
        }
        return nil
    }

    /// « Série 6 · Exercice 6.3 » → « Exercice 6.3 ».
    static func shortExercise(_ label: String) -> String {
        label.components(separatedBy: " · ").last ?? label
    }

    // MARK: Les gestes

    /// L'indice demandé par le bouton : un cran au-dessus du dernier donné (au plus 3 ; le 4 est « La solution »).
    static func hintPrompt(after level: Int) -> String {
        switch min(max(level, 0) + 1, 3) {
        case 1: return "Donne-moi un indice de niveau 1 (orientation) : où regarder, sans l'outil ni la solution."
        case 2: return "Donne-moi l'indice de niveau 2 (l'outil) : la propriété ou le théorème à utiliser, sans l'appliquer à ma place."
        default: return "Donne-moi l'indice de niveau 3 (l'amorce) : le premier geste concret, sans finir."
        }
    }

    enum Next: Equatable {
        case hint(Int)
        case tryIt
        case check
        case nextStep
        case explain
        case solution
    }

    /// Ce qu'on propose après une réponse, selon l'état (au lieu des mêmes trois puces tout le temps).
    static func suggestions(_ state: State, replyAsksQuestion: Bool) -> [Next] {
        guard state.exercise != nil else { return [.explain] }
        let check: [Next] = state.copy == nil ? [] : [.check]
        let level = state.hintLevel
        var list: [Next]
        if !state.tutor {
            list = [.explain] + check + [.nextStep]
        } else if replyAsksQuestion && level >= 1 {
            list = [.tryIt] + (level < 3 ? [.hint(level + 1)] : [.solution]) + check
        } else {
            switch level {
            case 0: list = [.hint(1)] + check + [.explain]
            case 1, 2: list = [.hint(level + 1)] + check + [.explain]
            case 3: list = check + [.solution, .explain]
            default: list = check + [.nextStep]
            }
        }
        if state.marked != .notMarked, !list.contains(.nextStep) { list.append(.nextStep) }
        return Array(list.prefix(3))
    }

    /// Une réponse qui se termine sur une question : c'est à l'étudiant·e de jouer.
    static func asksQuestion(_ reply: String) -> Bool {
        let tail = SeriesReview.withoutBlocks(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.hasSuffix("?") || tail.suffix(3).contains("?")
    }

    // MARK: « Regarde la page 4 »

    /// Les pages de **la copie** demandées : rien si le message parle de la série, de l'énoncé, du
    /// polycopié ou du corrigé (ces pages-là ne sont pas dans le cahier).
    static func copyPageRequest(in text: String) -> [Int] {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        for word in ["serie", "enonce", "polycopie", "poly", "cours", "corrige", "slides", "diapo"] where folded.contains(word) { return [] }
        return pageRequest(in: text)
    }

    /// Les numéros de page demandés (« page 4 », « pages 3-5 », « p. 4 et 5 », « p4 ») : le seul motif
    /// libre qu'on lit, parce que l'app peut y répondre (joindre cette page) — au plus 4 pages.
    static func pageRequest(in text: String) -> [Int] {
        let pattern = #"(?i)\b(?:pages?|p)\.?\s*(\d{1,3})(?:\s*(?:-|–|à|a)\s*(\d{1,3})|\s*(?:,|et)\s*(\d{1,3}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [Int] = []
        let whole = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: whole) {
            func number(_ index: Int) -> Int? {
                Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
            }
            guard let first = number(1), first > 0 else { continue }
            if let upper = number(2), upper >= first, upper - first < 4 {
                found += Array(first...upper)
            } else {
                found.append(first)
                if let other = number(3), other > 0 { found.append(other) }
            }
        }
        return Array(Set(found)).sorted().prefix(4).map { $0 }
    }

    /// 3, 4, 5, 9 → « 3–5, 9 ».
    static func ranges(_ pages: [Int]) -> String {
        var parts: [String] = []
        var start: Int?, last: Int?
        for page in Set(pages).sorted() {
            if let current = last, page == current + 1 { last = page; continue }
            if let start, let last { parts.append(start == last ? "\(start)" : "\(start)–\(last)") }
            start = page; last = page
        }
        if let start, let last { parts.append(start == last ? "\(start)" : "\(start)–\(last)") }
        return parts.joined(separator: ", ")
    }
}
