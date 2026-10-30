// Port des sections de Validation/main.swift qui portent sur la fiche de
// révision, la carte d'étude, les notes du Mac, NotebookLM et son protocole :
//   « La semaine relie la fiche », « Notes (GoodNotes → Google Drive) »,
//   « Personnalisation : règles des notes », « Fiche compréhensible… »,
//   « Fiche de révision », « NotebookLM : le protocole ».
// Chaque `check` Swift devient un `it` du même libellé.

import { describe, expect, it } from "vitest";

import {
  RevisionChapter, RevisionEntry, RevisionEntryKind, RevisionSheet, RevisionSheetAI,
  RevisionSheetBuilder, RevisionText,
} from "../../src/domain/revisionSheet.ts";
import type { BotafogoBlock } from "../../src/domain/botafogoPage.ts";
import {
  Diagram, DiagramLayout, LearningPath, MindGraph, MindLayout, StudyLinks,
} from "../../src/domain/studyMapGraph.ts";
import { StudyLink, StudyMap, StudyMastery, StudyRelation } from "../../src/domain/studyMap.ts";
import { Course } from "../../src/models/course.ts";
import { StudyMapAI } from "../../src/domain/studyMapAI.ts";
import { NotebookExport } from "../../src/domain/notebookExport.ts";
import { NotesLibrary, NotesRules, type CourseKey } from "../../src/domain/notesLibrary.ts";
import { NotebookLMWire, NotebookParseError } from "../../src/domain/notebookLMWire.ts";
import "../../src/domain/registerCodecs.ts";

function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

const eq = <T>(a: T, b: T): boolean => JSON.stringify(a) === JSON.stringify(b);

describe("La semaine relie la fiche (RevisionSheet.chaptersForPath)", () => {
  const entry = (id: string, link: string): RevisionEntry =>
    new RevisionEntry({ id, kind: "theorem", title: id, body: "b", source: "", link });
  const sheet = new RevisionSheet({
    origin: "handout", generatedAt: new Date(), chapters: [
      new RevisionChapter({ id: "c0", title: "Suites", entries: [entry("a", "/handout/matiere/m_suites"), entry("b", "/handout/matiere/m_suites/cauchy")] }),
      new RevisionChapter({ id: "c1", title: "Limites", entries: [entry("c", "studytrack-poly:///handout/matiere/m_limites")] }),
      new RevisionChapter({ id: "c2", title: "Sans lien", entries: [entry("d", "")] }),
    ],
  });
  check(sheet.chaptersForPath("/handout/matiere/m_suites").map((c) => c.id).join(",") === "c0", "semaine : une section → son chapitre");
  check(sheet.chaptersForPath("/handout/matiere/m_suites/cauchy/detail").map((c) => c.id).join(",") === "c0", "semaine : une sous-section d'un renvoi → le chapitre");
  check(sheet.chaptersForPath("/handout/matiere/m_limites").map((c) => c.id).join(",") === "c1", "semaine : un lien de l'app est reconnu");
  check(sheet.chaptersForPath("/handout/matiere/autre").length === 0 && sheet.chaptersForPath("").length === 0, "semaine : rien à relier");
});

describe("Notes (GoodNotes → Google Drive)", () => {
  const courses: CourseKey[] = [
    { code: "CS-101", name: "Advanced information, computation, communication I" },
    { code: "CS-107", name: "Introduction à la programmation" },
    { code: "MATH-101", name: "Analyse I classe inversée" },
    { code: "MATH-111", name: "Algèbre linéaire classe inversée" },
    { code: "PHYS-101", name: "Physique générale : mécanique anglais" },
  ];
  const course = (folder: string): string | null =>
    NotesLibrary.course(folder, courses)?.code ?? null;
  check(course("MATH-111 Algèbre linéaire") === "MATH-111" && course("PHYS-101 Mécanique") === "PHYS-101", "cahier : par le code");
  check(course("Algèbre Linéaire") === "MATH-111" && course("Mécanique") === "PHYS-101" && course("Analyse") === "MATH-101"
    && course("Programmation") === "CS-107", "cahier : par le nom");
  check(course("AICC") === "CS-101", "cahier : par l'acronyme");
  check(course("Photos") === null, "cahier sans cours");
  const now = new Date();
  const doc = NotesLibrary.document("EPFL BA1/Algèbre Linéaire/Semaine 3/Série 3.pdf", now);
  check(doc?.notebook === "Algèbre Linéaire" && doc?.week === 3 && doc?.seriesNumber === 3 && doc?.isSolution === false, "document : cahier, semaine, série");
  check(NotesLibrary.document("EPFL BA1/Algèbre Linéaire/Semaine 3/Serie 03 Solutions.pdf", now)?.isSolution === true, "document : un corrigé");
  check(NotesLibrary.seriesNumber("PS5 (1)") === 5 && NotesLibrary.seriesNumber("Séance et série 4") === 4
    && NotesLibrary.seriesNumber("Problem Set 6") === 6 && NotesLibrary.seriesNumber("Lecture 5a") === null, "numéro de série");
  const docs = [
    NotesLibrary.document("N/Semaine 3/Série 3 poly.pdf", new Date(now.getTime() - 100_000))!,
    NotesLibrary.document("N/Semaine 3/Série 3.pdf", now)!,
    NotesLibrary.document("N/Semaine 3/Serie 03 Solutions.pdf", new Date(now.getTime() + 10_000))!,
    NotesLibrary.document("N/Semaine 5/Séance Et Série 5.pdf", now)!,
  ];
  check(NotesLibrary.copy(3, 3, docs)?.title === "Série 3", "ta copie : la plus récente, pas le corrigé");
  check(NotesLibrary.copy(9, 5, docs)?.title === "Séance Et Série 5", "ta copie : la série de la semaine");

  // Personnalisation : règles des notes.
  const two: CourseKey[] = [{ code: "MATH-101", name: "Analyse I" }, { code: "MATH-106", name: "Analyse II" }];
  const rules = new NotesRules({ notebooks: { Analyse: "MATH-106", Brouillons: "" } });
  check(NotesLibrary.course("Analyse", two, rules)?.code === "MATH-106", "cahier rangé à la main : l'emporte");
  check(NotesLibrary.course("Brouillons", two, rules) === null, "cahier écarté à la main");
  rules.seriesWords = ["TD", "Übung"];
  rules.weekWords = ["Woche"];
  check(NotesLibrary.seriesNumber("TD 4 corrigé", rules) === 4 && NotesLibrary.seriesNumber("Übung 07", rules) === 7
    && NotesLibrary.seriesNumber("Série 3", rules) === null, "mots d'une série choisis");
  check(NotesLibrary.weekNumber("Woche 3", rules) === 3 && NotesLibrary.weekNumber("Semaine 3", rules) === null, "mot de semaine choisi");
  check(NotesLibrary.seriesNumber("laps 3") === null && NotesLibrary.seriesNumber("PS5") === 5, "un mot court commence un mot");
  check(NotesRules.standard.encoded() === NotesRules.decode("{}")?.encoded(), "règles par défaut relues");
});

describe("Fiche compréhensible : liens, carte, schémas, parcours", () => {
  const entry = (id: string, kind: RevisionEntryKind, title: string, body = "…"): RevisionEntry =>
    new RevisionEntry({ id, kind, title, body });
  const sheet = new RevisionSheet({
    origin: "ai", generatedAt: new Date(0), chapters: [
      new RevisionChapter({
        id: "c0", title: "Suites", entries: [
          entry("a", "definition", "Définition 1.1 (suite bornée)", "Une suite est bornée si…"),
          entry("b", "theorem", "Théorème 1.2 (monotone bornée)", "Par la définition 1.1, une suite monotone bornée converge."),
          entry("c", "method", "Montrer qu'une suite converge", "Utiliser le théorème 1.2 puis la proposition 2.1."),
        ],
      }),
      new RevisionChapter({
        id: "c1", title: "Séries", entries: [
          entry("d", "proposition", "Proposition 2.1 (critère de Cauchy)", "Une suite de Cauchy converge."),
          entry("e", "pitfall", "Piège : série et suite", "Ne pas confondre une série et sa suite des termes."),
          entry("f", "definition", "Définition 1.1 (suite bornée)", "doublon"),
        ],
      }),
    ],
  });
  const keyed = sheet.keyed;
  check(keyed.length === 6 && new Set(keyed.map((item) => item.key)).size === 6, "carte : chaque notion a une clé, un doublon prend « #2 »");
  check(keyed[0].key === "definition 1.1 (suite bornee)" && keyed[5].key === "definition 1.1 (suite bornee)#2", "carte : la clé est le titre sans accents ni casse");
  check(sheet.entryForKey(keyed[1].key)?.entry.id === "b", "carte : on retrouve une notion par sa clé");

  // Liens déduits des citations
  const cited = StudyLinks.cited(sheet);
  const byID = new Map(keyed.map((item) => [item.entry.id, item.key]));
  const has = (from: string, to: string): boolean =>
    cited.some((link) => link.from === byID.get(from) && link.to === byID.get(to) && link.relation === "uses");
  check(has("b", "a"), "liens : « par la définition 1.1 » → le théorème se sert de la définition");
  check(has("c", "b") && has("c", "d"), "liens : la méthode cite le théorème 1.2 et la proposition 2.1");
  check(!cited.some((link) => link.from === link.to), "liens : jamais une notion qui se cite elle-même");
  check(!has("a", "b"), "liens : le sens est celui de la citation");

  // Fusion : ce qu'on a posé à la main reste
  const userLink = new StudyLink({ from: byID.get("e")!, to: byID.get("d")!, relation: "contrast", note: "à ne pas confondre", userMade: true });
  const stale = new StudyLink({ from: byID.get("a")!, to: "disparu", relation: "needs" });
  const merged = StudyLinks.merged([userLink, stale], cited, new Set(keyed.map((item) => item.key)));
  check(merged.some((link) => link.id === userLink.id) && !merged.some((link) => link.id === stale.id) && merged.length === cited.length + 1,
    "liens : ceux posés à la main restent, un lien vers rien tombe");
  check(StudyLinks.merged([userLink], [userLink], new Set(keyed.map((item) => item.key))).length === 1, "liens : pas de doublon");

  // Voisinage
  const map = new StudyMap();
  map.links = cited.concat([userLink]);
  const near = StudyLinks.neighbourhood(byID.get("b")!, map, new Set(keyed.map((item) => item.key)));
  check(near.before.map((item) => item.key).join("|") === byID.get("a") && near.after.map((item) => item.key).join("|") === byID.get("c"),
    "voisinage : ce qui précède (la définition), ce qui suit (la méthode)");
  check(StudyLinks.neighbourhood(byID.get("e")!, map, new Set(keyed.map((item) => item.key))).aside.map((item) => item.key).join("|") === byID.get("d"),
    "voisinage : à ne pas confondre, dans les deux sens");
  check(StudyLinks.neighbourhood(byID.get("d")!, map, new Set(keyed.map((item) => item.key))).aside.map((item) => item.key).join("|") === byID.get("e"),
    "voisinage : de l'autre côté aussi");

  // Parcours : une notion jamais avant ce dont elle a besoin
  const inverted = new StudyMap();
  inverted.links = [new StudyLink({ from: byID.get("a")!, to: byID.get("d")!, relation: "needs" })];
  const order = LearningPath.order(sheet, inverted);
  check(order.indexOf(byID.get("d")!) < order.indexOf(byID.get("a")!),
    "parcours : la proposition passe avant ce qui en a besoin, même plus loin dans la fiche");
  check(new Set(order).size === new Set(keyed.map((item) => item.key)).size && order.length === 6, "parcours : toutes les notions, une fois");
  check(eq(LearningPath.order(sheet, new StudyMap()), keyed.map((item) => item.key)), "parcours : sans lien, l'ordre de la fiche");
  const cyclic = new StudyMap();
  cyclic.links = [
    new StudyLink({ from: byID.get("a")!, to: byID.get("b")!, relation: "needs" }),
    new StudyLink({ from: byID.get("b")!, to: byID.get("a")!, relation: "needs" }),
  ];
  check(LearningPath.order(sheet, cyclic).length === 6, "parcours : un cycle ne bloque rien");
  const progress = new StudyMap();
  progress.links = cited;
  check(LearningPath.next(sheet, progress) === keyed[0].key, "parcours : on commence par la première notion pas solide");
  progress.progress[keyed[0].key] = { level: StudyMastery.solid, at: new Date() };
  check(LearningPath.next(sheet, progress) !== keyed[0].key, "parcours : une notion solide passe");
  progress.progress[keyed[1].key] = { level: StudyMastery.shaky, at: new Date() };
  const counts = LearningPath.counts(sheet, progress);
  check(counts.solid === 1 && counts.shaky === 1 && counts.unknown === 4 && counts.total === 6 && Math.abs(counts.fraction - 1 / 6) < 1e-9,
    "parcours : le compte (solide, fragile, pas encore)");
  // Ce qui porte beaucoup pèse plus.
  const weak = new StudyMap();
  weak.links = [
    new StudyLink({ from: byID.get("b")!, to: byID.get("a")!, relation: "needs" }),
    new StudyLink({ from: byID.get("c")!, to: byID.get("a")!, relation: "needs" }),
    new StudyLink({ from: byID.get("e")!, to: byID.get("a")!, relation: "needs" }),
  ];
  check(eq(LearningPath.weakSpots(sheet, weak, 1), [byID.get("a")]), "parcours : la notion dont trois autres dépendent est à reprendre d'abord");
  weak.progress[byID.get("a")!] = { level: StudyMastery.solid, at: new Date() };
  check(!LearningPath.weakSpots(sheet, weak, 10).includes(byID.get("a")!), "parcours : le solide n'est pas à reprendre");
  check(LearningPath.shakyPrerequisites(byID.get("b")!, weak, new Set(keyed.map((item) => item.key))).length === 0,
    "parcours : prérequis tous solides, rien à reprendre d'abord");
  weak.progress[byID.get("a")!] = { level: StudyMastery.shaky, at: new Date() };
  check(eq(LearningPath.shakyPrerequisites(byID.get("b")!, weak, new Set(keyed.map((item) => item.key))), [byID.get("a")]),
    "parcours : « reprends d'abord… » quand un prérequis est fragile");

  // Carte mentale
  const tidy = new StudyMap();
  tidy.customNodes = [
    { id: "x1", title: "Mon idée", parent: byID.get("b")! },
    { id: "x2", title: "Orpheline", parent: "disparu" },
  ];
  const nodes = MindGraph.nodes(sheet, tidy, "Analyse");
  check(nodes[0]?.id === "root" && nodes.filter((node) => node.role.kind === "chapter").length === 2 && nodes.length === 1 + 2 + 6 + 2,
    "carte : la racine, les chapitres, les notions, les idées");
  check(nodes.find((node) => node.id === "custom:x1")?.parent === byID.get("b") && nodes.find((node) => node.id === "custom:x2")?.parent === "root",
    "carte : une idée est accrochée à sa notion, sinon à la racine");
  const positions = MindLayout.twoSided(nodes);
  check(positions["root"]?.x === 0 && positions["root"]?.y === 0, "carte : la racine est au centre");
  check(nodes.filter((node) => node.depth === 1 && node.role.kind === "chapter").some((node) => (positions[node.id]?.x ?? 0) > 0)
    && nodes.filter((node) => node.role.kind === "chapter").some((node) => (positions[node.id]?.x ?? 0) < 0),
    "carte : les chapitres des deux côtés de la racine");
  const seenPoints = new Set<string>();
  let overlap = false;
  for (const node of nodes) {
    const point = positions[node.id];
    if (point !== undefined && seenPoints.has(`${point.x}|${point.y}`)) overlap = true;
    if (point !== undefined) seenPoints.add(`${point.x}|${point.y}`);
  }
  check(!overlap && Object.keys(positions).length === nodes.length, "carte : pas deux nœuds au même endroit");
  const chapterX = nodes.filter((node) => node.role.kind === "chapter").map((node) => Math.abs(positions[node.id]?.x ?? 0));
  const entryX = nodes.filter((node) => node.role.kind === "entry").map((node) => Math.abs(positions[node.id]?.x ?? 0));
  check(new Set(chapterX).size === 1 && new Set(entryX).size === 1 && entryX[0] > chapterX[0],
    "carte : une colonne par profondeur, les notions plus loin que les chapitres");
  const hiddenNodes = MindGraph.visible(nodes, new Set([MindGraph.chapterNode("c0")]));
  check(hiddenNodes.length === nodes.length - 3 - 1 && !hiddenNodes.some((node) => node.id === byID.get("a"))
    && hiddenNodes.some((node) => node.id === MindGraph.chapterNode("c0")), "carte : replier un chapitre cache ses notions (et leurs idées)");
  check(Object.keys(MindLayout.twoSided([])).length === 0, "carte : rien à placer, rien");
  const box = MindLayout.bounds(positions)!;
  check(box.minX < 0 && box.maxX > 0, "carte : les bornes englobent les deux côtés");

  // Schémas
  const diagram = new Diagram({ id: "s", title: "Choisir", kind: "tree" });
  diagram.nodes = [
    { id: "q", label: "Monotone ?" }, { id: "y", label: "Oui : bornée ?" },
    { id: "n", label: "Non : Cauchy ?" }, { id: "z", label: "Converge" },
  ];
  diagram.edges = [
    { from: "q", to: "y", label: "oui" }, { from: "q", to: "n", label: "non" },
    { from: "y", to: "z" }, { from: "n", to: "z" },
  ];
  const layout = DiagramLayout.layered(diagram);
  check(layout.layers.length === 3 && eq(layout.layers[0], ["q"])
    && eq([...layout.layers[1]].sort(), ["n", "y"]) && eq(layout.layers[2], ["z"]),
  "schéma : couches du plus long chemin");
  check(layout.positions["q"]!.y < layout.positions["y"]!.y && layout.positions["y"]!.y < layout.positions["z"]!.y, "schéma : de haut en bas");
  check(layout.positions["y"]!.x !== layout.positions["n"]!.x && layout.width > 0 && layout.height > 0, "schéma : deux nœuds d'une couche côte à côte");
  check(Math.abs(layout.positions["q"]!.x - layout.width / 2) < 1e-9 && Math.abs(layout.positions["z"]!.x - layout.width / 2) < 1e-9,
    "schéma : une couche seule est centrée");
  const cycle = new Diagram({ id: "c", title: "Boucle", kind: "flow" });
  cycle.nodes = [{ id: "a", label: "A" }, { id: "b", label: "B" }, { id: "c", label: "C" }];
  cycle.edges = [{ from: "a", to: "b" }, { from: "b", to: "c" }, { from: "c", to: "a" }];
  const looped = DiagramLayout.layered(cycle);
  check(looped.layers.length === 3 && looped.backEdges.length === 1 && Object.keys(looped.positions).length === 3,
    "schéma : un cycle est tracé, la flèche de retour mise à part");
  const broken = new Diagram({ id: "s", title: "Choisir", kind: "tree", nodes: diagram.nodes, edges: [...diagram.edges] });
  broken.edges.push({ from: "q", to: "inconnu" });
  broken.edges.push({ from: "z", to: "z" });
  check(Object.keys(DiagramLayout.layered(broken).positions).length === 4, "schéma : une flèche vers rien ou vers soi-même est ignorée");
  check(Object.keys(DiagramLayout.layered(new Diagram({ id: "v", title: "Vide", kind: "flow" })).positions).length === 0, "schéma : vide, rien");

  // Réponse de Claude
  const prompt = StudyMapAI.prompt("Analyse", sheet);
  check(Object.keys(prompt.ids).length === 6 && prompt.text.includes("[e1] (definition) Définition 1.1") && prompt.text.includes("## Séries"),
    "IA : le message donne chaque notion avec son identifiant");
  const answer = `Voici :
\`\`\`json
{"entries":[{"id":"e2","gist":"Une suite qui monte sans dépasser un plafond finit par se poser.","why":"C'est le critère de convergence le plus utilisé.","example":"$u_n = 1 - 1/n$","question":"Pourquoi borné est-il nécessaire ?","answer":"Sinon elle peut diverger vers l'infini."},
            {"id":"e99","gist":"inconnue"}, {"id":"e5","gist":""}],
 "links":[{"from":"e2","to":"e1","relation":"needs","note":"borné"},{"from":"e5","to":"e4","relation":"à ne pas confondre"},{"from":"e2","to":"e77","relation":"needs"},{"from":"e2","to":"e1","relation":"???"}],
 "schemas":[{"title":"Choisir un critère","kind":"tree","nodes":[{"id":"n1","label":"Monotone ?","entry":"e2"},{"id":"n2","label":"Converge","entry":"e99"}],"edges":[{"from":"n1","to":"n2","label":"oui"},{"from":"n1","to":"zz"}]},
            {"title":"Trop petit","kind":"flow","nodes":[{"id":"x","label":"seul"}],"edges":[]},
            {"title":"Suite ou série","kind":"comparison","columns":["Suite","Série"],"rows":[["Objet","u_n","somme"]]},
            {"kind":"flow"}]}
\`\`\``;
  const seeded = new StudyMap();
  seeded.progress[byID.get("a")!] = { level: StudyMastery.solid, at: new Date(5000) };
  seeded.notes[byID.get("a")!] = "ma note";
  seeded.links = [userLink];
  const applied = StudyMapAI.apply(answer, sheet, prompt.ids, seeded, new Date(99_000));
  check(applied !== null, "IA : une réponse avec du texte et un bloc de code se lit");
  check(applied?.enrichment[byID.get("b")!]?.gist?.startsWith("Une suite qui monte") === true
    && applied?.enrichment[byID.get("b")!]?.check?.answer === "Sinon elle peut diverger vers l'infini.",
    "IA : la phrase en clair et la question");
  check(Object.keys(applied?.enrichment ?? {}).length === 1, "IA : une notion inconnue ou vide ne donne rien");
  check(applied?.links.some((link) => link.id === userLink.id) === true
    && applied?.links.some((link) => link.from === byID.get("b") && link.to === byID.get("a") && link.relation === "needs" && link.note === "borné") === true,
    "IA : ses liens s'ajoutent, ceux posés à la main restent");
  check(applied?.links.some((link) => link.relation === "contrast" && link.from === byID.get("e") && link.to === byID.get("d")) === true,
    "IA : « à ne pas confondre » en toutes lettres devient un lien de contraste");
  check(applied?.links.filter((link) => link.to === "e77" || (link.relation === "needs" && link.to === byID.get("a") && link.from === byID.get("b"))).length === 1,
    "IA : un lien vers une notion inconnue ou à la relation illisible tombe (sans doublon)");
  check(applied?.links.some((link) => link.from === byID.get("b") && link.to === byID.get("a") && link.relation === "uses") === true,
    "IA : les citations de la fiche s'ajoutent aussi");
  check(applied?.diagrams.length === 2 && applied?.diagrams[0].kind === "tree" && applied?.diagrams[0].nodes.length === 2,
    "IA : un schéma d'un seul nœud ou sans titre tombe");
  check(applied?.diagrams[0].nodes[0].entry === byID.get("b") && applied?.diagrams[0].nodes[1].entry === undefined,
    "IA : un nœud désigne sa notion, ou rien si elle n'existe pas");
  check(applied?.diagrams[0].edges.length === 1, "IA : une flèche vers un nœud absent tombe");
  check(applied?.diagrams[1].kind === "comparison" && eq(applied?.diagrams[1].rows?.[0], ["Objet", "u_n", "somme"]),
    "IA : une comparaison garde ses colonnes et ses lignes");
  check(applied?.progress[byID.get("a")!]?.level === StudyMastery.solid && applied?.notes[byID.get("a")!] === "ma note",
    "IA : où tu en es et tes notes ne bougent pas");
  check(applied?.enrichedAt?.getTime() === 99_000, "IA : la date de l'enrichissement");
  check(StudyMapAI.apply("pas de json", sheet, prompt.ids, seeded) === null, "IA : une réponse sans JSON est refusée");

  // Une nouvelle fiche : ce qui désigne encore quelque chose reste
  const shorter = new RevisionSheet({
    origin: "ai", generatedAt: new Date(), chapters: [new RevisionChapter({
      id: "z0", title: "Nouveau", entries: [
        entry("a2", "definition", "Définition 1.1 (suite bornée)"),
        entry("b2", "theorem", "Théorème nouveau"),
      ],
    })],
  });
  const richer = applied!;
  richer.customNodes = [{ id: "x", title: "idée" }];
  const rebased = StudyMapAI.rebased(richer, shorter);
  check(Object.keys(rebased.progress).includes(byID.get("a")!) && Object.keys(rebased.notes).length === 1,
    "nouvelle fiche : la maîtrise et les notes d'une notion qui existe encore restent");
  const shorterKeys = new Set(shorter.keyed.map((item) => item.key));
  check(Object.keys(rebased.enrichment).length === 0
    && rebased.links.every((link) => shorterKeys.has(link.from) && shorterKeys.has(link.to)),
    "nouvelle fiche : ce qui désignait une notion disparue tombe");
  check(rebased.customNodes.length === 1, "nouvelle fiche : tes idées restent");

  // Garder
  const back = StudyMap.decode(applied!.encoded());
  check(back?.encoded() === applied!.encoded(), "carte : se relit telle qu'écrite");
  check(StudyMap.decode("") === null && StudyMap.decode("pas du json") === null, "carte : vide ou illisible, rien");
  check(new StudyMap().isEmpty && !applied!.isEmpty, "carte : « vide » veut dire rien du tout");
  const implication = new StudyLink({ from: "a", to: "b", relation: "implies" }).prerequisite;
  check(StudyRelation.label("needs") !== StudyRelation.inverseLabel("needs")
    && implication?.before === "a" && implication?.after === "b",
  "liens : « implique » met le premier avant, « a besoin de » le second");
  check(new StudyLink({ from: "a", to: "b", relation: "contrast" }).prerequisite === null, "liens : un contraste n'a pas d'ordre");

  // Un même voisin n'est montré qu'une fois (citation + lien de Claude sur la même paire)
  const twice = new StudyMap();
  twice.links = [
    new StudyLink({ from: "x", to: "y", relation: "uses" }),
    new StudyLink({ from: "x", to: "y", relation: "needs", note: "un plafond" }),
  ];
  const once = StudyLinks.neighbourhood("x", twice, new Set(["x", "y"]));
  check(once.before.length === 1 && once.before[0].note === "un plafond", "voisinage : un voisin une seule fois, avec l'explication");

  // Par chapitre : la même fiche, regardée un chapitre à la fois
  check(eq(sheet.keyedIn("c1").map((item) => item.entry.id), ["d", "e", "f"]) && sheet.keyedIn(null).length === 6 && sheet.keyedIn("inconnu").length === 0,
    "chapitre : ses notions, ou toutes");
  check(sheet.keyedIn("c1")[0]?.key === keyed[3].key, "chapitre : les clés restent celles de la fiche entière");
  const oneChapter = MindGraph.nodes(sheet, new StudyMap(), "Analyse", "c1");
  check(oneChapter[0]?.title === "Séries" && oneChapter[0]?.role.kind === "root" && oneChapter.length === 4
    && oneChapter.slice(1).every((node) => node.parent === MindGraph.rootID && node.depth === 1),
    "carte d'un chapitre : lui en racine, ses notions autour");
  const withIdea = new StudyMap();
  withIdea.customNodes = [
    { id: "i", title: "idée", parent: MindGraph.chapterNode("c1") },
    { id: "j", title: "ailleurs", parent: MindGraph.chapterNode("c0") },
  ];
  const ideas = MindGraph.nodes(sheet, withIdea, "Analyse", "c1").filter((node) => node.role.kind === "custom");
  check(ideas.map((node) => node.title).join("|") === "idée" && ideas[0]?.parent === MindGraph.rootID,
    "carte d'un chapitre : seulement les idées de ce chapitre");
  const mastered = new StudyMap();
  mastered.progress[keyed[3].key] = { level: StudyMastery.solid, at: new Date() };
  const chapterCounts = LearningPath.counts(sheet, mastered, "c1");
  check(chapterCounts.unknown === 2 && chapterCounts.shaky === 0 && chapterCounts.solid === 1 && LearningPath.counts(sheet, mastered).total === 6,
    "parcours d'un chapitre : le compte de ce chapitre seul");
  check(LearningPath.order(sheet, mastered, "c1").length === 3 && LearningPath.next(sheet, mastered, "c1") === keyed[4].key,
    "parcours d'un chapitre : l'ordre et la suite de ce chapitre");

  const scopedPrompt = StudyMapAI.prompt("Analyse", sheet, 220, 400, "c1");
  check(scopedPrompt.text.includes("CHAPITRE : Séries") && !scopedPrompt.text.includes("Théorème 1.2")
    && Object.keys(scopedPrompt.ids).length === 3 && scopedPrompt.ids["e4"] === keyed[3].key,
    "IA d'un chapitre : seulement ses notions, avec leurs identifiants de la fiche entière");
  const chapterAnswer = `{"entries":[{"id":"e4","gist":"Si les termes se rapprochent, ça converge."}],
 "links":[{"from":"e5","to":"e4","relation":"contrast","note":"à ne pas confondre"}],
 "schemas":[{"title":"Cauchy","kind":"flow","nodes":[{"id":"a","label":"Termes proches"},{"id":"b","label":"Converge"}],"edges":[{"from":"a","to":"b"}]}]}`;
  const base = new StudyMap();
  base.links = [new StudyLink({ from: keyed[1].key, to: keyed[0].key, relation: "needs", note: "d'ailleurs" })];
  base.diagrams = [new Diagram({ id: "ailleurs", title: "Autre chapitre", kind: "flow" })];
  const scoped = StudyMapAI.apply(chapterAnswer, sheet, scopedPrompt.ids, base, new Date(5000), "c1");
  check(scoped !== null && scoped!.enrichment[keyed[3].key]?.gist !== undefined
    && scoped!.enrichedChapters?.["c1"]?.getTime() === 5000 && scoped!.enrichedAt === null,
    "IA d'un chapitre : la phrase en clair, et ce chapitre est noté comme relu (pas le cours)");
  check(scoped!.links.some((link) => link.from === keyed[1].key && link.note === "d'ailleurs")
    && scoped!.links.some((link) => link.relation === "contrast"),
    "IA d'un chapitre : les liens des autres chapitres restent, les siens s'ajoutent");
  check(scoped!.diagrams.length === 2 && scoped!.diagrams.some((schema) => schema.chapter === "c1" && schema.title === "Cauchy")
    && scoped!.diagrams.some((schema) => schema.id === "ailleurs"),
    "IA d'un chapitre : son schéma s'ajoute, celui d'un autre reste");
  const again = StudyMapAI.apply(chapterAnswer, sheet, scopedPrompt.ids, scoped!, new Date(), "c1")!;
  check(again.diagrams.length === 2, "IA d'un chapitre : refaire remplace ses schémas au lieu de les doubler");
  const whole = StudyMapAI.apply(`{"schemas":[{"title":"Tout","kind":"flow","nodes":[{"id":"a","label":"x"},{"id":"b","label":"y"}],"edges":[{"from":"a","to":"b"}]}]}`,
    sheet, {}, scoped!)!;
  check(whole.diagrams.some((schema) => schema.chapter === "c1") && whole.diagrams.some((schema) => schema.title === "Tout" && schema.chapter === null)
    && !whole.diagrams.some((schema) => schema.id === "ailleurs"),
    "IA du cours : remplace ceux du cours, garde ceux des chapitres");
  const gone = StudyMapAI.rebased(scoped!, new RevisionSheet({
    origin: "ai", generatedAt: new Date(), chapters: [new RevisionChapter({
      id: "c0", title: "Suites", entries: [entry("a", "definition", "Définition 1.1 (suite bornée)", "x")],
    })],
  }));
  check(gone.enrichedChapters?.["c1"] === undefined && gone.diagrams.every((schema) => schema.chapter === null),
    "nouvelle fiche : un chapitre disparu ne laisse rien derrière lui");

  const chapterFiles = NotebookExport.files("Analyse", "MATH-101", sheet, scoped!, "c1");
  const chapterSheet = chapterFiles.find((file) => file.name.startsWith("01"))?.text ?? "";
  check(chapterSheet.includes("Piège : série et suite") && !chapterSheet.includes("Théorème 1.2")
    && chapterFiles.every((file) => file.name.includes("Séries")),
    "NotebookLM d'un chapitre : seulement ses notions, nommé d'après lui");
  check((chapterFiles.find((file) => file.name.startsWith("03"))?.text ?? "").includes("Cauchy")
    && !(chapterFiles.find((file) => file.name.startsWith("03"))?.text ?? "").includes("Autre chapitre"),
    "NotebookLM d'un chapitre : seulement ses schémas");

  // NotebookLM
  const notebook = applied!;
  notebook.enrichment[byID.get("a")!] = { gist: "Un plafond et un plancher." };
  const files = NotebookExport.files("Analyse I", "MATH-101", sheet, notebook);
  check(["01 Fiche · MATH-101.md", "02 Liens entre les notions · MATH-101.md", "03 Schémas · MATH-101.md",
    "04 Questions pour se tester · MATH-101.md", "00 Lis-moi · MATH-101.md"].every((name) => files.some((file) => file.name === name)),
  "NotebookLM : la fiche, les liens, les schémas, les questions, le mode d'emploi");
  const sheetFile = files.find((file) => file.name.startsWith("01"))!.text;
  check(sheetFile.includes("### Théorème 1.2 (monotone bornée) (Théorème)") && sheetFile.includes("En clair : Un plafond et un plancher.")
    && sheetFile.includes("À comprendre avant : Définition 1.1 (suite bornée)"),
  "NotebookLM : chaque notion avec son en clair et ce qu'il faut comprendre avant");
  check(files.find((file) => file.name.startsWith("02"))!.text.includes("**Théorème 1.2 (monotone bornée)** a besoin de **Définition 1.1 (suite bornée)** — borné"),
    "NotebookLM : les liens en phrases");
  check(files.find((file) => file.name.startsWith("03"))!.text.includes("| Objet | u_n | somme |")
    && files.find((file) => file.name.startsWith("03"))!.text.includes("Monotone ? →"),
  "NotebookLM : un tableau et les flèches des schémas");
  check(eq(NotebookExport.files("X", "X", sheet, new StudyMap()).map((file) => file.name), ["01 Fiche · X.md", "00 Lis-moi · X.md"]),
    "NotebookLM : sans liens ni schémas, la fiche seule");
});

describe("Fiche de révision", () => {
  const blocks: BotafogoBlock[] = [
    { type: "paragraph", text: "Introduction." },
    {
      type: "theorem", kind: "definition", title: "Définition 5.1",
      content: [{ type: "paragraph", text: "Une suite $(a_n)$ est de **Cauchy** si…" }],
    },
    {
      type: "theorem", kind: "theorem", title: "Théorème 5.4 (critère de d'Alembert)", content: [
        { type: "paragraph", text: "Si $\\lim |a_{n+1}/a_n| < 1$, la série converge." },
        { type: "folded", fold: "proof", title: "Preuve", content: [{ type: "paragraph", text: "On compare à une série géométrique." }] },
      ],
    },
    { type: "theorem", kind: "example", title: "Exemple 5.2", content: [{ type: "paragraph", text: "La série harmonique." }] },
    {
      type: "aside", title: "Informel", content: [{
        type: "theorem", kind: "proposition", title: "Proposition 5.3",
        content: [{ type: "paragraph", text: "Le terme général tend vers $0$." }],
      }],
    },
  ];
  const found = RevisionSheetBuilder.entries(blocks, "5.1 Séries", "/handout/matiere/m_series");
  check(eq(found.map((entry) => entry.title), ["Définition 5.1", "Théorème 5.4 (critère de d'Alembert)", "Proposition 5.3"]),
    `polycopié : définitions, théorèmes, propositions (même dans un encadré), sans les exemples — ${found.map((entry) => entry.title).join(", ")}`);
  check(found[1] !== undefined && !found[1].body.includes("géométrique") && found[1].body.includes("converge"),
    "polycopié : l'énoncé sans sa preuve");
  check(found[0]?.link === "/handout/matiere/m_series" && found[0]?.source === "5.1 Séries", "polycopié : la section où le relire");

  const sheet = RevisionSheetBuilder.sheet(
    [{ title: "5 Séries", sections: [{ title: "5.1 Séries", path: "/handout/matiere/m_series" }] }],
    { "/handout/matiere/m_series": blocks },
  );
  check(sheet.chapters.length === 1 && sheet.entries.length === 3, "polycopié : un chapitre, trois énoncés");
  check(RevisionSheet.decode(sheet.encoded())?.encoded() === sheet.encoded(), "la fiche se garde et se relit telle quelle");
  check(sheet.filtered("alembert").flatMap((chapter) => chapter.entries).length === 1, "l'index retrouve « d'Alembert » sans accent ni casse");
  check(sheet.filtered("").length === 1, "sans recherche, toute la fiche");

  const relevant = sheet.relevant("Étudier la convergence de la série $\\sum n!/n^n$ avec le critère de d'Alembert.");
  check(relevant[0]?.title.includes("Alembert") === true,
    `à savoir : le critère cité par l'exercice vient d'abord — ${relevant.map((entry) => entry.title).join(", ")}`);
  check(sheet.relevant("Dessiner un triangle équilatéral.").length === 0, "à savoir : rien plutôt qu'un hasard");
  check(sheet.relevant("Appliquer le théorème 5.4.")[0]?.title.startsWith("Théorème 5.4") === true, "à savoir : un numéro cité suffit");

  const answer = `Voici la fiche :
\`\`\`json
{"chapters":[{"title":"Applications linéaires","entries":[
  {"kind":"définition","title":"Noyau","body":"$\\\\ker T$","source":"Cours 5"},
  {"kind":"Méthode","title":"Famille libre","body":"Poser une combinaison nulle…"},
  {"kind":"bizarre","title":"","body":"Toujours vérifier les hypothèses."},
  {"kind":"theorem","title":"","body":""}]},
  {"title":"Vide","entries":[]}]}
\`\`\``;
  const ai = RevisionSheetAI.sheet(answer);
  check(ai?.chapters.length === 1 && eq(ai?.entries.map((entry) => entry.kind), ["definition", "method", "remark"]),
    `réponse du modèle : genres reconnus, entrées vides et chapitres vides écartés — ${ai?.entries.map((entry) => entry.kind).join(",") ?? ""}`);
  check(ai?.entries.at(-1)?.title === "Remarque", "réponse du modèle : un titre manquant prend le nom du genre");
  check(RevisionSheetAI.sheet("Désolé, je ne peux pas.") === null, "réponse du modèle sans JSON : pas de fiche");
  const long = RevisionSheetAI.prompt("X", [
    { title: "A", text: "a".repeat(300_000) },
    { title: "B", text: "b".repeat(300_000) },
    { title: "C", text: "court" },
  ], 100_000);
  check(long.length < 110_000 && long.includes("=== C ===\ncourt"), "consigne : le matériel tient dans le budget, les petits documents restent entiers");

  // Le texte pur reste accessible.
  check(RevisionText.number("Théorème 3.4 (des gendarmes)") === "3.4", "texte : le numéro d'un énoncé");
  check(RevisionEntryKind.parse("Théorème") === "theorem", "texte : un genre reconnu");
});

describe("Branchement des codecs (Course.revisionSheet / Course.studyMap)", () => {
  // `registerCodecs.ts` est importé en tête de ce fichier : les deux getters du
  // modèle doivent rendre les types du domaine, pas le JSON brut.
  const course = new Course({ code: "MATH-101", name: "Analyse I" });
  const sheet = new RevisionSheet({
    origin: "ai", generatedAt: new Date(1000), chapters: [new RevisionChapter({
      id: "c0", title: "Suites", entries: [new RevisionEntry({ id: "a", kind: "definition", title: "Définition 1.1", body: "…" })],
    })],
  });
  course.revisionSheetRaw = sheet.encoded();
  const decoded = course.revisionSheet;
  check(decoded !== null && decoded instanceof RevisionSheet && decoded.encoded() === sheet.encoded(),
    "codec : Course.revisionSheet décode en RevisionSheet");

  check(course.studyMap instanceof StudyMap && course.studyMap.isEmpty, "codec : une carte vide reste vide");
  const map = new StudyMap();
  map.links = [new StudyLink({ from: "a", to: "b", relation: "needs" })];
  course.studyMap = map;
  check(course.studyMapRaw !== "" && course.studyMap.links.length === 1 && course.studyMap instanceof StudyMap,
    "codec : Course.studyMap décode en StudyMap");
  course.studyMapRaw = "";
  check(course.studyMap instanceof StudyMap && course.studyMap.isEmpty, "codec : un JSON vide donne une carte vide");
});

describe("NotebookLM : le protocole", () => {
  const id = "11111111-2222-3333-4444-555555555555";
  const body = NotebookLMWire.body("CCqFvf", NotebookLMWire.createNotebookParams("Analyse & co"), "AB:12=");
  check(body.startsWith("f.req=") && body.endsWith("&") && body.includes("&at=AB%3A12%3D&"), "NotebookLM : le corps porte f.req et le jeton at, encodés");
  check(body.includes("CCqFvf") && body.includes("Analyse%20%26%20co"), "NotebookLM : le code d'appel et le titre (encodé) sont dans le corps");
  const url = NotebookLMWire.url("https://notebook.google.com", "izAoDd", `/notebook/${id}`, "123")!.toString();
  check(url.includes("rpcids=izAoDd") && url.includes("f.sid=123") && url.includes("rt=c") && url.includes("source-path=/notebook/"), "NotebookLM : l'adresse d'un appel");
  check(NotebookLMWire.createNotebookParams("T").length === 4, "NotebookLM : créer un carnet = titre + 3 emplacements");

  const text = NotebookLMWire.addTextSourceParams(id, "Fiche", "Corps");
  check(text.length === 3 && text[1] === id, "NotebookLM : une source texte vise le carnet");
  const audio = NotebookLMWire.createAudioParams(id, ["s1", "s2"], "Consigne", "fr", 1, 2);
  const sent = JSON.stringify(audio);
  check(sent.includes('"s1"') && sent.includes('"s2"') && sent.includes("Consigne") && sent.includes('"fr"'), "NotebookLM : le podcast cite ses sources, la consigne et la langue");

  // Réponse : préfixe anti-XSSI, longueur, bloc wrb.fr
  const payload = `[["${id}","Titre"]]`;
  const inner = JSON.stringify(["wrb.fr", "CCqFvf", payload, null, null, null, "generic"]);
  const response = `)]}'\n\n123\n[${inner}]\n25\n[["e",4,null,null,64]]\n`;
  const parsed = NotebookLMWire.result(response, "CCqFvf");
  check(NotebookLMWire.firstID(parsed) === id, "NotebookLM : l'identifiant du carnet se retrouve dans la réponse");
  let other: unknown = undefined;
  try { other = NotebookLMWire.result(response, "izAoDd"); } catch { other = undefined; }
  check(other == null, "NotebookLM : une réponse à un autre appel n'est pas la nôtre");
  let notAnswer = false;
  try { NotebookLMWire.result("<html>Connexion</html>", "CCqFvf"); } catch (error) {
    if (error instanceof NotebookParseError && error.kind === "notAnswer") notAnswer = true;
  }
  check(notAnswer, "NotebookLM : la page de connexion à la place d'une réponse = session expirée");
  const refusedRow = JSON.stringify(["wrb.fr", "CCqFvf", null, null, null, [3], "generic"]);
  let refused: number | null = null;
  try { NotebookLMWire.result(`)]}'\n10\n[${refusedRow}]`, "CCqFvf"); } catch (error) {
    if (error instanceof NotebookParseError && error.kind === "refused") refused = error.code;
  }
  check(refused === 3, "NotebookLM : un code d'erreur dans la réponse est remonté");

  // Les jetons de la page
  const page = '<script>window.WIZ_global_data = {"SNlM0e":"AF1_Qp:1785","FdrFJe":"-98765","x":1}</script>';
  check(NotebookLMWire.field("SNlM0e", page) === "AF1_Qp:1785" && NotebookLMWire.field("FdrFJe", page) === "-98765",
    "NotebookLM : le jeton et la session se lisent dans la page");
  check(NotebookLMWire.field("SNlM0e", "<html>rien</html>") === null, "NotebookLM : pas de jeton, rien");

  // L'adresse d'un carnet
  check(NotebookLMWire.notebookID(`https://notebooklm.google.com/notebook/${id}?authuser=0`) === id,
    "NotebookLM : l'identifiant se lit dans l'adresse du carnet");
  check(NotebookLMWire.notebookID("https://notebooklm.google.com/") === null
    && NotebookLMWire.notebookID("n'importe quoi") === null, "NotebookLM : sans carnet dans l'adresse, rien");

  // Les artefacts : état, type, adresse du son
  const ready: unknown[] = ["a1", "Résumé audio", 1, null, 3, null,
    [null, null, null, null, null, [["https://x.test/a.m4a", null, "audio/mp4"], ["https://x.test/b.webm", null, "audio/webm"]]]];
  const working: unknown[] = ["a2", "En cours", 1, null, 2];
  const failed: unknown[] = ["a3", "Raté", 1, null, 4];
  for (const shape of [[[ready, working, failed]], [ready, working, failed]] as unknown[][][]) {
    const list = NotebookLMWire.artifacts(shape);
    check(eq(list.map((artifact) => artifact.state), ["ready", "working", "failed"])
      && list[0].audioURL?.toString() === "https://x.test/a.m4a" && list[1].audioURL === null,
    "NotebookLM : les artefacts (enveloppés ou à plat) : état et son");
  }
  check(NotebookLMWire.artifacts(null).length === 0 && NotebookLMWire.artifacts("n'importe quoi").length === 0,
    "NotebookLM : pas d'artefacts, une liste vide");
  check(!NotebookLMWire.isSignedIn(["NID", "__Secure-1PSIDTS", "SIDCC"]) && NotebookLMWire.isSignedIn(["NID", "SAPISID"]),
    "NotebookLM : connecté seulement avec un cookie de session, pas ceux d'une simple visite");
  check(NotebookLMWire.isApp("notebook.google.com") && NotebookLMWire.isApp("notebooklm.google.com")
    && !NotebookLMWire.isApp("accounts.google.com") && !NotebookLMWire.isApp("notebooklm.google"),
  "NotebookLM : l'app, pas la page de connexion ni la vitrine");
  check(NotebookLMWire.podcastInstructions("Analyse I").includes("Analyse I"), "NotebookLM : la consigne cite le cours");
});
