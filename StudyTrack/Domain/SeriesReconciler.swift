import Foundation

/// Retrouve, dans une nouvelle lecture d'un énoncé, les exercices déjà
/// enregistrés — **par leur contenu, pas par leur numéro**.
///
/// La série 6 d'AICC a été révisée après l'import : un « Exercise 1 (repris de
/// la semaine 5) » ajouté en tête, trois exercices retirés. Tout s'était décalé
/// d'un cran : la « 6.1 » de l'app était l'« Exercise 2 » du PDF, et Claude,
/// qui lisait le PDF, ne parlait plus du même exercice. Fusionner par numéro
/// aurait mis l'avancement du télescopage sur l'exercice des fonctions
/// génératrices.
///
/// Un enseignant ajoute et retire des exercices, il les réordonne rarement :
/// l'appariement est un **alignement qui garde l'ordre** (comme un diff), qui
/// maximise la ressemblance des textes (titre et énoncé, mots communs). Le
/// numéro ne sert qu'à départager.
enum SeriesReconciler {

    struct Item: Equatable {
        var number: String
        var title: String
        var statement: String
    }

    /// En dessous, deux exercices ne sont pas « le même » (sauf même numéro et
    /// textes vides).
    static let threshold = 0.18

    /// `result[i]` : l'indice dans `existing` de l'exercice qui devient le
    /// i-ième de `incoming`, ou `nil` (un nouvel exercice).
    static func match(existing: [Item], incoming: [Item]) -> [Int?] {
        let n = existing.count, m = incoming.count
        guard n > 0, m > 0 else { return Array(repeating: nil, count: m) }
        let oldWords = existing.map(words)
        let newWords = incoming.map(words)
        var score = Array(repeating: Array(repeating: 0.0, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                score[i][j] = similarity(oldWords[i], newWords[j], sameNumber: minor(existing[i].number) == minor(incoming[j].number))
            }
        }
        // Alignement : best[i][j] = meilleur total avec les i premiers anciens
        // et les j premiers nouveaux.
        var best = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                var value = max(best[i - 1][j], best[i][j - 1])
                if score[i - 1][j - 1] >= threshold { value = max(value, best[i - 1][j - 1] + score[i - 1][j - 1]) }
                best[i][j] = value
            }
        }
        var result: [Int?] = Array(repeating: nil, count: m)
        var i = n, j = m
        while i > 0, j > 0 {
            let s = score[i - 1][j - 1]
            if s >= threshold, abs(best[i][j] - (best[i - 1][j - 1] + s)) < 1e-9 {
                result[j - 1] = i - 1
                i -= 1; j -= 1
            } else if best[i - 1][j] >= best[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    /// Ressemblance de deux exercices (0 → 1) : la part de mots en commun
    /// (Dice), plus un petit bonus pour le même numéro.
    static func similarity(_ a: Set<String>, _ b: Set<String>, sameNumber: Bool) -> Double {
        let bonus = sameNumber ? 0.05 : 0
        guard !a.isEmpty, !b.isEmpty else { return sameNumber ? threshold : 0 }
        let common = Double(a.intersection(b).count)
        return 2 * common / Double(a.count + b.count) + bonus
    }

    /// Les mots qui portent le sens : minuscules, sans accents ni formules,
    /// au moins trois lettres, sans les mots outils des consignes.
    static func words(_ item: Item) -> Set<String> {
        let text = (item.title + " " + item.statement)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        let raw = text.split { !$0.isLetter }.map(String.init)
        return Set(raw.filter { $0.count >= 3 && !stopWords.contains($0) }.map(stem))
    }

    /// « algorithms » et « algorithm » sont le même mot.
    private static func stem(_ word: String) -> String {
        word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    private static func minor(_ number: String) -> String {
        number.split(whereSeparator: { $0 == "." || $0 == "-" }).last.map(String.init) ?? number
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "are", "each", "following", "given", "use", "using",
        "find", "show", "determine", "which", "what", "how", "its", "their", "these", "those", "into", "when",
        "exercise", "exercice", "les", "des", "une", "pour", "que", "qui", "dans", "est", "sur", "avec", "par",
        "montrer", "trouver", "determiner", "suivant", "suivante", "suivants", "suivantes", "soit", "the",
        "not", "all", "any", "can", "you", "your", "his", "her", "has", "have", "been", "will",
    ]
}
