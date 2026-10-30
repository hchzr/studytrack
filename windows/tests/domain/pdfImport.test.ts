// Port de la section « Import PDF de bout en bout : vrais PDF, vraie extraction »
// (Validation/main.swift). Les PDF sont ceux que `Validation/PDFFixtures.swift`
// dessine avec CoreText : ils ont été générés une fois par ce même code et sont
// rangés dans `tests/fixtures/pdf/`. L'extraction est refaite ici par pdfjs-dist,
// comme PDFKit côté Mac.

import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { PDFLayoutExtractor } from "../../src/services/pdfLayoutExtractor.ts";
import { SeriesDocumentInference } from "../../src/domain/seriesDocumentInference.ts";
import {
  SeriesAIParsing, prepareLayout,
} from "../../src/domain/seriesAIParsing.ts";
import {
  DetectedExercise, DetectedSubQuestion, SeriesPDFParser,
} from "../../src/services/seriesPDFParser.ts";
import { SeriesLayoutParser, type PDFLayoutLine } from "../../src/domain/seriesLayout.ts";
import type { DetectedSeries } from "../../src/services/seriesPDFParser.ts";
import { characters } from "../../src/domain/textRepair.ts";

function fixture(name: string): Uint8Array {
  return new Uint8Array(readFileSync(new URL(`../fixtures/pdf/${name}`, import.meta.url)));
}

interface Run {
  lines: PDFLayoutLine[];
  series: DetectedSeries[];
  hint: number | null;
}

async function run(name: string): Promise<Run> {
  const lines = await PDFLayoutExtractor.linesFromData(fixture(name));
  const hint = SeriesDocumentInference.seriesNumber(lines, name)?.number ?? null;
  return { lines, series: SeriesLayoutParser.parse(lines, hint), hint };
}

const analyse = await run("polycopie.pdf");
const english = await run("exercises.pdf");
const numbered = await run("MATH-111_s.pdf");
const nested = await run("analyse-serie-03.pdf");
const physics = await run("PS4.pdf");

const outline = (series: DetectedSeries | undefined, number: string): string =>
  DetectedSubQuestion.outline(series?.exercises.find((exercise) => exercise.number === number)?.subQuestions ?? []);

describe("Import PDF de bout en bout : polycopié français", () => {
  it("PDFKit rend taille et gras des titres", () => {
    expect(analyse.lines.some((line) => line.fontSize > 11.5 && line.isBold)).toBe(true);
  });
  it("un titre en ligne est vu comme commençant en gras", () => {
    expect(analyse.lines.some((line) => line.startsBold && !line.isBold)).toBe(true);
  });
  it("le retrait des questions est mesuré (… → …)", () => {
    const bodyIndent = analyse.lines.find((line) => line.text.trim().startsWith("Calculer"))?.indent ?? 0;
    const questionIndent = analyse.lines.find((line) => line.text.trim().startsWith("a)"))?.indent ?? 0;
    expect(questionIndent).toBeGreaterThan(bodyIndent + 10);
  });
  it("série 4 lue dans l'en-tête courant — 4", () => { expect(analyse.hint).toBe(4); });
  it("une seule série, la 4 — 4", () => {
    expect(analyse.series.length).toBe(1);
    expect(analyse.series[0]?.number).toBe(4);
  });
  it("quatre exercices, ni fantôme ni citation — 4.1,4.2,4.3,4.4", () => {
    expect(analyse.series[0]?.exercises.map((exercise) => exercise.number)).toEqual(["4.1", "4.2", "4.3", "4.4"]);
  });
  it("intitulé entre parenthèses — « Changement de variable »", () => {
    expect(analyse.series[0]?.exercises[0]?.title).toBe("Changement de variable");
  });
  it("questions a) b) de l'exercice 4.1", () => {
    expect(analyse.series[0]?.exercises[0]?.subQuestions.map((question) => question.label)).toEqual(["a", "b"]);
  });
  it("4.2 facultatif", () => {
    expect(analyse.series[0]?.exercises.find((exercise) => exercise.number === "4.2")?.isBonus).toBe(true);
  });
  it("titre sur la ligne suivante en page 2 — « Intégrale impropre »", () => {
    expect(analyse.series[0]?.exercises.find((exercise) => exercise.number === "4.3")?.title)
      .toBe("Intégrale impropre");
  });
  const prepared = prepareLayout(analyse.lines, analyse.hint);
  it("entrée IA : titres marqués et pages séparées", () => {
    expect(prepared.includes("# Exercice 1")).toBe(true);
    expect(prepared.includes("--- page 2 ---")).toBe(true);
  });
});

describe("Import PDF de bout en bout : polycopié anglais", () => {
  it("« Exercise Set 7 » : série 7", () => {
    expect(english.hint).toBe(7);
    expect(english.series[0]?.number).toBe(7);
  });
  it("trois « Problem » — 7.1,7.2,7.3", () => {
    expect(english.series[0]?.exercises.map((exercise) => exercise.number)).toEqual(["7.1", "7.2", "7.3"]);
  });
  it("questions (a) (b)", () => {
    expect(english.series[0]?.exercises[0]?.subQuestions.map((question) => question.label)).toEqual(["a", "b"]);
  });
  it("« optional » vaut bonus", () => {
    expect(english.series[0]?.exercises.find((exercise) => exercise.number === "7.2")?.isBonus).toBe(true);
  });
});

describe("Import PDF de bout en bout : titres numérotés", () => {
  it("titres numérotés en gras — 2.1,2.2,2.3", () => {
    expect(numbered.series[0]?.exercises.map((exercise) => exercise.number)).toEqual(["2.1", "2.2", "2.3"]);
  });
  it("intitulé d'un titre numéroté", () => {
    expect(numbered.series[0]?.exercises[0]?.title).toBe("Espaces vectoriels");
  });
});

describe("Import PDF de bout en bout : Analyze I, série 03", () => {
  it("série 3 « Suites » — 3 Suites", () => {
    expect(nested.series.length).toBe(1);
    expect(nested.series[0]?.number).toBe(3);
    expect(nested.series[0]?.title).toBe("Suites");
  });
  it("cinq exercices « Ex-03-xx » — 3.1,3.2,3.3,3.11,3.12", () => {
    expect(nested.series[0]?.exercises.map((exercise) => exercise.number))
      .toEqual(["3.1", "3.2", "3.3", "3.11", "3.12"]);
  });
  it("deux niveaux : 1(a–c) et 2(a–e), plus seulement 1 et 2 — 1(a,b,c),2(a,b,c,d,e)", () => {
    expect(outline(nested.series[0], "3.1")).toBe("1(a,b,c),2(a,b,c,d,e)");
  });
  it("huit cases réelles pour 3.1", () => {
    expect(DetectedExercise.leafQuestionCount(nested.series[0]!.exercises[0])).toBe(8);
  });
  it("liste en deux colonnes remise dans l'ordre, puis « Ensuite » — 1,2,3,4,part", () => {
    expect(outline(nested.series[0], "3.3")).toBe("1,2,3,4,part");
  });
  it("la consigne avant « Ensuite » est une partie à cocher — part,1,2,3", () => {
    expect(outline(nested.series[0], "3.11")).toBe("part,1,2,3");
  });
  it("…avec son texte — « Calculer la limite… »", () => {
    expect(nested.series[0]?.exercises.find((exercise) => exercise.number === "3.11")?.subQuestions[0]?.text
      .startsWith("Calculer la limite")).toBe(true);
  });
  it("une liste de conditions n'est pas une liste de questions — (vide)", () => {
    expect(outline(nested.series[0], "3.12")).toBe("");
  });
  it("le texte d'une question est lu — « Soit (xn)… »", () => {
    expect(nested.series[0]?.exercises[0]?.subQuestions[0]?.text.startsWith("Soit (xn)")).toBe(true);
  });
  const nestedInput = prepareLayout(nested.lines, nested.hint);
  it("le pied de page répété n'est pas envoyé au modèle", () => {
    expect(nestedInput.includes("Compilation")).toBe(false);
  });
});

describe("Import PDF de bout en bout : PHYS-101(en)", () => {
  it("titres numérotés sur la marge, sans gras visible — 4.1,4.2,4.3", () => {
    expect(physics.series[0]?.exercises.map((exercise) => exercise.number)).toEqual(["4.1", "4.2", "4.3"]);
  });
  it("une suite 1, 2, 3 sur la marge est un repère sûr", () => {
    expect(physics.series[0]?.exercises.every((exercise) => exercise.isConfident)).toBe(true);
  });
  it("les « 1. » décalés sont des questions — 1,2", () => {
    expect(physics.series[0]?.exercises[0]?.subQuestions.map((question) => question.label)).toEqual(["1", "2"]);
  });
  it("intitulé anglais lu tel quel", () => {
    expect(physics.series[0]?.exercises[0]?.title).toBe("Rotating space station");
  });
  it("langue du document : anglais", () => {
    expect(SeriesDocumentInference.languageName(physics.lines.map((line) => line.text).join("\n"))).toBe("anglais");
  });
  it("la langue est dite au modèle", () => {
    expect(prepareLayout(physics.lines, 4, "anglais").includes("ne traduis rien")).toBe(true);
  });
});

describe("Import PDF de bout en bout : ce que le modèle ne doit pas casser", () => {
  it("un titre de série égal au nom du cours est effacé", () => {
    expect(SeriesDocumentInference.seriesTitle("Analyse I", "Analyse I", "MATH-101")).toBe("");
  });
  it("un vrai titre de série est gardé", () => {
    expect(SeriesDocumentInference.seriesTitle("Intégrales", "Analyse I", "MATH-101")).toBe("Intégrales");
  });
  it("« Soit f… » est un énoncé, pas un titre", () => {
    expect(SeriesPDFParser.looksLikeTitle("Soit f une fonction continue sur R")).toBe(false);
  });
  it("« Let f… » non plus", () => {
    expect(SeriesPDFParser.looksLikeTitle("Let f be continuous")).toBe(false);
  });
  it("un titre nominal reste un titre", () => {
    expect(SeriesPDFParser.looksLikeTitle("Calcul d'intégrales")).toBe(true);
  });
  it("une seule « question » n'en fait pas une liste", () => {
    expect(SeriesAIParsing.parse(`{"series":[{"number":4,"exercises":[{"number":"4.2","questions":["1.5"]}]}]}`)
      [0]?.exercises[0]?.subQuestions.length).toBe(0);
  });

  // La lecture du texte l'emporte sur le modèle pour les questions.
  const local = [{
    number: 3,
    title: "",
    exercises: [{
      number: "3.10",
      title: "",
      isBonus: false,
      statement: "",
      subQuestions: [DetectedSubQuestion.make("1"), DetectedSubQuestion.make("2")],
      isConfident: true,
    }],
  }];
  const model = [{
    number: 3,
    title: "Suites",
    exercises: [{
      number: "3.10",
      title: "",
      isBonus: false,
      statement: "",
      subQuestions: [DetectedSubQuestion.make("1"), DetectedSubQuestion.make("2"), DetectedSubQuestion.make("3")],
      isConfident: true,
    }],
  }];
  it("un modèle qui voit les pages l'emporte sur la lecture du texte", () => {
    expect(SeriesAIParsing.merge(local, model, null, true)[0]?.exercises[0]?.subQuestions.length).toBe(3);
  });
  const localWithPart = [{
    number: 3,
    title: "",
    exercises: [{
      number: "3.11",
      title: "",
      isBonus: false,
      statement: "",
      subQuestions: [
        DetectedSubQuestion.make("", { text: "Calculer lim an", kind: "part" }),
        DetectedSubQuestion.make("1"),
        DetectedSubQuestion.make("2"),
      ],
      isConfident: true,
    }],
  }];
  const seenNoPart = [{
    number: 3,
    title: "",
    exercises: [{
      number: "3.11",
      title: "",
      isBonus: false,
      statement: "",
      subQuestions: ["1", "2", "3"].map((label) => DetectedSubQuestion.make(label, { text: "lu" })),
      isConfident: true,
    }],
  }];
  it("la partie sans numéro trouvée localement est remise devant les questions lues — part,1,2,3", () => {
    const withPart = SeriesAIParsing.merge(localWithPart, seenNoPart, null, true)[0]?.exercises[0]?.subQuestions ?? [];
    expect(DetectedSubQuestion.outline(withPart)).toBe("part,1,2,3");
  });
  it("questions lues dans le PDF préférées à celles du modèle", () => {
    expect(SeriesAIParsing.merge(local, model)[0]?.exercises[0]?.subQuestions.length).toBe(2);
  });

  // Un modèle qui traduit ou décale ses exercices est corrigé par le PDF.
  const shifted = [{
    number: 4,
    title: "",
    exercises: [
      { number: "4.1", title: "Station spatiale en rotation", isBonus: false, statement: "", subQuestions: [], isConfident: true },
      { number: "4.2", title: "Mouvement circulaire", isBonus: false, statement: "", subQuestions: [], isConfident: true },
      { number: "4.3", title: "Trouver l'erreur", isBonus: false, statement: "", subQuestions: [], isConfident: true },
      { number: "4.4", title: "Question promue", isBonus: false, statement: "", subQuestions: [], isConfident: true },
    ],
  }];
  it("un exercice inventé hors d'une numérotation complète est écarté — 4.1,4.2,4.3", () => {
    const fixed = SeriesAIParsing.merge(physics.series, shifted, 4)[0]?.exercises ?? [];
    expect(fixed.map((exercise) => exercise.number)).toEqual(["4.1", "4.2", "4.3"]);
  });
  it("l'intitulé imprimé l'emporte sur la traduction du modèle", () => {
    const fixed = SeriesAIParsing.merge(physics.series, shifted, 4)[0]?.exercises ?? [];
    expect(fixed[0]?.title).toBe("Rotating space station");
  });

  // Un modèle de vision qui saute une colonne ne fait pas perdre de questions.
  const sixLocal = [{
    number: 4,
    title: "",
    exercises: [{
      number: "4.8",
      title: "",
      isBonus: false,
      statement: "",
      subQuestions: Array.from({ length: 6 }, (_, index) => DetectedSubQuestion.make(String(index + 1), { text: "texte" })),
      isConfident: true,
    }],
  }];
  const threeSeen = [{
    number: 4,
    title: "",
    exercises: [{
      number: "4.8",
      title: "",
      isBonus: false,
      statement: "",
      subQuestions: Array.from({ length: 3 }, (_, index) => DetectedSubQuestion.make(String(index + 1), { text: "b_n = \\log n" })),
      isConfident: true,
    }],
  }];
  const recovered = SeriesAIParsing.merge(sixLocal, threeSeen, null, true)[0]?.exercises[0]?.subQuestions ?? [];
  it("questions oubliées par la vision rendues — 1,2,3,4,5,6", () => {
    expect(recovered.map((question) => question.label)).toEqual(["1", "2", "3", "4", "5", "6"]);
  });
  it("le texte lu par le modèle est gardé", () => {
    expect(recovered[0]?.text).toBe("b_n = \\log n");
  });

  it("« 4-3 » → 4.3 (et non 4.43)", () => {
    expect(SeriesAIParsing.normalizeNumber("4-3", 4)).toBe("4.3");
  });
  it("« Ex-04-07 » → 4.7", () => { expect(SeriesAIParsing.normalizeNumber("Ex-04-07", 4)).toBe("4.7"); });
  it("« 7 » → 4.7", () => { expect(SeriesAIParsing.normalizeNumber("7", 4)).toBe("4.7"); });
  it("« 4.10 » reste", () => { expect(SeriesAIParsing.normalizeNumber("4.10", 4)).toBe("4.10"); });

  it("« Calculer les sommes » est un titre de modèle", () => {
    expect(SeriesPDFParser.looksLikeGeneratedTitle("Calculer les sommes")).toBe(true);
  });
  it("titre imprimé commençant par un verbe gardé", () => {
    expect(SeriesPDFParser.looksLikeGeneratedTitle("Find the error: Sliding block")).toBe(true);
  });
  it("« Soit f… » reste un énoncé", () => {
    expect(SeriesPDFParser.looksLikeGeneratedTitle("Soit f une fonction continue")).toBe(false);
  });
  it("une phrase ponctuée reste un énoncé", () => {
    expect(SeriesPDFParser.looksLikeGeneratedTitle("Montrer que la suite est bornée.")).toBe(false);
  });
  it("le numéro seul n'est pas un titre", () => {
    expect(SeriesPDFParser.looksLikeGeneratedTitle("Ex-04-03")).toBe(false);
  });
});

describe("Import PDF de bout en bout : déterminisme", () => {
  // `DetectedSubQuestion.==` ignore l'identité d'édition ; on compare donc les
  // valeurs sans les identifiants, comme le `==` Swift de DetectedSeries.
  const withoutIds = (series: DetectedSeries[]): unknown => series.map((item) => ({
    number: item.number,
    title: item.title,
    exercises: item.exercises.map((exercise) => ({
      ...exercise,
      subQuestions: exercise.subQuestions.map(function strip(question): unknown {
        return { label: question.label, text: question.text, kind: question.kind, children: question.children.map(strip) };
      }),
    })),
  }));
  it("lecture déterministe", async () => {
    const again = await run("polycopie.pdf");
    expect(withoutIds(again.series)).toEqual(withoutIds(analyse.series));
  });
});

// Une garde sur le volume préparé : la mise en page reste sous le budget.
describe("Import PDF de bout en bout : budget du modèle", () => {
  it("la mise en page tient dans le budget", () => {
    expect(characters(prepareLayout(analyse.lines, analyse.hint)).length)
      .toBeLessThanOrEqual(SeriesAIParsing.layoutBudget);
  });
});
