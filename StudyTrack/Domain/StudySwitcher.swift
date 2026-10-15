import Foundation

/// Le sélecteur d'étude (⌘Tab dans le bureau) : l'ordre des outils et des apps,
/// le dernier utilisé d'abord, comme le sélecteur du système qu'il remplace.
///
/// Pur et testé. Les entrées sont des identifiants (`pane:exercise`,
/// `app:com.goodnotesapp.x`, `claude`) ; ce qu'elles ouvrent est dans le Mac.
struct StudySwitcherModel: Equatable {
    /// Les plus récents d'abord, sans doublon.
    private(set) var recent: [String] = []

    static let memory = 24

    mutating func touch(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.memory { recent.removeLast(recent.count - Self.memory) }
    }

    /// Les entrées disponibles, le plus récemment utilisé en tête ; celles
    /// jamais utilisées suivent dans l'ordre donné.
    func order(available: [String]) -> [String] {
        let known = recent.filter(available.contains)
        return known + available.filter { !known.contains($0) }
    }

    /// Où tombe la sélection après `step` appuis (⇧ : en arrière), en boucle.
    static func move(from index: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + step) % count + count) % count
    }
}

/// La recherche d'étude (⌘Espace) : ce qui ressemble à un calcul est calculé.
enum StudySearchQuery {

    /// Les noms que le moteur de calcul connaît ; tout autre mot de deux lettres
    /// ou plus est du texte, pas une expression.
    private static let known = ["sin", "cos", "tan", "asin", "acos", "atan", "exp", "ln", "log", "sqrt",
                                "abs", "det", "inv", "rref", "transpose", "rank", "trace", "solve",
                                "pi", "int", "root", "re", "im", "conj", "arg", "sinh", "cosh", "tanh"]

    /// L'expression à calculer, ou `nil` si la requête est une recherche.
    /// `=` en tête force le calcul ; sinon il faut un chiffre, un opérateur, et
    /// aucun mot (« série 3 », « PHYS-101 » restent des recherches).
    static func mathExpression(_ query: String) -> String? {
        var text = query.trimmingCharacters(in: .whitespaces)
        let forced = text.hasPrefix("=")
        if forced { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var rest = text.lowercased()
        for name in known.sorted(by: { $0.count > $1.count }) { rest = rest.replacingOccurrences(of: name, with: " ") }
        let words = rest.split(whereSeparator: { !$0.isLetter })
        if words.contains(where: { $0.count >= 2 }) { return nil }
        if forced { return text }
        let hasDigit = text.contains { $0.isNumber }
        let hasOperator = text.contains { "+-*/^()".contains($0) }
        return hasDigit && hasOperator ? text : nil
    }
}
