// Port des sections de Validation/main.swift qui exercent SeriesLayoutParser et SeriesPDFParser
// (sans PDFKit ni les parties encore non portées) : « Détection des exercices dans un PDF de
// série », « Formats réels de polycopiés EPFL », « Intitulé ou énoncé ? », « Mise en page du
// PDF : titre ou énoncé ? », « Tolérance de forme des polycopiés », et les checks de
// « Import PDF : ce que le document dit de lui-même » / « Import PDF de bout en bout » qui ne
// reposent que sur ces deux parseurs. Un `it` par check Swift, le libellé du check pour nom.
import { describe, expect, it } from "vitest";

import {
  PDFLayoutLine, SeriesLayoutParser, makeQuestionMark,
  type QuestionMark,
} from "../../src/domain/seriesLayout.ts";
import { DetectedSubQuestion, SeriesPDFParser } from "../../src/services/seriesPDFParser.ts";

const numbersOf = (series: { exercises: { number: string }[] } | undefined) => series?.exercises.map((e) => e.number);

describe("Détection des exercices dans un PDF de série", () => {
  // Polycopié EPFL typique : en-tête de série, exercices numérotés, un bonus.
  const typical = `Série 3 – Intégrales généralisées
Exercice 3.1
Calculer l'intégrale suivante sur R.
Exercice 3.2 (bonus)
Exercice 3.3 – Théorème de Fubini
`;
  const typicalSeries = SeriesPDFParser.parse(typical);
  const three = typicalSeries[0];
  it("un polycopié type donne une série", () => {
    expect(typicalSeries.length).toBe(1);
  });
  it("série 3 détectée", () => {
    expect(three.number).toBe(3);
  });
  it("intitulé de série : « Intégrales généralisées »", () => {
    expect(three.title).toBe("Intégrales généralisées");
  });
  it("trois exercices dans l'ordre", () => {
    expect(numbersOf(three)).toEqual(["3.1", "3.2", "3.3"]);
  });
  it("« (bonus) » reconnu sur la ligne", () => {
    expect(three.exercises.find((e) => e.number === "3.2")?.isBonus).toBe(true);
  });
  it("intitulé d'exercice conservé", () => {
    expect(three.exercises.find((e) => e.number === "3.3")?.title).toBe("Théorème de Fubini");
  });
  it("un exercice normal n'est pas marqué bonus", () => {
    expect(three.exercises.find((e) => e.number === "3.1")?.isBonus).toBe(false);
  });

  const multiSeries = SeriesPDFParser.parse("Série 1\n1.1\n1.2\nSérie 2\nExercice 2.1\n");
  it("deux séries regroupées", () => {
    expect(multiSeries.length).toBe(2);
  });
  it("séries dans l'ordre", () => {
    expect(multiSeries.map((s) => s.number)).toEqual([1, 2]);
  });
  it("la première série a deux exercices", () => {
    expect(multiSeries[0]?.exercises.length).toBe(2);
  });

  const wrappedSeries = SeriesPDFParser.parse("Exercice 4.1\n(bonus)\nExercice 4.2\n");
  it("« bonus » reconnu sur la ligne suivante", () => {
    expect(wrappedSeries[0]?.exercises.find((e) => e.number === "4.1")?.isBonus).toBe(true);
  });
  it("le bonus ne déborde pas sur l'exercice suivant", () => {
    expect(wrappedSeries[0]?.exercises.find((e) => e.number === "4.2")?.isBonus).toBe(false);
  });

  const bareSeries = SeriesPDFParser.parse("Exercice 1\nExercice 2\n");
  it("« Exercice 1 / Exercice 2 » hors série : numérotés dans la série 1", () => {
    expect(bareSeries.length === 1 && bareSeries[0].exercises.map((e) => e.number).join(",") === "1.1,1.2").toBe(true);
  });

  it("un doublon ne crée pas deux exercices", () => {
    expect(SeriesPDFParser.parse("Exercice 1.1\nExercice 1.1\n")[0]?.exercises.length).toBe(1);
  });
  it("espace insécable toléré", () => {
    expect(SeriesPDFParser.parse("Exercice 5.1\n")[0]?.exercises[0]?.number).toBe("5.1");
  });

  // Un PDF scanné ne contient aucun texte : le parseur ne doit rien inventer.
  it("texte vide : aucune série inventée", () => {
    expect(SeriesPDFParser.parse("")).toEqual([]);
  });
  it("texte sans numéro : aucune série inventée", () => {
    expect(SeriesPDFParser.parse("Cours d'analyse\nProfesseur Untel\n")).toEqual([]);
  });
  it("série à deux chiffres", () => {
    expect(SeriesPDFParser.majorComponent("12.4")).toBe(12);
  });
  it("numéro illisible → rien", () => {
    expect(SeriesPDFParser.majorComponent("n/a")).toBeNull();
  });
});

describe("Formats réels de polycopiés EPFL", () => {
  // Analyse 1 inversée : « Ex-02-01: », en-tête « Série 02 (Nombres R) », et deux
  // exercices collés sur une même ligne par l'extraction du PDF.
  const analyse = `Série 02 (Nombres R)
Ex-02-01: Montrer que dans R,
1) Si x y alors x + x y + y.
Ex-02-08: Ex-02-09: Montrer que si n est un entier tel que n2 est pair.
Ex-02-11: (Cet exercice est facultatif.)
Soit C := {x ∈ R+ : x3 < 1}.
Ex-02-12: Montrer que l’ensemble C est ouvert.
`;
  const analyseSeries = SeriesPDFParser.parse(analyse);
  const s = analyseSeries[0];
  it("Analyse 1 : une seule série", () => {
    expect(analyseSeries.length).toBe(1);
  });
  it("Analyse 1 : série 2", () => {
    expect(s.number).toBe(2);
  });
  it("Analyse 1 : titre sans parenthèses « Nombres R »", () => {
    expect(s.title).toBe("Nombres R");
  });
  it("Analyse 1 : numéros lus", () => {
    expect(numbersOf(s)).toEqual(["2.1", "2.8", "2.9", "2.11", "2.12"]);
  });
  it("Analyse 1 : « Ex-02-09 » collé sur la ligne du 08 est bien détecté", () => {
    expect(s.exercises.some((e) => e.number === "2.9")).toBe(true);
  });
  it("Analyse 1 : le 08 ne vole pas le titre du 09", () => {
    expect(s.exercises.find((e) => e.number === "2.8")?.title).toBe("");
  });
  it("Analyse 1 : « facultatif » vaut bonus", () => {
    expect(s.exercises.find((e) => e.number === "2.11")?.isBonus).toBe(true);
  });
  it("Analyse 1 : un exercice normal n'est pas bonus", () => {
    expect(s.exercises.find((e) => e.number === "2.12")?.isBonus).toBe(false);
  });

  // Algèbre linéaire inversée : « Exercice N » suivi de la première phrase de
  // l'énoncé, pollué par les métadonnées de mise en page « Type : … Défi : ⋆⋆ ».
  const algebre = `Série 2
Exercice 1 solution générale.
Type : Technique Défi : ⋆⋆
Exercice 2 Type : Concept Défi : ⋆⋆
Exercice 3
`;
  const algebreSeries = SeriesPDFParser.parse(algebre);
  const a = algebreSeries[0];
  it("Algèbre : une seule série", () => {
    expect(algebreSeries.length).toBe(1);
  });
  it("Algèbre : série 2 lue depuis l'en-tête", () => {
    expect(a.number).toBe(2);
  });
  it("Algèbre : trois exercices, numérotés par leur série", () => {
    expect(numbersOf(a)).toEqual(["2.1", "2.2", "2.3"]);
  });
  it("Algèbre : « solution générale. » n'est pas retenu comme titre", () => {
    expect(a.exercises[0]?.title).toBe("");
  });
  it("Algèbre : les métadonnées « Type : … Défi : … » ne polluent pas le titre", () => {
    expect(a.exercises.find((e) => e.number === "2.2")?.title).toBe("");
  });
  it("Algèbre : « Exercice 3 » seul n'invente pas de titre", () => {
    expect(a.exercises.find((e) => e.number === "2.3")?.title).toBe("");
  });
});

describe("Intitulé ou énoncé ?", () => {
  const looks = SeriesPDFParser.looksLikeTitle;
  it("une phrase terminée par un point est un énoncé", () => { expect(looks("solution générale.")).toBe(false); });
  it("un fragment de mot est rejeté", () => { expect(looks("tions change.")).toBe(false); });
  it("une suite d'énoncé en minuscule est rejetée", () => { expect(looks("ou contre-exemple.")).toBe(false); });
  it("une consigne complète est rejetée", () => { expect(looks("Montrer que l'ensemble C est ouvert.")).toBe(false); });
  it("une énumération est rejetée", () => { expect(looks("1) Si x y alors x + x y + y.")).toBe(false); });
  it("un point-virgule final est rejeté", () => { expect(looks("Montrer que ;")).toBe(false); });
  it("un point-virgule interne ne suffit pas à rejeter — limite assumée de la règle", () => {
    expect(looks("Diagonalisation ; applications")).toBe(true);
  });
  it("un texte trop long est rejeté", () => { expect(looks("Mot ".repeat(30))).toBe(false); });
  it("un texte vide est rejeté", () => { expect(looks("   ")).toBe(false); });
  it("un intitulé court est conservé", () => { expect(looks("Diagonalisation")).toBe(true); });
  it("un intitulé de deux mots est conservé", () => { expect(looks("Espaces vectoriels")).toBe(true); });
  it("un intitulé sans ponctuation est conservé", () => { expect(looks("Nombres R")).toBe(true); });

  // Et sur un document complet : le titre explicite après deux-points survit.
  const titreSeries = SeriesPDFParser.parse("Série 3\nExercice 1 : Diagonalisation\nExercice 2 : Espaces vectoriels\n");
  it("un intitulé explicite après deux-points est conservé", () => {
    expect(titreSeries[0]?.exercises[0]?.title).toBe("Diagonalisation");
  });
  it("les deux exercices sont lus", () => {
    expect(titreSeries[0]?.exercises.length).toBe(2);
  });

  // Les métadonnées seules ne laissent pas un titre vide de sens.
  it("les métadonnées seules ne font pas un titre", () => {
    expect(SeriesPDFParser.exerciseTitle("Type : Technique Défi : ⋆⋆")).toBe("");
  });
  it("un vrai intitulé traverse le nettoyage", () => {
    expect(SeriesPDFParser.exerciseTitle("Diagonalisation")).toBe("Diagonalisation");
  });
});

describe("Mise en page du PDF : titre ou énoncé ?", () => {
  // Le cas signalé sur un vrai polycopié : « Exercice 1 » suivi de la première
  // phrase de l'énoncé. Le texte seul ne permet pas de les distinguer ; la taille
  // de police, si. C'est tout l'objet de `SeriesLayoutParser`.
  const layout = (text: string, size: number, bold = false, page = 0) =>
    PDFLayoutLine.make(text, { fontSize: size, isBold: bold, pageIndex: page });

  const algebreLayout = [
    layout("Série 2", 16),
    layout("Exercice 1", 13),
    layout("solution générale.", 11),
    layout("Type : Technique Défi : ⋆⋆", 9),
    layout("Exercice 2", 13),
    layout("tions change.", 11),
    layout("Exercice 3", 13),
    layout("ou contre-exemple.", 11),
  ];
  it("corps de texte déduit de la police la plus lue", () => {
    expect(SeriesLayoutParser.bodyFontSize(algebreLayout)).toBe(11);
  });

  const algebreParsed = SeriesLayoutParser.parse(algebreLayout);
  it("une seule série", () => { expect(algebreParsed.length).toBe(1); });
  it("série 2 lue depuis l'en-tête", () => { expect(algebreParsed[0]?.number).toBe(2); });
  it("trois exercices", () => { expect(numbersOf(algebreParsed[0])).toEqual(["2.1", "2.2", "2.3"]); });
  it("aucun énoncé n'est pris pour un intitulé", () => {
    expect(algebreParsed[0]?.exercises.every((e) => e.title === "")).toBe(true);
  });

  // Un vrai intitulé, lui, doit survivre.
  const titreLayout = [
    layout("Série 3", 16),
    layout("Exercice 1 : Diagonalisation", 13),
    layout("Montrer que la matrice est diagonalisable.", 11),
    layout("Exercice 2", 13),
    layout("Espaces vectoriels", 13),
  ];
  const titreParsed = SeriesLayoutParser.parse(titreLayout);
  it("intitulé sur la même ligne", () => { expect(titreParsed[0]?.exercises[0]?.title).toBe("Diagonalisation"); });
  it("deux exercices", () => { expect(titreParsed[0]?.exercises.length).toBe(2); });

  // Un titre peut tenir sur deux lignes, à condition que la seconde soit du **même
  // niveau** que la première. C'est ce qui autorise la suite, et interdit l'énoncé.
  const twoLineParsed = SeriesLayoutParser.parse([
    layout("Série 4", 16),
    layout("Exercice 1", 13),
    layout("Formes bilinéaires", 13),
    layout("Montrer que la forme est symétrique.", 11),
  ]);
  it("titre sur deux lignes accepté", () => {
    expect(twoLineParsed[0]?.exercises[0]?.title).toBe("Formes bilinéaires");
  });

  // Le bonus est souvent plus bas que la ligne suivante : l'ancienne lecture ne
  // regardait qu'une ligne, et le manquait.
  const bonusParsed = SeriesLayoutParser.parse([
    layout("Série 5", 16),
    layout("Exercice 4", 13),
    layout("Montrer que l'ensemble est ouvert.", 11),
    layout("Indication : utiliser la boule unité.", 11),
    layout("(Cet exercice est facultatif.)", 11),
    layout("Exercice 5", 13),
    layout("Calculer la limite.", 11),
  ]);
  it("bonus trouvé trois lignes plus bas", () => {
    expect(bonusParsed[0]?.exercises.find((e) => e.number === "5.4")?.isBonus).toBe(true);
  });
  it("le bonus ne déborde pas sur l'exercice suivant", () => {
    expect(bonusParsed[0]?.exercises.find((e) => e.number === "5.5")?.isBonus).toBe(false);
  });

  // Sans information de police — texte collé — on retombe sur les motifs, sans régression.
  const pasted = SeriesLayoutParser.parse(
    "Série 2\nExercice 1 solution générale.\nExercice 2\n".split("\n").map((t) => PDFLayoutLine.make(t)));
  it("texte sans mise en page : les motifs prennent le relais", () => {
    expect(numbersOf(pasted[0])).toEqual(["2.1", "2.2"]);
  });
  it("et la règle sur les intitulés s'applique quand même", () => {
    expect(pasted[0]?.exercises[0]?.title).toBe("");
  });

  // Une tête de série sans exercice reste visible pour être complétée à la main.
  const headerOnlyParsed = SeriesLayoutParser.parse([layout("Série 7", 16), layout("Consignes générales.", 11)]);
  it("série annoncée sans exercice : conservée, liste vide", () => {
    expect(headerOnlyParsed.length === 1 && headerOnlyParsed[0]?.exercises.length === 0).toBe(true);
  });

  // « Ex-02-04 » porte la série dans son numéro, même sans en-tête.
  const dashedParsed = SeriesLayoutParser.parse([
    layout("Ex-02-04: Montrer que si n est pair.", 11),
    layout("Ex-02-05: En déduire le résultat.", 11),
  ]);
  it("série déduite du numéro d'exercice", () => { expect(dashedParsed[0]?.number).toBe(2); });
  it("deux exercices « Ex-02-xx »", () => { expect(dashedParsed[0]?.exercises.length).toBe(2); });

  // Le corps est en gras partout (diapositives) : le gras ne doit plus servir de
  // signal, sinon chaque ligne deviendrait un titre.
  const allBoldParsed = SeriesLayoutParser.parse([
    layout("Série 2", 16, true),
    layout("Exercice 1", 14, true),
    layout("solution générale.", 14, true),
  ]);
  it("corps entièrement en gras : aucun faux intitulé", () => {
    expect(allBoldParsed[0]?.exercises[0]?.title).toBe("");
  });
});

describe("Tolérance de forme des polycopiés", () => {
  // Tous les cours n'écrivent pas « Exercice 1.1 ».
  const count = (text: string) => SeriesPDFParser.parse(text)[0]?.exercises.length;
  it("« Ex 1.1 » sans tiret", () => { expect(count("Ex 1.1\nEx 1.2\n")).toBe(2); });
  it("« Ex.1.1 »", () => { expect(count("Ex.1.1\n")).toBe(1); });
  it("« Exercice n° 1.1 »", () => { expect(count("Exercice n° 1.1\n")).toBe(1); });
  it("« Exo 2.1 »", () => { expect(count("Exo 2.1\n")).toBe(1); });
  it("« Problème 1.1 »", () => { expect(count("Problème 1.1\n")).toBe(1); });
  it("séparateur médian « 1·2 »", () => { expect(count("1·2\n")).toBe(1); });

  // Robustesse à une mise en page inconnue : la série est conservée sans exercice,
  // pour que l'écran de relecture reste utilisable.
  const headerOnly = SeriesPDFParser.parse("Série 4\nDes consignes sans numéro d'exercice.\n");
  it("une série annoncée sans exercice reconnu est conservée", () => {
    expect(headerOnly.length === 1 && headerOnly[0]?.number === 4 && headerOnly[0]?.exercises.length === 0).toBe(true);
  });

  // Pas de faux positif sur du texte courant.
  it("une phrase sans numéro en tête ne crée pas d'exercice", () => {
    expect(SeriesPDFParser.parse("Le chapitre traite de ce point.\n")).toEqual([]);
  });
  it("une référence de page ne crée pas d'exercice", () => {
    expect(SeriesPDFParser.parse("Voir la page 12 pour la suite.\n")).toEqual([]);
  });
});

// Les checks de « Import PDF : ce que le document dit de lui-même » qui ne reposent que sur
// SeriesLayoutParser / SeriesPDFParser (SeriesDocumentInference et SeriesAIParsing : non portés).
describe("Import PDF : ce que le document dit de lui-même", () => {
  const line = (text: string, size = 11, o: { bold?: boolean; page?: number; indent?: number; startsBold?: boolean } = {}) =>
    PDFLayoutLine.make(text, {
      fontSize: size, isBold: o.bold ?? false, pageIndex: o.page ?? 0, indent: o.indent ?? 60, startsBold: o.startsBold ?? false,
    });

  // Sans en-tête en tête de ligne, la série vient du document.
  const noHeader = [line("Exercice 1", 13), line("Soit f.", 11), line("Exercice 2", 13), line("Calculer.", 11)];
  it("série déduite du document : 4.1, 4.2", () => {
    expect(numbersOf(SeriesLayoutParser.parse(noHeader, 4)[0])).toEqual(["4.1", "4.2"]);
  });

  // Anglais et allemand.
  const english = [line("Exercise 1", 13), line("Prove it.", 11), line("Problem 2", 13), line("Compute.", 11)];
  it("« Exercise 1 », « Problem 2 » reconnus", () => {
    expect(numbersOf(SeriesLayoutParser.parse(english, 2)[0])).toEqual(["2.1", "2.2"]);
  });
  it("texte collé en anglais, série fournie", () => {
    expect(numbersOf(SeriesPDFParser.parse("Exercise 1\nExercise 2\n", 3)[0])).toEqual(["3.1", "3.2"]);
  });
  it("« Aufgabe 1 » reconnu", () => {
    expect(SeriesPDFParser.parse("Aufgabe 1\n")[0]?.exercises.length).toBe(1);
  });

  // Faux positifs : une démonstration numérotée, une citation.
  const phantoms = [line("Série 3", 16), line("Exercice 1", 13),
    line("1.5 Montrer que la suite converge vers zéro quand n tend vers l'infini.", 11),
    line("Exercice 2 de la série précédente nous a appris que la limite existe.", 11),
    line("Exercice 2", 13)];
  it("ni « 1.5 » de corps de texte ni une citation ne créent d'exercice", () => {
    expect(numbersOf(SeriesLayoutParser.parse(phantoms)[0])).toEqual(["3.1", "3.2"]);
  });

  // Un « 1. » mis en forme de titre, dans un document sans mot-clé : un exercice.
  const numbered = [line("Série 6", 16), line("1. Suites", 12, { bold: true, indent: 60 }),
    line("Soit u.", 11), line("2. Séries", 12, { bold: true, indent: 60 })];
  it("« 1. Suites » en gras : exercice 6.1", () => {
    expect(numbersOf(SeriesLayoutParser.parse(numbered)[0])).toEqual(["6.1", "6.2"]);
  });

  // Titre en ligne (LaTeX) : la ligne commence en gras.
  const runIn = [line("Série 2", 16),
    line("Exercice 1. Soit f une fonction continue.", 11, { startsBold: true }),
    line("Exercice 2. Calculer la limite.", 11, { startsBold: true })];
  it("titres « en ligne » reconnus", () => {
    expect(SeriesLayoutParser.parse(runIn)[0]?.exercises.length).toBe(2);
  });

  // Questions rattachées à l'exercice.
  const questions = [line("Série 1", 16), line("Exercice 1", 13), line("Soit f.", 11),
    line("a) Montrer que f est continue.", 11, { indent: 80 }),
    line("b) En déduire la limite.", 11, { indent: 80 }),
    line("Exercice 2", 13), line("Question 1 : calculer.", 11), line("Question 2 : conclure.", 11)];
  const withQuestions = SeriesLayoutParser.parse(questions);
  it("« Question 1 » n'est pas un exercice quand le document dit « Exercice »", () => {
    expect(numbersOf(withQuestions[0])).toEqual(["1.1", "1.2"]);
  });
  it("questions a) b) rattachées à l'exercice 1.1", () => {
    expect(withQuestions[0]?.exercises[0]?.subQuestions.map((q) => q.label)).toEqual(["a", "b"]);
  });
  const onlyQuestions = [line("Série 2", 16), line("Question 1", 13), line("Question 2", 13)];
  it("sans autre mot-clé, « Question N » est un exercice", () => {
    expect(SeriesLayoutParser.parse(onlyQuestions)[0]?.exercises.length).toBe(2);
  });
  it("une liste qui ne commence pas par a/1/i n'est pas une liste de questions", () => {
    expect(SeriesLayoutParser.isQuestionSequence(["c", "d"])).toBe(false);
  });
});

// Les checks de « Import PDF de bout en bout » qui n'ont besoin ni de PDFKit ni de
// SeriesAIParsing. Non portés : les neuf `run(PDFFixtures…)` (vrais PDF, extraction PDFKit).
describe("Import PDF de bout en bout : étiquettes de questions et intitulés (sans PDF)", () => {
  const marks = (items: [string, number][]): QuestionMark[] => items.map(([label, indent]) => makeQuestionMark(label, indent));
  const twoLevels = marks([["1", 84], ["a", 105], ["b", 105], ["2", 84], ["a", 105], ["b", 105], ["c", 106]]);

  it("« Soit f… » est un énoncé, pas un titre", () => {
    expect(SeriesPDFParser.looksLikeTitle("Soit f une fonction continue sur R")).toBe(false);
  });
  it("« Let f… » non plus", () => { expect(SeriesPDFParser.looksLikeTitle("Let f be continuous")).toBe(false); });
  it("un titre nominal reste un titre", () => { expect(SeriesPDFParser.looksLikeTitle("Calcul d'intégrales")).toBe(true); });

  it("premier niveau : 1, 2", () => {
    expect(SeriesLayoutParser.topLevelQuestions(twoLevels)).toEqual(["1", "2"]);
  });
  it("second niveau rattaché à sa question", () => {
    expect(DetectedSubQuestion.outline(SeriesLayoutParser.questionTree(twoLevels))).toBe("1(a,b),2(a,b,c)");
  });
  it("trois questions sur une même ligne", () => {
    expect(SeriesLayoutParser.questionMark("1) an = 1 2) an = n 3) an = 2", true, 84)?.map((m) => m.label)).toEqual(["1", "2", "3"]);
  });
  it("« (an) » dans le texte n'est pas une question", () => {
    expect(SeriesLayoutParser.questionMark("1) Si (an) est croissante", true, 84)?.map((m) => m.label)).toEqual(["1"]);
  });
  it("liste de conditions reconnue", () => {
    expect(SeriesLayoutParser.introListsConditions("Montrer qu'il existe une suite qui satisfait simultanément aux deux conditions suivantes :")).toBe(true);
  });
  it("« limites suivantes » reste une liste de questions", () => {
    expect(SeriesLayoutParser.introListsConditions("Calculer les limites suivantes :")).toBe(false);
  });
  it("deux colonnes triées", () => {
    expect(SeriesLayoutParser.topLevelQuestions(marks([["1", 84], ["3", 315], ["2", 84], ["4", 315]]))).toEqual(["1", "2", "3", "4"]);
  });
  it("« i » dans une liste de lettres reste une lettre", () => {
    expect(SeriesLayoutParser.topLevelQuestions(marks([["a", 0], ["b", 0], ["i", 0], ["j", 0]]))).toEqual(["a", "b", "i", "j"]);
  });
  it("chiffres romains dans l'ordre", () => {
    expect(SeriesLayoutParser.topLevelQuestions(marks([["i", 0], ["ii", 0], ["iii", 0], ["iv", 0]]))).toEqual(["i", "ii", "iii", "iv"]);
  });

  // Le modèle renvoie le numéro comme titre quand le PDF n'en donne pas.
  it("« Ex-03-01 » n'est pas un titre", () => { expect(SeriesPDFParser.looksLikeTitle("Ex-03-01")).toBe(false); });
  it("« Exercice 3 » n'est pas un titre", () => { expect(SeriesPDFParser.looksLikeTitle("Exercice 3")).toBe(false); });
  it("« Exercice de synthèse » en est un", () => { expect(SeriesPDFParser.looksLikeTitle("Exercice de synthèse")).toBe(true); });

  it("énoncé lu dans le PDF : la première phrase, sans « Exercise 5. »", () => {
    expect(SeriesLayoutParser.firstSentence(
      "Exercise 5. Adapt the bubble sort algorithm so that it stops when no swaps are required (when the list is sorted). Express this in pseudocode."))
      .toBe("Adapt the bubble sort algorithm so that it stops when no swaps are required (when the list is sorted).");
  });
});
