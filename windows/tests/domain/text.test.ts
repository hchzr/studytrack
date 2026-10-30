// Port de Validation/main.swift : TextRepair, MathMarkup (accents) et HTMLLayout.
import { describe, expect, it } from "vitest";
import { TextRepair } from "../../src/domain/textRepair.ts";
import { MathMarkup } from "../../src/domain/mathMarkup.ts";
import { HTMLLayout } from "../../src/domain/htmlLayout.ts";
import { SeriesLayoutParser } from "../../src/domain/seriesLayout.ts";

describe("Accents réparés à la source (TextRepair, MathMarkup)", () => {
  it("PDF LaTeX : l'accent aigu dessiné avant la lettre rejoint sa lettre", () => {
    expect(TextRepair.clean("S´erie 3 : ´equations diff´erentielles")).toBe("Série 3 : équations différentielles");
  });
  it("…et dessiné après la lettre aussi", () => {
    expect(TextRepair.composeAccents("e´te´, re´sume´")).toBe("été, résumé");
  });
  it("grave, circonflexe, tréma, cédille", () => {
    expect(TextRepair.composeAccents("pr`es de la fenˆetre, M¨uller, garc¸on")).toBe("près de la fenêtre, Müller, garçon");
  });
  it("« ´ » tapé pour une apostrophe devient une apostrophe", () => {
    expect(TextRepair.composeAccents("l´analyse, qu´il, jusqu´ici, d´efinition")).toBe("l’analyse, qu’il, jusqu’ici, définition");
  });
  it("un exposant (même entre deux lettres) ou du code ne sont pas touchés", () => {
    expect(TextRepair.composeAccents("x^2 + `code`, x^y, ℝ^n")).toBe("x^2 + `code`, x^y, ℝ^n");
  });
  it("Moodle : entités nommées, décimales et hexadécimales", () => {
    expect(TextRepair.clean("S&eacute;rie 4 &#8211; l&#039;int&#xE9;grale &amp; co")).toBe("Série 4 – l'intégrale & co");
  });
  it("Moodle : texte UTF-8 relu en Latin-1 (double encodage) réparé", () => {
    // « SÃ©rie 2 Ã  rendre â€” corrigÃ© » (la tirette est le « ” » de Windows-1252)
    const mojibake = "SÃ©rie 2 Ã  rendre â€” corrigÃ©";
    expect(TextRepair.clean(mojibake)).toBe("Série 2 à rendre — corrigé");
  });
  it("forme composée (NFC) : un « é » est un seul caractère", () => {
    expect(TextRepair.clean("énoncé") === "énoncé" && [...TextRepair.clean("énoncé")].length === 6).toBe(true);
  });
  it("un texte propre ressort intact", () => {
    const clean = "Algèbre linéaire — Série 4 : l’ensemble A′ = {n : xₙ < 0}, f''(x) ≥ 0";
    expect(TextRepair.clean(clean)).toBe(clean);
  });
  it("MathMarkup : accents LaTeX composés au lieu de « 'e »", () => {
    expect(MathMarkup.plain(String.raw`Montrer que la s\'erie est \`a termes positifs, o\`u \^etre, na\"\i ve, gar\c{c}on`))
      .toBe("Montrer que la série est à termes positifs, où être, naïve, garçon");
  });
  it("MathMarkup : ``guillemets'' LaTeX, sans toucher f''(x)", () => {
    expect(MathMarkup.plain("Quelques indéterminations ``\\frac{0}{0}''") === "Quelques indéterminations “0⁄0”"
      && MathMarkup.plain("f''(x) > 0") === "f''(x) > 0").toBe(true);
  });
});

describe("Page web d'exercices, lue comme une mise en page", () => {
  const html = `
    <html><head><style>.x{}</style></head><body><nav>Menu</nav>
    <h1>Série 5 — Récursivité</h1>
    <h2>Exercice 1 : Factorielle</h2><p>Écrire une fonction récursive.</p>
    <ol><li>Version naïve</li><li>Version terminale</li></ol>
    <p><strong>Exercice 2.</strong> Calculer les nombres de Fibonacci.</p>
    <h2>Exercice 3 : Tours de Hanoï</h2><p>Résoudre pour n disques.</p>
    </body></html>
    `;
  const lines = HTMLLayout.lines(html);

  it("titres en gras et plus grands, menus écartés", () => {
    expect(lines[0]?.text === "Série 5 — Récursivité" && lines[0]?.isBold === true && !lines.some((l) => l.text === "Menu")).toBe(true);
  });
  it("les questions d'une liste sont en retrait", () => {
    const item = lines.find((l) => l.text === "Version naïve");
    const body = lines.find((l) => l.text === "Écrire une fonction récursive.");
    expect((item?.indent ?? 0) > (body?.indent ?? 0)).toBe(true);
  });
  it("« Exercice 2. » en gras en début de ligne", () => {
    expect(lines.some((l) => l.text.startsWith("Exercice 2.") && l.startsBold)).toBe(true);
  });
  it("trois exercices reconnus sur une page jamais vue", () => {
    const detected = SeriesLayoutParser.parse(lines, 5);
    const exercises = detected[0]?.exercises ?? [];
    expect(exercises.length, `(${exercises.map((e) => e.number)})`).toBe(3);
  });
});
