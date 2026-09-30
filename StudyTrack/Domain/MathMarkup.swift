import Foundation

/// Un texte avec des formules, découpé en morceaux à afficher.
///
/// Les énoncés arrivent du modèle en notation simple ou en LaTeX léger :
/// `x_n = \frac{an+b}{cn+d}`, `|a_n - ℓ| \le \varepsilon`, `a_{2k+1}`. Affichés
/// tels quels, ils se lisaient « a_n » — illisible pour un énoncé de maths.
///
/// Ce moteur est **pur** (testé dans `validate.sh`) : il ne fait que découper en
/// morceaux normal / indice / exposant et remplacer les commandes par leurs
/// symboles. `MathText` en fait une `Text` SwiftUI.
enum MathMarkup {

    enum Style: Equatable { case normal, subscripted, superscripted }

    struct Run: Equatable {
        var text: String
        var style: Style
    }

    /// Le texte contient-il quelque chose à mettre en forme ?
    static func hasMarkup(_ text: String) -> Bool {
        text.contains("_") || text.contains("^") || text.contains("\\") || text.contains("$")
    }

    static func runs(_ source: String) -> [Run] {
        var parser = Parser(Array(source.replacingOccurrences(of: "$", with: "")))
        return merge(parser.parse(style: .normal, until: nil))
    }

    /// Le texte à plat, symboles remplacés (pour l'accessibilité et les widgets).
    static func plain(_ source: String) -> String {
        runs(source).map(\.text).joined()
    }

    private static func merge(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.style == run.style {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }

    // MARK: Symboles

    static let symbols: [String: String] = [
        "lt": "<", "gt": ">", "le": "≤", "leq": "≤", "leqslant": "⩽", "ge": "≥", "geq": "≥", "geqslant": "⩾",
        "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "infty": "∞", "to": "→", "rightarrow": "→", "longrightarrow": "⟶", "leftarrow": "←",
        "Rightarrow": "⇒", "implies": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔",
        "mapsto": "↦", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩",
        "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃", "neg": "¬",
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "circ": "∘",
        "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇",
        "ldots": "…", "dots": "…", "cdots": "⋯", "prime": "′", "quad": " ", "qquad": "  ",
        ",": " ", ";": " ", "!": "", " ": " ", "{": "{", "}": "}", "|": "‖", "%": "%",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "ell": "ℓ", "lim": "lim", "sup": "sup", "inf": "inf", "max": "max", "min": "min",
        "sin": "sin", "cos": "cos", "tan": "tan", "ln": "ln", "log": "log", "exp": "exp",
        "left": "", "right": "", "big": "", "Big": "", "displaystyle": "", "limits": "",
        // Macros du polycopié de Botafogo (\bR = ℝ) et commandes de mise en
        // page qui n'ont pas de sens sur une ligne.
        "bR": "ℝ", "bC": "ℂ", "bN": "ℕ", "bZ": "ℤ", "bQ": "ℚ",
        "bigl": "", "bigr": "", "Bigl": "", "Bigr": "", "biggl": "", "biggr": "",
        "textstyle": "", "nolimits": "", "notag": "", "nonumber": "",
        "lvert": "|", "rvert": "|", "vert": "|",
        "colon": ":", "setminus": "∖", "supset": "⊃", "supseteq": "⊇",
        "longmapsto": "⟼", "searrow": "↘", "nearrow": "↗", "downarrow": "↓", "uparrow": "↑",
        "cot": "cot", "arcsin": "arcsin", "arccos": "arccos", "arctan": "arctan",
        "sinh": "sinh", "cosh": "cosh", "tanh": "tanh", "det": "det", "liminf": "lim inf", "limsup": "lim sup"
    ]

    static let blackboard: [Character: String] = [
        "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ", "C": "ℂ", "P": "ℙ", "K": "𝕂"
    ]

    // MARK: Analyse

    private struct Parser {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { index >= chars.count }

        mutating func parse(style: Style, until closing: Character?) -> [Run] {
            var runs: [Run] = []
            var buffer = ""
            func flush() {
                if !buffer.isEmpty { runs.append(Run(text: buffer, style: style)) }
                buffer = ""
            }
            while !atEnd {
                let char = chars[index]
                if let closing, char == closing {
                    index += 1
                    break
                }
                switch char {
                case "\\":
                    index += 1
                    let command = readCommand()
                    let produced = expand(command, style: style)
                    if produced.count == 1, produced[0].style == style {
                        buffer += produced[0].text
                    } else {
                        flush()
                        runs += produced
                    }
                case "_", "^":
                    // Un « _ » ou « ^ » isolé dans une phrase n'est pas une formule.
                    let previous = index > 0 ? chars[index - 1] : " "
                    let isScript = previous.isLetter || previous.isNumber || ")]}|′'".contains(previous) || !buffer.isEmpty
                    index += 1
                    guard isScript, !atEnd, chars[index] != " " else {
                        buffer.append(char)
                        continue
                    }
                    flush()
                    let target: Style = char == "_" ? .subscripted : .superscripted
                    runs += argument(style: target)
                case "{":
                    index += 1
                    flush()
                    runs += parse(style: style, until: "}")
                default:
                    buffer.append(char)
                    index += 1
                }
            }
            flush()
            return runs
        }

        /// `\frac`, `\le`, `\,` — le nom d'une commande.
        mutating func readCommand() -> String {
            guard !atEnd else { return "" }
            if !chars[index].isLetter {
                let single = String(chars[index])
                index += 1
                return single
            }
            var name = ""
            while !atEnd, chars[index].isLetter {
                name.append(chars[index])
                index += 1
            }
            return name
        }

        /// L'argument d'un indice, d'un exposant ou d'une commande : `{…}`, une
        /// commande, ou un seul caractère.
        mutating func argument(style: Style) -> [Run] {
            while !atEnd, chars[index] == " " { index += 1 }
            guard !atEnd else { return [] }
            if chars[index] == "{" {
                index += 1
                return parse(style: style, until: "}")
            }
            if chars[index] == "\\" {
                index += 1
                return expand(readCommand(), style: style)
            }
            let single = chars[index]
            index += 1
            return [Run(text: String(single), style: style)]
        }

        mutating func expand(_ command: String, style: Style) -> [Run] {
            switch command {
            case "frac", "dfrac", "tfrac":
                let numerator = argument(style: style)
                let denominator = argument(style: style)
                return fraction(numerator, denominator, style: style)
            case "sqrt":
                let body = argument(style: style)
                let text = body.map(\.text).joined()
                let simple = text.count <= 1 || (text.allSatisfy { $0.isLetter || $0.isNumber } && body.allSatisfy { $0.style == style })
                return [Run(text: "√", style: style)] + (simple ? body : [Run(text: "(", style: style)] + body + [Run(text: ")", style: style)])
            case "mathbb":
                let body = argument(style: style).map(\.text).joined()
                return [Run(text: String(body.map { MathMarkup.blackboard[$0] ?? String($0) }.joined()), style: style)]
            case "mathrm", "mathbf", "mathit", "text", "textrm", "operatorname", "mathcal", "boldsymbol":
                return argument(style: style)
            case "overline", "bar":
                return argument(style: style).map { Run(text: $0.text + "\u{0305}", style: $0.style) }
            default:
                if let symbol = MathMarkup.symbols[command] {
                    return [Run(text: symbol, style: style)]
                }
                // Commande inconnue : on garde son nom, lisible, plutôt que rien.
                return [Run(text: command, style: style)]
            }
        }

        /// `\frac{a}{b}` : « a⁄b » pour des termes courts, « (a)/(b) » sinon.
        func fraction(_ numerator: [Run], _ denominator: [Run], style: Style) -> [Run] {
            let top = numerator.map(\.text).joined()
            let bottom = denominator.map(\.text).joined()
            let flat = numerator.allSatisfy { $0.style == style } && denominator.allSatisfy { $0.style == style }
            if style == .normal, flat, top.count <= 3, bottom.count <= 3 {
                return [Run(text: top, style: .superscripted), Run(text: "⁄", style: .normal),
                        Run(text: bottom, style: .subscripted)]
            }
            func wrap(_ runs: [Run], _ text: String) -> [Run] {
                let atomic = text.count <= 1 || text.allSatisfy { $0.isLetter || $0.isNumber }
                return atomic ? runs : [Run(text: "(", style: style)] + runs + [Run(text: ")", style: style)]
            }
            return wrap(numerator, top) + [Run(text: "/", style: style)] + wrap(denominator, bottom)
        }
    }
}
