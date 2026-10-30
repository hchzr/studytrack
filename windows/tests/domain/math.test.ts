// Port de Validation/main.swift : MathMarkup, MathEngine, MathWorkbench, TeXNormalizer.
import { describe, expect, it } from "vitest";
import { MathEngine, MathEnvironment } from "../../src/domain/mathEngine.ts";
import { Complex, MathWorkbench, MathSession } from "../../src/domain/mathWorkbench.ts";
import type { MathOutput } from "../../src/domain/mathWorkbench.ts";
import { MathMarkup, TeXNormalizer } from "../../src/domain/mathMarkup.ts";

describe("MathMarkup : formules lisibles", () => {
  const M = MathMarkup;
  const r = (s: string): string[] =>
    M.runs(s).map((run) => {
      switch (run.style) {
        case "normal": return run.text;
        case "subscripted": return `_[${run.text}]`;
        case "superscripted": return `^[${run.text}]`;
      }
    });
  it("indice simple", () => { expect(r("a_n")).toEqual(["a", "_[n]"]); });
  it("indice entre accolades", () => { expect(r("x_{n+1} = 2")).toEqual(["x", "_[n+1]", " = 2"]); });
  it("exposant", () => { expect(r("n^2+1")).toEqual(["n", "^[2]", "+1"]); });
  it("symboles", () => { expect(M.plain("|a_n - \\ell| \\le \\varepsilon")).toBe("|an - ℓ| ≤ ε"); });
  it("fraction courte en forme de fraction", () => { expect(r("$\\frac{1}{2}$")).toEqual(["^[1]", "⁄", "_[2]"]); });
  it("fraction longue parenthésée", () => { expect(M.plain("\\frac{an+b}{cn+d}")).toBe("(an+b)/(cn+d)"); });
  it("racine d'une expression", () => { expect(M.plain("\\sqrt{n^2+2}")).toBe("√(n2+2)"); });
  it("racine simple", () => { expect(M.plain("\\sqrt{x}")).toBe("√x"); });
  it("ensembles", () => { expect(M.plain("n \\in \\mathbb{N}^*")).toBe("n ∈ ℕ*"); });
  it("limite", () => { expect(M.plain("\\lim_{n \\to \\infty} a_n = L")).toBe("limn → ∞ an = L"); });
  it("un « _ » isolé entre espaces reste du texte", () => { expect(r("prix _ unitaire")).toEqual(["prix _ unitaire"]); });
  it("commande inconnue : son nom, pas un trou", () => { expect(M.plain("\\unknown{x}")).toBe("unknownx"); });
  it("texte sans formule : rien à faire", () => { expect(M.hasMarkup("Montrer la borne")).toBe(false); });
});

describe("Formules : commandes de police", () => {
  it("\\mathsf{i} → i", () => { expect(MathMarkup.plain("$z^2=-3+4\\mathsf{i}$")).toBe("z2=-3+4i"); });
  it("\\textbf, \\mathtt", () => { expect(MathMarkup.plain("$\\textbf{v}$ et $\\mathtt{x}$")).toBe("v et x"); });
  it("Math : \\mathsf{i} → i", () => {
    expect(MathMarkup.plain("z^2=-3+4\\mathsf{i}")).toBe(MathMarkup.plain("z^2=-3+4i"));
  });
});

describe("Botafogo : noms et macros (MathMarkup)", () => {
  it("macro Botafogo \\bR → ℝ", () => { expect(MathMarkup.plain("$x \\in \\bR$")).toBe("x ∈ ℝ"); });
});

describe("Calculatrice du mode étude (MathEngine)", () => {
  const env = new MathEnvironment();
  const calc = (text: string): number | null => {
    try { return env.run(text); } catch { return null; }
  };
  const fails = (text: string): boolean => {
    try { env.run(text); return false; } catch { return true; }
  };
  const near = (a: number | null, b: number, eps = 1e-9): boolean => a !== null && Math.abs(a - b) < eps;

  it("priorités : 1 + 2·3 = 7", () => { expect(near(calc("1 + 2 * 3"), 7)).toBe(true); });
  it("puissance à droite : 2^3^2 = 512", () => { expect(near(calc("2^3^2"), 512)).toBe(true); });
  it("−2² = −4 (l'exposant d'abord)", () => { expect(near(calc("-2^2"), -4)).toBe(true); });
  it("multiplication implicite entre parenthèses", () => { expect(near(calc("(1+2)(3+4)"), 21)).toBe(true); });
  it("2π implicite", () => { expect(near(calc("2pi"), 2 * Math.PI)).toBe(true); });
  it("factorielle", () => { expect(near(calc("5!"), 120)).toBe(true); });
  it("sin(π/6) = 1/2", () => { expect(near(calc("sin(pi/6)"), 0.5, 1e-12)).toBe(true); });
  it("notation scientifique", () => { expect(near(calc("1e-3 * 2"), 0.002)).toBe(true); });
  it("2e = 2·e (pas une notation scientifique)", () => { expect(near(calc("2e"), 2 * Math.E)).toBe(true); });
  it("ans reprend le dernier résultat", () => { expect(near(calc("ans + 1"), 2 * Math.E + 1)).toBe(true); });
  it("coefficient binomial", () => { expect(near(calc("binom(5, 2)"), 10)).toBe(true); });
  it("le point-virgule sépare aussi les arguments", () => { expect(near(calc("max(3; 7; 2)"), 7)).toBe(true); });
  it("variable nommée puis réutilisée", () => {
    expect(near(calc("a = 3"), 3) && near(calc("2a + 1"), 7)).toBe(true);
  });
  it("a(a+1) : un produit, pas un appel", () => { expect(near(calc("a(a+1)"), 12)).toBe(true); });
  it("définir une fonction ne rend pas de valeur", () => { expect(calc("f(x) = x^2 - 2") === null).toBe(true); });
  it("appeler une fonction définie", () => { expect(near(calc("f(3)"), 7)).toBe(true); });
  it("dérivée numérique : f'(3) = 6", () => { expect(near(calc("f'(3)"), 6, 1e-6)).toBe(true); });
  it("dérivée seconde : f''(1) = 2", () => { expect(near(calc("f''(1)"), 2, 1e-3)).toBe(true); });
  it("intégrale de Simpson : ∫₀³ (x² − 2) dx = 3", () => { expect(near(calc("int(f, 0, 3)"), 3, 1e-9)).toBe(true); });
  it("racine par dichotomie : √2", () => { expect(near(calc("root(f, 0, 2)"), Math.sqrt(2), 1e-10)).toBe(true); });
  it("deux racines de x² − 2 sur [−3, 3]", () => { expect(MathEngine.roots("f", -3, 3, env).length === 2).toBe(true); });
  it("une asymptote n'est pas une racine", () => {
    expect(calc("g(x) = 1/x") === null && MathEngine.roots("g", -1, 1, env).length === 0).toBe(true);
  });
  it("le tracé saute la valeur indéfinie", () => { expect(MathEngine.sample("g", -1, 1, 5, env).length === 4).toBe(true); });
  it("racine d'un négatif : erreur, pas NaN", () => { expect(fails("sqrt(-1)")).toBe(true); });
  it("division par zéro : erreur", () => { expect(fails("1/0")).toBe(true); });
  it("syntaxe incomplète et nom inconnu refusés", () => { expect(fails("2 +") && fails("zz + 1")).toBe(true); });
  it("une constante ne se redéfinit pas", () => { expect(fails("pi = 3")).toBe(true); });
  it("mode degrés", () => {
    env.degrees = true;
    expect(near(calc("sin(30)"), 0.5, 1e-12)).toBe(true);
  });
  it("affichage : arrondi propre", () => {
    expect(MathEngine.format(0.1 + 0.2) === "0.3" && MathEngine.format(42) === "42" && MathEngine.format(-0.0) === "0").toBe(true);
  });
  it("affichage : notation scientifique", () => { expect(MathEngine.format(6.02e23).includes("10^23")).toBe(true); });
});

describe("Calcul : comme sur papier (MathWorkbench)", () => {
  const session = new MathSession();
  const run = (line: string): MathOutput | null => {
    try { return MathWorkbench.run(line, session); } catch { return null; }
  };
  const solutions = (line: string): string[] | null => {
    const output = run(line);
    return output && output.kind === "solutions" ? output.roots : null;
  };

  it("une inconnue libre : tracée, sans « x n'est pas défini »", () => {
    expect(run("x^2 - 2")).toEqual({ kind: "plotted", definition: "f(x) = x^2 - 2" });
    expect(session.engine.functions.has("f")).toBe(true);
  });
  it("une deuxième fonction : g", () => {
    expect(run("sin(t)")).toEqual({ kind: "plotted", definition: "g(t) = sin(t)" });
  });
  it("équation du second degré", () => {
    const roots = solutions("x^2 = 2");
    const exact = JSON.stringify(run("x^2 = 2")) === JSON.stringify({ kind: "solutions", variable: "x", roots: ["-1.41421", "1.41421"] });
    expect(exact || (roots !== null && roots.length === 2)).toBe(true);
  });
  it("z⁵ = 1 : cinq racines, dont 1 et e^(i·2π/5)", () => {
    const roots = solutions("z^5 = 1");
    expect(roots).not.toBeNull();
    expect(roots!.length === 5 && roots!.includes("1") && roots!.includes("e^(i·2π/5)")).toBe(true);
  });
  it("z² = -3+4i : ±(1+2i)", () => {
    const roots = solutions("z^2 = -3+4i");
    expect(roots).not.toBeNull();
    expect(new Set(roots!)).toEqual(new Set(["1 + 2i", "-1 - 2i"]));
  });
  it("cos(x) = x : racine numérique", () => {
    const roots = solutions("cos(x) = x");
    expect(roots).not.toBeNull();
    expect(roots!.length === 1 && roots![0].startsWith("0.739")).toBe(true);
  });
  it("division complexe exacte", () => {
    expect(run("(1+2i)/(3-i)")).toEqual({ kind: "complex", value: "1/10 + 7/10i", polar: new Complex(0.1, 0.7).polar });
  });
  it("e^(iπ) = -1", () => {
    const output = run("e^(i*pi)");
    expect(output?.kind).toBe("complex");
    expect(output!.kind === "complex" && output!.value).toBe("-1");
  });
  it("forme polaire", () => {
    const polar = new Complex(1, 1).polar;
    expect(polar === "1.41421·e^(i·1π/4)" || polar.includes("π/4")).toBe(true);
  });
  it("les définitions marchent toujours", () => {
    expect(run("a = 3")).toEqual({ kind: "value", value: "3" });
    expect(run("2a + 1")).toEqual({ kind: "value", value: "7" });
  });
  it("matrice définie", () => {
    expect(run("A = [[1,2],[3,4]]")).toEqual({ kind: "matrix", rows: [["1", "2"], ["3", "4"]] });
  });
  it("déterminant", () => { expect(run("det(A)")).toEqual({ kind: "value", value: "-2" }); });
  it("inverse, en fractions", () => {
    expect(run("inv(A)")).toEqual({ kind: "matrix", rows: [["-2", "1"], ["3/2", "-1/2"]] });
  });
  it("produit, scalaire", () => {
    expect(run("A*A")).toEqual({ kind: "matrix", rows: [["7", "10"], ["15", "22"]] });
    expect(run("2A")).toEqual({ kind: "matrix", rows: [["2", "4"], ["6", "8"]] });
  });
  it("forme échelonnée réduite, rang", () => {
    expect(run("rref([[1,2,3],[2,4,6]])")).toEqual({ kind: "matrix", rows: [["1", "2", "3"], ["0", "0", "0"]] });
    expect(run("rank([[1,2,3],[2,4,6]])")).toEqual({ kind: "value", value: "1" });
  });
  it("système A·x = b", () => {
    expect(run("solve(A, [5,6])")).toEqual({ kind: "matrix", rows: [["-4"], ["9/2"]] });
  });
  it("matrice non inversible refusée", () => {
    expect(() => MathWorkbench.run("inv([[1,2],[2,4]])", session)).toThrow();
  });
  it("fractions quand c'en est", () => {
    expect(MathWorkbench.format(0.75) === "3/4" && MathWorkbench.format(2) === "2"
      && MathWorkbench.format(Math.PI) === MathEngine.format(Math.PI)).toBe(true);
  });
});

// Les vérifications de TeXNormalizer sont dispersées dans plusieurs sections de
// main.swift (« Claude dans le mode étude », « Botafogo : polycopié ») ; seules
// celles qui n'exercent que ce moteur sont portées ici.
describe("TeX des sites pour le moteur natif (TeXNormalizer)", () => {
  const N = TeXNormalizer.normalize;
  it("TeX : \\dfrac reste grand", () => { expect(N("\\dfrac{1}{2}")).toBe("{\\displaystyle\\frac{1}{2}}"); });
  it("TeX : \\tfrac → \\frac", () => { expect(N("\\tfrac{1}{2}")).toBe("\\frac{1}{2}"); });
  it("TeX : moins en tête de case rapproché", () => {
    expect(N("\\begin{pmatrix} -1 & -2 \\\\ -3 & 4 \\end{pmatrix}"))
      .toBe("\\begin{pmatrix} -\\!\\!1 & -\\!\\!2 \\\\ -\\!\\!3 & 4 \\end{pmatrix}");
  });
  it("TeX : soustraction intacte", () => { expect(N("a - b")).toBe("a - b"); });
  it("TeX : \\operatorname → \\mathrm", () => { expect(N("\\operatorname{rg}(A)")).toBe("\\mathrm{rg}(A)"); });
  it("TeX : trait au-dessus indicé posé sur un groupe vide (plantage SwiftMath)", () => {
    expect(N("\\overline{S}_{\\sigma^{(N)}}")).toBe("\\overline{S}{}_{\\sigma^{(N)}}");
  });
  it("TeX : aligned sans & → gather", () => {
    expect(N("\\begin{aligned}x\\mapsto f(x)\\end{aligned}")).toBe("\\begin{gather}x\\mapsto f(x)\\end{gather}");
  });
  it("TeX : aligned à 4 colonnes → matrix", () => {
    expect(N("\\begin{aligned}a&=b&c&=d\\end{aligned}")).toBe("\\begin{matrix}a&=b&c&=d\\end{matrix}");
  });
  it("TeX : cases à une colonne complété", () => {
    expect(N("\\begin{cases}\\text{a}\\\\ \\text{b}\\end{cases}")).toBe("\\begin{cases}\\text{a}&\\\\ \\text{b}&\\end{cases}");
  });
  it("TeX : aligned emboîtant cases intact", () => {
    expect(N("\\begin{aligned}a&=b\\\\&=\\begin{cases}1&x\\\\2&y\\end{cases}\\end{aligned}")?.includes("\\begin{aligned}")).toBe(true);
  });
  it("TeX : \\not\\in, \\not=", () => {
    expect(N("x\\not\\in A") === "x\\notin A" && N("x\\not=y") === "x\\neq y").toBe(true);
  });
  it("TeX : \\stackrel → exposant", () => { expect(N("a\\stackrel{BH}{=}b")).toBe("a{=}^{BH}b"); });
  it("TeX : \\small retiré", () => { expect(N("{\\small a+b}")).toBe("{ a+b}"); });
  it("TeX : \\cancel grisé", () => { expect(N("\\cancel{x}")).toBe("\\textcolor{gray}{x}"); });
  it("TeX : \\substack → matrix", () => {
    expect(N("\\sum_{\\substack{n\\geq1\\\\n}}")).toBe("\\sum_{{\\begin{matrix}n\\geq1\\\\n\\end{matrix}}}");
  });
  it("TeX : \\: → \;", () => { expect(N("a\\:b")).toBe("a\;b"); });
  it("TeX : \\underbrace → trait dessous, l'annotation reste dessous", () => {
    expect(N("\\underbrace{a+2}_{=0}")).toBe("\\underline{a+2}_{=0}");
  });
  it("TeX : \\mathscr", () => {
    expect(N("\\mathscr{B}=(v_1,\\ldots,v_n)")).toBe("\\mathcal{B}=(v_1,\\ldots,v_n)");
  });
  it("TeX : array → matrix", () => {
    expect(N("\\left[\\begin{array}{cc|c} 1 & 2 & 3 \\end{array}\\right]"))
      .toBe("\\left[\\begin{matrix} 1 & 2 & 3 \\end{matrix}\\right]");
  });
  it("TeX : align*, label retiré", () => {
    expect(N("\\begin{align*} a &= b \\label{eq} \\end{align*}")).toBe("\\begin{aligned} a &= b  \\end{aligned}");
  });
  it("TeX : equation sans numéro", () => { expect(N("\\begin{equation} x \\end{equation}")).toBe("x"); });
  it("TeX : macro \\R", () => { expect(N("x \\in \\R")).toBe("x \\in \\mathbb{R}"); });
  it("TeX : symboles Unicode → commandes", () => { expect(N("a ≤ b, x ∈ ℝ")).toBe("a \\leq b, x \\in \\mathbb{R}"); });
  it("TeX : entités et retour à la ligne gardé", () => { expect(N("a &amp; b \\\\ c")).toBe("a & b \\\\ c"); });
  it("TeX : \\pmod", () => { expect(N("a \\pmod{n}")).toBe("a \\quad(\\mathrm{mod}\\ n)"); });
  it("TeX : symbole inconnu → affichage en ligne", () => { expect(N("x ⊞ y")).toBeNull(); });
  it("TeX : \\Re n'est pas \\R", () => { expect(N("\\Re z")).toBe("\\Re z"); });
});
