import Foundation

/// La calculatrice du mode étude : ce qu'on demandait à GeoGebra ou à un site
/// de calcul, dans l'app — et **pur**, donc testé (`validate.sh`).
///
/// On tape comme sur papier : `2x^2 - 3x + 1`, `sin(pi/6)`, `5!`, `sqrt 2`
/// n'est pas accepté (il faut des parenthèses), mais la multiplication
/// implicite l'est (`2x`, `3(x+1)`, `(x-1)(x+1)`, `2pi`). On peut nommer :
/// `a = 3`, `f(x) = x^2 - a`, puis `f(2)`, `f'(1)` (dérivée numérique),
/// `int(f, 0, 1)` (intégrale de Simpson), `root(f, 0, 2)` (une racine par
/// dichotomie). Les fonctions définies se tracent (`MathEngine.sample`).
enum MathEngine {

    // MARK: Arbre

    indirect enum Node: Equatable {
        case number(Double)
        case variable(String)
        case negate(Node)
        case binary(Character, Node, Node)
        case factorial(Node)
        case call(String, [Node])
        /// `f'(x)`, `f''(x)` : la dérivée d'ordre `order` d'une fonction nommée.
        case derivative(String, order: Int, Node)
    }

    /// Une ligne de la calculatrice.
    enum Statement: Equatable {
        case expression(Node)
        case assignment(String, Node)
        case function(String, [String], Node)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case syntax(String)
        case unknownName(String)
        case arity(String)
        case domain(String)

        var errorDescription: String? {
            switch self {
            case .syntax(let detail): return "Écriture incomprise : \(detail)"
            case .unknownName(let name): return "« \(name) » n'est pas défini"
            case .arity(let name): return "\(name) : mauvais nombre d'arguments"
            case .domain(let detail): return detail
            }
        }
    }

    // MARK: Environnement

    struct Environment {
        var variables: [String: Double] = [:]
        var functions: [String: (parameters: [String], body: Node)] = [:]
        /// Les fonctions trigonométriques en degrés.
        var degrees = false

        init() {}

        /// Applique une ligne : rend la valeur calculée, ou `nil` pour une
        /// définition de fonction.
        mutating func run(_ line: String) throws -> Double? {
            switch try MathEngine.parse(line) {
            case .expression(let node):
                let value = try MathEngine.evaluate(node, in: self)
                variables["ans"] = value
                return value
            case .assignment(let name, let node):
                guard !MathEngine.isReserved(name) else { throw Failure.syntax("« \(name) » est réservé") }
                let value = try MathEngine.evaluate(node, in: self)
                variables[name] = value
                return value
            case .function(let name, let parameters, let body):
                guard !MathEngine.isReserved(name) else { throw Failure.syntax("« \(name) » est réservé") }
                functions[name] = (parameters, body)
                return nil
            }
        }
    }

    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi, "phi": (1 + sqrt(5)) / 2]
    static let builtins: Set<String> = [
        "sin", "cos", "tan", "asin", "acos", "atan", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "exp", "ln", "log", "log2", "sqrt", "cbrt", "abs", "floor", "ceil", "round", "sign",
        "min", "max", "binom", "int", "root", "atan2", "mod",
    ]

    static func isReserved(_ name: String) -> Bool {
        constants[name] != nil || builtins.contains(name)
    }

    // MARK: Lecture

    static func parse(_ line: String) throws -> Statement {
        var parser = Parser(tokens: try tokenize(line))
        return try parser.statement()
    }

    static func parseExpression(_ text: String) throws -> Node {
        var parser = Parser(tokens: try tokenize(text))
        let node = try parser.expression()
        guard parser.atEnd else { throw Failure.syntax("fin inattendue") }
        return node
    }

    enum Token: Equatable {
        case number(Double)
        case name(String)
        case symbol(Character)
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "³", with: "^3").replacingOccurrences(of: "√", with: "sqrt"))
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace { index += 1; continue }
            if c.isNumber || (c == "." && index + 1 < chars.count && chars[index + 1].isNumber) {
                var end = index
                while end < chars.count, chars[end].isNumber || chars[end] == "." { end += 1 }
                // Notation scientifique : 1e-3 (mais pas « 2e » = 2·e).
                if end < chars.count, chars[end] == "e" || chars[end] == "E" {
                    var look = end + 1
                    if look < chars.count, chars[look] == "-" || chars[look] == "+" { look += 1 }
                    if look < chars.count, chars[look].isNumber {
                        end = look
                        while end < chars.count, chars[end].isNumber { end += 1 }
                    }
                }
                guard let value = Double(String(chars[index..<end])) else { throw Failure.syntax(String(chars[index..<end])) }
                tokens.append(.number(value))
                index = end
            } else if c.isLetter || c == "π" {
                var end = index
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
                tokens.append(.name(String(chars[index..<end])))
                index = end
            } else if "+-*/^()!,;='".contains(c) {
                tokens.append(.symbol(c == ";" ? "," : c))
                index += 1
            } else {
                throw Failure.syntax("caractère « \(c) »")
            }
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0

        var atEnd: Bool { position >= tokens.count }
        var current: Token? { atEnd ? nil : tokens[position] }

        mutating func eat(_ symbol: Character) -> Bool {
            if current == .symbol(symbol) { position += 1; return true }
            return false
        }

        mutating func expect(_ symbol: Character) throws {
            guard eat(symbol) else { throw Failure.syntax("« \(symbol) » attendu") }
        }

        mutating func statement() throws -> Statement {
            // `f(x, y) = …` ou `a = …`
            if case .name(let name)? = current, let equal = tokens.firstIndex(of: .symbol("=")) {
                if equal == position + 1 {
                    position += 2
                    let body = try expression()
                    guard atEnd else { throw Failure.syntax("fin inattendue") }
                    return .assignment(name, body)
                }
                if position + 1 < tokens.count, tokens[position + 1] == .symbol("(") {
                    var parameters: [String] = []
                    var cursor = position + 2
                    while cursor < equal, case .name(let parameter) = tokens[cursor] {
                        parameters.append(parameter)
                        cursor += 1
                        if tokens[cursor] == .symbol(",") { cursor += 1 }
                    }
                    if cursor == equal - 1, tokens[cursor] == .symbol(")"), !parameters.isEmpty {
                        position = equal + 1
                        let body = try expression()
                        guard atEnd else { throw Failure.syntax("fin inattendue") }
                        return .function(name, parameters, body)
                    }
                }
                throw Failure.syntax("« = » mal placé")
            }
            let node = try expression()
            guard atEnd else { throw Failure.syntax("fin inattendue") }
            return .expression(node)
        }

        mutating func expression() throws -> Node {
            var node = try term()
            while true {
                if eat("+") { node = .binary("+", node, try term()) }
                else if eat("-") { node = .binary("-", node, try term()) }
                else { return node }
            }
        }

        mutating func term() throws -> Node {
            var node = try unary()
            while true {
                if eat("*") { node = .binary("*", node, try unary()) }
                else if eat("/") { node = .binary("/", node, try unary()) }
                else if startsOperand { node = .binary("*", node, try power()) } // multiplication implicite
                else { return node }
            }
        }

        /// Ce qui suit peut-il commencer un facteur (multiplication implicite) ?
        var startsOperand: Bool {
            switch current {
            case .number?, .name?: return true
            case .symbol("(")?: return true
            default: return false
            }
        }

        mutating func unary() throws -> Node {
            if eat("-") { return .negate(try unary()) }
            if eat("+") { return try unary() }
            return try power()
        }

        mutating func power() throws -> Node {
            let base = try postfix()
            if eat("^") { return .binary("^", base, try unary()) } // à droite : 2^3^2 = 2^9
            return base
        }

        mutating func postfix() throws -> Node {
            var node = try primary()
            while eat("!") { node = .factorial(node) }
            return node
        }

        mutating func primary() throws -> Node {
            switch current {
            case .number(let value)?:
                position += 1
                return .number(value)
            case .name(let name)?:
                position += 1
                var order = 0
                while eat("'") { order += 1 }
                if eat("(") {
                    var arguments: [Node] = []
                    if !eat(")") {
                        repeat { arguments.append(try expression()) } while eat(",")
                        try expect(")")
                    }
                    if order > 0 {
                        guard arguments.count == 1 else { throw Failure.arity(name) }
                        return .derivative(name, order: order, arguments[0])
                    }
                    return .call(name, arguments)
                }
                guard order == 0 else { throw Failure.syntax("« \(name)' » sans argument") }
                return .variable(name)
            case .symbol("(")?:
                position += 1
                let inner = try expression()
                try expect(")")
                return inner
            case nil:
                throw Failure.syntax("expression incomplète")
            case .symbol(let symbol)?:
                throw Failure.syntax("« \(symbol) » inattendu")
            }
        }
    }

    // MARK: Calcul

    static func evaluate(_ node: Node, in environment: Environment, locals: [String: Double] = [:]) throws -> Double {
        func eval(_ node: Node) throws -> Double { try evaluate(node, in: environment, locals: locals) }
        switch node {
        case .number(let value):
            return value
        case .variable(let name):
            if let value = locals[name] ?? environment.variables[name] ?? constants[name] { return value }
            throw Failure.unknownName(name)
        case .negate(let inner):
            return -(try eval(inner))
        case .binary(let op, let left, let right):
            let a = try eval(left), b = try eval(right)
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/":
                guard b != 0 else { throw Failure.domain("division par zéro") }
                return a / b
            default: return pow(a, b)
            }
        case .factorial(let inner):
            let n = try eval(inner)
            guard n >= 0, n == n.rounded(), n <= 170 else { throw Failure.domain("factorielle d'un entier positif seulement") }
            return n == 0 ? 1 : (1...Int(n)).reduce(1.0) { $0 * Double($1) }
        case .derivative(let name, let order, let argument):
            let x = try eval(argument)
            return try derivative(of: name, order: order, at: x, in: environment)
        case .call(let name, let arguments):
            if let function = environment.functions[name] {
                guard function.parameters.count == arguments.count else { throw Failure.arity(name) }
                var inner = locals
                for (parameter, argument) in zip(function.parameters, arguments) { inner[parameter] = try eval(argument) }
                return try evaluate(function.body, in: environment, locals: inner)
            }
            // `x(x+1)`, `a(b+c)` : un nombre devant une parenthèse, pas un appel.
            if !builtins.contains(name), arguments.count == 1,
               let factor = locals[name] ?? environment.variables[name] ?? constants[name] {
                return factor * (try eval(arguments[0]))
            }
            return try builtin(name, arguments, environment: environment, locals: locals)
        }
    }

    private static func builtin(_ name: String, _ arguments: [Node], environment: Environment,
                                locals: [String: Double]) throws -> Double {
        func value(_ index: Int) throws -> Double { try evaluate(arguments[index], in: environment, locals: locals) }
        let angle: (Double) -> Double = { environment.degrees ? $0 * .pi / 180 : $0 }
        let inverse: (Double) -> Double = { environment.degrees ? $0 * 180 / .pi : $0 }
        switch name {
        case "int", "root":
            // `int(f, a, b)` / `root(f, a, b)` : f est une fonction définie.
            guard arguments.count == 3, case .variable(let function) = arguments[0] else { throw Failure.arity(name) }
            let a = try value(1), b = try value(2)
            let f: (Double) throws -> Double = { try call(function, $0, in: environment) }
            return name == "int" ? try simpson(f, a, b) : try bisect(f, a, b)
        case "min", "max":
            guard !arguments.isEmpty else { throw Failure.arity(name) }
            let values = try arguments.indices.map(value)
            return name == "min" ? values.min()! : values.max()!
        case "binom", "atan2", "mod":
            guard arguments.count == 2 else { throw Failure.arity(name) }
            let a = try value(0), b = try value(1)
            if name == "atan2" { return inverse(atan2(a, b)) }
            if name == "mod" {
                guard b != 0 else { throw Failure.domain("modulo zéro") }
                return a - b * (a / b).rounded(.down)
            }
            guard a >= 0, b >= 0, b <= a, a == a.rounded(), b == b.rounded() else { throw Failure.domain("binom(n, k) : 0 ≤ k ≤ n entiers") }
            var result = 1.0
            for i in 0..<Int(min(b, a - b)) { result = result * (a - Double(i)) / Double(i + 1) }
            return result.rounded()
        default:
            break
        }
        guard builtins.contains(name) else { throw Failure.unknownName(name) }
        guard arguments.count == 1 else { throw Failure.arity(name) }
        let x = try value(0)
        switch name {
        case "sin": return sin(angle(x))
        case "cos": return cos(angle(x))
        case "tan": return tan(angle(x))
        case "asin", "arcsin":
            guard abs(x) <= 1 else { throw Failure.domain("arcsin hors de [-1, 1]") }
            return inverse(asin(x))
        case "acos", "arccos":
            guard abs(x) <= 1 else { throw Failure.domain("arccos hors de [-1, 1]") }
            return inverse(acos(x))
        case "atan", "arctan": return inverse(atan(x))
        case "sinh": return sinh(x)
        case "cosh": return cosh(x)
        case "tanh": return tanh(x)
        case "exp": return exp(x)
        case "ln":
            guard x > 0 else { throw Failure.domain("ln d'un nombre ≤ 0") }
            return log(x)
        case "log":
            guard x > 0 else { throw Failure.domain("log d'un nombre ≤ 0") }
            return log10(x)
        case "log2":
            guard x > 0 else { throw Failure.domain("log2 d'un nombre ≤ 0") }
            return log2(x)
        case "sqrt":
            guard x >= 0 else { throw Failure.domain("racine d'un nombre négatif") }
            return x.squareRoot()
        case "cbrt": return cbrt(x)
        case "abs": return abs(x)
        case "floor": return x.rounded(.down)
        case "ceil": return x.rounded(.up)
        case "round": return x.rounded()
        default: return x > 0 ? 1 : (x < 0 ? -1 : 0)
        }
    }

    /// Appelle une fonction définie à une variable.
    static func call(_ name: String, _ x: Double, in environment: Environment) throws -> Double {
        guard let function = environment.functions[name] else { throw Failure.unknownName(name) }
        guard function.parameters.count == 1 else { throw Failure.arity(name) }
        return try evaluate(function.body, in: environment, locals: [function.parameters[0]: x])
    }

    /// Dérivée numérique (différences centrées, pas adapté à l'échelle de x).
    static func derivative(of name: String, order: Int, at x: Double, in environment: Environment) throws -> Double {
        guard order >= 1 else { return try call(name, x, in: environment) }
        let h = order == 1 ? max(1e-5, abs(x) * 1e-5) : max(1e-3, abs(x) * 1e-3)
        if order == 1 {
            return (try call(name, x + h, in: environment) - call(name, x - h, in: environment)) / (2 * h)
        }
        let f = { (t: Double) in try derivative(of: name, order: order - 1, at: t, in: environment) }
        return (try f(x + h) - f(x - h)) / (2 * h)
    }

    /// Intégrale de Simpson composite (2 000 intervalles).
    static func simpson(_ f: (Double) throws -> Double, _ a: Double, _ b: Double, intervals: Int = 2000) throws -> Double {
        let n = intervals % 2 == 0 ? intervals : intervals + 1
        let h = (b - a) / Double(n)
        var sum = try f(a) + f(b)
        for i in 1..<n { sum += Double(i % 2 == 0 ? 2 : 4) * (try f(a + Double(i) * h)) }
        return sum * h / 3
    }

    /// Une racine dans [a, b] par dichotomie (il faut un changement de signe).
    static func bisect(_ f: (Double) throws -> Double, _ a: Double, _ b: Double) throws -> Double {
        var lo = a, hi = b
        var flo = try f(lo)
        let fhi = try f(hi)
        if flo == 0 { return lo }
        if fhi == 0 { return hi }
        guard flo.sign != fhi.sign else { throw Failure.domain("pas de changement de signe entre \(format(a)) et \(format(b))") }
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            let fm = try f(mid)
            if fm == 0 || (hi - lo) / 2 < 1e-13 { return mid }
            if fm.sign == flo.sign { lo = mid; flo = fm } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: Tracé

    struct Point: Equatable, Identifiable {
        var x: Double
        var y: Double
        var id: Double { x }
    }

    /// Des points de la fonction sur [from, to] ; les valeurs indéfinies ou
    /// énormes (asymptotes) sont omises — le tracé s'interrompt.
    static func sample(_ name: String, from: Double, to: Double, count: Int = 400, in environment: Environment) -> [Point] {
        guard to > from, count > 1 else { return [] }
        let step = (to - from) / Double(count - 1)
        return (0..<count).compactMap { i in
            let x = from + Double(i) * step
            guard let y = try? call(name, x, in: environment), y.isFinite, abs(y) < 1e9 else { return nil }
            return Point(x: x, y: y)
        }
    }

    /// Les racines visibles sur [from, to] (changements de signe affinés).
    static func roots(_ name: String, from: Double, to: Double, in environment: Environment) -> [Double] {
        let points = sample(name, from: from, to: to, count: 800, in: environment)
        var found: [Double] = []
        for (a, b) in zip(points, points.dropFirst()) where a.y == 0 || a.y.sign != b.y.sign {
            // Une asymptote change aussi de signe : on garde seulement les vraies racines.
            guard abs(a.y) < 1e3, abs(b.y) < 1e3,
                  let root = try? bisect({ try call(name, $0, in: environment) }, a.x, b.x),
                  let value = try? call(name, root, in: environment), abs(value) < 1e-6 else { continue }
            if found.last.map({ abs($0 - root) > 1e-6 }) ?? true { found.append(root) }
        }
        return found
    }

    // MARK: Affichage

    /// `0.30000000000000004` → `0.3` ; les entiers sans décimales ; la notation
    /// scientifique pour les très grands et très petits nombres.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "indéfini" : (value > 0 ? "∞" : "−∞") }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e12 || magnitude < 1e-6 {
            return String(format: "%.6g", value).replacingOccurrences(of: "e+", with: "·10^").replacingOccurrences(of: "e-", with: "·10^-")
        }
        var text = String(format: "%.10f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
