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
        text.contains("_") || text.contains("^") || text.contains("\\") || text.contains("$") || text.contains("``")
    }

    /// Accent de LaTeX → accent combinant Unicode.
    static let accentMarks: [String: String] = [
        "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "\"": "\u{0308}",
        "~": "\u{0303}", "c": "\u{0327}", "H": "\u{030B}", "v": "\u{030C}"
    ]

    /// ``guillemets'' de LaTeX → « “ ” ». Seulement après un ``, pour ne pas
    /// toucher la dérivée seconde f''(x).
    static func typographicQuotes(_ source: String) -> String {
        guard source.contains("``") else { return source }
        var result = ""
        var rest = Substring(source)
        while let open = rest.range(of: "``") {
            result += rest[..<open.lowerBound] + "“"
            rest = rest[open.upperBound...]
            if let close = rest.range(of: "''") {
                result += rest[..<close.lowerBound] + "”"
                rest = rest[close.upperBound...]
            }
        }
        return result + rest
    }

    static func runs(_ source: String) -> [Run] {
        var parser = Parser(Array(typographicQuotes(source).replacingOccurrences(of: "$", with: "")))
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
        "RR": "ℝ", "CC": "ℂ", "NN": "ℕ", "ZZ": "ℤ", "QQ": "ℚ",
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
            // `\mathsf{i}` (l'unité imaginaire des séries d'analyse) sortait « mathsfi ».
            case "mathrm", "mathbf", "mathit", "text", "textrm", "operatorname", "mathcal", "boldsymbol",
                 "mathsf", "mathtt", "mathscr", "mathfrak", "textbf", "textit", "textsf", "texttt", "emph", "mbox", "hbox", "pmb":
                return argument(style: style)
            case "overline", "bar":
                return argument(style: style).map { Run(text: $0.text + "\u{0305}", style: $0.style) }
            // Les accents de LaTeX : `\'e`, `\'{e}`, `\`a`, `\^o`, `\"u`, `\c{c}`.
            // Ils sortaient tels quels — « 'e », « ^o » — dans un énoncé ou un
            // titre lu par le modèle : l'accent était là, mais à côté de la lettre.
            case "'", "`", "^", "\"", "~", "c", "H", "v":
                guard let mark = MathMarkup.accentMarks[command] else { return [] }
                let isCommand = !atEnd && chars[index] == "\\"
                let body = argument(style: style)
                // `\"\i ve` : l'espace qui termine `\i` n'est pas du texte.
                if isCommand, !atEnd, chars[index] == " " { index += 1 }
                guard let first = body.first, let letter = first.text.first else { return body }
                let accented = (String(letter) + mark).precomposedStringWithCanonicalMapping
                return [Run(text: accented + first.text.dropFirst(), style: first.style)] + body.dropFirst()
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

// MARK: - TeX pour la mise en page native

/// Le TeX des sites (MathJax, KaTeX : Courseware, Moodle, Ed, Botafogo) → le
/// TeX que le moteur de formules natif (SwiftMath) sait mettre en page.
///
/// Ce moteur ne connaît pas tout : `\dfrac`, `\operatorname`, l'environnement
/// `array`, `\mathscr`… y échouaient, et il **efface** en silence les symboles
/// Unicode (`≤`, `ℝ`). On traduit ce qui a un équivalent ; s'il reste un
/// caractère qu'il effacerait, `nil` : la formule garde l'affichage en ligne
/// (`MathMarkup`), lisible à défaut d'être mise en page. Pur, testé.
enum TeXNormalizer {

    static func normalize(_ source: String) -> String? {
        var text = source
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        text = environments(text)
        text = commands(text)
        text = unicode(text)
        // Un moins en tête de case (`& -1`) : le moteur l'espace comme une
        // soustraction (« − 1 ») ; rapproché, il se lit comme en LaTeX.
        text = text.replacingOccurrences(of: #"(&|\\\\|\\begin\{[a-zA-Z*]+\})(\s*)-(?!\\!)"#, with: #"$1$2-\\!\\!"#, options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { $0.value > 0xFF }) else { return nil }
        return trimmed
    }

    // MARK: Environnements

    private static func environments(_ source: String) -> String {
        var text = source
        // `array` : une matrice dont on ignore l'alignement des colonnes.
        text = text.replacingOccurrences(of: #"\\begin\{array\}\s*(\[[a-z]\])?\s*\{[^{}]*\}"#, with: #"\\begin{matrix}"#, options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\begin\{alignat\*?\}\s*\{\d+\}"#, with: #"\\begin{aligned}"#, options: .regularExpression)
        let renamed: [String: String?] = [
            "array": "matrix", "smallmatrix": "matrix",
            "align": "aligned", "align*": "aligned", "flalign": "aligned", "flalign*": "aligned",
            "eqnarray": "aligned", "eqnarray*": "aligned", "alignat": "aligned", "alignat*": "aligned", "alignedat": "aligned",
            "gather*": "gather", "multline": "gather", "multline*": "gather", "gathered": "gather",
            "dcases": "cases", "rcases": "cases",
            // Un seul bloc de formule : l'environnement n'ajoute que le numéro.
            "equation": nil, "equation*": nil, "displaymath": nil, "math": nil
        ]
        for (name, replacement) in renamed {
            for side in ["begin", "end"] {
                let tag = "\\\(side){\(name)}"
                text = text.replacingOccurrences(of: tag, with: replacement.map { "\\\(side){\($0)}" } ?? " ")
            }
        }
        return text
    }

    // MARK: Commandes

    /// Commande → son équivalent (sans la barre oblique de tête, sauf mention).
    static let renamed: [String: String] = [
        "dfrac": "\\frac", "tfrac": "\\frac", "cfrac": "\\frac",
        "mathscr": "\\mathcal", "boldsymbol": "\\mathbf", "pmb": "\\mathbf", "mathbold": "\\mathbf",
        "operatorname": "\\mathrm", "mathop": "\\mathrm",
        "textnormal": "\\text", "textup": "\\text", "mbox": "\\text", "hbox": "\\text", "textmd": "\\text",
        "overrightarrow": "\\vec", "overleftarrow": "\\vec", "overline": "\\overline",
        "varnothing": "\\emptyset", "leqslant": "\\leq", "geqslant": "\\geq",
        "lvert": "|", "rvert": "|", "lVert": "\\Vert", "rVert": "\\Vert",
        "implies": "\\Longrightarrow", "impliedby": "\\Longleftarrow",
        "intercal": "\\top", "transpose": "\\top",
        "bmod": "\\mathrm{mod}", "dots": "\\ldots", "dotsc": "\\ldots", "dotsb": "\\cdots", "dotsm": "\\cdots", "dotso": "\\ldots",
        "hookrightarrow": "\\rightarrow", "xrightarrow": "\\longrightarrow", "xleftarrow": "\\longleftarrow",
        "smallsetminus": "\\setminus", "hline": "",
        "lbrack": "[", "rbrack": "]", "lparen": "(", "rparen": ")",
        "R": "\\mathbb{R}", "N": "\\mathbb{N}", "Z": "\\mathbb{Z}", "Q": "\\mathbb{Q}", "C": "\\mathbb{C}",
        "bR": "\\mathbb{R}", "bC": "\\mathbb{C}", "bN": "\\mathbb{N}", "bZ": "\\mathbb{Z}", "bQ": "\\mathbb{Q}",
        "enspace": "\\quad", "thinspace": "\\,", "medspace": "\\;", "thickspace": "\\;",
        "bigl": "", "bigr": "", "Bigl": "", "Bigr": "", "biggl": "", "biggr": "", "Biggl": "", "Biggr": "",
        "big": "", "Big": "", "bigg": "", "Bigg": "", "bigm": "", "Bigm": "",
        "nonumber": "", "notag": "", "nolimits": "", "ensuremath": "", "boxed": "",
        "overbrace": "", "underbrace": "", "displaylimits": "", "middle": ""
    ]

    /// Commandes dont l'argument n'a pas d'équivalent affichable : retirées avec lui.
    static let droppedWithArgument: Set<String> = ["label", "tag", "cline", "vspace", "phantom", "hphantom", "vphantom", "ref", "eqref"]

    private static func commands(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        var i = 0
        func skipSpaces() { while i < chars.count, chars[i] == " " { i += 1 } }
        /// L'argument entre accolades qui suit (sans les accolades), et avance après lui.
        func readGroup() -> String? {
            skipSpaces()
            guard i < chars.count, chars[i] == "{" else { return nil }
            var depth = 0
            let start = i
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1; if depth == 0 { i += 1; return String(chars[(start + 1)..<(i - 1)]) } }
                i += 1
            }
            return String(chars[(start + 1)...])
        }
        while i < chars.count {
            let char = chars[i]
            guard char == "\\", i + 1 < chars.count, chars[i + 1].isLetter else {
                // `\\`, `\{`, `\,` : recopiés tels quels, par deux.
                if char == "\\", i + 1 < chars.count { out.append(char); out.append(chars[i + 1]); i += 2; continue }
                out.append(char); i += 1; continue
            }
            var j = i + 1
            while j < chars.count, chars[j].isLetter { j += 1 }
            let name = String(chars[(i + 1)..<j])
            i = j
            if i < chars.count, chars[i] == "*", ["operatorname", "tag", "hspace", "vspace"].contains(name) { i += 1 }
            if droppedWithArgument.contains(name) {
                _ = readGroup()
            } else if name == "hspace" {
                _ = readGroup()
                out += "\\quad "
            } else if name == "dfrac", let top = readGroup(), let bottom = readGroup() {
                // La fraction « de display » au milieu d'une phrase reste grande.
                out += "{\\displaystyle\\frac{" + commands(top) + "}{" + commands(bottom) + "}}"
            } else if name == "pmod" {
                out += "\\quad(\\mathrm{mod}\\ " + commands(readGroup() ?? "") + ")"
            } else if let replacement = renamed[name] {
                out += replacement
                // Ne pas coller la commande suivante à des lettres : `\R x` → `\mathbb{R} x`.
                if replacement.last?.isLetter == true, i < chars.count, chars[i].isLetter { out += " " }
            } else {
                out += "\\" + name
            }
        }
        return out
    }

    // MARK: Unicode

    /// Les symboles qu'un texte copié (ou Ed) met dans une formule.
    static let unicodeCommands: [Character: String] = {
        var map: [Character: String] = [
            "ℝ": "\\mathbb{R}", "ℂ": "\\mathbb{C}", "ℕ": "\\mathbb{N}", "ℤ": "\\mathbb{Z}", "ℚ": "\\mathbb{Q}",
            "−": "-", "–": "-", "′": "'", "″": "''", "⩽": "\\leq", "⩾": "\\geq", "‖": "\\Vert", "∣": "\\mid",
            "≤": "\\leq", "≥": "\\geq", "≠": "\\neq", "≈": "\\approx", "≡": "\\equiv", "∼": "\\sim", "≃": "\\simeq", "≅": "\\cong",
            "∈": "\\in", "∉": "\\notin", "∋": "\\ni", "⊂": "\\subset", "⊆": "\\subseteq", "⊃": "\\supset", "⊇": "\\supseteq",
            "∪": "\\cup", "∩": "\\cap", "∅": "\\emptyset", "∀": "\\forall", "∃": "\\exists", "¬": "\\neg", "∧": "\\wedge", "∨": "\\vee",
            "→": "\\to", "←": "\\leftarrow", "↦": "\\mapsto", "⇒": "\\Rightarrow", "⇐": "\\Leftarrow", "⇔": "\\Leftrightarrow",
            "⟶": "\\longrightarrow", "⟹": "\\Longrightarrow", "⟺": "\\Longleftrightarrow", "↔": "\\leftrightarrow",
            "×": "\\times", "·": "\\cdot", "⋅": "\\cdot", "÷": "\\div", "±": "\\pm", "∓": "\\mp", "∘": "\\circ", "⊗": "\\otimes", "⊕": "\\oplus",
            "∞": "\\infty", "∑": "\\sum", "∏": "\\prod", "∫": "\\int", "∮": "\\oint", "∂": "\\partial", "∇": "\\nabla", "√": "\\sqrt",
            "…": "\\ldots", "⋯": "\\cdots", "⋮": "\\vdots", "⋱": "\\ddots", "ℓ": "\\ell", "⊥": "\\perp", "∖": "\\setminus",
            "⟨": "\\langle", "⟩": "\\rangle", "⌊": "\\lfloor", "⌋": "\\rfloor", "⌈": "\\lceil", "⌉": "\\rceil", "°": "^\\circ",
            "α": "\\alpha", "β": "\\beta", "γ": "\\gamma", "δ": "\\delta", "ε": "\\varepsilon", "ϵ": "\\epsilon", "ζ": "\\zeta",
            "η": "\\eta", "θ": "\\theta", "ϑ": "\\vartheta", "ι": "\\iota", "κ": "\\kappa", "λ": "\\lambda", "μ": "\\mu", "ν": "\\nu",
            "ξ": "\\xi", "π": "\\pi", "ρ": "\\rho", "σ": "\\sigma", "τ": "\\tau", "υ": "\\upsilon", "φ": "\\varphi", "ϕ": "\\phi",
            "χ": "\\chi", "ψ": "\\psi", "ω": "\\omega", "Γ": "\\Gamma", "Δ": "\\Delta", "Θ": "\\Theta", "Λ": "\\Lambda", "Ξ": "\\Xi",
            "Π": "\\Pi", "Σ": "\\Sigma", "Φ": "\\Phi", "Ψ": "\\Psi", "Ω": "\\Omega"
        ]
        map["\u{2009}"] = "\\,"
        map["\u{202F}"] = "\\,"
        return map
    }()

    private static func unicode(_ source: String) -> String {
        guard source.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return source }
        var out = ""
        let chars = Array(source)
        for (index, char) in chars.enumerated() {
            if let command = unicodeCommands[char] {
                out += command
                // `αx` → `\alpha x`, pas `\alphax`.
                if command.last?.isLetter == true, index + 1 < chars.count, chars[index + 1].isLetter { out += " " }
            } else {
                out.append(char)
            }
        }
        return out
    }
}
