// Port de la section « Recherche globale » de Validation/main.swift.
// Chaque `check` Swift devient un `it` du même libellé.

import { describe, expect, it } from "vitest";

import { Course, ModelStore, SeedData } from "../../src/models/index.ts";
import { SearchDocument, SearchEngine, SearchHit, SearchKind } from "../../src/domain/searchEngine.ts";
import { SearchIndexBuilder } from "../../src/domain/searchIndexBuilder.ts";
import { AcademicMilestone } from "../../src/models/academicMilestone.ts";
import { DateUtils } from "../../src/domain/dateUtils.ts";
import "../../src/domain/registerCodecs.ts";

function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

const store = new ModelStore();
SeedData.seed(store);
const courses = store.fetch(Course);

const catalogue: SearchDocument[] = [
  new SearchDocument({
    id: "course.1", kind: "course", title: "Algorithms I",
    subtitle: "CS-250 · 6 crédits", detail: "algorithms i cs 250 cs250", courseCode: "CS-250",
  }),
  new SearchDocument({
    id: "course.2", kind: "course", title: "Analyse I",
    subtitle: "MATH-101 · 7 crédits", detail: "analyse i math 101 math101", courseCode: "MATH-101",
  }),
  new SearchDocument({
    id: "exercise.1", kind: "exercise", title: "Exercice 3.2 — Tri fusion",
    subtitle: "CS-250 · Série 3", detail: "exercice 3 2 tri fusion algo recursif",
    courseCode: "CS-250", date: new Date(),
  }),
  new SearchDocument({
    id: "theory.1", kind: "theory", title: "Analyse asymptotique",
    subtitle: "CS-250 · Vidéo 1.2", detail: "video 1 2 complexite grand o", courseCode: "CS-250",
  }),
  new SearchDocument({
    id: "session.1", kind: "session", title: "Révision récurrences",
    subtitle: "CS-250 · Exercices", detail: "revision recurrences exercices",
    courseCode: "CS-250", date: new Date(),
  }),
  new SearchDocument({
    id: "milestone.1", kind: "milestone", title: "Fin des examens",
    subtitle: "Fin des examens · 30 janv.", detail: "fin des examens",
  }),
];

describe("Recherche globale", () => {
  check(SearchEngine.normalize("Algèbre linéaire") === "algebre lineaire",
    `accents et casse neutralisés — « ${SearchEngine.normalize("Algèbre linéaire")} »`);
  check(SearchEngine.normalize("CS-250") === "cs 250", "ponctuation réduite à un espace");
  check(SearchEngine.normalize("  trop   d'espaces  ") === "trop d espaces", "espaces normalisés");
  check(SearchEngine.tokens("algo exo").join("|") === "algo|exo", "mots séparés");
  check(SearchEngine.search("", []).length === 0, "requête vide : aucun résultat");
  check(SearchEngine.search("   ", []).length === 0, "requête blanche : aucun résultat");

  // Trouver par intitulé.
  const algoHits = SearchEngine.search("algorithms", catalogue);
  check(algoHits[0]?.document.id === "course.1", "le cours sort en premier");
  check(algoHits[0]?.match === "title", "…et la correspondance est annoncée comme un intitulé");

  // Sans accent ni casse.
  check(SearchEngine.search("ANALYSE", catalogue).some((hit) => hit.document.id === "course.2"),
    "recherche insensible aux accents et à la casse");
  check(SearchEngine.search("asymptotique", catalogue)[0]?.document.id === "theory.1",
    "un titre de théorie se trouve");

  // Par code de cours, sous ses trois écritures.
  for (const written of ["CS-250", "cs250", "cs 250"]) {
    const found = SearchEngine.search(written, catalogue);
    check(found.some((hit) => hit.document.id === "exercise.1"), `« ${written} » trouve les exercices du cours`);
  }
  check(SearchEngine.search("cs250", catalogue).some((hit) => hit.document.id === "theory.1"),
    "…et la théorie du même cours");

  // Tous les mots doivent correspondre : c'est ce qui rend la recherche utile.
  const bothWords = SearchEngine.search("tri fusion", catalogue);
  check(bothWords.length === 1 && bothWords[0]?.document.id === "exercise.1",
    `deux mots : seul le document qui contient les deux sort (${bothWords.length})`);
  check(SearchEngine.search("tri banane", catalogue).length === 0, "un mot absent disqualifie le document");
  check(SearchEngine.search("algo cours", catalogue).length === 0,
    "« algo » ne suffit pas si le second mot n'existe nulle part");

  // Un mot du détail suffit, mais l'intitulé passe devant.
  const detailHit = SearchEngine.search("recursif", catalogue);
  check(detailHit[0]?.document.id === "exercise.1", "un mot du détail trouve le document");
  check(detailHit[0]?.match === "detail", "…et la correspondance est annoncée comme un détail");

  // Le code de cours est un cas intermédiaire, annoncé comme tel.
  const codeOnly = SearchEngine.search("math101", catalogue);
  check(codeOnly[0]?.match === "course", "correspondance par code annoncée comme telle");

  // À score égal, l'ordre des natures est stable : cours, puis exercice.
  const broad = SearchEngine.search("cs", catalogue);
  check(broad[0]?.kind === "course", "à pertinence comparable, un cours passe avant un exercice");
  const compare = (lhs: SearchHit, rhs: SearchHit): number =>
    lhs.score !== rhs.score ? rhs.score - lhs.score : SearchKind.rank(lhs.kind) - SearchKind.rank(rhs.kind);
  const sorted = [...broad].sort(compare);
  check(broad.every((hit, index) => hit.document.id === sorted[index]?.document.id) || broad.length < 2,
    "le tri est déterministe");

  // Groupement et résumé.
  const grouped = SearchEngine.grouped(algoHits);
  check(grouped.length === 1 && grouped[0]?.kind === "course", "regroupement par nature");
  check(SearchEngine.summary([], "").includes("Tape un code"), "sans requête, l'écran explique quoi taper");
  check(SearchEngine.summary([], "zzz").includes("zzz"), "sans résultat, la requête est citée");
  check(SearchEngine.summary(algoHits, "algorithms").includes("1 résultat"), "avec résultats, le compte est annoncé");

  // Le plafond : au-delà, la liste cesse d'aider.
  const many = Array.from({ length: 200 }, (_, index) => new SearchDocument({
    id: `x.${index}`, kind: "exercise", title: `Exercice ${index} trigonométrie`, detail: "trigonometrie",
  }));
  check(SearchEngine.search("trigonometrie", many).length === SearchEngine.limit,
    `les résultats sont plafonnés à ${SearchEngine.limit}`);

  // ── Index construit depuis les modèles ──────────────────────────────────────
  const indexCourse = courses.find((course) => course.code === "CS-250");
  if (indexCourse !== undefined) {
    const documents = SearchIndexBuilder.documents({ courses: [indexCourse] });
    check(documents.some((document) => document.kind === "course"), "le cours est indexé");
    check(documents.some((document) => document.kind === "series"), "ses séries sont indexées");
    check(documents.some((document) => document.kind === "exercise"), "ses exercices sont indexés");
    check(documents.some((document) => document.kind === "theory"), "sa théorie est indexée");
    check(documents.some((document) => document.kind === "exam"), "ses évaluations sont indexées");
    check(documents.length > 10, `l'index est fourni (${documents.length} documents pour un cours)`);

    // Le code du cours se retrouve sous ses deux écritures.
    const codeHit = SearchEngine.search("cs250", documents);
    check(codeHit.length !== 0, `« cs250 » trouve le cours et son contenu (${codeHit.length} résultats)`);

    // Chercher un titre réel du cours d'exemple.
    const series = indexCourse.sortedSeries[0];
    if (series !== undefined) {
      const found = SearchEngine.search(`serie ${series.seriesNumber}`, documents);
      check(found.some((hit) => hit.kind === "series" || hit.kind === "exercise"), "une série se retrouve par son numéro");
    }
    check(SearchEngine.search("zzzzintrouvable", documents).length === 0, "un mot absent ne ramène rien");
  }

  // Groupes et échéances sont indexables aussi.
  const builderMilestone = new AcademicMilestone({
    externalID: "test.fin-examens", title: "Fin des examens",
    date: DateUtils.addDays(30, new Date()), kind: "examEnd",
  });
  const nonCourseDocuments = SearchIndexBuilder.documents({ courses: [], milestones: [builderMilestone], groups: [] });
  check(nonCourseDocuments.some((document) => document.kind === "milestone"), "les échéances de l'EPFL sont cherchables");
  check(SearchEngine.search("examen", nonCourseDocuments).some((hit) => hit.kind === "milestone"),
    "…et se trouvent par leur intitulé");
});
