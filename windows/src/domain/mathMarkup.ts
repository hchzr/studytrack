import { characters, isLetter, isNumber, precomposed, trimWhitespaces, trimWhitespacesAndNewlines } from "./textRepair.ts";

/// Un texte avec des formules, découpé en morceaux à afficher.
///
/// Les énoncés arrivent du modèle en notation simple ou en LaTeX léger :
/// `x_n = \frac{an+b}{cn+d}`, `|a_n - ℓ| \le \varepsilon`, `a_{2k+1}`. Affichés
/// tels quels, ils se lisaient « a_n » — illisible pour un énoncé de maths.
///
/// Ce moteur est **pur** (testé) : il ne fait que découper en morceaux
/// normal / indice / exposant et remplacer les commandes par leurs symboles.
/// L'interface en fait du texte mis en forme.

export type MathStyle = "normal" | "subscripted" | "superscripted";

export interface MathRun {
  text: string;
  style: MathStyle;
}

function replaceAll(text: string, from: string, to: string): string {
  return text.split(from).join(to);
}

/// Le texte contient-il quelque chose à mettre en forme ?
export function hasMarkup(text: string): boolean {
  return text.includes("_") || text.includes("^") || text.includes("\\") || text.includes("$") || text.includes("``");
}

/// Accent de LaTeX → accent combinant Unicode.
export const accentMarks = new Map<string, string>([
  ["'", "́"], ["`", "̀"], ["^", "̂"], ["\"", "̈"],
  ["~", "̃"], ["c", "̧"], ["H", "̋"], ["v", "̌"],
]);

/// ``guillemets'' de LaTeX → « “ ” ». Seulement après un ``, pour ne pas
/// toucher la dérivée seconde f''(x).
export function typographicQuotes(source: string): string {
  if (!source.includes("``")) return source;
  let result = "";
  let rest = source;
  for (;;) {
    const open = rest.indexOf("``");
    if (open < 0) break;
    result += rest.slice(0, open) + "“";
    rest = rest.slice(open + 2);
    const close = rest.indexOf("''");
    if (close >= 0) {
      result += rest.slice(0, close) + "”";
      rest = rest.slice(close + 2);
    }
  }
  return result + rest;
}

export function runs(source: string): MathRun[] {
  const parser = new MarkupParser(characters(replaceAll(typographicQuotes(source), "$", "")));
  return merge(parser.parse("normal", null));
}

/// Le texte à plat, symboles remplacés (pour l'accessibilité et les widgets).
export function plain(source: string): string {
  return runs(source).map((r) => r.text).join("");
}

function merge(list: MathRun[]): MathRun[] {
  const result: MathRun[] = [];
  for (const run of list) {
    if (run.text === "") continue;
    const last = result[result.length - 1];
    if (last && last.style === run.style) {
      result[result.length - 1] = { text: last.text + run.text, style: last.style };
    } else {
      result.push({ text: run.text, style: run.style });
    }
  }
  return result;
}

// MARK: Symboles

export const symbols = new Map<string, string>(Object.entries({
  RR: "ℝ", CC: "ℂ", NN: "ℕ", ZZ: "ℤ", QQ: "ℚ",
  lt: "<", gt: ">", le: "≤", leq: "≤", leqslant: "⩽", ge: "≥", geq: "≥", geqslant: "⩾",
  neq: "≠", ne: "≠", approx: "≈", equiv: "≡", sim: "∼",
  infty: "∞", to: "→", rightarrow: "→", longrightarrow: "⟶", leftarrow: "←",
  Rightarrow: "⇒", implies: "⇒", Leftarrow: "⇐", Leftrightarrow: "⇔", iff: "⇔",
  mapsto: "↦", in: "∈", notin: "∉", subset: "⊂", subseteq: "⊆", cup: "∪", cap: "∩",
  emptyset: "∅", varnothing: "∅", forall: "∀", exists: "∃", neg: "¬",
  cdot: "·", times: "×", div: "÷", pm: "±", mp: "∓", circ: "∘",
  sum: "∑", prod: "∏", int: "∫", partial: "∂", nabla: "∇",
  ldots: "…", dots: "…", cdots: "⋯", prime: "′", quad: " ", qquad: "  ",
  ",": " ", ";": " ", "!": "", " ": " ", "{": "{", "}": "}", "|": "‖", "%": "%",
  alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ε", varepsilon: "ε",
  zeta: "ζ", eta: "η", theta: "θ", vartheta: "ϑ", iota: "ι", kappa: "κ",
  lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", pi: "π", rho: "ρ", sigma: "σ",
  tau: "τ", upsilon: "υ", phi: "φ", varphi: "φ", chi: "χ", psi: "ψ", omega: "ω",
  Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Xi: "Ξ", Pi: "Π",
  Sigma: "Σ", Phi: "Φ", Psi: "Ψ", Omega: "Ω",
  ell: "ℓ", lim: "lim", sup: "sup", inf: "inf", max: "max", min: "min",
  sin: "sin", cos: "cos", tan: "tan", ln: "ln", log: "log", exp: "exp",
  left: "", right: "", big: "", Big: "", displaystyle: "", limits: "",
  // Macros du polycopié de Botafogo (\bR = ℝ) et commandes de mise en
  // page qui n'ont pas de sens sur une ligne.
  bR: "ℝ", bC: "ℂ", bN: "ℕ", bZ: "ℤ", bQ: "ℚ",
  bigl: "", bigr: "", Bigl: "", Bigr: "", biggl: "", biggr: "",
  textstyle: "", nolimits: "", notag: "", nonumber: "",
  lvert: "|", rvert: "|", vert: "|",
  colon: ":", setminus: "∖", supset: "⊃", supseteq: "⊇",
  longmapsto: "⟼", searrow: "↘", nearrow: "↗", downarrow: "↓", uparrow: "↑",
  cot: "cot", arcsin: "arcsin", arccos: "arccos", arctan: "arctan",
  sinh: "sinh", cosh: "cosh", tanh: "tanh", det: "det", liminf: "lim inf", limsup: "lim sup",
}));

export const blackboard = new Map<string, string>([
  ["N", "ℕ"], ["Z", "ℤ"], ["Q", "ℚ"], ["R", "ℝ"], ["C", "ℂ"], ["P", "ℙ"], ["K", "𝕂"],
]);

// `\mathsf{i}` (l'unité imaginaire des séries d'analyse) sortait « mathsfi » :
// toutes les commandes de police ne gardent que leur argument.
const fontCommands = new Set([
  "mathrm", "mathbf", "mathit", "text", "textrm", "operatorname", "mathcal", "boldsymbol",
  "mathsf", "mathtt", "mathscr", "mathfrak", "textbf", "textit", "textsf", "texttt", "emph", "mbox", "hbox", "pmb",
]);

// MARK: Analyse

class MarkupParser {
  index = 0;

  constructor(readonly chars: string[]) {}

  get atEnd(): boolean { return this.index >= this.chars.length; }

  parse(style: MathStyle, closing: string | null): MathRun[] {
    let list: MathRun[] = [];
    let buffer = "";
    const flush = () => {
      if (buffer !== "") list.push({ text: buffer, style });
      buffer = "";
    };
    while (!this.atEnd) {
      const char = this.chars[this.index];
      if (closing !== null && char === closing) {
        this.index += 1;
        break;
      }
      switch (char) {
        case "\\": {
          this.index += 1;
          const command = this.readCommand();
          const produced = this.expand(command, style);
          if (produced.length === 1 && produced[0].style === style) {
            buffer += produced[0].text;
          } else {
            flush();
            list = list.concat(produced);
          }
          break;
        }
        case "_":
        case "^": {
          // Un « _ » ou « ^ » isolé dans une phrase n'est pas une formule.
          const previous = this.index > 0 ? this.chars[this.index - 1] : " ";
          const isScript = isLetter(previous) || isNumber(previous) || ")]}|′'".includes(previous) || buffer !== "";
          this.index += 1;
          if (!(isScript && !this.atEnd && this.chars[this.index] !== " ")) {
            buffer += char;
            break;
          }
          flush();
          const target: MathStyle = char === "_" ? "subscripted" : "superscripted";
          list = list.concat(this.argument(target));
          break;
        }
        case "{":
          this.index += 1;
          flush();
          list = list.concat(this.parse(style, "}"));
          break;
        default:
          buffer += char;
          this.index += 1;
      }
    }
    flush();
    return list;
  }

  /// `\frac`, `\le`, `\,` — le nom d'une commande.
  readCommand(): string {
    if (this.atEnd) return "";
    if (!isLetter(this.chars[this.index])) {
      const single = this.chars[this.index];
      this.index += 1;
      return single;
    }
    let name = "";
    while (!this.atEnd && isLetter(this.chars[this.index])) {
      name += this.chars[this.index];
      this.index += 1;
    }
    return name;
  }

  /// L'argument d'un indice, d'un exposant ou d'une commande : `{…}`, une
  /// commande, ou un seul caractère.
  argument(style: MathStyle): MathRun[] {
    while (!this.atEnd && this.chars[this.index] === " ") this.index += 1;
    if (this.atEnd) return [];
    if (this.chars[this.index] === "{") {
      this.index += 1;
      return this.parse(style, "}");
    }
    if (this.chars[this.index] === "\\") {
      this.index += 1;
      return this.expand(this.readCommand(), style);
    }
    const single = this.chars[this.index];
    this.index += 1;
    return [{ text: single, style }];
  }

  expand(command: string, style: MathStyle): MathRun[] {
    switch (command) {
      case "frac":
      case "dfrac":
      case "tfrac": {
        const numerator = this.argument(style);
        const denominator = this.argument(style);
        return this.fraction(numerator, denominator, style);
      }
      case "sqrt": {
        const body = this.argument(style);
        const text = body.map((r) => r.text).join("");
        const simple = characters(text).length <= 1
          || (characters(text).every((c) => isLetter(c) || isNumber(c)) && body.every((r) => r.style === style));
        return [{ text: "√", style }].concat(simple ? body : [{ text: "(", style }].concat(body, [{ text: ")", style }]));
      }
      case "mathbb": {
        const body = this.argument(style).map((r) => r.text).join("");
        return [{ text: characters(body).map((c) => blackboard.get(c) ?? c).join(""), style }];
      }
      case "overline":
      case "bar":
        return this.argument(style).map((r) => ({ text: r.text + "̅", style: r.style }));
      default:
        break;
    }
    if (fontCommands.has(command)) return this.argument(style);
    // Les accents de LaTeX : `\'e`, `\'{e}`, `\`a`, `\^o`, `\"u`, `\c{c}`.
    // Ils sortaient tels quels — « 'e », « ^o » — dans un énoncé ou un
    // titre lu par le modèle : l'accent était là, mais à côté de la lettre.
    if (accentMarks.has(command)) {
      const mark = accentMarks.get(command)!;
      const isCommand = !this.atEnd && this.chars[this.index] === "\\";
      const body = this.argument(style);
      // `\"\i ve` : l'espace qui termine `\i` n'est pas du texte.
      if (isCommand && !this.atEnd && this.chars[this.index] === " ") this.index += 1;
      const first = body[0];
      const letters = first ? characters(first.text) : [];
      if (!first || letters.length === 0) return body;
      const accented = precomposed(letters[0] + mark);
      return [{ text: accented + letters.slice(1).join(""), style: first.style }, ...body.slice(1)];
    }
    const symbol = symbols.get(command);
    if (symbol !== undefined) return [{ text: symbol, style }];
    // Commande inconnue : on garde son nom, lisible, plutôt que rien.
    return [{ text: command, style }];
  }

  /// `\frac{a}{b}` : « a⁄b » pour des termes courts, « (a)/(b) » sinon.
  fraction(numerator: MathRun[], denominator: MathRun[], style: MathStyle): MathRun[] {
    const top = numerator.map((r) => r.text).join("");
    const bottom = denominator.map((r) => r.text).join("");
    const flat = numerator.every((r) => r.style === style) && denominator.every((r) => r.style === style);
    if (style === "normal" && flat && characters(top).length <= 3 && characters(bottom).length <= 3) {
      return [{ text: top, style: "superscripted" }, { text: "⁄", style: "normal" }, { text: bottom, style: "subscripted" }];
    }
    const wrap = (list: MathRun[], text: string): MathRun[] => {
      const atomic = characters(text).length <= 1 || characters(text).every((c) => isLetter(c) || isNumber(c));
      return atomic ? list : [{ text: "(", style }].concat(list, [{ text: ")", style }]);
    };
    return wrap(numerator, top).concat([{ text: "/", style }], wrap(denominator, bottom));
  }
}

export const MathMarkup = { hasMarkup, accentMarks, typographicQuotes, runs, plain, symbols, blackboard };

// MARK: - TeX pour la mise en page native

/// Le TeX des sites (MathJax, KaTeX : Courseware, Moodle, Ed, Botafogo) → le
/// TeX que le moteur de formules natif sait mettre en page.
///
/// Ce moteur ne connaît pas tout : `\dfrac`, `\operatorname`, l'environnement
/// `array`, `\mathscr`… y échouaient, et il **efface** en silence les symboles
/// Unicode (`≤`, `ℝ`). On traduit ce qui a un équivalent ; s'il reste un
/// caractère qu'il effacerait, `null` : la formule garde l'affichage en ligne
/// (`MathMarkup`), lisible à défaut d'être mise en page. Pur, testé.

export function normalize(source: string): string | null {
  let text = source;
  for (const [from, to] of [["&amp;", "&"], ["&lt;", "<"], ["&gt;", ">"], [" ", " "]]) text = replaceAll(text, from, to);
  text = environments(text);
  text = fittingColumns(text);
  text = commands(text);
  // `\:` (espace moyenne) : le moteur ne connaît que `\;`.
  text = replaceAll(text, "\\:", "\;");
  // `\overline{S}_{a^{b}}` fait tomber le moteur ; posé sur un groupe
  // vide (`\overline{S}{}_{…}`), l'indice se dessine pareil.
  text = text.replace(/(\\overline\{(?:[^{}]|\{[^{}]*\})*\})(\s*[_^])/g, "$1{}$2");
  text = unicode(text);
  // Un moins en tête de case (`& -1`) : le moteur l'espace comme une
  // soustraction (« − 1 ») ; rapproché, il se lit comme en LaTeX.
  text = text.replace(/(&|\\\\|\\begin\{[a-zA-Z*]+\})(\s*)-(?!\\!)/g, "$1$2-\\!\\!");
  const trimmed = trimWhitespacesAndNewlines(text);
  if (trimmed === "") return null;
  for (const ch of trimmed) if (ch.codePointAt(0)! > 0xff) return null;
  return trimmed;
}

// MARK: Environnements

/// Renommages d'environnements, `null` = l'environnement disparaît (remplacé par une espace).
const renamedEnvironments: [string, string | null][] = [
  ["array", "matrix"], ["smallmatrix", "matrix"],
  ["align", "aligned"], ["align*", "aligned"], ["flalign", "aligned"], ["flalign*", "aligned"],
  ["eqnarray", "aligned"], ["eqnarray*", "aligned"], ["alignat", "aligned"], ["alignat*", "aligned"], ["alignedat", "aligned"],
  ["gather*", "gather"], ["multline", "gather"], ["multline*", "gather"], ["gathered", "gather"],
  ["dcases", "cases"], ["rcases", "cases"],
  // Un seul bloc de formule : l'environnement n'ajoute que le numéro.
  ["equation", null], ["equation*", null], ["displaymath", null], ["math", null],
];

function environments(source: string): string {
  let text = source;
  // `array` : une matrice dont on ignore l'alignement des colonnes.
  text = text.replace(/\\begin\{array\}\s*(\[[a-z]\])?\s*\{[^{}]*\}/g, () => "\\begin{matrix}");
  text = text.replace(/\\begin\{alignat\*?\}\s*\{\d+\}/g, () => "\\begin{aligned}");
  for (const [name, replacement] of renamedEnvironments) {
    for (const side of ["begin", "end"]) {
      const tag = `\\${side}{${name}}`;
      text = replaceAll(text, tag, replacement === null ? " " : `\\${side}{${replacement}}`);
    }
  }
  return text;
}

/// Le moteur veut exactement deux colonnes dans `aligned` et `cases` :
/// `aligned` sans `&` devient `gather`, avec plus de deux colonnes une
/// matrice ; une ligne de `cases` sans `&` reçoit une seconde case vide.
export function fittingColumns(source: string): string {
  let text = source;
  for (const name of ["aligned", "cases"]) {
    const open = `\\begin{${name}}`, close = `\\end{${name}}`;
    let searchStart = 0;
    for (;;) {
      const begin = text.indexOf(open, searchStart);
      if (begin < 0) break;
      const beginEnd = begin + open.length;
      // La fin qui lui correspond (les environnements s'emboîtent).
      let depth = 1;
      let cursor = beginEnd;
      let end: number | null = null;
      while (depth > 0) {
        const nextOpen = text.indexOf(open, cursor);
        const nextClose = text.indexOf(close, cursor);
        if (nextClose < 0) break;
        if (nextOpen >= 0 && nextOpen < nextClose) {
          depth += 1; cursor = nextOpen + open.length;
        } else {
          depth -= 1; cursor = nextClose + close.length;
          if (depth === 0) end = nextClose;
        }
      }
      if (end === null) break;
      const body = text.slice(beginEnd, end);
      const rows = topLevelRows(body);
      const columns = rows.map(topLevelAmpersands);
      let replacement: string | null = null;
      if (name === "aligned") {
        const widest = Math.max(0, ...columns);
        if (widest === 0) {
          replacement = "\\begin{gather}" + body + "\\end{gather}";
        } else if (widest > 1) {
          replacement = "\\begin{matrix}" + body + "\\end{matrix}";
        } else if (columns.includes(0)) {
          const fixed = rows.map((row, i) => (columns[i] === 0 && trimWhitespaces(row) !== "" ? "&" + row : row));
          replacement = open + fixed.join("\\\\") + close;
        }
      } else if (columns.includes(0)) {
        const fixed = rows.map((row, i) => (columns[i] === 0 && trimWhitespaces(row) !== "" ? row + "&" : row));
        replacement = open + fixed.join("\\\\") + close;
      }
      if (replacement !== null) {
        text = text.slice(0, begin) + replacement + text.slice(end + close.length);
        searchStart = Math.min(text.length, begin + replacement.length);
      } else {
        searchStart = end + close.length;
      }
    }
  }
  return text;
}

/// Les lignes d'un environnement (`\\`), sans couper dans un groupe ni un environnement emboîté.
function topLevelRows(body: string): string[] {
  const rows: string[] = [];
  let current = "", depth = 0;
  const chars = characters(body);
  let i = 0;
  while (i < chars.length) {
    const rest = chars.slice(i, Math.min(chars.length, i + 7)).join("");
    if (rest.startsWith("\\begin")) depth += 1;
    if (rest.startsWith("\\end")) depth -= 1;
    if (chars[i] === "{") depth += 1; else if (chars[i] === "}") depth -= 1;
    if (chars[i] === "\\" && i + 1 < chars.length) {
      if (chars[i + 1] === "\\" && depth === 0) { rows.push(current); current = ""; i += 2; continue; }
      current += chars[i] + chars[i + 1]; i += 2; continue;
    }
    current += chars[i]; i += 1;
  }
  rows.push(current);
  return rows;
}

function topLevelAmpersands(row: string): number {
  let count = 0, depth = 0;
  const chars = characters(row);
  let i = 0;
  while (i < chars.length) {
    const rest = chars.slice(i, Math.min(chars.length, i + 7)).join("");
    if (rest.startsWith("\\begin")) depth += 1; else if (rest.startsWith("\\end")) depth -= 1;
    if (chars[i] === "\\") { i += 2; continue; }
    if (chars[i] === "{") depth += 1;
    else if (chars[i] === "}") depth -= 1;
    else if (chars[i] === "&" && depth === 0) count += 1;
    i += 1;
  }
  return count;
}

// MARK: Commandes

/// Commande → son équivalent (sans la barre oblique de tête, sauf mention).
export const renamed = new Map<string, string>(Object.entries({
  dfrac: "\\frac", tfrac: "\\frac", cfrac: "\\frac",
  mathscr: "\\mathcal", boldsymbol: "\\mathbf", pmb: "\\mathbf", mathbold: "\\mathbf",
  operatorname: "\\mathrm", mathop: "\\mathrm",
  textnormal: "\\text", textup: "\\text", mbox: "\\text", hbox: "\\text", textmd: "\\text",
  overrightarrow: "\\vec", overleftarrow: "\\vec", overline: "\\overline",
  varnothing: "\\emptyset", leqslant: "\\leq", geqslant: "\\geq",
  lvert: "|", rvert: "|", lVert: "\\Vert", rVert: "\\Vert",
  implies: "\\Longrightarrow", impliedby: "\\Longleftarrow",
  intercal: "\\top", transpose: "\\top",
  bmod: "\\mathrm{mod}", dots: "\\ldots", dotsc: "\\ldots", dotsb: "\\cdots", dotsm: "\\cdots", dotso: "\\ldots",
  hookrightarrow: "\\rightarrow", xrightarrow: "\\longrightarrow", xleftarrow: "\\longleftarrow",
  smallsetminus: "\\setminus", hline: "",
  lbrack: "[", rbrack: "]", lparen: "(", rparen: ")",
  R: "\\mathbb{R}", N: "\\mathbb{N}", Z: "\\mathbb{Z}", Q: "\\mathbb{Q}", C: "\\mathbb{C}",
  bR: "\\mathbb{R}", bC: "\\mathbb{C}", bN: "\\mathbb{N}", bZ: "\\mathbb{Z}", bQ: "\\mathbb{Q}",
  enspace: "\\quad", thinspace: "\\,", medspace: "\;", thickspace: "\;",
  bigl: "", bigr: "", Bigl: "", Bigr: "", biggl: "", biggr: "", Biggl: "", Biggr: "",
  big: "", Big: "", bigg: "", Bigg: "", bigm: "", Bigm: "",
  nonumber: "", notag: "", nolimits: "", ensuremath: "", boxed: "",
  overbrace: "\\overline", underbrace: "\\underline", displaylimits: "", middle: "",
  // Tailles de texte et classes d'atomes : le moteur choisit seul.
  small: "", footnotesize: "", scriptsize: "", tiny: "", normalsize: "", large: "", Large: "",
  mathopen: "", mathclose: "", mathrel: "", mathbin: "", mathord: "", mathpunct: "", mathinner: "",
  // Un terme barré (simplification) : grisé, faute de trait.
  cancel: "\\textcolor{gray}", bcancel: "\\textcolor{gray}", xcancel: "\\textcolor{gray}", sout: "\\textcolor{gray}",
  // Des symboles absents de la fonte : d'autres, distincts entre eux.
  bigstar: "\\star", clubsuit: "\\bullet", spadesuit: "\\triangle", blacklozenge: "\\square",
  heartsuit: "\\circ", diamondsuit: "\\ast", diamond: "\\ast", blacksquare: "\\square",
  LaTeX: "\\text{LaTeX}", TeX: "\\text{TeX}",
}));

/// Commandes dont l'argument n'a pas d'équivalent affichable : retirées avec lui.
export const droppedWithArgument = new Set(["label", "tag", "cline", "vspace", "phantom", "hphantom", "vphantom", "ref", "eqref"]);

function commands(source: string): string {
  const chars = characters(source);
  let out = "";
  let i = 0;
  const skipSpaces = () => { while (i < chars.length && chars[i] === " ") i += 1; };
  /// L'argument entre accolades qui suit (sans les accolades), et avance après lui.
  const readGroup = (): string | null => {
    skipSpaces();
    if (!(i < chars.length && chars[i] === "{")) return null;
    let depth = 0;
    const start = i;
    while (i < chars.length) {
      if (chars[i] === "\\") { i += 2; continue; }
      if (chars[i] === "{") depth += 1;
      if (chars[i] === "}") {
        depth -= 1;
        if (depth === 0) { i += 1; return chars.slice(start + 1, i - 1).join(""); }
      }
      i += 1;
    }
    return chars.slice(start + 1).join("");
  };
  while (i < chars.length) {
    const char = chars[i];
    if (!(char === "\\" && i + 1 < chars.length && isLetter(chars[i + 1]))) {
      // `\\`, `\{`, `\,` : recopiés tels quels, par deux.
      if (char === "\\" && i + 1 < chars.length) { out += char + chars[i + 1]; i += 2; continue; }
      out += char; i += 1; continue;
    }
    let j = i + 1;
    while (j < chars.length && isLetter(chars[j])) j += 1;
    const name = chars.slice(i + 1, j).join("");
    i = j;
    if (i < chars.length && chars[i] === "*" && ["operatorname", "tag", "hspace", "vspace"].includes(name)) i += 1;
    let top: string | null, bottom: string | null, base: string | null, rows: string | null;
    if (droppedWithArgument.has(name)) {
      readGroup();
    } else if (name === "hspace") {
      readGroup();
      out += "\\quad ";
    } else if (name === "dfrac" && (top = readGroup()) !== null && (bottom = readGroup()) !== null) {
      // La fraction « de display » au milieu d'une phrase reste grande.
      out += "{\\displaystyle\\frac{" + commands(top) + "}{" + commands(bottom) + "}}";
    } else if (["stackrel", "overset", "underset"].includes(name) && (top = readGroup()) !== null && (base = readGroup()) !== null) {
      // `\stackrel{BH}{=}` : pas d'empilement dans le moteur, la marque en exposant.
      out += "{" + commands(base) + "}" + (name === "underset" ? "_{" : "^{") + commands(top) + "}";
    } else if (name === "substack" && (rows = readGroup()) !== null) {
      out += "{\\begin{matrix}" + commands(rows) + "\\end{matrix}}";
    } else if (name === "not") {
      // `\not\in`, `\not=` : les relations barrées que le moteur connaît.
      skipSpaces();
      const rest = chars.slice(i).join("");
      if (rest.startsWith("\\in") && !(characters(rest.slice(3)).length > 0 && isLetter(characters(rest.slice(3))[0]))) {
        out += "\\notin"; i += 3;
      } else if (rest.startsWith("=")) {
        out += "\\neq"; i += 1;
      } else {
        out += "\\not";
      }
      if (i < chars.length && isLetter(chars[i])) out += " ";
    } else if (name === "pmod") {
      out += "\\quad(\\mathrm{mod}\\ " + commands(readGroup() ?? "") + ")";
    } else if (renamed.has(name)) {
      const replacement = renamed.get(name)!;
      out += replacement;
      // Ne pas coller la commande suivante à des lettres : `\R x` → `\mathbb{R} x`.
      const lastChar = characters(replacement).pop();
      if (lastChar !== undefined && isLetter(lastChar) && i < chars.length && isLetter(chars[i])) out += " ";
    } else {
      out += "\\" + name;
    }
  }
  return out;
}

// MARK: Unicode

/// Les symboles qu'un texte copié (ou Ed) met dans une formule.
export const unicodeCommands = new Map<string, string>([
  ["ℝ", "\\mathbb{R}"], ["ℂ", "\\mathbb{C}"], ["ℕ", "\\mathbb{N}"], ["ℤ", "\\mathbb{Z}"], ["ℚ", "\\mathbb{Q}"],
  ["−", "-"], ["–", "-"], ["′", "'"], ["″", "''"], ["⩽", "\\leq"], ["⩾", "\\geq"], ["‖", "\\Vert"], ["∣", "\\mid"],
  ["≤", "\\leq"], ["≥", "\\geq"], ["≠", "\\neq"], ["≈", "\\approx"], ["≡", "\\equiv"], ["∼", "\\sim"], ["≃", "\\simeq"], ["≅", "\\cong"],
  ["∈", "\\in"], ["∉", "\\notin"], ["∋", "\\ni"], ["⊂", "\\subset"], ["⊆", "\\subseteq"], ["⊃", "\\supset"], ["⊇", "\\supseteq"],
  ["∪", "\\cup"], ["∩", "\\cap"], ["∅", "\\emptyset"], ["∀", "\\forall"], ["∃", "\\exists"], ["¬", "\\neg"], ["∧", "\\wedge"], ["∨", "\\vee"],
  ["→", "\\to"], ["←", "\\leftarrow"], ["↦", "\\mapsto"], ["⇒", "\\Rightarrow"], ["⇐", "\\Leftarrow"], ["⇔", "\\Leftrightarrow"],
  ["⟶", "\\longrightarrow"], ["⟹", "\\Longrightarrow"], ["⟺", "\\Longleftrightarrow"], ["↔", "\\leftrightarrow"],
  ["×", "\\times"], ["·", "\\cdot"], ["⋅", "\\cdot"], ["÷", "\\div"], ["±", "\\pm"], ["∓", "\\mp"], ["∘", "\\circ"], ["⊗", "\\otimes"], ["⊕", "\\oplus"],
  ["∞", "\\infty"], ["∑", "\\sum"], ["∏", "\\prod"], ["∫", "\\int"], ["∮", "\\oint"], ["∂", "\\partial"], ["∇", "\\nabla"], ["√", "\\sqrt"],
  ["…", "\\ldots"], ["⋯", "\\cdots"], ["⋮", "\\vdots"], ["⋱", "\\ddots"], ["ℓ", "\\ell"], ["⊥", "\\perp"], ["∖", "\\setminus"],
  ["⟨", "\\langle"], ["⟩", "\\rangle"], ["⌊", "\\lfloor"], ["⌋", "\\rfloor"], ["⌈", "\\lceil"], ["⌉", "\\rceil"], ["°", "^\\circ"],
  ["α", "\\alpha"], ["β", "\\beta"], ["γ", "\\gamma"], ["δ", "\\delta"], ["ε", "\\varepsilon"], ["ϵ", "\\epsilon"], ["ζ", "\\zeta"],
  ["η", "\\eta"], ["θ", "\\theta"], ["ϑ", "\\vartheta"], ["ι", "\\iota"], ["κ", "\\kappa"], ["λ", "\\lambda"], ["μ", "\\mu"], ["ν", "\\nu"],
  ["ξ", "\\xi"], ["π", "\\pi"], ["ρ", "\\rho"], ["σ", "\\sigma"], ["τ", "\\tau"], ["υ", "\\upsilon"], ["φ", "\\varphi"], ["ϕ", "\\phi"],
  ["χ", "\\chi"], ["ψ", "\\psi"], ["ω", "\\omega"], ["Γ", "\\Gamma"], ["Δ", "\\Delta"], ["Θ", "\\Theta"], ["Λ", "\\Lambda"], ["Ξ", "\\Xi"],
  ["Π", "\\Pi"], ["Σ", "\\Sigma"], ["Φ", "\\Phi"], ["Ψ", "\\Psi"], ["Ω", "\\Omega"],
  [" ", "\\,"], [" ", "\\,"],
]);

function unicode(source: string): string {
  if (!/[^\u0000-\u007f]/.test(source)) return source;
  let out = "";
  const chars = characters(source);
  chars.forEach((char, index) => {
    const command = unicodeCommands.get(char);
    if (command !== undefined) {
      out += command;
      // `αx` → `\alpha x`, pas `\alphax`.
      const last = characters(command).pop()!;
      if (isLetter(last) && index + 1 < chars.length && isLetter(chars[index + 1])) out += " ";
    } else {
      out += char;
    }
  });
  return out;
}

export const TeXNormalizer = { normalize, fittingColumns, renamed, droppedWithArgument, unicodeCommands };
