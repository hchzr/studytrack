import {
  MathEnvironment, MathFailure, constants, evaluate, format as engineFormat, isReserved,
  parseExpression, pow, roots as engineRoots, roundAway,
} from "./mathEngine.ts";
import type { MathNode } from "./mathEngine.ts";
import { characters, isLetter, isNumber, trimWhitespaces } from "./textRepair.ts";

/// La calculatrice « comme sur papier » du mode étude, au-dessus de
/// `MathEngine` : ce qu'on tape est compris sans syntaxe à apprendre.
///
/// - `x^2 - 2` (une inconnue libre) → une fonction, tracée (`f`, `g`…) ;
/// - `x^2 = 2`, `z^5 = 1`, `cos(x) = x` → résolu : toutes les racines d'un
///   polynôme (complexes comprises, méthode de Durand–Kerner), sinon les
///   racines réelles trouvées par changement de signe ;
/// - `(1+2i)/(3-i)`, `e^(i pi)` → un nombre complexe, forme algébrique et polaire ;
/// - `A = [[1,2],[3,4]]`, `det(A)`, `inv(A)`, `rref(A)`, `A*B`, `solve(A, b)`
///   → l'algèbre linéaire de MATH-111, résultats en fractions quand ils le sont.
///
/// Pur, testé.

/// Le résultat d'une ligne (`MathWorkbench.Output`).
export type MathOutput =
  | { kind: "value"; value: string }
  | { kind: "plotted"; definition: string }
  | { kind: "solutions"; variable: string; roots: string[] }
  | { kind: "matrix"; rows: string[][] }
  | { kind: "complex"; value: string; polar: string }
  | { kind: "defined"; text: string };

export class MathSession {
  engine = new MathEnvironment();
  matrices = new Map<string, Matrix>();
}

export function run(line: string, session: MathSession): MathOutput {
  const text = trimWhitespaces(line);
  if (text === "") throw MathFailure.syntax("ligne vide");
  if (MatrixParser.concerns(text, new Set(session.matrices.keys()))) {
    return MatrixParser.run(text, session);
  }
  const parts = text.split("=");
  if (parts.length === 2 && !isDefinition(parts[0])) {
    return solve(parts[0], parts[1], session.engine);
  }
  if (parts.length === 1) {
    const node = parseExpression(text);
    const free = freeNames(node, session.engine);
    if ((free.size === 1 && free.has("i")) || (free.size === 0 && mentions(node, "i") && !session.engine.variables.has("i"))) {
      const value = ComplexMath.evaluate(node, session.engine);
      return { kind: "complex", value: value.algebraic, polar: value.polar };
    }
    if (free.size === 1) {
      const variable = [...free][0];
      const name = nextFunctionName(session.engine);
      session.engine.functions.set(name, { parameters: [variable], body: node });
      return { kind: "plotted", definition: `${name}(${variable}) = ${text}` };
    }
  }
  const value = session.engine.run(text);
  if (value !== null) return { kind: "value", value: format(value) };
  return { kind: "defined", text };
}

/// `a = …`, `f(x) = …` : une définition, pas une équation.
export function isDefinition(lhs: string): boolean {
  const left = trimWhitespaces(lhs);
  // `cos(x) = x` est une équation : `cos` ne se redéfinit pas.
  let name = "";
  for (const c of characters(left)) {
    if (!(isLetter(c) || isNumber(c) || c === "_")) break;
    name += c;
  }
  if (isReserved(name)) return false;
  if (/^[A-Za-zα-ωπ][A-Za-z0-9_]*$/.test(left)) return true;
  return /^[A-Za-z][A-Za-z0-9_]*\(\s*[A-Za-z][A-Za-z0-9_]*(\s*,\s*[A-Za-z][A-Za-z0-9_]*)*\s*\)$/.test(left);
}

// MARK: Inconnues

export function freeNames(node: MathNode, environment: MathEnvironment): Set<string> {
  switch (node.kind) {
    case "number": return new Set();
    case "variable":
      return !environment.variables.has(node.name) && !constants.has(node.name) ? new Set([node.name]) : new Set();
    case "negate":
    case "factorial": return freeNames(node.inner, environment);
    case "binary": return new Set([...freeNames(node.left, environment), ...freeNames(node.right, environment)]);
    case "call": {
      // `int(f, 0, 1)` : `f` nomme une fonction, pas une inconnue.
      const skipFirst = node.name === "int" || node.name === "root";
      const result = new Set<string>();
      node.args.forEach((argument, offset) => {
        if (skipFirst && offset === 0) return;
        for (const name of freeNames(argument, environment)) result.add(name);
      });
      return result;
    }
    case "derivative": return freeNames(node.arg, environment);
  }
}

export function mentions(node: MathNode, name: string): boolean {
  switch (node.kind) {
    case "number": return false;
    case "variable": return node.name === name;
    case "negate":
    case "factorial": return mentions(node.inner, name);
    case "derivative": return mentions(node.arg, name);
    case "binary": return mentions(node.left, name) || mentions(node.right, name);
    case "call": return node.args.some((a) => mentions(a, name));
  }
}

export function nextFunctionName(environment: MathEnvironment): string {
  for (const name of ["f", "g", "h", "p", "q", "r", "u", "v", "w"]) {
    if (!environment.functions.has(name)) return name;
  }
  let index = 1;
  while (environment.functions.has(`f${index}`)) index += 1;
  return `f${index}`;
}

// MARK: Équations

export function solve(lhs: string, rhs: string, environment: MathEnvironment): MathOutput {
  const left = parseExpression(lhs), right = parseExpression(rhs);
  const difference: MathNode = { kind: "binary", op: "-", left, right };
  const free = freeNames(difference, environment);
  const complex = free.has("i") && free.size > 1;
  if (complex) free.delete("i");
  if (free.size !== 1) {
    throw MathFailure.domain(free.size === 0 ? "Aucune inconnue à trouver." : "Une seule inconnue, s'il te plaît.");
  }
  const variable = [...free][0];
  let polynomial: Polynomial | null = null;
  try { polynomial = Polynomial.from(difference, variable, environment); } catch { polynomial = null; }
  if (polynomial && polynomial.degree >= 1) {
    const found = polynomial.roots().sort((a, b) => (a.re < b.re || (a.re === b.re && a.im < b.im) ? -1 : b.re < a.re || (b.re === a.re && b.im < a.im) ? 1 : 0));
    return { kind: "solutions", variable, roots: found.map((z) => z.readable) };
  }
  // Pas un polynôme : les racines réelles, par changement de signe.
  const local = environment.copy();
  local.functions.set("__solve", { parameters: [variable], body: difference });
  const real = engineRoots("__solve", -100, 100, local);
  if (real.length === 0) throw MathFailure.domain("Pas de solution réelle trouvée entre −100 et 100.");
  return { kind: "solutions", variable, roots: real.map(format) };
}

// MARK: Affichage

/// `0.333…` → `1/3`, `2.5` → `5/2`, sinon le nombre arrondi.
export function format(value: number): string {
  const f = fraction(value);
  if (f !== null) return f;
  return engineFormat(value);
}

export function fraction(value: number): string | null {
  if (!(Number.isFinite(value) && (value !== roundAway(value) || Math.abs(value) < 1e12))) return null;
  if (Math.abs(value - roundAway(value)) < 1e-10) return engineFormat(roundAway(value));
  for (let denominator = 2; denominator <= 100; denominator++) {
    const numerator = value * denominator;
    if (Math.abs(numerator - roundAway(numerator)) < 1e-9 * denominator) {
      return `${roundAway(numerator) + 0}/${denominator}`;
    }
  }
  return null;
}

// MARK: - Nombres complexes

export class Complex {
  static readonly i = new Complex(0, 1);

  constructor(readonly re: number, readonly im: number) {}

  plus(b: Complex): Complex { return new Complex(this.re + b.re, this.im + b.im); }
  minus(b: Complex): Complex { return new Complex(this.re - b.re, this.im - b.im); }
  times(b: Complex): Complex {
    return new Complex(this.re * b.re - this.im * b.im, this.re * b.im + this.im * b.re);
  }
  dividedBy(b: Complex): Complex {
    const d = b.re * b.re + b.im * b.im;
    return new Complex((this.re * b.re + this.im * b.im) / d, (this.im * b.re - this.re * b.im) / d);
  }
  negated(): Complex { return new Complex(-this.re, -this.im); }

  get modulus(): number { return Math.sqrt(this.re * this.re + this.im * this.im); }
  get argument(): number { return Math.atan2(this.im, this.re); }

  static exp(z: Complex): Complex {
    return new Complex(Math.exp(z.re) * Math.cos(z.im), Math.exp(z.re) * Math.sin(z.im));
  }
  static log(z: Complex): Complex { return new Complex(Math.log(z.modulus), z.argument); }

  static pow(z: Complex, w: Complex): Complex {
    // Puissance entière : exacte (pas de détour par le logarithme).
    if (w.im === 0 && w.re === roundAway(w.re) && Math.abs(w.re) <= 64) {
      let result = new Complex(1, 0);
      for (let k = 0; k < Math.abs(w.re); k++) result = result.times(z);
      return w.re < 0 ? new Complex(1, 0).dividedBy(result) : result;
    }
    if (z.re === 0 && z.im === 0) return new Complex(0, 0);
    return Complex.exp(w.times(Complex.log(z)));
  }

  /// `3 - 2i`, `1.5i`, `-1` (les restes d'arrondi effacés).
  get algebraic(): string {
    const clean = (x: number) => (Math.abs(x) < 1e-10 ? 0 : x);
    const a = clean(this.re), b = clean(this.im);
    if (b === 0) return format(a);
    const imaginary = Math.abs(b) === 1 ? "i" : format(Math.abs(b)) + "i";
    if (a === 0) return (b < 0 ? "-" : "") + imaginary;
    return format(a) + (b < 0 ? " - " : " + ") + imaginary;
  }

  /// La forme la plus lisible : algébrique si elle est exacte (`1 + 2i`),
  /// polaire si l'angle est une fraction de π (`e^(i·2π/5)`), sinon algébrique.
  get readable(): string {
    const exact = fraction(this.re) !== null && fraction(this.im) !== null;
    if (exact || Math.abs(this.im) < 1e-10) return this.algebraic;
    const ratio = this.argument / Math.PI;
    if (fraction(ratio) === null) return this.algebraic;
    const r = fraction(this.modulus);
    const polar = this.polar;
    // `drop { $0 != "e" }` : on garde à partir du premier « e ».
    const start = polar.indexOf("e");
    return r === "1" ? (start < 0 ? "" : polar.slice(start)) : polar;
  }

  /// `2·e^(iπ/3)` : le module et l'argument (en fraction de π quand c'en est une).
  get polar(): string {
    const r = format(this.modulus);
    const ratio = this.argument / Math.PI;
    let angle: string;
    const f = fraction(ratio);
    if (Math.abs(this.argument) < 1e-12) angle = "0";
    else if (f !== null) {
      angle = f === "1" ? "π" : f === "-1" ? "-π" : f.includes("/") ? f.split("/").join("π/") : f + "π";
    } else angle = engineFormat(this.argument);
    return `${r}·e^(i·${angle})`;
  }
}

export const ComplexMath = {
  evaluate(node: MathNode, environment: MathEnvironment): Complex {
    const ev = (n: MathNode) => ComplexMath.evaluate(n, environment);
    switch (node.kind) {
      case "number": return new Complex(node.value, 0);
      case "variable": {
        if (node.name === "i" && !environment.variables.has("i")) return Complex.i;
        const value = environment.variables.get(node.name) ?? constants.get(node.name);
        if (value !== undefined) return new Complex(value, 0);
        throw MathFailure.unknownName(node.name);
      }
      case "negate": return ev(node.inner).negated();
      case "binary": {
        const x = ev(node.left), y = ev(node.right);
        switch (node.op) {
          case "+": return x.plus(y);
          case "-": return x.minus(y);
          case "*": return x.times(y);
          case "/":
            if (!(y.modulus > 0)) throw MathFailure.domain("division par zéro");
            return x.dividedBy(y);
          case "^": return Complex.pow(x, y);
          default: throw MathFailure.syntax(`« ${node.op} »`);
        }
      }
      case "call": {
        if (node.args.length !== 1) throw MathFailure.arity(node.name);
        const z = ev(node.args[0]);
        switch (node.name) {
          case "re": return new Complex(z.re, 0);
          case "im": return new Complex(z.im, 0);
          case "conj": return new Complex(z.re, -z.im);
          case "abs": return new Complex(z.modulus, 0);
          case "arg": return new Complex(z.argument, 0);
          case "exp": return Complex.exp(z);
          case "ln":
          case "log": return Complex.log(z);
          case "sqrt": return Complex.pow(z, new Complex(0.5, 0));
          case "sin": return Complex.exp(Complex.i.times(z)).minus(Complex.exp(Complex.i.times(z).negated())).dividedBy(new Complex(0, 2));
          case "cos": return Complex.exp(Complex.i.times(z)).plus(Complex.exp(Complex.i.times(z).negated())).dividedBy(new Complex(2, 0));
          default:
            if (z.im !== 0) throw MathFailure.domain(`${node.name} d'un complexe : pas pris en charge`);
            return new Complex(evaluate({ kind: "call", name: node.name, args: [{ kind: "number", value: z.re }] }, environment), 0);
        }
      }
      case "factorial":
      case "derivative":
        return new Complex(evaluate(node, environment), 0);
    }
  },
};

// MARK: - Polynômes

class NotPolynomial extends Error {}

/// Un polynôme à coefficients complexes (`coefficients[k]` devant `x^k`).
export class Polynomial {
  constructor(readonly coefficients: Complex[]) {}

  get degree(): number {
    let d = this.coefficients.length - 1;
    while (d > 0 && this.coefficients[d].modulus < 1e-14) d -= 1;
    return d;
  }

  plus(b: Polynomial): Polynomial {
    const n = Math.max(this.coefficients.length, b.coefficients.length);
    const zero = new Complex(0, 0);
    const result: Complex[] = [];
    for (let k = 0; k < n; k++) result.push((this.coefficients[k] ?? zero).plus(b.coefficients[k] ?? zero));
    return new Polynomial(result);
  }
  negated(): Polynomial { return new Polynomial(this.coefficients.map((c) => c.negated())); }
  times(b: Polynomial): Polynomial {
    const result = new Array<Complex>(this.coefficients.length + b.coefficients.length - 1).fill(new Complex(0, 0));
    this.coefficients.forEach((x, i) => b.coefficients.forEach((y, j) => { result[i + j] = result[i + j].plus(x.times(y)); }));
    return new Polynomial(result);
  }

  /// L'expression comme polynôme en `variable` ; échoue sinon (`sin(x)`, `1/x`…).
  static from(node: MathNode, variable: string, environment: MathEnvironment): Polynomial {
    const constant = (n: MathNode) => new Polynomial([ComplexMath.evaluate(n, environment)]);
    const from = (n: MathNode) => Polynomial.from(n, variable, environment);
    switch (node.kind) {
      case "variable":
        if (node.name === variable) return new Polynomial([new Complex(0, 0), new Complex(1, 0)]);
        return constant(node);
      case "number":
        return constant(node);
      case "negate":
        return from(node.inner).negated();
      case "binary": {
        switch (node.op) {
          case "+": { const a = from(node.left); return a.plus(from(node.right)); }
          case "-": { const a = from(node.left); return a.plus(from(node.right).negated()); }
          case "*": { const a = from(node.left); return a.times(from(node.right)); }
          case "/": {
            if (mentions(node.right, variable)) throw new NotPolynomial();
            const divisor = ComplexMath.evaluate(node.right, environment);
            return new Polynomial(from(node.left).coefficients.map((c) => c.dividedBy(divisor)));
          }
          case "^": {
            if (mentions(node.right, variable)) throw new NotPolynomial();
            const exponent = evaluate(node.right, environment);
            if (!(exponent >= 0 && exponent === roundAway(exponent) && exponent <= 40)) throw new NotPolynomial();
            const base = from(node.left);
            let result = new Polynomial([new Complex(1, 0)]);
            for (let k = 0; k < Math.trunc(exponent); k++) result = result.times(base);
            return result;
          }
          default: throw new NotPolynomial();
        }
      }
      default:
        if (mentions(node, variable)) throw new NotPolynomial();
        return constant(node);
    }
  }

  /// Toutes les racines (Durand–Kerner), polies, les quasi-réelles ramenées au réel.
  roots(): Complex[] {
    const n = this.degree;
    if (n < 1) return [];
    const lead = this.coefficients[n];
    const monic = this.coefficients.slice(0, n + 1).map((c) => c.dividedBy(lead));
    const value = (z: Complex) => [...monic].reverse().reduce((acc, c) => acc.times(z).plus(c), new Complex(0, 0));
    const roots: Complex[] = [];
    for (let k = 0; k < n; k++) roots.push(Complex.pow(new Complex(0.4, 0.9), new Complex(k, 0)));
    for (let sweep = 0; sweep < 500; sweep++) {
      let change = 0;
      for (let i = 0; i < n; i++) {
        let denominator = new Complex(1, 0);
        for (let j = 0; j < n; j++) if (j !== i) denominator = denominator.times(roots[i].minus(roots[j]));
        if (!(denominator.modulus > 0)) continue;
        const step = value(roots[i]).dividedBy(denominator);
        roots[i] = roots[i].minus(step);
        change = Math.max(change, step.modulus);
      }
      if (change < 1e-14) break;
    }
    return roots.map((z) => new Complex(Math.abs(z.re) < 1e-9 ? 0 : z.re, Math.abs(z.im) < 1e-9 ? 0 : z.im));
  }
}

// MARK: - Matrices

export interface ReducedMatrix {
  matrix: Matrix;
  rank: number;
  determinantSign: number;
  pivotProduct: number;
}

export class Matrix {
  constructor(readonly rows: number[][]) {}

  get rowCount(): number { return this.rows.length; }
  get columnCount(): number { return this.rows.length > 0 ? this.rows[0].length : 0; }

  static identity(n: number): Matrix {
    return new Matrix(Array.from({ length: n }, (_, i) => Array.from({ length: n }, (_, j) => (j === i ? 1 : 0))));
  }

  get transposed(): Matrix {
    return new Matrix(Array.from({ length: this.columnCount }, (_, j) => this.rows.map((r) => r[j])));
  }

  times(b: Matrix): Matrix {
    if (this.columnCount !== b.rowCount) {
      throw MathFailure.domain(`Tailles incompatibles (${this.rowCount}×${this.columnCount} · ${b.rowCount}×${b.columnCount}).`);
    }
    return new Matrix(this.rows.map((row) => Array.from({ length: b.columnCount }, (_, j) => {
      let sum = 0;
      row.forEach((x, k) => { sum += x * b.rows[k][j]; });
      return sum;
    })));
  }

  plus(b: Matrix): Matrix {
    if (this.rowCount !== b.rowCount || this.columnCount !== b.columnCount) throw MathFailure.domain("Tailles différentes.");
    return new Matrix(this.rows.map((row, i) => row.map((x, j) => x + b.rows[i][j])));
  }

  scaled(k: number): Matrix { return new Matrix(this.rows.map((row) => row.map((x) => x * k))); }

  /// Forme échelonnée réduite (pivot de Gauss partiel), et le nombre de pivots.
  reduced(): ReducedMatrix {
    const m = this.rows.map((r) => [...r]);
    let lead = 0, rank = 0, sign = 1, product = 1;
    for (let r = 0; r < this.rowCount; r++) {
      if (!(lead < this.columnCount)) break;
      let i = r;
      while (Math.abs(m[i][lead]) < 1e-12) {
        i += 1;
        if (i === this.rowCount) {
          i = r;
          lead += 1;
          if (lead === this.columnCount) return { matrix: new Matrix(m), rank, determinantSign: sign, pivotProduct: product };
        }
      }
      if (i !== r) { [m[i], m[r]] = [m[r], m[i]]; sign = -sign; }
      const pivot = m[r][lead];
      product *= pivot;
      m[r] = m[r].map((x) => x / pivot);
      for (let k = 0; k < this.rowCount; k++) {
        if (k === r) continue;
        const factor = m[k][lead];
        m[k] = m[k].map((x, c) => x - factor * m[r][c]);
      }
      rank += 1;
      lead += 1;
    }
    return {
      matrix: new Matrix(m.map((row) => row.map((x) => (Math.abs(x) < 1e-12 ? 0 : x)))),
      rank, determinantSign: sign, pivotProduct: product,
    };
  }

  determinant(): number {
    if (this.rowCount !== this.columnCount) throw MathFailure.domain("Le déterminant demande une matrice carrée.");
    const reduced = this.reduced();
    return reduced.rank < this.rowCount ? 0 : reduced.determinantSign * reduced.pivotProduct;
  }

  inverse(): Matrix {
    if (this.rowCount !== this.columnCount) throw MathFailure.domain("Seule une matrice carrée s'inverse.");
    const identity = Matrix.identity(this.rowCount).rows;
    const augmented = new Matrix(this.rows.map((row, i) => [...row, ...identity[i]])).reduced();
    const diagonalIsOne = Array.from({ length: this.rowCount }, (_, i) => i)
      .every((i) => Math.abs(augmented.matrix.rows[i][i] - 1) < 1e-9);
    if (!(augmented.rank === this.rowCount && diagonalIsOne)) {
      throw MathFailure.domain("Matrice non inversible (déterminant nul).");
    }
    return new Matrix(augmented.matrix.rows.map((row) => row.slice(this.rowCount)));
  }

  get formatted(): string[][] { return this.rows.map((row) => row.map(format)); }
}

type MatrixValue = { kind: "scalar"; x: number } | { kind: "matrix"; m: Matrix };

/// Le petit langage des matrices : littéraux `[[1,2],[3,4]]`, noms, `+ - *`,
/// un scalaire devant, `^` entier, `det inv rref transpose rank trace solve`.
export const MatrixParser = {
  functions: new Set(["det", "inv", "rref", "transpose", "rank", "trace", "tr", "solve"]),

  concerns(text: string, known: Set<string>): boolean {
    if (text.includes("[")) return true;
    // Les noms, même collés à un nombre (`2A` → `A`).
    const words = new Set(text.match(/[A-Za-z_][A-Za-z0-9_]*/g) ?? []);
    const intersects = (other: Set<string>) => [...words].some((w) => other.has(w));
    return intersects(known) || (intersects(MatrixParser.functions) && intersects(known));
  },

  run(text: string, session: MathSession): MathOutput {
    let source = text;
    let target: string | null = null;
    const equal = text.indexOf("=");
    if (equal >= 0 && /^[A-Za-z][A-Za-z0-9_]*$/.test(trimWhitespaces(text.slice(0, equal)))) {
      target = trimWhitespaces(text.slice(0, equal));
      source = text.slice(equal + 1);
    }
    const parser = new MatrixExpressionParser(characters(source), session);
    const value = parser.expression();
    parser.skip();
    if (parser.index !== parser.chars.length) throw MathFailure.syntax("fin inattendue");
    if (value.kind === "matrix") {
      if (target !== null) session.matrices.set(target, value.m);
      return { kind: "matrix", rows: value.m.formatted };
    }
    if (target !== null) session.engine.variables.set(target, value.x);
    return { kind: "value", value: format(value.x) };
  },
};

class MatrixExpressionParser {
  index = 0;

  constructor(readonly chars: string[], readonly session: MathSession) {}

  skip(): void { while (this.index < this.chars.length && this.chars[this.index] === " ") this.index += 1; }

  eat(c: string): boolean {
    this.skip();
    if (this.index < this.chars.length && this.chars[this.index] === c) { this.index += 1; return true; }
    return false;
  }

  expression(): MatrixValue {
    let value = this.term();
    for (;;) {
      if (this.eat("+")) value = this.combine(value, this.term(), "+");
      else if (this.eat("-")) value = this.combine(value, this.term(), "-");
      else return value;
    }
  }

  term(): MatrixValue {
    let value = this.power();
    for (;;) {
      this.skip();
      if (this.eat("*")) {
        value = this.combine(value, this.power(), "*");
      } else if (this.index < this.chars.length
        && (this.chars[this.index] === "[" || isLetter(this.chars[this.index]) || this.chars[this.index] === "(")) {
        value = this.combine(value, this.power(), "*");
      } else {
        return value;
      }
    }
  }

  power(): MatrixValue {
    const base = this.unary();
    if (!this.eat("^")) return base;
    const exponent = this.unary();
    if (!(exponent.kind === "scalar" && exponent.x === roundAway(exponent.x))) throw MathFailure.syntax("puissance entière attendue");
    const n = exponent.x;
    if (base.kind === "scalar") return { kind: "scalar", x: pow(base.x, n) };
    let result = Matrix.identity(base.m.rowCount);
    const factor = n < 0 ? base.m.inverse() : base.m;
    for (let k = 0; k < Math.trunc(Math.abs(n)); k++) result = result.times(factor);
    return { kind: "matrix", m: result };
  }

  unary(): MatrixValue {
    if (this.eat("-")) return this.combine({ kind: "scalar", x: -1 }, this.unary(), "*");
    return this.primary();
  }

  primary(): MatrixValue {
    this.skip();
    if (!(this.index < this.chars.length)) throw MathFailure.syntax("expression incomplète");
    const c = this.chars[this.index];
    if (c === "(") {
      this.index += 1;
      const v = this.expression();
      if (!this.eat(")")) throw MathFailure.syntax("« ) » manquante");
      return v;
    }
    if (c === "[") return { kind: "matrix", m: this.literal() };
    if (isNumber(c) || c === ".") {
      let text = "";
      while (this.index < this.chars.length && (isNumber(this.chars[this.index]) || this.chars[this.index] === ".")) {
        text += this.chars[this.index];
        this.index += 1;
      }
      const value = Number(text);
      if (text === "" || Number.isNaN(value)) throw MathFailure.syntax(text);
      return { kind: "scalar", x: value };
    }
    if (isLetter(c)) {
      let name = "";
      while (this.index < this.chars.length
        && (isLetter(this.chars[this.index]) || isNumber(this.chars[this.index]) || this.chars[this.index] === "_")) {
        name += this.chars[this.index];
        this.index += 1;
      }
      if (MatrixParser.functions.has(name) && this.eat("(")) {
        const args = [this.expression()];
        while (this.eat(",")) args.push(this.expression());
        if (!this.eat(")")) throw MathFailure.syntax("« ) » manquante");
        return this.apply(name, args);
      }
      const m = this.session.matrices.get(name);
      if (m) return { kind: "matrix", m };
      const x = this.session.engine.variables.get(name) ?? constants.get(name);
      if (x !== undefined) return { kind: "scalar", x };
      throw MathFailure.unknownName(name);
    }
    throw MathFailure.syntax(`« ${c} » inattendu`);
  }

  literal(): Matrix {
    if (!this.eat("[")) throw MathFailure.syntax("« [ » attendu");
    let rows: number[][] = [];
    if (this.eat("[")) {
      this.index -= 1;
      do { rows.push(this.row()); } while (this.eat(","));
    } else {
      rows = [this.numbers("]")];
      if (!this.eat("]")) throw MathFailure.syntax("« ] » manquant");
      // `[1,2,3]` : un vecteur colonne.
      return new Matrix(rows[0].map((x) => [x]));
    }
    if (!this.eat("]")) throw MathFailure.syntax("« ] » manquant");
    const width = rows.length > 0 ? rows[0].length : undefined;
    if (width === undefined || !rows.every((r) => r.length === width)) {
      throw MathFailure.domain("Les lignes n'ont pas toutes la même longueur.");
    }
    return new Matrix(rows);
  }

  row(): number[] {
    if (!this.eat("[")) throw MathFailure.syntax("« [ » attendu");
    const values = this.numbers("]");
    if (!this.eat("]")) throw MathFailure.syntax("« ] » manquant");
    return values;
  }

  numbers(end: string): number[] {
    const values: number[] = [];
    do {
      this.skip();
      let text = "";
      let depth = 0;
      while (this.index < this.chars.length && ((this.chars[this.index] !== "," && this.chars[this.index] !== end) || depth > 0)) {
        if (this.chars[this.index] === "(") depth += 1;
        if (this.chars[this.index] === ")") depth -= 1;
        text += this.chars[this.index];
        this.index += 1;
      }
      values.push(evaluate(parseExpression(text), this.session.engine));
    } while (this.eat(","));
    return values;
  }

  apply(name: string, args: MatrixValue[]): MatrixValue {
    const matrix = (value: MatrixValue): Matrix => {
      if (value.kind === "matrix") return value.m;
      throw MathFailure.domain(`${name} attend une matrice`);
    };
    switch (name) {
      case "det": return { kind: "scalar", x: matrix(args[0]).determinant() };
      case "inv": return { kind: "matrix", m: matrix(args[0]).inverse() };
      case "rref": return { kind: "matrix", m: matrix(args[0]).reduced().matrix };
      case "transpose": return { kind: "matrix", m: matrix(args[0]).transposed };
      case "rank": return { kind: "scalar", x: matrix(args[0]).reduced().rank };
      case "trace":
      case "tr": {
        const m = matrix(args[0]);
        let sum = 0;
        for (let k = 0; k < Math.min(m.rowCount, m.columnCount); k++) sum += m.rows[k][k];
        return { kind: "scalar", x: sum };
      }
      case "solve": {
        if (args.length !== 2) throw MathFailure.arity(name);
        return { kind: "matrix", m: matrix(args[0]).inverse().times(matrix(args[1])) };
      }
      default: throw MathFailure.unknownName(name);
    }
  }

  combine(a: MatrixValue, b: MatrixValue, op: string): MatrixValue {
    if (a.kind === "scalar" && b.kind === "scalar") {
      if (op === "+") return { kind: "scalar", x: a.x + b.x };
      if (op === "-") return { kind: "scalar", x: a.x - b.x };
      return { kind: "scalar", x: a.x * b.x };
    }
    if (a.kind === "matrix" && b.kind === "matrix") {
      if (op === "+") return { kind: "matrix", m: a.m.plus(b.m) };
      if (op === "-") return { kind: "matrix", m: a.m.plus(b.m.scaled(-1)) };
      return { kind: "matrix", m: a.m.times(b.m) };
    }
    if (op === "*") {
      if (a.kind === "scalar" && b.kind === "matrix") return { kind: "matrix", m: b.m.scaled(a.x) };
      if (a.kind === "matrix" && b.kind === "scalar") return { kind: "matrix", m: a.m.scaled(b.x) };
    }
    throw MathFailure.domain("On n'ajoute pas un nombre à une matrice.");
  }
}

export const MathWorkbench = {
  Session: MathSession,
  run,
  isDefinition,
  freeNames,
  mentions,
  nextFunctionName,
  solve,
  format,
  fraction,
};
