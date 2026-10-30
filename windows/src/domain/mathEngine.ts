import { characters, isLetter, isNumber, isWhitespace } from "./textRepair.ts";

/// La calculatrice du mode étude : ce qu'on demandait à GeoGebra ou à un site
/// de calcul, dans l'app — et **pur**, donc testé.
///
/// On tape comme sur papier : `2x^2 - 3x + 1`, `sin(pi/6)`, `5!`, `sqrt 2`
/// n'est pas accepté (il faut des parenthèses), mais la multiplication
/// implicite l'est (`2x`, `3(x+1)`, `(x-1)(x+1)`, `2pi`). On peut nommer :
/// `a = 3`, `f(x) = x^2 - a`, puis `f(2)`, `f'(1)` (dérivée numérique),
/// `int(f, 0, 1)` (intégrale de Simpson), `root(f, 0, 2)` (une racine par
/// dichotomie). Les fonctions définies se tracent (`MathEngine.sample`).

// MARK: Arbre

export type MathNode =
  | { kind: "number"; value: number }
  | { kind: "variable"; name: string }
  | { kind: "negate"; inner: MathNode }
  /// `op` est un seul caractère : `+ - * / ^`.
  | { kind: "binary"; op: string; left: MathNode; right: MathNode }
  | { kind: "factorial"; inner: MathNode }
  | { kind: "call"; name: string; args: MathNode[] }
  /// `f'(x)`, `f''(x)` : la dérivée d'ordre `order` d'une fonction nommée.
  | { kind: "derivative"; name: string; order: number; arg: MathNode };

/// Une ligne de la calculatrice.
export type MathStatement =
  | { kind: "expression"; node: MathNode }
  | { kind: "assignment"; name: string; node: MathNode }
  | { kind: "function"; name: string; parameters: string[]; body: MathNode };

export type MathFailureKind = "syntax" | "unknownName" | "arity" | "domain";

/// `MathEngine.Failure` : une erreur de lecture ou de calcul, avec son message en français.
export class MathFailure extends Error {
  readonly kind: MathFailureKind;
  readonly detail: string;

  constructor(kind: MathFailureKind, detail: string) {
    super(MathFailure.describe(kind, detail));
    this.kind = kind;
    this.detail = detail;
  }

  static describe(kind: MathFailureKind, detail: string): string {
    switch (kind) {
      case "syntax": return `Écriture incomprise : ${detail}`;
      case "unknownName": return `« ${detail} » n'est pas défini`;
      case "arity": return `${detail} : mauvais nombre d'arguments`;
      case "domain": return detail;
    }
  }

  get errorDescription(): string { return this.message; }

  static syntax(detail: string): MathFailure { return new MathFailure("syntax", detail); }
  static unknownName(name: string): MathFailure { return new MathFailure("unknownName", name); }
  static arity(name: string): MathFailure { return new MathFailure("arity", name); }
  static domain(detail: string): MathFailure { return new MathFailure("domain", detail); }
}

// MARK: Arithmétique à la C

/// `Double.rounded()` de Swift : au plus proche, les demis en s'éloignant de zéro
/// (`Math.round` arrondit les demis vers +∞).
export function roundAway(x: number): number {
  if (!Number.isFinite(x)) return x;
  const r = Math.round(Math.abs(x));
  return x < 0 ? -r : r;
}

/// `pow` de la libm : `Math.pow` diffère sur `pow(1, ±∞)`, `pow(-1, ±∞)` et `pow(1, NaN)`.
export function pow(a: number, b: number): number {
  if (a === 1) return 1;
  if (a === -1 && (b === Infinity || b === -Infinity)) return 1;
  return Math.pow(a, b);
}

/// `FloatingPointSign` : vrai pour un nombre négatif, `-0` compris.
function isMinus(x: number): boolean {
  return x < 0 || Object.is(x, -0);
}

// MARK: Environnement

export interface MathFunction {
  parameters: string[];
  body: MathNode;
}

/// Un état de calculatrice. Une valeur en Swift (struct) : `copy()` rend un clone indépendant.
export class MathEnvironment {
  variables = new Map<string, number>();
  functions = new Map<string, MathFunction>();
  /// Les fonctions trigonométriques en degrés.
  degrees = false;

  copy(): MathEnvironment {
    const clone = new MathEnvironment();
    clone.variables = new Map(this.variables);
    clone.functions = new Map(this.functions);
    clone.degrees = this.degrees;
    return clone;
  }

  /// Applique une ligne : rend la valeur calculée, ou `null` pour une
  /// définition de fonction.
  run(line: string): number | null {
    const statement = parse(line);
    switch (statement.kind) {
      case "expression": {
        const value = evaluate(statement.node, this);
        this.variables.set("ans", value);
        return value;
      }
      case "assignment": {
        if (isReserved(statement.name)) throw MathFailure.syntax(`« ${statement.name} » est réservé`);
        const value = evaluate(statement.node, this);
        this.variables.set(statement.name, value);
        return value;
      }
      case "function":
        if (isReserved(statement.name)) throw MathFailure.syntax(`« ${statement.name} » est réservé`);
        this.functions.set(statement.name, { parameters: statement.parameters, body: statement.body });
        return null;
    }
  }
}

export const constants = new Map<string, number>([
  ["pi", Math.PI], ["π", Math.PI], ["e", Math.E], ["tau", 2 * Math.PI], ["phi", (1 + Math.sqrt(5)) / 2],
]);
export const builtins = new Set<string>([
  "sin", "cos", "tan", "asin", "acos", "atan", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
  "exp", "ln", "log", "log2", "sqrt", "cbrt", "abs", "floor", "ceil", "round", "sign",
  "min", "max", "binom", "int", "root", "atan2", "mod",
]);

export function isReserved(name: string): boolean {
  return constants.has(name) || builtins.has(name);
}

// MARK: Lecture

export function parse(line: string): MathStatement {
  const parser = new Parser(tokenize(line));
  return parser.statement();
}

export function parseExpression(text: string): MathNode {
  const parser = new Parser(tokenize(text));
  const node = parser.expression();
  if (!parser.atEnd) throw MathFailure.syntax("fin inattendue");
  return node;
}

export type MathToken =
  | { kind: "number"; value: number }
  | { kind: "name"; value: string }
  | { kind: "symbol"; value: string };

/// `Double(String)` de Swift : `null` plutôt que NaN quand le texte n'est pas un nombre.
export function parseDouble(text: string): number | null {
  if (text === "") return null;
  const value = Number(text);
  return Number.isNaN(value) ? null : value;
}

function replaceAll(text: string, from: string, to: string): string {
  return text.split(from).join(to);
}

export function tokenize(text: string): MathToken[] {
  const tokens: MathToken[] = [];
  let source = text;
  for (const [from, to] of [["×", "*"], ["÷", "/"], ["−", "-"], ["²", "^2"], ["³", "^3"], ["√", "sqrt"]]) {
    source = replaceAll(source, from, to);
  }
  const chars = characters(source);
  let index = 0;
  while (index < chars.length) {
    const c = chars[index];
    if (isWhitespace(c)) { index += 1; continue; }
    if (isNumber(c) || (c === "." && index + 1 < chars.length && isNumber(chars[index + 1]))) {
      let end = index;
      while (end < chars.length && (isNumber(chars[end]) || chars[end] === ".")) end += 1;
      // Notation scientifique : 1e-3 (mais pas « 2e » = 2·e).
      if (end < chars.length && (chars[end] === "e" || chars[end] === "E")) {
        let look = end + 1;
        if (look < chars.length && (chars[look] === "-" || chars[look] === "+")) look += 1;
        if (look < chars.length && isNumber(chars[look])) {
          end = look;
          while (end < chars.length && isNumber(chars[end])) end += 1;
        }
      }
      const literal = chars.slice(index, end).join("");
      const value = parseDouble(literal);
      if (value === null) throw MathFailure.syntax(literal);
      tokens.push({ kind: "number", value });
      index = end;
    } else if (isLetter(c) || c === "π") {
      let end = index;
      while (end < chars.length && (isLetter(chars[end]) || isNumber(chars[end]) || chars[end] === "_")) end += 1;
      tokens.push({ kind: "name", value: chars.slice(index, end).join("") });
      index = end;
    } else if ("+-*/^()!,;='".includes(c)) {
      tokens.push({ kind: "symbol", value: c === ";" ? "," : c });
      index += 1;
    } else {
      throw MathFailure.syntax(`caractère « ${c} »`);
    }
  }
  return tokens;
}

function isSymbol(token: MathToken | undefined, symbol: string): boolean {
  return token !== undefined && token.kind === "symbol" && token.value === symbol;
}

class Parser {
  position = 0;

  constructor(readonly tokens: MathToken[]) {}

  get atEnd(): boolean { return this.position >= this.tokens.length; }
  get current(): MathToken | undefined { return this.atEnd ? undefined : this.tokens[this.position]; }

  eat(symbol: string): boolean {
    if (isSymbol(this.current, symbol)) { this.position += 1; return true; }
    return false;
  }

  expect(symbol: string): void {
    if (!this.eat(symbol)) throw MathFailure.syntax(`« ${symbol} » attendu`);
  }

  statement(): MathStatement {
    // `f(x, y) = …` ou `a = …`
    const first = this.current;
    const equal = this.tokens.findIndex((t) => isSymbol(t, "="));
    if (first !== undefined && first.kind === "name" && equal >= 0) {
      const name = first.value;
      if (equal === this.position + 1) {
        this.position += 2;
        const body = this.expression();
        if (!this.atEnd) throw MathFailure.syntax("fin inattendue");
        return { kind: "assignment", name, node: body };
      }
      if (this.position + 1 < this.tokens.length && isSymbol(this.tokens[this.position + 1], "(")) {
        const parameters: string[] = [];
        let cursor = this.position + 2;
        while (cursor < equal && this.tokens[cursor].kind === "name") {
          parameters.push((this.tokens[cursor] as { value: string }).value);
          cursor += 1;
          if (isSymbol(this.tokens[cursor], ",")) cursor += 1;
        }
        if (cursor === equal - 1 && isSymbol(this.tokens[cursor], ")") && parameters.length > 0) {
          this.position = equal + 1;
          const body = this.expression();
          if (!this.atEnd) throw MathFailure.syntax("fin inattendue");
          return { kind: "function", name, parameters, body };
        }
      }
      throw MathFailure.syntax("« = » mal placé");
    }
    const node = this.expression();
    if (!this.atEnd) throw MathFailure.syntax("fin inattendue");
    return { kind: "expression", node };
  }

  expression(): MathNode {
    let node = this.term();
    for (;;) {
      if (this.eat("+")) node = { kind: "binary", op: "+", left: node, right: this.term() };
      else if (this.eat("-")) node = { kind: "binary", op: "-", left: node, right: this.term() };
      else return node;
    }
  }

  term(): MathNode {
    let node = this.unary();
    for (;;) {
      if (this.eat("*")) node = { kind: "binary", op: "*", left: node, right: this.unary() };
      else if (this.eat("/")) node = { kind: "binary", op: "/", left: node, right: this.unary() };
      else if (this.startsOperand) node = { kind: "binary", op: "*", left: node, right: this.power() }; // multiplication implicite
      else return node;
    }
  }

  /// Ce qui suit peut-il commencer un facteur (multiplication implicite) ?
  get startsOperand(): boolean {
    const token = this.current;
    if (token === undefined) return false;
    return token.kind === "number" || token.kind === "name" || isSymbol(token, "(");
  }

  unary(): MathNode {
    if (this.eat("-")) return { kind: "negate", inner: this.unary() };
    if (this.eat("+")) return this.unary();
    return this.power();
  }

  power(): MathNode {
    const base = this.postfix();
    if (this.eat("^")) return { kind: "binary", op: "^", left: base, right: this.unary() }; // à droite : 2^3^2 = 2^9
    return base;
  }

  postfix(): MathNode {
    let node = this.primary();
    while (this.eat("!")) node = { kind: "factorial", inner: node };
    return node;
  }

  primary(): MathNode {
    const token = this.current;
    if (token === undefined) throw MathFailure.syntax("expression incomplète");
    if (token.kind === "number") {
      this.position += 1;
      return { kind: "number", value: token.value };
    }
    if (token.kind === "name") {
      const name = token.value;
      this.position += 1;
      let order = 0;
      while (this.eat("'")) order += 1;
      if (this.eat("(")) {
        const args: MathNode[] = [];
        if (!this.eat(")")) {
          do { args.push(this.expression()); } while (this.eat(","));
          this.expect(")");
        }
        if (order > 0) {
          if (args.length !== 1) throw MathFailure.arity(name);
          return { kind: "derivative", name, order, arg: args[0] };
        }
        return { kind: "call", name, args };
      }
      if (order !== 0) throw MathFailure.syntax(`« ${name}' » sans argument`);
      return { kind: "variable", name };
    }
    if (token.value === "(") {
      this.position += 1;
      const inner = this.expression();
      this.expect(")");
      return inner;
    }
    throw MathFailure.syntax(`« ${token.value} » inattendu`);
  }
}

// MARK: Calcul

/// `locals[name] ?? variables[name] ?? constants[name]`.
function lookup(name: string, environment: MathEnvironment, locals: Map<string, number>): number | undefined {
  return locals.get(name) ?? environment.variables.get(name) ?? constants.get(name);
}

export function evaluate(node: MathNode, environment: MathEnvironment, locals: Map<string, number> = new Map()): number {
  const ev = (n: MathNode) => evaluate(n, environment, locals);
  switch (node.kind) {
    case "number":
      return node.value;
    case "variable": {
      const value = lookup(node.name, environment, locals);
      if (value !== undefined) return value;
      throw MathFailure.unknownName(node.name);
    }
    case "negate":
      return -ev(node.inner);
    case "binary": {
      const a = ev(node.left), b = ev(node.right);
      switch (node.op) {
        case "+": return a + b;
        case "-": return a - b;
        case "*": return a * b;
        case "/":
          if (b === 0) throw MathFailure.domain("division par zéro");
          return a / b;
        default: return pow(a, b);
      }
    }
    case "factorial": {
      const n = ev(node.inner);
      if (!(n >= 0 && n === roundAway(n) && n <= 170)) throw MathFailure.domain("factorielle d'un entier positif seulement");
      let result = 1;
      for (let i = 1; i <= n; i++) result *= i;
      return result;
    }
    case "derivative": {
      const x = ev(node.arg);
      return derivative(node.name, node.order, x, environment);
    }
    case "call": {
      const fn = environment.functions.get(node.name);
      if (fn) {
        if (fn.parameters.length !== node.args.length) throw MathFailure.arity(node.name);
        const inner = new Map(locals);
        fn.parameters.forEach((parameter, i) => inner.set(parameter, ev(node.args[i])));
        return evaluate(fn.body, environment, inner);
      }
      // `x(x+1)`, `a(b+c)` : un nombre devant une parenthèse, pas un appel.
      if (!builtins.has(node.name) && node.args.length === 1) {
        const factor = lookup(node.name, environment, locals);
        if (factor !== undefined) return factor * ev(node.args[0]);
      }
      return builtin(node.name, node.args, environment, locals);
    }
  }
}

function builtin(name: string, args: MathNode[], environment: MathEnvironment, locals: Map<string, number>): number {
  const value = (index: number) => evaluate(args[index], environment, locals);
  const angle = (x: number) => (environment.degrees ? (x * Math.PI) / 180 : x);
  const inverse = (x: number) => (environment.degrees ? (x * 180) / Math.PI : x);
  switch (name) {
    case "int":
    case "root": {
      // `int(f, a, b)` / `root(f, a, b)` : f est une fonction définie.
      const target = args[0];
      if (args.length !== 3 || target.kind !== "variable") throw MathFailure.arity(name);
      const a = value(1), b = value(2);
      const f = (x: number) => call(target.name, x, environment);
      return name === "int" ? simpson(f, a, b) : bisect(f, a, b);
    }
    case "min":
    case "max": {
      if (args.length === 0) throw MathFailure.arity(name);
      const values = args.map((_, i) => value(i));
      let result = values[0];
      for (const v of values.slice(1)) {
        if (name === "min" ? v < result : result < v) result = v;
      }
      return result;
    }
    case "binom":
    case "atan2":
    case "mod": {
      if (args.length !== 2) throw MathFailure.arity(name);
      const a = value(0), b = value(1);
      if (name === "atan2") return inverse(Math.atan2(a, b));
      if (name === "mod") {
        if (b === 0) throw MathFailure.domain("modulo zéro");
        return a - b * Math.floor(a / b);
      }
      if (!(a >= 0 && b >= 0 && b <= a && a === roundAway(a) && b === roundAway(b))) {
        throw MathFailure.domain("binom(n, k) : 0 ≤ k ≤ n entiers");
      }
      let result = 1;
      const steps = Math.trunc(Math.min(b, a - b));
      for (let i = 0; i < steps; i++) result = (result * (a - i)) / (i + 1);
      return roundAway(result);
    }
    default:
      break;
  }
  if (!builtins.has(name)) throw MathFailure.unknownName(name);
  if (args.length !== 1) throw MathFailure.arity(name);
  const x = value(0);
  switch (name) {
    case "sin": return Math.sin(angle(x));
    case "cos": return Math.cos(angle(x));
    case "tan": return Math.tan(angle(x));
    case "asin":
    case "arcsin":
      if (!(Math.abs(x) <= 1)) throw MathFailure.domain("arcsin hors de [-1, 1]");
      return inverse(Math.asin(x));
    case "acos":
    case "arccos":
      if (!(Math.abs(x) <= 1)) throw MathFailure.domain("arccos hors de [-1, 1]");
      return inverse(Math.acos(x));
    case "atan":
    case "arctan": return inverse(Math.atan(x));
    case "sinh": return Math.sinh(x);
    case "cosh": return Math.cosh(x);
    case "tanh": return Math.tanh(x);
    case "exp": return Math.exp(x);
    case "ln":
      if (!(x > 0)) throw MathFailure.domain("ln d'un nombre ≤ 0");
      return Math.log(x);
    case "log":
      if (!(x > 0)) throw MathFailure.domain("log d'un nombre ≤ 0");
      return Math.log10(x);
    case "log2":
      if (!(x > 0)) throw MathFailure.domain("log2 d'un nombre ≤ 0");
      return Math.log2(x);
    case "sqrt":
      if (!(x >= 0)) throw MathFailure.domain("racine d'un nombre négatif");
      return Math.sqrt(x);
    case "cbrt": return Math.cbrt(x);
    case "abs": return Math.abs(x);
    case "floor": return Math.floor(x);
    case "ceil": return Math.ceil(x);
    case "round": return roundAway(x);
    default: return x > 0 ? 1 : x < 0 ? -1 : 0;
  }
}

/// Appelle une fonction définie à une variable.
export function call(name: string, x: number, environment: MathEnvironment): number {
  const fn = environment.functions.get(name);
  if (!fn) throw MathFailure.unknownName(name);
  if (fn.parameters.length !== 1) throw MathFailure.arity(name);
  return evaluate(fn.body, environment, new Map([[fn.parameters[0], x]]));
}

/// Dérivée numérique (différences centrées, pas adapté à l'échelle de x).
export function derivative(name: string, order: number, x: number, environment: MathEnvironment): number {
  if (order < 1) return call(name, x, environment);
  const h = order === 1 ? Math.max(1e-5, Math.abs(x) * 1e-5) : Math.max(1e-3, Math.abs(x) * 1e-3);
  if (order === 1) {
    return (call(name, x + h, environment) - call(name, x - h, environment)) / (2 * h);
  }
  const f = (t: number) => derivative(name, order - 1, t, environment);
  return (f(x + h) - f(x - h)) / (2 * h);
}

/// Intégrale de Simpson composite (2 000 intervalles).
export function simpson(f: (x: number) => number, a: number, b: number, intervals = 2000): number {
  const n = intervals % 2 === 0 ? intervals : intervals + 1;
  const h = (b - a) / n;
  let sum = f(a) + f(b);
  for (let i = 1; i < n; i++) sum += (i % 2 === 0 ? 2 : 4) * f(a + i * h);
  return (sum * h) / 3;
}

/// Une racine dans [a, b] par dichotomie (il faut un changement de signe).
export function bisect(f: (x: number) => number, a: number, b: number): number {
  let lo = a, hi = b;
  let flo = f(lo);
  const fhi = f(hi);
  if (flo === 0) return lo;
  if (fhi === 0) return hi;
  if (isMinus(flo) === isMinus(fhi)) {
    throw MathFailure.domain(`pas de changement de signe entre ${format(a)} et ${format(b)}`);
  }
  for (let k = 0; k < 200; k++) {
    const mid = (lo + hi) / 2;
    const fm = f(mid);
    if (fm === 0 || (hi - lo) / 2 < 1e-13) return mid;
    if (isMinus(fm) === isMinus(flo)) { lo = mid; flo = fm; } else { hi = mid; }
  }
  return (lo + hi) / 2;
}

// MARK: Tracé

export interface MathPoint {
  x: number;
  y: number;
}

/// Des points de la fonction sur [from, to] ; les valeurs indéfinies ou
/// énormes (asymptotes) sont omises — le tracé s'interrompt.
export function sample(name: string, from: number, to: number, count: number, environment: MathEnvironment): MathPoint[] {
  if (!(to > from && count > 1)) return [];
  const step = (to - from) / (count - 1);
  const points: MathPoint[] = [];
  for (let i = 0; i < count; i++) {
    const x = from + i * step;
    let y: number;
    try { y = call(name, x, environment); } catch { continue; }
    if (!Number.isFinite(y) || !(Math.abs(y) < 1e9)) continue;
    points.push({ x, y });
  }
  return points;
}

/// Les racines visibles sur [from, to] (changements de signe affinés).
export function roots(name: string, from: number, to: number, environment: MathEnvironment): number[] {
  const points = sample(name, from, to, 800, environment);
  const found: number[] = [];
  for (let i = 0; i + 1 < points.length; i++) {
    const a = points[i], b = points[i + 1];
    if (!(a.y === 0 || isMinus(a.y) !== isMinus(b.y))) continue;
    // Une asymptote change aussi de signe : on garde seulement les vraies racines.
    if (!(Math.abs(a.y) < 1e3 && Math.abs(b.y) < 1e3)) continue;
    let root: number, value: number;
    try {
      root = bisect((x) => call(name, x, environment), a.x, b.x);
      value = call(name, root, environment);
    } catch { continue; }
    if (!(Math.abs(value) < 1e-6)) continue;
    if (found.length === 0 || Math.abs(found[found.length - 1] - root) > 1e-6) found.push(root);
  }
  return found;
}

// MARK: Affichage

/// Les chiffres exacts d'un double positif fini : `entier` et `fraction` en décimal,
/// sans arrondi (`printf` de la libm arrondit sur la valeur binaire exacte, au pair
/// en cas d'égalité ; `toFixed` de JS choisit le plus grand).
function exactDecimal(positive: number): { integer: string; fraction: string } {
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, positive);
  const bits = view.getBigUint64(0);
  const exponentField = Number((bits >> 52n) & 0x7ffn);
  const fractionBits = bits & ((1n << 52n) - 1n);
  const mantissa = exponentField === 0 ? fractionBits : fractionBits | (1n << 52n);
  const exponent = (exponentField === 0 ? 1 : exponentField) - 1075;
  if (exponent >= 0) return { integer: (mantissa << BigInt(exponent)).toString(), fraction: "" };
  const k = -exponent;
  const digits = (mantissa * 5n ** BigInt(k)).toString().padStart(k + 1, "0");
  return { integer: digits.slice(0, digits.length - k), fraction: digits.slice(digits.length - k) };
}

/// Arrondit `kept` (chiffres gardés) d'après `rest` (chiffres suivants), au pair en cas d'égalité.
/// Peut rendre un chiffre de plus (`999` → `1000`).
function roundHalfEven(kept: string, rest: string): string {
  if (rest === "") return kept;
  const first = rest[0];
  let up: boolean;
  if (first > "5") up = true;
  else if (first < "5") up = false;
  else if (/[1-9]/.test(rest.slice(1))) up = true;
  else up = kept !== "" && (kept.charCodeAt(kept.length - 1) - 48) % 2 === 1;
  if (!up) return kept;
  const next = (BigInt(kept === "" ? "0" : kept) + 1n).toString();
  return next.padStart(kept.length, "0");
}

/// `String(format: "%.10f", value)`.
function formatFixed10(value: number): string {
  const { integer, fraction } = exactDecimal(Math.abs(value));
  const keptFraction = fraction.slice(0, 10).padEnd(10, "0");
  const rounded = roundHalfEven(integer + keptFraction, fraction.slice(10));
  const padded = rounded.padStart(11, "0");
  const text = `${padded.slice(0, padded.length - 10)}.${padded.slice(padded.length - 10)}`;
  return (isMinus(value) ? "-" : "") + text;
}

/// `String(format: "%.6g", value)` pour les grandeurs en notation scientifique
/// (|x| ≥ 10⁶ ou < 10⁻⁴), les seules qu'`format` envoie ici.
function formatG6(value: number): string {
  const { integer, fraction } = exactDecimal(Math.abs(value));
  const all = integer + fraction;
  const firstNonZero = all.search(/[1-9]/);
  let exponent = integer.length - 1 - firstNonZero;
  const significant = all.slice(firstNonZero);
  let kept = roundHalfEven(significant.slice(0, 6).padEnd(6, "0"), significant.slice(6));
  if (kept.length > 6) { kept = kept.slice(0, 6); exponent += 1; }
  const decimals = kept.slice(1).replace(/0+$/, "");
  const mantissa = kept[0] + (decimals === "" ? "" : "." + decimals);
  const digits = String(Math.abs(exponent)).padStart(2, "0");
  return `${isMinus(value) ? "-" : ""}${mantissa}e${exponent < 0 ? "-" : "+"}${digits}`;
}

/// `0.30000000000000004` → `0.3` ; les entiers sans décimales ; la notation
/// scientifique pour les très grands et très petits nombres.
export function format(value: number): string {
  if (!Number.isFinite(value)) return Number.isNaN(value) ? "indéfini" : value > 0 ? "∞" : "−∞";
  if (value === 0) return "0";
  const magnitude = Math.abs(value);
  if (magnitude >= 1e12 || magnitude < 1e-6) {
    return replaceAll(replaceAll(formatG6(value), "e+", "·10^"), "e-", "·10^-");
  }
  let text = formatFixed10(value);
  while (text.endsWith("0")) text = text.slice(0, -1);
  if (text.endsWith(".")) text = text.slice(0, -1);
  return text === "-0" ? "0" : text;
}

export const MathEngine = {
  Failure: MathFailure,
  Environment: MathEnvironment,
  constants,
  builtins,
  isReserved,
  parse,
  parseExpression,
  tokenize,
  evaluate,
  call,
  derivative,
  simpson,
  bisect,
  sample,
  roots,
  format,
};
