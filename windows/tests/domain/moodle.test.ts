// Port des sections de Validation/main.swift qui portent sur l'import Moodle,
// les MOOC, Botafogo, Explique et les vidéos d'un cours.
//
// Chaque `check` Swift devient un `it` du même libellé ; la condition est
// évaluée à la collecte, dans l'ordre du fichier Swift.

import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Course, Exercise, ExerciseSeries, ModelStore, TheoryItem } from "../../src/models/index.ts";
import {
  BotafogoParser, ContentDraft, ContentDraftBuilder, ContentDraftItem, ContentDraftSection,
  ContentSource, ScrapedCourse, ScrapedItem, ScrapedSection,
} from "../../src/domain/courseContentImport.ts";
import {
  MoocReference, MoodleActivity, MoodleCourseAnalyzer, MoodleCourseSnapshot, MoodleFolderExpander, MoodleSection,
} from "../../src/domain/moodleCourseAnalyzer.ts";
import { MoodleLinks } from "../../src/domain/botafogoProgram.ts";
import { MoodleCourseAI } from "../../src/domain/moodleAIHint.ts";
import { MoodleCourseMatcher, MoodleCourseRef, MoodleOnboarding, MoodleStateParser } from "../../src/domain/moodleImport.ts";
import { MoodleNews, MoodleNewsKind } from "../../src/domain/moodleNews.ts";
import {
  BotafogoCatalog, BotafogoDocument, BotafogoLinks, BotafogoNode, BotafogoProgram,
  BotafogoProgramBuilder, BotafogoSite, SiteLinks,
} from "../../src/domain/botafogoProgram.ts";
import { CoursePlanParser } from "../../src/domain/coursePlanParser.ts";
import { CourseVideos } from "../../src/domain/courseVideos.ts";
import { MoocMerger } from "../../src/domain/moocMerger.ts";
import { MathMarkup } from "../../src/domain/mathMarkup.ts";
import { ExpliqueImport } from "../../src/domain/expliqueImport.ts";
import { ContentDraftWriter } from "../../src/domain/courseContentWriter.ts";

function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

const eq = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);
const at = (year: number, month: number, day: number, hour = 0, minute = 0): Date =>
  new Date(year, month - 1, day, hour, minute);

const activity = (id: string, name: string, module = "resource", extra: Partial<ConstructorParameters<typeof MoodleActivity>[0]> = {}): MoodleActivity =>
  new MoodleActivity({ id, name, module, url: `https://moodle.epfl.ch/mod/${module}/view.php?id=${id}`, ...extra });
const section = (number: number, title: string, activities: MoodleActivity[], extra: Partial<ConstructorParameters<typeof MoodleSection>[0]> = {}): MoodleSection =>
  new MoodleSection({ number, title, activities, ...extra });
const snapshot = (title: string, url: string, sections: MoodleSection[]): MoodleCourseSnapshot =>
  new MoodleCourseSnapshot({ title, url, sections });
const item = (o: ConstructorParameters<typeof ContentDraftItem>[0]): ContentDraftItem => new ContentDraftItem(o);
const draftSection = (o: ConstructorParameters<typeof ContentDraftSection>[0]): ContentDraftSection =>
  new ContentDraftSection(o);
const draft = (o: ConstructorParameters<typeof ContentDraft>[0]): ContentDraft => new ContentDraft(o);
const theory = (number: string, url: string, extra: Partial<ConstructorParameters<typeof ContentDraftItem>[0]> = {}): ContentDraftItem =>
  new ContentDraftItem({ kind: "theory", number, title: `T${number}`, url, videoCount: 0, seriesNumber: null, theoryKind: "reading", ...extra });

const termStart = new Date(2026, 8, 7);
const store = new ModelStore();

describe("Import de contenu (Moodle, Courseware, Botafogo)", () => {
  check(ContentDraftBuilder.week("Semaine 3", null) === 3, "« Semaine 3 » → S3");
  check(ContentDraftBuilder.week("Week 12 - Revision", null) === 12, "« Week 12 » → S12");
  check(ContentDraftBuilder.week("S4 : intégrales", null) === 4, "« S4 : … » → S4");
  check(ContentDraftBuilder.week("21 septembre - 27 septembre", termStart) === 3,
    "section Moodle datée « 21 septembre - 27 septembre » → S3");
  check(ContentDraftBuilder.week("5 October - 11 October", termStart) === 5, "section datée en anglais → S5");
  check(ContentDraftBuilder.week("Généralités", termStart) === null, "une section sans semaine n'en invente pas");
  check(ContentDraftBuilder.week("Séries numériques", null) === null, "« Séries » n'est pas « S… » + numéro");

  check(ContentDraftBuilder.seriesNumber("Série 3 - énoncé") === 3, "« Série 3 - énoncé » → 3");
  check(ContentDraftBuilder.seriesNumber("Serie_07.pdf") === 7, "« Serie_07 » → 7");
  check(ContentDraftBuilder.seriesNumber("Exercise set 4") === 4, "« Exercise set 4 » → 4");
  check(ContentDraftBuilder.leadingNumber("3.2 Limite: a_n\\to L")?.number === "3.2", "« 3.2 Limite » → 3.2");
  check(ContentDraftBuilder.leadingNumber("II.4 Trigonométrie")?.number === "II.4", "« II.4 » gardé tel quel");
  check(ContentDraftBuilder.leadingNumber("Chapitre 5 : Séries")?.number === "5", "« Chapitre 5 : … » → 5");
  check(ContentDraftBuilder.leadingNumber("2025 Examen blanc") === null, "une année n'est pas un chapitre");
  check(ContentDraftBuilder.cleanTitle("Nombres: \\(\\mathbb{R}\\)") === "Nombres: \\mathbb{R}",
    "délimiteurs LaTeX retirés, la formule reste pour MathText");

  const kind = (title: string, type = "resource", source: ContentSource = "moodle"): string =>
    ContentDraftBuilder.classify(ScrapedItem.make(title, { type }), title, source);
  check(kind("Série 3") === "series", "« Série 3 » est une série");
  check(kind("Corrigé série 3") === "ignore", "un corrigé n'est pas une série de plus");
  check(kind("Annonces", "forum") === "ignore", "le forum d'annonces s'ignore");
  check(kind("Slides chapitre 2") === "theory", "des diapos sont de la théorie");
  check(kind("Vidéo 2.1 : dérivées", "kalvidres") === "theory", "une vidéo est de la théorie");
  check(kind("Séries numériques", "resource") === "theory", "« Séries numériques » (matière) n'est pas une série d'exercices");
  check(kind("Quiz 1", "quiz") === "ignore", "un quiz s'ignore par défaut");
  check(kind("5.3 Séries et critères", "section", "botafogo") === "theory", "Botafogo n'a que de la théorie");

  const moodle = ScrapedCourse.make("moodle", "Analyse I (MATH-101)", "https://moodle.epfl.ch/course/view.php?id=1", [
    ScrapedSection.make("Généralités", [ScrapedItem.make("Annonces", { type: "forum" })]),
    ScrapedSection.make("7 septembre - 13 septembre", [
      ScrapedItem.make("Vidéo 1.1 Introduction", { url: "https://mediaspace.epfl.ch/1", type: "kalvidres" }),
      ScrapedItem.make("Polycopié chapitre 1 Fichier", { url: "https://moodle.epfl.ch/f/1", type: "resource" }),
      ScrapedItem.make("Série 1", { url: "https://moodle.epfl.ch/s/1", type: "resource" }),
      ScrapedItem.make("Série 1 (version imprimable)", { url: "https://moodle.epfl.ch/s/1b", type: "resource" }),
      ScrapedItem.make("Corrigé 1", { url: "https://moodle.epfl.ch/c/1", type: "resource" }),
    ]),
    ScrapedSection.make("14 septembre - 20 septembre", [
      ScrapedItem.make("Série 2", { url: "https://moodle.epfl.ch/s/2", type: "resource" }),
    ]),
  ]);
  const contentDraft = ContentDraftBuilder.draft(moodle, "moodle", termStart);
  check(contentDraft.sections.length === 3, `trois sections lues (${contentDraft.sections.length})`);
  check(contentDraft.sections[0]?.isIncluded === false, "« Généralités » (que du forum) est décochée");
  check(contentDraft.sections[1]?.week === 1 && !contentDraft.sections[1]?.weekIsInferred,
    "la 1ʳᵉ semaine datée tombe en S1, lue sur la page");
  check(contentDraft.sections[2]?.week === 2, "la 2ᵉ en S2");
  check(contentDraft.seriesCount === 2, `deux séries, la version imprimable fusionnée (${contentDraft.seriesCount})`);
  check(contentDraft.sections[1]?.items[0]?.theoryKind === "video" && contentDraft.sections[1]?.items[0]?.videoCount === 1,
    "la vidéo MediaSpace compte comme une vidéo de théorie");
  check(contentDraft.sections[1]?.items[0]?.number === "1.1", "le numéro de la vidéo est lu dans son titre");
  check(contentDraft.sections[1]?.items.some((entry) => entry.title === "Polycopié chapitre 1") === true,
    "le suffixe « Fichier » de Moodle est retiré");

  const importCourse = new Course({ code: "MATH-101", name: "Analyse I" });
  store.insert(importCourse);
  const first = ContentDraftWriter.apply(contentDraft, importCourse, store);
  check(first.theoryAdded === 2 && first.seriesAdded === 2, `import : 2 théorie + 2 séries — ${first.message}`);
  check(importCourse.series.find((series) => series.seriesNumber === 2)?.plannedWeek === 2, "la série 2 est planifiée en S2");
  const watched = importCourse.theoryItems.find((entry) => entry.number === "1.1");
  if (watched !== undefined) watched.watchedAt = new Date();
  const edited = contentDraft.clone();
  edited.sections[2].week = 3;
  const second = ContentDraftWriter.apply(edited, importCourse, store);
  check(second.theoryAdded === 0 && second.seriesAdded === 0, "réimport : rien en double");
  check(importCourse.theoryItems.find((entry) => entry.number === "1.1")?.isWatched === true, "réimport : l'avancement est gardé");
  check(importCourse.series.find((series) => series.seriesNumber === 2)?.plannedWeek === 3, "réimport : la semaine corrigée est appliquée");
  check(eq(importCourse.contentSources, ["https://moodle.epfl.ch/course/view.php?id=1"]), "la page source est retenue, une fois");

  const flat = ScrapedCourse.make("courseware", "MOOC", "", [
    ScrapedSection.make("Introduction", [ScrapedItem.make("Bienvenue", { type: "sequential" })]),
    ScrapedSection.make("Module A", [ScrapedItem.make("Leçon", { type: "sequential", videoCount: 3 })]),
  ]);
  const flatDraft = ContentDraftBuilder.draft(flat, "courseware", null);
  check(eq(flatDraft.sections.map((entry) => entry.week), [1, 2]) && flatDraft.sections.every((entry) => entry.weekIsInferred),
    "semaines proposées dans l'ordre et marquées comme supposées");
  check(flatDraft.videoCount === 3, `les vidéos d'une leçon de MOOC sont comptées (${flatDraft.videoCount})`);

  const toc = `
    <title>Analyse 1 | S. Friedli (EPFL)</title>
    <li class="had-nav-toplevel">
    <a href="#this-is-preface" data-bs-toggle="collapse" aria-expanded="false" >I. Préface</a>
     <ul class="had-nav-secondlevel collapse" id="this-is-preface">
      <li class="had-nav-link-secondlevel" id="a"><a href="resources/sections/m_intro_objectifs.html">I.1 Un cours d'Analyse 1</a></li>
     </ul>
    <li class="had-nav-toplevel">
    <a href="#chap-nombres-reels" data-bs-toggle="collapse" aria-expanded="false" >1. Nombres: \\(\\mathbb{R}\\)</a>
     <ul class="had-nav-secondlevel collapse" id="chap-nombres-reels">
    <li class="had-pdf-link"><a href="resources/pdfschapitres/chap-nombres-reels.pdf" target="_blank" >PDF du Chapitre</a>
      <li class="had-nav-link-secondlevel" id="b"><a href="resources/sections/m_reels_intro.html">1.1 Introduction</a></li>
      <li class="had-nav-link-secondlevel" id="c"><a href="resources/sections/m_reels_R_est_un_corps.html">1.2 Règles de calcul: \\(+,-,\\cdot,\\div\\)</a></li>
     </ul>
    `;
  const base = new URL("https://botafogo.epfl.ch/analyse-1/");
  const tocPage = BotafogoParser.parseTOC(toc, base);
  check(tocPage.title === "Analyse 1", `titre du polycopié — ${tocPage.title}`);
  check(tocPage.sections.length === 2 && tocPage.sections[1].items.length === 2,
    "deux chapitres, le PDF du chapitre n'est pas un élément");
  check(tocPage.sections[1]?.items[0]?.url === "https://botafogo.epfl.ch/analyse-1/resources/sections/m_reels_intro.html",
    "adresse de section résolue");
  const botaDraft = ContentDraftBuilder.draft(tocPage, "botafogo", null);
  check(botaDraft.sections[0]?.isIncluded === false, "la préface (I.) est décochée");
  check(botaDraft.sections[1]?.week === 1, "le chapitre 1 est proposé en S1");
  check(eq(botaDraft.sections[1]?.items.map((entry) => entry.number), ["1.1", "1.2"]), "numéros du polycopié gardés");
  const sectionHTML = `
    <div class="video">
     <a class="video-button" data-bs-toggle="collapse" href="#IDVID-x" role="button">Suites qui tendent vers zéro</a>
     <div class="collapse" id="IDVID-x"><video class="video-plyr" playsinline controls></video></div>
    </div>
    <div class="anim-video"><video class="anim-video-plyr" preload="none" playsinline></video></div>
    `;
  check(eq(BotafogoParser.videoTitles(sectionHTML), ["Suites qui tendent vers zéro"]),
    "une vidéo de cours comptée, l'animation ignorée");
  const home = `
    <li><span class="link-description">Mon cours d'analyse:</span>
    <a href="/analyse-1/" class="button-link">Version EN LIGNE</a></li>
    `;
  const catalog = BotafogoParser.catalog(home, new URL("https://botafogo.epfl.ch/"));
  check(catalog[0]?.title === "Mon cours d'analyse" && catalog[0]?.url.toString() === "https://botafogo.epfl.ch/analyse-1/",
    "catalogue de Botafogo lu");
});

describe("Import : ce qui est écarté le reste", () => {
  const keepCourse = new Course({ code: "TEST-301", name: "Écarts" });
  store.insert(keepCourse);
  const reviewed = new ContentDraft({
    source: "moodle", courseTitle: "", url: "https://moodle.epfl.ch/course/view.php?id=1",
    sections: [new ContentDraftSection({
      title: "S1", week: 1, weekIsInferred: false, isIncluded: true,
      items: [theory("1.1", "u1"), theory("1.2", "u2")],
    })],
  });
  reviewed.sections[0].items[1].kind = "ignore";
  ContentDraftWriter.apply(reviewed, keepCourse, store);
  check(keepCourse.theoryItems.length === 1, "la relecture n'importe que ce qui est gardé");
  keepCourse.theoryItems[0].plannedWeek = 4;
  const refreshed = reviewed.clone();
  refreshed.sections[0].items[1].kind = "theory";
  refreshed.sections[0].week = 2;
  ContentDraftWriter.apply(refreshed, keepCourse, store, false);
  check(keepCourse.theoryItems.length === 1, "la mise à jour automatique ne réajoute pas un élément écarté");
  check(keepCourse.theoryItems[0]?.plannedWeek === 4, "…ni ne défait une semaine corrigée à la main");
  ContentDraftWriter.apply(refreshed, keepCourse, store);
  check(keepCourse.theoryItems.length === 2, "une nouvelle relecture peut le reprendre");
  check(MoodleCourseMatcher.linkedID(keepCourse.contentSources) === 1, "l'adresse du cours Moodle est retenue");
  store.delete(keepCourse);
});

describe("Botafogo : programme hebdomadaire", () => {
  const script = "var x=1;const P=[{type:`section`,name:`Infos`,metadata:{},index:0,children:[{type:`section`,name:`Bienvenue`,url:`sections/welcome`,metadata:{},index:0}]},{type:`week`,name:`Suites réelles`,metadata:{number:`03`,dates:`22-26 sept`,releaseDate:`2026-09-18T06:00:00.000Z`},index:1,children:[{type:`lecture`,name:`Cours 05`,url:`aulas/aula-05`,metadata:{day:`Mercredi`,date:`2026-09-23T12:00:00.000Z`,videoId:`0_5f16lokn`},index:0},{type:`series`,name:`Nombres $\\\\bR$`,url:`series/AN_serie_03`,metadata:{solutionsDate:`2026-09-24T06:00:00.000Z`},index:1,children:[{type:`exercise`,name:`Ex-03-01`,url:`exercices/a`,metadata:{serie:`03`,number:`01`},index:0},{type:`exercise`,name:`Ex-03-02`,url:`exercices/b`,metadata:{serie:`03`,number:`02`},index:1}]}]}],Q=!0,R=void 0;";
  const program = BotafogoProgram.extract(script);
  check(program?.length === 2, `le programme se relit dans le code du site (${program?.length ?? 0} nœuds)`);
  const week = program?.find((node) => node.type === "week");
  check(week?.meta("number") === "03" && week?.meta("dates") === "22-26 sept", "une semaine : numéro et dates");
  check(week?.children?.[0]?.meta("videoId") === "0_5f16lokn", "un cours filmé et sa vidéo");
  check(BotafogoProgram.extract("const a=[{type:`section`}];") === null, "sans semaine, pas de programme");
  check(BotafogoProgram.contentPath("series/AN_serie_03") === "/course_material/series/an_serie_03", "chemin de l'API des contenus");
  check(BotafogoProgram.seriesNumber("series/AN_serie_03") === 3, "numéro de série lu dans l'adresse");

  const lectureJSON = `{"body":{"type":"root","children":[{"type":"element","tagName":"h4","properties":{},"children":[{"type":"text","value":"Matière"}]},{"type":"element","tagName":"latex-ref","properties":{"collection":"content","target":"m_suites_R_x"},"children":[{"type":"text","value":"3.5 Les suites"}]},{"type":"element","tagName":"latex-ref","properties":{"target":"seances-du-soir"},"children":[{"type":"text","value":"séances du soir"}]},{"type":"element","tagName":"videokaltura","properties":{"entryId":"0_abc","title":"Cours 05"},"children":[]}]}}`;
  const lecture = BotafogoDocument.lecture(lectureJSON);
  check(eq(lecture.references.map((reference) => reference.target), ["m_suites_R_x"]), "seules les sections du polycopié comptent comme théorie");
  check(lecture.videos[0]?.id === "0_abc", "la vidéo d'un cours");

  const seriesJSON = `{"body":{"type":"root","children":[{"type":"element","tagName":"exercise","properties":{},"children":[{"type":"element","tagName":"template","properties":{},"children":[],"content":{"type":"root","children":[{"type":"element","tagName":"b","properties":{},"children":[{"type":"text","value":"Ex-3-1:"}]},{"type":"element","tagName":"p","properties":{},"children":[{"type":"text","value":"Soit "},{"type":"element","tagName":"katex-renderer","properties":{"content":"(x_{n})"},"children":[]},{"type":"text","value":" une suite."}]},{"type":"element","tagName":"ol","properties":{},"children":[{"type":"element","tagName":"li","properties":{},"children":[{"type":"text","value":"Montrer que"},{"type":"element","tagName":"ol","properties":{},"children":[{"type":"element","tagName":"li","properties":{},"children":[{"type":"text","value":"elle est bornée"}]},{"type":"element","tagName":"li","properties":{},"children":[{"type":"text","value":"elle converge"}]}]}]},{"type":"element","tagName":"li","properties":{},"children":[{"type":"text","value":"Calculer sa limite"}]}]},{"type":"element","tagName":"indication","properties":{},"children":[{"type":"element","tagName":"template","properties":{},"children":[],"content":{"type":"root","children":[{"type":"text","value":"Penser aux gendarmes."}]}}]},{"type":"element","tagName":"solution","properties":{},"children":[{"type":"element","tagName":"template","properties":{},"children":[],"content":{"type":"root","children":[{"type":"text","value":"La limite vaut 1."}]}}]}]}}]}]}}`;
  const parsed = BotafogoDocument.exercises(seriesJSON);
  check(parsed[0]?.number === "3.1", "numéro lu dans « Ex-3-1 »");
  check(parsed[0]?.statement === "Soit $(x_{n})$ une suite.", `énoncé, formules comprises (${parsed[0]?.statement ?? ""})`);
  check(eq(parsed[0]?.questions.map((question) => question.label), ["1", "2"])
    && eq(parsed[0]?.questions[0]?.children.map((question) => question.label), ["a", "b"]), "questions 1, 2 et points (a), (b)");
  check(parsed[0]?.questions[0]?.children[1]?.text === "elle converge", "texte d'un point");
  check(parsed[0]?.hint === "Penser aux gendarmes." && parsed[0]?.solution === "La limite vaut 1.", "indication et solution");

  const handout = [{ title: "3 Suites réelles", path: "#_3", children: [
    { title: "3.5 Les suites monotones et bornées", path: "/handout/matiere/m_suites_r_x", children: [] },
    { title: "3.6 Suites qui tendent vers l'infini", path: "/handout/matiere/m_other", children: [] },
  ] }];
  const root = new URL("https://botafogo.epfl.ch/analyse-1-GM/");
  const weekDraft = BotafogoProgramBuilder.draft({
    title: "Analyse I / GM", program: program ?? [], root, handout,
    lectures: { "aulas/aula-05": lecture }, series: { "series/AN_serie_03": parsed },
  });
  const weekSection = weekDraft.sections[0];
  check(weekSection?.title.startsWith("Semaine 3 · Suites réelles") === true && weekSection?.week === 3,
    "une section par semaine du programme");
  const items = weekSection?.items ?? [];
  check(items[0]?.number === "C5" && items[0]?.url === "https://mediaspace.epfl.ch/media/0_5f16lokn",
    "le cours filmé, avec sa vidéo");
  check(items.some((entry) => entry.number === "3.5" && entry.title === "Les suites monotones et bornées"),
    "la section enseignée, titre complet malgré la casse de l'identifiant");
  const seriesItem = items.find((entry) => entry.kind === "series");
  check(seriesItem?.title === "Nombres ℝ" && seriesItem?.seriesNumber === 3, `la série de la semaine (${seriesItem?.title ?? ""})`);
  check(seriesItem?.exercises.length === 2 && seriesItem?.exercises[0]?.questions.length === 2, "ses exercices et leurs questions");
  check(seriesItem?.exercises[0]?.url === "https://botafogo.epfl.ch/analyse-1-GM/?cours=exercices/a", "le lien de chaque exercice");
  const withoutDraft = BotafogoProgramBuilder.draft({
    title: "Analyse I / GM", program: program ?? [], root, handout,
    lectures: {}, series: { "series/AN_serie_03": parsed }, unpublished: new Set(["exercices/b"]),
  });
  const keptSeries = withoutDraft.sections[0]?.items.find((entry) => entry.kind === "series");
  check(eq(keptSeries?.exercises.map((exercise) => exercise.number), ["3.1"]),
    `l'exercice en brouillon sur le site est écarté — ${keptSeries?.exercises.map((exercise) => exercise.number) ?? []}`);
  check(BotafogoDocument.isUnpublished(`{"body":null,"meta":{"_draft":true}}`)
    && !BotafogoDocument.isUnpublished(`{"body":{"type":"root","children":[]},"meta":{}}`),
    "une page Botafogo en brouillon se reconnaît");
  const bfRoot = new URL("https://botafogo.epfl.ch/analyse-1-flipped/");
  check(BotafogoProgram.handoutURL(bfRoot, "m_reels_intro") === "https://botafogo.epfl.ch/analyse-1-flipped/?polycopie=matiere/m_reels_intro",
    "section du polycopié : ?polycopie=matiere/…");
  check(BotafogoLinks.normalize(new URL("https://botafogo.epfl.ch/analyse-1-flipped/?cours=&polycopie=/handout/matiere/m_reels_intro")).toString()
    === "https://botafogo.epfl.ch/analyse-1-flipped/?polycopie=matiere/m_reels_intro",
    "un ancien lien (cours vide, /handout/) est réparé à l'ouverture");
  check(BotafogoLinks.normalize(new URL("https://botafogo.epfl.ch/analyse-1-flipped?cours=series/AN_serie_03&polycopie=")).toString()
    === "https://botafogo.epfl.ch/analyse-1-flipped/?cours=series/AN_serie_03",
    "…et la barre finale, sans laquelle la requête est perdue");
  check(BotafogoLinks.isPage("https://botafogo.epfl.ch/analyse-1-flipped/?cours=series/AN_serie_06")
    && !BotafogoLinks.isPage("https://botafogo.epfl.ch/analyse-1-flipped/files/serie06.pdf")
    && !BotafogoLinks.isPage("https://moodle.epfl.ch/mod/resource/view.php?id=1")
    && !BotafogoLinks.isPage(""), "Botafogo : une série est une page lue en natif, pas un PDF à télécharger");
  check(BotafogoLinks.coursPath("https://botafogo.epfl.ch/analyse-1-flipped/?cours=series/AN_serie_06") === "series/AN_serie_06"
    && BotafogoLinks.coursPath("https://botafogo.epfl.ch/analyse-1-flipped/?cours=") === null,
    "Botafogo : la page d'une série se retrouve depuis son adresse");
  check(eq(BotafogoLinks.normalize(new URL("https://moodle.epfl.ch/course/view.php?id=1&x=")).toString(),
    "https://moodle.epfl.ch/course/view.php?id=1&x="), "les autres sites ne sont pas touchés");
  check(SiteLinks.normalize(new URL("https://moodle.epfl.ch/mod/resource/view.php?id=42")).toString()
    === "https://moodle.epfl.ch/mod/resource/view.php?id=42&redirect=1",
    "un fichier Moodle s'ouvre sur le fichier, pas sur la page « télécharger »");
  check(MathMarkup.plain("z^2=-3+4\\mathsf{i}") === MathMarkup.plain("z^2=-3+4i"), "Math : \\mathsf{i} → i");
  check(seriesItem?.solutionsAt !== null && seriesItem?.solutionsAt !== undefined, "la date de publication du corrigé");
  const leftovers = weekDraft.sections[weekDraft.sections.length - 1];
  check(leftovers?.isIncluded === false && eq(leftovers?.items.map((entry) => entry.number), ["3.6"]),
    "ce que le programme ne cite pas est proposé à part, décoché");

  const aCourse = new Course({ code: "TEST-501", name: "Programme" });
  store.insert(aCourse);
  const outcome = ContentDraftWriter.apply(weekDraft, aCourse, store);
  const written = aCourse.series.find((series) => series.seriesNumber === 3);
  check(outcome.exercisesAdded === 2 && written?.exercises.length === 2, "les exercices sont écrits à l'import");
  const firstExercise = written?.exercises.find((exercise) => exercise.exerciseNumber === "3.1");
  check(firstExercise?.leafSubQuestions.length === 3 && firstExercise?.hint === "Penser aux gendarmes."
    && firstExercise?.solution === "La limite vaut 1.", "…avec questions, indication et solution");
  check(written?.plannedWeek === 3 && written?.solutionsAt !== null && written?.topic === "Nombres ℝ",
    "…à leur semaine, thème et corrigé");
  check(aCourse.theoryItems.some((entry) => entry.number === "3.5" && entry.plannedWeek === 3 && entry.urlString.includes("m_suites_r_x")) === true,
    "la théorie tombe à la semaine où elle est enseignée, avec son lien");
  firstExercise?.subQuestions[0]?.toggle();
  ContentDraftWriter.apply(weekDraft, aCourse, store, false);
  check(firstExercise?.subQuestionDoneCount === 2, "une mise à jour garde les questions cochées");
  store.delete(aCourse);
});

describe("Moodle : analyse de vrais cours", () => {
  const act = (name: string, module: string, target: string | null = null, due: Date | null = null, visible = true): MoodleActivity =>
    activity(String(++nextID), name, module, { target, dueDate: due, isVisible: visible });
  let nextID = 0;

  // CS-107
  const cs107 = snapshot("Introduction à la programmation", "https://moodle.epfl.ch/course/view.php?id=14847", [
    section(0, "Informations générales", []),
    section(1, "Horaires et salles", [act("Cours en présentiel: Mercredi 1415-1500 au RLCE124", "label")]),
    section(2, "Calendrier", [act("Plan du cours", "url", "https://proginsc.epfl.ch/wwwhiver/planning.php")]),
    section(5, "Fora", [act("Annonces du cours", "forum"), act("Forum de discussion", "lti")]),
    section(7, "Mini-projet 1 en auto-évaluation", [
      act("Fin du projet (fin du challenge et objectif pour 60% des points a minima)", "label"),
      act("⚠️Selection d'un groupe (DÉLAI 13.10, 18:00)⚠️", "choicegroup")]),
    section(18, " Semaine 4 : Types «avancés»", [
      act("Enregistrement vidéo du cours du 1.10.2025", "url", "https://mediaspace.epfl.ch/media/CS-107+cours+4/0_abc"),
      act("Transparents (4 pages sur 1)", "url", "https://proginsc.epfl.ch/wwwhiver/documents/cours04.pdf"),
      act("Transparents (1 page sur 1)", "url", "https://proginsc.epfl.ch/wwwhiver/documents/cours04-full.pdf"),
      act("Enoncé/Corrigé de la série 4", "url", "https://proginsc.epfl.ch/wwwhiver/series/serie04/serie.html")]),
    section(21, "Semaine 1 : Introduction & Mise en place de l'environnement", [
      act("Transparents (Introduction) (1 page sur 1)", "url", "https://proginsc.epfl.ch/wwwhiver/documents/cours01a.pdf"),
      act("Transparents (algorithmes) (1 page sur 1)", "url", "https://proginsc.epfl.ch/wwwhiver/documents/cours01b.pdf"),
      act("Enoncé/Corrigé de la série 1", "url", "https://proginsc.epfl.ch/wwwhiver/series/serie01/serie.html"),
      act("Matériel annexe :Mini-référence : Environnement", "label")]),
    section(22, "Examen Final (samedi 12.12, 09:00-12:00)", []),
    section(24, "Questionnaires", [act("Machines personnelles", "questionnaire")]),
  ]);
  const d107 = MoodleCourseAnalyzer.draft(cs107, termStart);
  const weeks107 = d107.sections.filter((entry) => entry.week > 0);
  check(eq(weeks107.map((entry) => entry.week), [1, 4]), `semaines remises dans l'ordre du semestre (${weeks107.map((entry) => entry.week)})`);
  const week4 = weeks107[weeks107.length - 1]?.items ?? [];
  const lecture4 = week4.find((entry) => entry.kind === "theory");
  check(week4.filter((entry) => entry.kind === "theory").length === 1, "l'enregistrement et les deux transparents font **un** cours");
  check(lecture4?.title === "Types «avancés»" && lecture4?.theoryKind === "video" && lecture4?.links.length === 3,
    `…nommé par le sujet de la semaine, vidéo et transparents liés (${lecture4?.title ?? ""})`);
  const series4 = week4.find((entry) => entry.kind === "series");
  check(series4?.seriesNumber === 4 && series4?.solutionURL === series4?.url, "« Enoncé/Corrigé de la série 4 » : énoncé et corrigé");
  const week1Theory = weeks107[0]?.items.filter((entry) => entry.kind === "theory") ?? [];
  check(week1Theory.length === 1 && week1Theory[0]?.links.length === 2
    && week1Theory[0]?.title === "Introduction & Mise en place de l'environnement",
    `un élément par semaine : les deux transparents réunis, nommés par le sujet (${week1Theory.map((entry) => entry.title)})`);
  const deadlines107 = d107.sections.find((entry) => entry.title.startsWith("Échéances"))?.items ?? [];
  check(deadlines107.some((entry) => entry.examKind === "exam" && entry.title === "Examen Final" && entry.date !== null),
    "l'examen final est une échéance, daté par le titre de sa section");
  check(deadlines107.some((entry) => entry.examKind === "project" && entry.title.includes("Selection d'un groupe")),
    "le mini-projet n'est pas du travail à suivre : son délai devient une échéance");
  check(!d107.sections.flatMap((entry) => entry.items).some((entry) => entry.title.includes("Fin du projet")
    && (entry.kind === "theory" || entry.kind === "series")), "rien du projet n'est rangé en théorie ou en série");
  check(d107.sections.find((entry) => entry.title.startsWith("Documents"))?.items.some((entry) => entry.title === "Plan du cours") === true,
    "le plan du cours est gardé comme document");

  // Série dont l'énoncé mène au MOOC
  const cs107b = snapshot("Introduction à la programmation", "https://moodle.epfl.ch/course/view.php?id=14847", [
    section(19, "Semaine 4 : Types «avancés»", [
      act("Enoncé de la série 4", "url", "https://courseware.epfl.ch/courses/course-v1:EPFL+intro-prog-java+2024/jump_to/block-v1:EPFL+intro-prog-java+2024+type@sequential+block@Exercices_ID-1"),
      act("Corrigé de la série 4", "url", "https://proginsc.epfl.ch/wwwhiver/series/serie04/serie.html")])]);
  const series4b = MoodleCourseAnalyzer.draft(cs107b, termStart).sections.flatMap((entry) => entry.items).find((entry) => entry.kind === "series");
  check(series4b?.url === "https://proginsc.epfl.ch/wwwhiver/series/serie04/serie.html",
    `énoncé sur le MOOC, corrigé sur proginsc : la page proginsc est l'énoncé (${series4b?.url ?? "aucune série"})`);

  // PHYS-101(en)
  const phys = snapshot("Physique générale : mécanique (anglais)", "u", [
    section(0, "General", [act("Math review", "resource"), act("Formula sheet for Final exam", "resource")]),
    section(1, "Previous final exams", [act("Final Exam 2025", "resource"), act("Final Exam Solutions 2025", "resource")]),
    section(2, "7 September - 13 September", [
      act("Lecture notes 1a (blank)", "resource"), act("Lecture notes 1a (annotated)", "resource"),
      act("Lecture notes 1b (blank)", "resource"), act("Lecture notes 1b (annotated)", "resource"),
      act("Lecture 1a recording", "url", "https://mediaspace.epfl.ch/media/1a"),
      act("Lecture 1b recording", "url", "https://mediaspace.epfl.ch/media/1b"),
      act("Problem Set 1: Motion in 1D", "resource"),
      act("Problem Set 1 Solutions: Motion in 1D", "resource")])]);
  const dphys = MoodleCourseAnalyzer.draft(phys, termStart);
  const physWeek = dphys.sections.find((entry) => entry.week === 1)?.items ?? [];
  const physTheory = physWeek.filter((entry) => entry.kind === "theory");
  check(eq(physTheory.map((entry) => entry.number), ["1"]) && physTheory[0]?.title === "Cours de la semaine 1",
    `les cours 1a et 1b : **un** élément de la semaine (${physTheory.map((entry) => entry.title)})`);
  check(physTheory[0]?.links.length === 6 && physTheory[0]?.links.filter((link) => link.kind === "video").length === 2,
    "…avec les quatre notes et les deux enregistrements");
  const ps1 = physWeek.find((entry) => entry.kind === "series");
  check(ps1?.seriesNumber === 1 && ps1?.title === "Motion in 1D" && ps1?.solutionURL !== "" && ps1?.pdfURL !== "",
    "Problem Set 1 : thème, PDF à lire, solutions rattachées");
  check(dphys.sections.find((entry) => entry.title === "Anciens examens")?.items[0]?.number === "2025"
    && (dphys.sections.find((entry) => entry.title === "Anciens examens")?.items[0]?.solutionURL ?? "") !== "",
    "l'examen 2025 et sa solution font une annale");

  // MATH-111
  const due = at(2026, 10, 2, 23, 59);
  const alg = snapshot("Algèbre linéaire (classe inversée)", "u", [
    section(1, "7 September - 13 September", [
      act("Série 1", "resource"), act("Série 1 - Corrigé", "resource"), act("Inscription à un groupe", "choicegroup"),
      act("Rendu 01 (en groupe) - Contrat et inscription sur Moodle", "assign", null, due),
      act("Notes du cours", "label"), act("introduction-2026", "resource"), act("01-Systemes-lineaires", "resource"),
      act("Equipe et comportements constructif-destructif", "resource"), act("Contrat-d-equipe", "resource")]),
    section(4, "28 September - 4 October", [
      act("serie04", "resource"), act("serie04 sol", "resource", null, null, false), act("04-Espaces-vectoriels", "resource"),
      act("Rendu 04 (en groupe)", "assign", null, due), act("rendu04 sol", "resource"),
      act("Apprendre à étudier - 03 (comprendre des preuves)", "resource")])]);
  const dalg = MoodleCourseAnalyzer.draft(alg, termStart);
  const algWeek1 = dalg.sections.find((entry) => entry.week === 1)?.items ?? [];
  check(algWeek1.some((entry) => entry.kind === "series" && entry.seriesNumber === 1 && entry.solutionURL !== ""), "Série 1 et son corrigé");
  check(algWeek1.some((entry) => entry.kind === "theory" && entry.title.includes("Systemes lineaires")), "le chapitre 01 devient de la théorie lisible");
  check(!algWeek1.some((entry) => entry.title.includes("Contrat") || entry.title.includes("Equipe")),
    "les documents d'équipe ne sont pas de la théorie");
  const algWeek4 = dalg.sections.find((entry) => entry.week === 4)?.items ?? [];
  check(algWeek4.some((entry) => entry.kind === "series" && entry.seriesNumber === 4 && entry.solutionURL === ""),
    "serie04 sans son corrigé (pas encore visible)");
  check(!algWeek4.some((entry) => entry.kind === "series" && entry.url.includes("rendu")), "le corrigé d'un rendu n'est pas une série");
  const algDeadlines = dalg.sections.find((entry) => entry.title.startsWith("Échéances"))?.items ?? [];
  check(algDeadlines.length === 2 && algDeadlines.every((entry) => entry.examKind === "assignment"
    && entry.date?.getTime() === due.getTime()), "les rendus notés sont des échéances datées");
  check(dalg.sections.find((entry) => entry.title.startsWith("Documents"))?.items.some((entry) => entry.title.startsWith("Apprendre à étudier")) === true,
    "« Apprendre à étudier » : un document, pas un cours");

  // CS-101
  const cs101 = snapshot("AICC I", "u", [
    section(5, "Week 2: 14 September - 18 September", [
      act("Lecture — Tuesday", "url", "https://www.dropbox.com/week_2_1.pdf"),
      act("Annotated lecture notes (Tuesday)", "resource"),
      act("Lecture — Wednesday", "url", "https://www.dropbox.com/week_2_2.pdf"),
      act("Exercise", "url", "https://urbanke.github.io/week02-exercises.pdf"),
      act("Solution", "url", "https://urbanke.github.io/week02-solutions.pdf")])]);
  const d101 = MoodleCourseAnalyzer.draft(cs101, termStart);
  const w2 = d101.sections[0]?.items ?? [];
  check(d101.sections[0]?.week === 2, "« Week 2 » est la semaine 2");
  check(eq(w2.filter((entry) => entry.kind === "theory").map((entry) => entry.title), ["Cours de la semaine 2"]),
    "cours du mardi et du mercredi : un élément de la semaine");
  check(w2[0]?.links.length === 3, "transparents du mardi et du mercredi, notes annotées : tous liés");
  const dropboxPDF = w2[0]?.links.find((link) => link.url.includes("dropbox"));
  check(dropboxPDF?.kind === "slides" || dropboxPDF?.kind === "pdf", "un PDF Dropbox (« .pdf?rlkey=… ») est un PDF, pas une page");

  // Vrais titres
  const real = snapshot("t", "u", [
    section(2, "Week 1: 7 September - 11 September", [
      act("Introduction", "url", "https://www.dropbox.com/scl/fi/x/introduction.pdf?rlkey=k&raw=1"),
      act("Lecture — Tuesday", "url", "https://www.dropbox.com/scl/fi/y/week_1_1.pdf?rlkey=k&raw=1")]),
    section(3, "Semaine 3 : Structures de contrôle (semaine courante)", [
      act("Transparents (4 pages sur 1)", "url", "https://proginsc.epfl.ch/cours03.pdf")]),
    section(4, "Semaine 1 : Introduction", [
      act("Vidéos à visionner et Quiz à résoudre avant le mercredi 16.9", "url", "https://mediaspace.epfl.ch/media/x"),
      act("Transparents (Introduction) (1 page sur 1)", "url", "https://proginsc.epfl.ch/cours01a.pdf")]),
    section(5, "14 September - 20 September", [
      act("Lecture notes 1a (blank)", "resource"),
      act("Lecture 1a recording", "url", "https://mediaspace.epfl.ch/media/PHYS-101%28en%29+Lecture+1a%3A+Motion+in+one+dimension/0_6y8w1d2s/30253")])]);
  const dreal = MoodleCourseAnalyzer.draft(real, termStart);
  const titles = dreal.sections.flatMap((entry) => entry.items).filter((entry) => entry.kind === "theory").map((entry) => entry.title);
  check(titles.includes("Introduction") && !titles.some((title) => title.includes("September")),
    `une plage de dates ne nomme pas un cours — ${titles}`);
  check(dreal.sections.some((entry) => entry.title === "Semaine 3 : Structures de contrôle"), "« (semaine courante) » retiré du titre");
  check(titles.includes("Structures de contrôle"), "…et le sujet de la semaine nomme son cours");
  check(!titles.includes("Cours du mercredi"), "une consigne « avant le mercredi » n'est pas le cours du mercredi");
  check(titles.includes("Motion in one dimension"), "le titre de l'enregistrement nomme le cours 1a");
  check(MoodleCourseAnalyzer.prettifyFileName("introduction-2026") === "Introduction", "nom de fichier rendu lisible");
  check(MoodleCourseAnalyzer.prettifyFileName("Plan du cours") === "Plan du cours", "un vrai titre reste tel quel");
  const ex2 = w2.find((entry) => entry.kind === "series");
  check(ex2?.seriesNumber === 2 && ex2?.pdfURL.endsWith("exercises.pdf") === true
    && ex2?.solutionURL.endsWith("solutions.pdf") === true, "« Exercise » / « Solution » : la série 2, PDF public à lire");

  // MOOC cité depuis Moodle
  const moocSnapshot = snapshot("Algèbre", "u", [
    section(3, "21 September - 27 September", [act("03-Calcul-matriciel", "resource")]),
    section(4, "28 September - 4 October", [act("04-Espaces-vectoriels", "resource")])]);
  const moocBase = MoodleCourseAnalyzer.draft(moocSnapshot, termStart);
  const key = "course-v1:EPFL+AlgebreLineaire+2026";
  const moocRefs = [new MoocReference({ url: `https://courseware.epfl.ch/courses/${key}/jump_to/block-v1:EPFL+AlgebreLineaire+2026+type@vertical+block@u1`,
                      title: "Vidéos de la semaine", sectionNumber: 3 })];
  check(moocRefs[0]?.url.includes(key), "clé du MOOC lue dans le lien");
  const mooc = ScrapedCourse.make("courseware", "Algèbre linéaire", "c", [
    ScrapedSection.make("Matrices", [
      ScrapedItem.make("Produit matriciel", {
        url: "https://courseware.epfl.ch/l1", type: "sequential", videoCount: 2,
        id: "block-v1:EPFL+AlgebreLineaire+2026+type@sequential+block@s1",
        blockIDs: ["block-v1:EPFL+AlgebreLineaire+2026+type@vertical+block@u1"],
        links: [{ title: "Vidéo 1", url: "https://courseware.epfl.ch/xblock/v1", kind: "video" },
                { title: "Vidéo 2", url: "https://courseware.epfl.ch/xblock/v2", kind: "video" }],
      })]),
    ScrapedSection.make("Semaine 6 : Déterminants", [ScrapedItem.make("Définition", { url: "https://courseware.epfl.ch/l2", type: "sequential" })]),
    ScrapedSection.make("4. Espaces vectoriels", [ScrapedItem.make("Sous-espaces", { url: "https://courseware.epfl.ch/l3", type: "sequential" })]),
    ScrapedSection.make("Annexe", [ScrapedItem.make("Rappels", { url: "https://courseware.epfl.ch/l4", type: "sequential" })]),
  ]);
  const merged = MoocMerger.merge({ mooc, references: moocRefs, snapshot: moocSnapshot, into: moocBase, termStart });
  const moocWeek = (url: string): number | null => {
    for (const entry of merged.sections) {
      for (const theoryItem of entry.items) {
        if (theoryItem.url === url || theoryItem.links.some((link) => link.url === url)) {
          return theoryItem.kind === "theory" ? theoryItem.plannedWeek(entry) : 0;
        }
      }
    }
    return null;
  };
  check(moocWeek("https://courseware.epfl.ch/xblock/v1") === 3 && moocWeek("https://courseware.epfl.ch/xblock/v2") === 3,
    "leçon citée depuis la section de la semaine 3 : ses vidéos dans la semaine 3");
  check(moocWeek("https://courseware.epfl.ch/l2") === 6, "« Semaine 6 » dans le titre du chapitre");
  check(moocWeek("https://courseware.epfl.ch/l3") === 4, `chapitre 4 → la semaine où Moodle traite le chapitre 4 (${moocWeek("https://courseware.epfl.ch/l3") ?? -1})`);
  check(moocWeek("https://courseware.epfl.ch/l4") === null, "une leçon que le cours ne demande pas n'est pas importée");
  const week3Items = merged.sections.filter((entry) => entry.week === 3).flatMap((entry) => entry.items).filter((entry) => entry.kind === "theory");
  check(week3Items.length === 2 && week3Items.some((entry) => entry.title === "MOOC · Matrices" && entry.number === "M1-1"),
    `le chapitre du MOOC demandé est un élément à part de la semaine 3, à côté du cours (${week3Items.map((entry) => entry.title)})`);
  check(MoocMerger.isExercise(ScrapedItem.make("Exercices de la semaine", { url: "x", type: "sequential" })),
    "les exercices en ligne du MOOC ne sont pas à faire ici");

  check(MoodleCourseAnalyzer.dueDate("Opened: Monday, 31 August 2026, 12:00 PM Due: Friday, 2 October 2026, 11:59 PM")?.getTime()
    === at(2026, 10, 2, 23, 59).getTime(), "échéance lue sur la page d'un devoir (anglais)");
  check(MoodleCourseAnalyzer.dueDate("Ouvert le : lundi 31 août 2026, 12:00 À remettre : vendredi 2 octobre 2026, 23:59") !== null,
    "…et en français");

  const written = new Course({ code: "TEST-601", name: "Écriture" });
  store.insert(written);
  const outcome = ContentDraftWriter.apply(dalg, written, store);
  check(outcome.deadlinesAdded === 2 && written.exams.length === 2, "les échéances deviennent des évaluations du cours");
  check(written.documents.some((document) => document.title.startsWith("Apprendre")), "les documents sont gardés comme liens");
  ContentDraftWriter.apply(dalg, written, store, false);
  check(written.exams.length === 2 && written.documents.length === outcome.documentsAdded, "une mise à jour ne double rien");
  const wphys = new Course({ code: "TEST-602", name: "Liens" });
  store.insert(wphys);
  ContentDraftWriter.apply(dphys, wphys, store);
  check(wphys.theoryItems.find((entry) => entry.number === "1")?.links.length === 6, "les liens d'un cours sont écrits");
  check(wphys.pastExams.length === 1, "l'annale est écrite");
  store.delete(written);
  store.delete(wphys);
});


describe("Explique (AICC) : cours en replay et exercices", () => {
  check(ExpliqueImport.slug(["https://moodle.epfl.ch/x", "https://explique.epfl.ch/cs101/exercises"]) === "cs101", "cours lu dans le lien Moodle");
  check(ExpliqueImport.slug("CS-101") === "cs101", "cours déduit du code");
  const due = ExpliqueImport.dueDate("Tuesday 29 September at 17:00", termStart);
  check(due?.getFullYear() === 2026 && due?.getMonth() === 8 && due?.getDate() === 29 && due?.getHours() === 17,
    "échéance « Tuesday 29 September at 17:00 »");
  check(ExpliqueImport.lectureNumber("Lecture 5: Proofs (view on speaker)") === 5
    && ExpliqueImport.lectureNumber("Proofs - 1") === null, "numéro de cours");

  const lectures = [
    { week: 3, title: "Lecture 5: Proofs (view on speaker)", url: "https://explique.epfl.ch/cs101/v/a" },
    { week: 3, title: "Lecture 6: Proofs", url: "https://explique.epfl.ch/cs101/v/b" },
    { week: 3, title: "Lecture 5: Proofs", url: "https://explique.epfl.ch/cs101/v/c" },
    { week: 3, title: "Lecture 5: Proofs (2026)", url: "https://explique.epfl.ch/cs101/v/d" },
    { week: 3, title: "Proofs - 1", url: "https://explique.epfl.ch/cs101/v/e" },
    { week: 1, title: "Lecture 1: Introduction", url: "https://explique.epfl.ch/cs101/v/f" },
  ];
  const exercises = [{ week: 3, title: "Proofs Explanation exercise", url: "https://explique.epfl.ch/cs101/e/x",
                       due: "Tuesday 29 September at 17:00", done: true }];
  const moodleItem = new ContentDraftItem({
    kind: "theory", number: "3", title: "Cours 6", url: "https://moodle.epfl.ch/slides6",
    videoCount: 0, seriesNumber: null, theoryKind: "slides",
  });
  moodleItem.links = [{ title: "Transparents", url: "https://moodle.epfl.ch/slides6", kind: "slides" }];
  const base = new ContentDraft({ source: "moodle", courseTitle: "CS-101", url: "", sections: [
    new ContentDraftSection({ title: "Semaine 3", week: 3, weekIsInferred: false, isIncluded: true, items: [moodleItem] }),
  ] });
  const merged = ExpliqueImport.merge(lectures, exercises, base, termStart);
  const week3 = merged.draft.sections.find((entry) => entry.week === 3)!;
  const week3Theory = week3.items.filter((entry) => entry.kind === "theory");
  check(week3Theory.length === 1 && week3Theory[0]?.title === "Cours 6",
    `semaine 3 : un seul élément, celui de Moodle (${week3Theory.map((entry) => entry.title)})`);
  const videos = week3Theory[0]?.links.filter((link) => link.kind === "video") ?? [];
  check(videos.length === 5 && videos[0]?.url.endsWith("/d") === true,
    "…avec les cinq vidéos de la semaine, l'enregistrement de l'année du cours 5 d'abord");
  check(merged.draft.sections.some((entry) => entry.week === 1
    && entry.items.some((theoryItem) => theoryItem.number === "1" && theoryItem.title === "Introduction")),
    "une semaine absente de Moodle reçoit son élément, nommé par son sujet");
  const deadline = merged.draft.sections.flatMap((entry) => entry.items).find((entry) => entry.kind === "deadline");
  check(deadline?.title === "Explique · Proofs" && deadline?.date?.getTime() === due?.getTime(), "l'exercice d'explication devient une échéance datée");
  const again = ExpliqueImport.merge(lectures, exercises, merged.draft, termStart);
  check(again.added === 0, "réimporter n'ajoute rien en double");
});

describe("Réimport : les cours d'une semaine fusionnés", () => {
  const course = new Course({ code: "TEST-909", name: "Fusion" });
  store.insert(course);
  const a = new TheoryItem({ course, sectionNumber: 4, number: "4.1", title: "Cours du mardi", kind: "slides",
                             plannedWeek: 4, sortOrder: 0, urlString: "https://x/tue.pdf" });
  const b = new TheoryItem({ course, sectionNumber: 4, number: "4.2", title: "Cours du mercredi", kind: "slides",
                             plannedWeek: 4, sortOrder: 1, urlString: "https://x/wed.pdf" });
  a.watchedAt = new Date(); b.watchedAt = new Date();
  store.insert(a); store.insert(b);
  const entry = new ContentDraftItem({
    kind: "theory", number: "4", title: "Cours de la semaine 4", url: "https://x/tue.pdf",
    videoCount: 0, seriesNumber: null, theoryKind: "slides",
  });
  entry.links = [
    { title: "mardi", url: "https://x/tue.pdf", kind: "slides" },
    { title: "mercredi", url: "https://x/wed.pdf", kind: "slides" },
  ];
  ContentDraftWriter.apply(new ContentDraft({ source: "moodle", courseTitle: "", url: "", sections: [
    new ContentDraftSection({ title: "Semaine 4", week: 4, weekIsInferred: false, isIncluded: true, items: [entry] }),
  ] }), course, store);
  const week4 = course.theoryItems.filter((theoryItem) => theoryItem.plannedWeek === 4);
  check(week4.length === 1 && week4[0]?.number === "4" && week4[0]?.links.length === 2,
    "un seul élément pour la semaine, avec les deux cours");
  check(week4[0]?.isWatched === true, "la semaine reste vue : ses deux cours l'étaient");
  store.delete(course);
});

describe("Vidéos d'un cours rangées par semaine", () => {
  check(CourseVideos.week("Semaine 3 : boucles", termStart, 14, 1) === 3, "« Semaine 3 »");
  check(CourseVideos.lecturesPerWeek(["Lecture 27: Advanced Probability", "Lecture 1"], 14) === 2,
    "28 cours sur 14 semaines : deux par semaine");
  check(CourseVideos.week("Lecture 7: Sets", termStart, 14, 2) === 4, "deux cours par semaine : le cours 7 est en semaine 4");
  check(CourseVideos.week("PHYS-101(en) Lecture 3a: Forces", termStart, 14, 1) === 3, "« Lecture 3a » : semaine 3");
  check(CourseVideos.week("CS-107 compléments du cours 4 (live-streaming du 1.10.2025)", termStart, 14, 1) === 4,
    "un enregistrement daté de l'an passé tombe dans la même semaine du semestre");
  check(CourseVideos.week("Bienvenue", termStart, 14, 1) === null, "sans indice : pas de semaine inventée");
  const videoDraft = new ContentDraft({ source: "moodle", courseTitle: "", url: "", sections: [] });
  const mergedVideos = CourseVideos.merge([
    { title: "Lecture 3: Forces", url: "https://m/3", week: 3, kind: "video", order: 0 },
    { title: "Intro", url: "https://m/0", week: null, kind: "video", order: 0 },
  ], videoDraft, 14, "MediaSpace");
  check(mergedVideos.added === 2 && mergedVideos.draft.sections.some((entry) => entry.week === 3 && entry.items[0]?.title === "Forces"),
    "une vidéo rangée en semaine 3, l'autre gardée dans les documents");
});

describe("Moodle : formats inconnus rangés par le modèle", () => {
  const raw = `Voici : {"activities":[{"id":"1","kind":"series","week":3,"series":3},{"id":"2","kind":"theory","week":3},{"id":"3","kind":"ignore","week":null},{"id":4,"kind":"solution","week":3,"series":3}]}`;
  const hints = MoodleCourseAI.parse(raw);
  check(eq(hints["1"], { kind: "series", week: 3, seriesNumber: 3 }) && hints["3"]?.kind === "ignore" && hints["4"]?.kind === "solution",
    "réponse du modèle lue (texte autour, id numérique toléré)");
  const oddActivity = (id: string, name: string, module = "resource"): MoodleActivity =>
    new MoodleActivity({ id, name, module, url: `https://moodle.epfl.ch/mod/${module}/view.php?id=${id}` });
  const odd = new MoodleCourseSnapshot({ title: "Cours bizarre", url: "u", sections: [
    new MoodleSection({ number: 0, title: "Général", activities: [
      oddActivity("2", "Séance du 21 septembre (vidéo)", "url"), oddActivity("3", "Café virtuel", "url")] }),
    new MoodleSection({ number: 1, title: "Semaine 3", activities: [
      oddActivity("1", "TP-trois : récursivité"), oddActivity("4", "TP-trois : ce qu'il fallait trouver")] }),
  ] });
  const plain = MoodleCourseAnalyzer.draft(odd, null);
  check(!plain.sections.flatMap((entry) => entry.items).some((entry) => entry.kind === "series"), "sans le modèle, « TP-trois » n'est pas reconnu comme série");
  const guided = MoodleCourseAnalyzer.draft(odd, null, 14, hints);
  const week3 = guided.sections.find((entry) => entry.week === 3)?.items ?? [];
  check(week3.some((entry) => entry.kind === "series" && entry.seriesNumber === 3 && entry.solutionURL !== ""),
    "avec le modèle : la série 3 et son corrigé");
  check(week3.some((entry) => entry.kind === "theory"), "la vidéo posée dans « Général » rejoint la semaine 3");
  check(!guided.sections.flatMap((entry) => entry.items).some((entry) => entry.title.includes("Café")), "ce que le modèle écarte disparaît");
  const payload = MoodleCourseAI.payload(odd, null, 14);
  check((payload["outline"] as string | undefined)?.includes("id=1 [resource] TP-trois") === true,
    "le plan envoyé : identifiants, types, noms");
});

describe("Plan du cours + MOOC : chapitres à regarder", () => {
  const answer = MoodleCourseAI.answer(`{"activities":[{"id":"1","kind":"ignore"}],"mooc":[{"id":"block-v1:X+type@chapter+block@c1","week":2},{"id":"block-v1:X+type@chapter+block@c2","week":3}]}`);
  check(answer.moocWeeks["block-v1:X+type@chapter+block@c1"] === 2 && answer.hints["1"]?.kind === "ignore",
    "réponse : activités et chapitres du MOOC");
  const mooc = ({ source: "courseware", title: "Initiation Java", url: "https://courseware.epfl.ch/c", sections: [
    ScrapedSection.make("Module 1 : Variables", [
      ScrapedItem.make("Variables", { url: "https://courseware.epfl.ch/v1", type: "sequential", videoCount: 1,
        links: [{ title: "Vidéo", url: "https://courseware.epfl.ch/video1", kind: "video" }] }),
      ScrapedItem.make("Quiz du module 1", { url: "https://courseware.epfl.ch/q1", type: "sequential" }),
    ], "block-v1:X+type@chapter+block@c1"),
    ScrapedSection.make("Module 5 : Fonctions", [
      ScrapedItem.make("Fonctions", { url: "https://courseware.epfl.ch/v5", type: "sequential", videoCount: 1 }),
    ], "block-v1:X+type@chapter+block@c5"),
  ] });
  const payload = MoodleCourseAI.payload(new MoodleCourseSnapshot({ title: "CS-107", url: "u", sections: [] }), null, 14,
    "2 16/09 MOOC 1 : vidéos Module 1", [mooc]);
  check((payload["mooc"] as string | undefined)?.includes("id=block-v1:X+type@chapter+block@c1 : module 1 — Module 1 : Variables") === true
    && payload["plan"] !== undefined, "le modèle reçoit le plan et les chapitres du MOOC");
  const planSnapshot = new MoodleCourseSnapshot({ title: "CS-107", url: "u", sections: [
    new MoodleSection({ number: 2, title: "Semaine 2 : Premiers pas", activities: [
      new MoodleActivity({ id: "9", name: "Transparents (1 page sur 1)", module: "url",
        url: "https://moodle.epfl.ch/mod/url/view.php?id=9", target: "https://proginsc.epfl.ch/cours02.pdf" })] }),
  ] });
  const base = MoodleCourseAnalyzer.draft(planSnapshot, null);
  const merged = MoocMerger.merge({ mooc, references: [], snapshot: planSnapshot, into: base, termStart: null,
    plannedWeeks: answer.moocWeeks });
  const week2 = merged.sections.filter((entry) => entry.week === 2).flatMap((entry) => entry.items).filter((entry) => entry.kind === "theory");
  check(week2.some((entry) => entry.links.some((link) => link.url.includes("cours02")))
    && week2.some((entry) => entry.title === "MOOC · Module 1 : Variables"
      && entry.links.some((link) => link.url === "https://courseware.epfl.ch/video1")),
    "semaine 2 : le cours (transparents) et le Module 1 du MOOC demandé par le plan, chacun son élément");
  check(!merged.sections.flatMap((entry) => entry.items).flatMap((entry) => entry.links).some((link) => link.url.includes("/v5")),
    "pas le module que le plan ne cite pas");
  check(week2.some((entry) => entry.title.startsWith("MOOC")
    && entry.links.some((link) => link.url.includes("/q1") && link.kind === "page")),
    "le quiz du module est une ligne de son chapitre, pas une vidéo");
});

describe("Série restée sur le MOOC : l'adresse du cours l'emporte", () => {
  const course = new Course({ code: "TEST-107", name: "Prog" });
  store.insert(course);
  const series = new ExerciseSeries({
    course, seriesNumber: 3, plannedWeek: 3, urlString: "https://courseware.epfl.ch/courses/x/serie3",
  });
  store.insert(series);
  const exercise = new Exercise({
    series, exerciseNumber: "3.1", statementURLString: "https://courseware.epfl.ch/courses/x/ex31",
  });
  store.insert(exercise);
  exercise.doneAt = new Date();
  const entry = new ContentDraftItem({ kind: "series", number: "3", title: "Série 3",
    url: "https://proginsc.epfl.ch/wwwhiver/series/serie03/serie.html",
    videoCount: 0, seriesNumber: 3, theoryKind: "reading" });
  entry.solutionURL = entry.url;
  ContentDraftWriter.apply(new ContentDraft({ source: "moodle", courseTitle: "", url: "", sections: [
    new ContentDraftSection({ title: "Semaine 3", week: 3, weekIsInferred: false, isIncluded: true, items: [entry] }),
  ] }), course, store);
  check(series.urlString.includes("proginsc") && series.needsReread, "la page de la série (proginsc) remplace le MOOC, et la série sera relue");
  check(exercise.statementURLString === "" && exercise.isDone, "l'exercice ne pointe plus vers le MOOC, et reste fait");
  store.delete(course);
});

describe("Plan du cours lu sans modèle (CS-107)", () => {
  const plan = `COURS
14h15 - 15h00
1
09/09/2026
11/09/2026
14:15 Présentation du cours | Environnement | Algorithmes
Série 1
2
16/09/2026
18/09/2026
14:15 MOOC 1 : vidéos Module 1 (Bases de programmation)
Premiers pas en programmation
MOOC 1 : quiz Module 1
Série 2
3
23/09/2026
25/09/2026
14:15 MOOC 1 : vidéos Module 2
MOOC 1 : vidéos Module 3
Structures de contrôle
MOOC 1 : quiz Module 2
8
28/10/2026
30/10/2026
14:15 [optionnel] MOOC 2 : vidéos Module 1
MOOC 2 : vidéos Module 2
9 02/11/2026
Mini-projet 1: objectif de date pour atteindre 60% des points
9
04/11/2026
06/11/2026
14:15 MOOC 2 : vidéos Module 3`;
  const found = CoursePlanParser.moocAssignments(plan, 14);
  check(eq(found, [
    { mooc: 1, module: 1, week: 2 }, { mooc: 1, module: 2, week: 3 }, { mooc: 1, module: 3, week: 3 },
    { mooc: 2, module: 1, week: 8 }, { mooc: 2, module: 2, week: 8 }, { mooc: 2, module: 3, week: 9 },
  ]), "semaine de chaque module, lue ligne par ligne");
  check(!found.some((assignment) => assignment.week === 1), "les quiz ne sont pas des vidéos à regarder");
  const chapter = (id: string, title: string): ScrapedSection =>
    ScrapedSection.make(title, [ScrapedItem.make("x", { url: `u-${id}` })], id);
  const welcome = ScrapedSection.make("Introduction", [
    ScrapedItem.make("Bienvenue", { url: "w1" }), ScrapedItem.make("Informations pratiques", { url: "w2" }),
  ], "w");
  const mooc1 = ({ source: "courseware", title: "Java", url: "", sections: [
    welcome, chapter("b", "Bases de programmation"), chapter("c", "Branchements"), chapter("d", "Boucles")] });
  const mooc2 = ({ source: "courseware", title: "POO", url: "", sections: [
    chapter("p", "Préambule"), chapter("i", "Introduction à la POO"), chapter("k", "Constructeurs"), chapter("h", "Héritage")] });
  const weeks = CoursePlanParser.chapterWeeks(found, [mooc1, mooc2]);
  check(eq(weeks, { b: 2, c: 3, d: 3, i: 8, k: 8, h: 9 }),
    "module N → N-ième chapitre, préambule non compté");
});

describe("Restes d'anciens imports du MOOC", () => {
  const course = new Course({ code: "TEST-108", name: "Prog" });
  store.insert(course);
  const moocSeries = new ExerciseSeries({ course, seriesNumber: 6, plannedWeek: 5,
    urlString: "https://courseware.epfl.ch/courses/x/jump_to/block@Exercices_ID-1313" });
  store.insert(moocSeries);
  const old1 = new TheoryItem({ course, sectionNumber: 2, number: "2.3", title: "Variables", kind: "video",
    plannedWeek: 0, urlString: "https://courseware.epfl.ch/l23" });
  const old2 = new TheoryItem({ course, sectionNumber: 2, number: "2.6", title: "Contrôle des connaissances (5 Questions)",
    kind: "reading", plannedWeek: 0, urlString: "https://courseware.epfl.ch/l26" });
  old1.videoCount = 1; old1.watchedAt = new Date();
  store.insert(old1); store.insert(old2);
  const chapterItem = new ContentDraftItem({ kind: "theory", number: "M1-2", title: "MOOC · Bases de programmation",
    url: "https://courseware.epfl.ch/l22", videoCount: 1, seriesNumber: null, theoryKind: "video", week: 2 });
  chapterItem.links = [{ title: "Variables — Vidéo", url: "https://courseware.epfl.ch/xblock/v", kind: "video" }];
  ContentDraftWriter.apply(new ContentDraft({ source: "moodle", courseTitle: "", url: "", sections: [
    new ContentDraftSection({ title: "Semaine 2", week: 2, weekIsInferred: false, isIncluded: true, items: [chapterItem] }),
  ] }), course, store);
  check(!course.series.some((entry) => entry.seriesNumber === 6), "la « série » du MOOC, pas commencée, est retirée");
  check(course.theoryItems.length === 1 && course.theoryItems[0]?.isWatched === true,
    `les anciennes leçons rejoignent leur chapitre, vu puisque ses vidéos l'étaient (${course.theoryItems.map((entry) => entry.title)})`);
  store.delete(course);
});

describe("Algèbre : leçons du MOOC rangées une à une par un ancien import", () => {
  const course = new Course({ code: "TEST-111", name: "Algèbre" });
  store.insert(course);
  const lesson = new TheoryItem({ course, sectionNumber: 4, number: "M4.2", title: "3.2 L'espace des coordonnées",
    kind: "video", plannedWeek: 3, urlString: "https://courseware.epfl.ch/courses/a/jump_to/l32" });
  lesson.links = [{ title: "Leçon", url: "https://courseware.epfl.ch/xblock/v32", kind: "video" }];
  lesson.videoCount = 1;
  const weekPDF = new TheoryItem({ course, sectionNumber: 3, number: "3", title: "Cours de la semaine 3",
    kind: "reading", plannedWeek: 3, urlString: "https://moodle.epfl.ch/mod/resource/view.php?id=1" });
  store.insert(lesson); store.insert(weekPDF);
  const chapterItem = new ContentDraftItem({ kind: "theory", number: "M1-4", title: "MOOC · Chapitre 3 : Espaces vectoriels",
    url: "https://courseware.epfl.ch/courses/a/jump_to/l31", videoCount: 2, seriesNumber: null, theoryKind: "video", week: 3 });
  chapterItem.links = [
    { title: "3.1 Définition — Leçon", url: "https://courseware.epfl.ch/xblock/v31", kind: "video" },
    { title: "3.2 L'espace des coordonnées — Leçon", url: "https://courseware.epfl.ch/xblock/v32", kind: "video" },
  ];
  ContentDraftWriter.apply(new ContentDraft({ source: "moodle", courseTitle: "", url: "", sections: [
    new ContentDraftSection({ title: "Semaine 3", week: 3, weekIsInferred: false, isIncluded: true, items: [chapterItem] }),
  ] }), course, store);
  check(eq(new Set(course.theoryItems.map((entry) => entry.number)), new Set(["3", "M1-4"])),
    `la leçon seule (semaine 3) disparaît derrière son chapitre, le cours de la semaine reste (${course.theoryItems.map((entry) => entry.number)})`);
  store.delete(course);
});

describe("Un cours jamais vu, compris en entier (énoncés, consignes, MOOC)", () => {
  const act = (id: string, name: string, module: string, target: string | null = null): MoodleActivity =>
    new MoodleActivity({ id, name, module, url: `https://moodle.epfl.ch/mod/${module}/view.php?id=${id}`, target });
  const week2 = new MoodleSection({ number: 3, title: "Semaine 2 : Cellules", activities: [
    act("10", "Feuille 2", "url", "https://courseware.epfl.ch/courses/course-v1:EPFL+Bio+2026/jump_to/block-v1:EPFL+Bio+2026+type@sequential+block@x"),
    act("11", "Réponses feuille 2", "resource", "https://moodle.epfl.ch/pluginfile.php/1/rep2.pdf"),
    act("12", "Diapos semaine 2", "resource", "https://moodle.epfl.ch/pluginfile.php/1/diapos2.pdf"),
  ] });
  week2.text = "Cette semaine : lisez le chapitre 2 et faites la feuille d'exercices sur le site du cours.";
  week2.links = [{ title: "feuille d'exercices", url: "https://bio.example.org/td/feuille2.html", kind: "page" }];
  week2.activities[0].destination = "mooc";
  week2.activities[0].preview = "Chapitre 2 · vidéos";
  const bio = new MoodleCourseSnapshot({ title: "Biologie (BIO-999)", url: "https://moodle.epfl.ch/course/view.php?id=9", sections: [week2] });

  const rules = MoodleCourseAnalyzer.draft(bio, null);
  const ruleSeries = rules.sections.flatMap((entry) => entry.items).find((entry) => entry.kind === "series");
  check(ruleSeries === undefined || MoocReference.courseKey(ruleSeries.url) === null,
    "sans le modèle, un lien vers un MOOC n'est pas pris pour l'énoncé");

  const payload = MoodleCourseAI.payload(bio, null, 14);
  const outline = (payload["outline"] as string | undefined) ?? "";
  check(outline.includes("Texte : « Cette semaine : lisez") && outline.includes("Lien L1 : feuille d'exercices → bio.example.org/td/feuille2.html")
    && outline.includes("{mooc}") && outline.includes("« Chapitre 2 · vidéos »") && payload["instructions"] === undefined,
    "le modèle reçoit consignes, liens cités, nature et début de chaque cible");

  const answer = MoodleCourseAI.answer(`{"activities":[{"id":"10","kind":"document","week":2},{"id":"11","kind":"solution","week":2,"series":2},{"id":"12","kind":"theory","week":2}],"series":[{"number":2,"week":2,"statement":"L1","solution":11},{"number":3,"week":3,"statement":"L99","solution":null}],"weeks":[{"week":2,"todo":"Lire le chapitre 2, faire la feuille 2 sur le site du cours."},{"week":40,"todo":"hors semestre"}]}`);
  check(eq(answer.series[0], { number: 2, week: 2, statement: "L1", solution: "a11" }),
    "réponse : série, énoncé cité dans la consigne, corrigé (id numérique toléré)");
  const understood = MoodleCourseAnalyzer.apply(answer, MoodleCourseAnalyzer.draft(bio, null, 14, answer.hints), bio, 14);
  const series2 = understood.sections.flatMap((entry) => entry.items).filter((entry) => entry.kind === "series");
  check(series2.length === 1 && series2[0]?.url === "https://bio.example.org/td/feuille2.html"
    && series2[0]?.solutionURL === "https://moodle.epfl.ch/pluginfile.php/1/rep2.pdf"
    && understood.sections.find((entry) => entry.items.some((itemEntry) => itemEntry.kind === "series"))?.week === 2,
    "la série 2 : énoncé sur le site du cours, corrigé en PDF, en semaine 2");
  check(!series2.some((entry) => entry.seriesNumber === 3), "une référence inconnue (L99) ne crée rien");
  check(eq(understood.weekGuide, { 2: "Lire le chapitre 2, faire la feuille 2 sur le site du cours." }),
    "la consigne de la semaine, gardée dans les semaines du semestre");

  const other = new MoodleCourseSnapshot({ title: "X", url: "u", sections: [
    new MoodleSection({ number: 1, title: "Semaine 1", activities: [
      act("20", "Série 1", "url", "https://example.org/mauvais.html"),
      act("21", "Série 1 : énoncé et corrigé", "url", "https://example.org/serie1.html")] }),
  ] });
  const fixed = MoodleCourseAnalyzer.apply(MoodleCourseAI.answer(`{"series":[{"number":1,"week":1,"statement":"a21"}]}`),
    MoodleCourseAnalyzer.draft(other, null), other, 14);
  check(fixed.sections.flatMap((entry) => entry.items).find((entry) => entry.kind === "series")?.url === "https://example.org/serie1.html",
    "l'énoncé que le modèle désigne remplace celui que les règles avaient choisi");
});

describe("Site d'un cours vide sur Moodle, trouvé sans table", () => {
  const home = new URL("https://botafogo.epfl.ch/");
  const catalog = [
    { title: "Mon cours d'analyse", url: new URL("analyse-1/", home) },
    { title: "Mon cours d'analyse pour GM", url: new URL("analyse-1-GM/", home) },
    { title: "Mon cours d'analyse classe inversée", url: new URL("analyse-1-flipped/", home) },
    { title: "Le polycopié d'ICS", url: new URL("ics/", home) },
  ];
  check(BotafogoCatalog.match("MATH-101(pi) Analyse I (classe inversée)", catalog)?.pathname === "/analyse-1-flipped/",
    "classe inversée : le polycopié dont tous les mots se retrouvent");
  check(BotafogoCatalog.match("MATH-101(a) Analyse I", catalog)?.pathname === "/analyse-1/",
    "le cours ordinaire : pas la version GM ni inversée");
  check(BotafogoCatalog.match("PHYS-101 Physique générale", catalog) === null, "aucun site inventé");
  const cited = new MoodleCourseSnapshot({ title: "Y", url: "u", sections: [
    new MoodleSection({ number: 0, title: "Infos", activities: [], links: [
      { title: "Polycopié", url: "https://botafogo.epfl.ch/analyse-b/chapitre1", kind: "page" }] }),
  ] });
  check(BotafogoCatalog.site(cited)?.toString().includes("analyse-b") === true, "un lien Botafogo cité par le cours l'emporte");
});

describe("MOOC : seulement les leçons demandées, chacune à sa semaine", () => {
  const lesson = (n: string, id: string): ScrapedItem => ScrapedItem.make(n, {
    url: `https://courseware.epfl.ch/${id}`, type: "sequential", videoCount: 1, id: `block-${id}`,
    links: [{ title: "Leçon", url: `https://courseware.epfl.ch/video-${id}`, kind: "video" }],
  });
  const mooc = ({ source: "courseware", title: "Algèbre", url: "https://courseware.epfl.ch/c", sections: [
    ScrapedSection.make("Chapitre 1 : Systèmes", [lesson("1.1 Intro", "a"), lesson("1.2 Gauss", "b"), lesson("1.3 Échelonnées", "c"), lesson("1.4 Option", "d")], "chap-1"),
    ScrapedSection.make("Chapitre 2 : Matrices", [lesson("2.1 Produit", "e"), lesson("2.2 Inverse", "f")], "chap-2"),
  ] });
  const payload = MoodleCourseAI.payload(new MoodleCourseSnapshot({ title: "MATH-999", url: "u", sections: [] }), null, 14, null, [mooc]);
  check((payload["mooc"] as string | undefined)?.includes("· m1.1.2 1.2 Gauss (1 vidéo)") === true, "chaque leçon du MOOC a sa référence");
  const answer = MoodleCourseAI.answer(`{"mooc":[{"week":1,"lessons":["m1.1.1","m1.1.2"]},{"week":2,"lessons":["M1.1.3","m1.2.1","m9.9.9"]}]}`);
  const lessons = MoodleCourseAI.lessonWeeks(answer, [mooc]);
  check(eq(lessons, { "block-a": 1, "block-b": 1, "block-c": 2, "block-e": 2 }),
    "références résolues, inconnues ignorées");
  const mergedChapters = MoocMerger.merge({ mooc, references: [],
    snapshot: new MoodleCourseSnapshot({ title: "MATH-999", url: "u", sections: [] }),
    into: new ContentDraft({ source: "moodle", courseTitle: "", url: "", sections: [] }),
    termStart: null, plannedLessons: lessons });
  const items = mergedChapters.sections.flatMap((entry) => entry.items.filter((itemEntry) => itemEntry.title.startsWith("MOOC"))
    .map((itemEntry) => ({ week: entry.week, item: itemEntry })));
  const week1 = items.filter((entry) => entry.week === 1).flatMap((entry) => entry.item.links.map((link) => link.url));
  const week2 = items.filter((entry) => entry.week === 2).flatMap((entry) => entry.item.links.map((link) => link.url));
  check(eq(week1, ["https://courseware.epfl.ch/video-a", "https://courseware.epfl.ch/video-b"])
    && eq(new Set(week2), new Set(["https://courseware.epfl.ch/video-c", "https://courseware.epfl.ch/video-e"])),
    "semaine 1 : 1.1–1.2 ; semaine 2 : 1.3 et 2.1 — ni 1.4 ni 2.2, non demandées");
  const numbers = items.map((entry) => entry.item.number);
  check(new Set(numbers).size === numbers.length && numbers.includes("M1-1-s1") && numbers.includes("M1-1-s2"),
    "un chapitre réparti : un élément par semaine, numéros distincts");

  const course = new Course({ code: "TEST-999", name: "Algèbre" });
  store.insert(course);
  const old = new TheoryItem({ course, sectionNumber: 1, number: "M1-1", title: "MOOC · Chapitre 1 : Systèmes",
    kind: "video", plannedWeek: 1, urlString: "https://courseware.epfl.ch/a" });
  old.links = ["a", "b", "c", "d"].map((suffix) => ({ title: "Leçon", url: `https://courseware.epfl.ch/video-${suffix}`, kind: "video" as const }));
  old.watchedAt = new Date();
  store.insert(old);
  ContentDraftWriter.apply(mergedChapters, course, store);
  const chapterOne = course.theoryItems.filter((entry) => entry.number.startsWith("M1-1"));
  check(chapterOne.length === 2 && chapterOne.every((entry) => entry.isWatched),
    `le chapitre vu, réparti sur deux semaines, reste vu des deux côtés (${chapterOne.map((entry) => entry.number)})`);
  check(!course.theoryItems.some((entry) => entry.number === "M1-1"), "l'ancien élément du chapitre entier ne reste pas en double");
  store.delete(course);
});

describe("Une autre source du cours complète Moodle", () => {
  const moodleDraft = new ContentDraft({ source: "moodle", courseTitle: "A", url: "", sections: [
    new ContentDraftSection({ title: "Semaine 1", week: 1, weekIsInferred: false, isIncluded: true, items: [
      new ContentDraftItem({ kind: "series", number: "1", title: "Série 1", url: "m1", videoCount: 0, seriesNumber: 1, theoryKind: "reading" })] }),
  ] });
  moodleDraft.weekGuide = { 1: "x" };
  const other = new ContentDraft({ source: "botafogo", courseTitle: "Poly", url: "", sections: [
    new ContentDraftSection({ title: "Semaine 1", week: 1, weekIsInferred: false, isIncluded: true, items: [
      new ContentDraftItem({ kind: "series", number: "1", title: "Série 1", url: "b1", videoCount: 0, seriesNumber: 1, theoryKind: "reading" }),
      new ContentDraftItem({ kind: "theory", number: "1.1", title: "Suites", url: "t1", videoCount: 2, seriesNumber: null, theoryKind: "video" })] }),
    new ContentDraftSection({ title: "Semaine 2", week: 2, weekIsInferred: false, isIncluded: true, items: [
      new ContentDraftItem({ kind: "series", number: "2", title: "Série 2", url: "b2", videoCount: 0, seriesNumber: 2, theoryKind: "reading" })] }),
  ] });
  const done = moodleDraft.completed(other);
  const all = done.sections.flatMap((entry) => entry.items);
  check(eq(all.filter((entry) => entry.kind === "series").map((entry) => entry.url), ["m1", "b2"])
    && all.some((entry) => entry.url === "t1"),
    "la série 1 reste celle de Moodle ; la série 2 et la théorie manquantes viennent de l'autre source");
  check(other.outline.includes("## Semaine 2 [semaine 2]") && other.outline.includes("Série 2 [série 2]"), "résumé lisible pour le modèle");
});

describe("Moodle : plan du cours et sections", () => {
  const state = `{"course":{"id":"14840","numsections":3},
   "section":[
    {"id":"100","section":0,"number":0,"title":"Généralités","cmlist":["1","2"],"visible":true,"component":null,"itemid":null},
    {"id":"101","section":1,"number":1,"title":"8 septembre - 14 septembre","cmlist":["3","4","5","9"],"visible":true,"component":null,"itemid":null},
    {"id":"102","section":2,"number":2,"title":"Semaine 2","cmlist":["6","7"],"visible":true,"component":null,"itemid":null},
    {"id":"103","section":3,"number":3,"title":"Sous-section","cmlist":["8"],"visible":true,"component":"mod_subsection","itemid":"9"}],
   "cm":[
    {"id":"1","name":"Annonces","module":"forum","url":"https://moodle.epfl.ch/mod/forum/view.php?id=1","uservisible":true},
    {"id":"2","name":"Plan du cours","module":"resource","url":"https://moodle.epfl.ch/mod/resource/view.php?id=2","uservisible":true},
    {"id":"3","name":"Vidéo 1.1 Introduction","module":"kalvidres","url":"https://moodle.epfl.ch/mod/kalvidres/view.php?id=3","uservisible":true},
    {"id":"4","name":"Série 1","module":"resource","url":"https://moodle.epfl.ch/mod/resource/view.php?id=4","uservisible":true},
    {"id":"5","name":"Corrigé série 1","module":"resource","url":"https://moodle.epfl.ch/mod/resource/view.php?id=5","uservisible":true},
    {"id":"6","name":"Série 2","module":"assign","url":"https://moodle.epfl.ch/mod/assign/view.php?id=6","uservisible":true},
    {"id":"7","name":"Caché","module":"resource","url":"","uservisible":false},
    {"id":"8","name":"Chapitre 1.2 Suites","module":"page","url":"https://moodle.epfl.ch/mod/page/view.php?id=8","uservisible":true},
    {"id":"9","name":"Sous-section","module":"subsection","url":"","uservisible":true}]}`;
  const page = MoodleStateParser.course(state, "Analyse I", "https://moodle.epfl.ch/course/view.php?id=14840");
  if (page !== null) {
    check(page.sections.length === 3, `la sous-section déléguée n'est pas une section de plus (${page.sections.length})`);
    check(eq(page.sections[1].items.map((entry) => entry.title),
      ["Vidéo 1.1 Introduction", "Série 1", "Corrigé série 1", "Chapitre 1.2 Suites"]),
      "ses activités sont rangées là où on les voit");
    check(!page.sections[2].items.some((entry) => entry.title === "Caché"), "une activité invisible n'est pas importée");
    const draft = ContentDraftBuilder.draft(page, "moodle", termStart, 14);
    check(draft.seriesCount === 2, `deux séries, le corrigé n'en est pas une (${draft.seriesCount})`);
    check(draft.sections.find((entry) => entry.title.startsWith("8 septembre"))?.week === 1, "une section datée tombe à sa semaine");
    check(draft.sections.find((entry) => entry.title === "Semaine 2")?.week === 2, "« Semaine 2 »");
    check(draft.sections.find((entry) => entry.title === "Généralités")?.items.find((entry) => entry.title === "Annonces")?.kind === "ignore",
      "un forum s'ignore");
  } else {
    check(false, "le plan Moodle doit se lire");
  }
  check(MoodleStateParser.course('{"error":true}', "", "") === null, "une erreur ne donne pas de plan");

  const search = `{"total":3,"courses":[{"id":14839,"fullname":"Analyse I","shortname":"MATH-101(a)"},{"id":14840,"fullname":"Analyse I","shortname":"MATH-101(e)"},{"id":7621,"fullname":"Biochimie","shortname":"CH-210"}],"warnings":[]}`;
  const found = MoodleStateParser.courses(search);
  check(found.length === 3 && found[1].baseCode === "MATH-101" && found[1].variant === "e", "résultats de recherche lus");
  const unique = MoodleCourseMatcher.match("CH-210", found);
  check(unique.type === "unique" && unique.ref === found[2], "un seul cours : relié d'office");
  const ambiguous = MoodleCourseMatcher.match("MATH-101", found);
  if (ambiguous.type === "ambiguous") check(ambiguous.refs.length === 2, "plusieurs sections : on demande laquelle");
  else check(false, "MATH-101 a deux sections");
  const enrolled = MoodleCourseMatcher.match("MATH-101", found, [found[1]]);
  check(enrolled.type === "unique" && enrolled.ref === found[1], "l'inscription départage les sections");
  const variant = MoodleCourseMatcher.match("math-101(a)", found);
  check(variant.type === "unique" && variant.ref === found[0], "un code écrit avec sa section la désigne");
  check(MoodleCourseMatcher.match("PHYS-101", found).type === "none", "rien trouvé");
  check(MoodleCourseMatcher.linkedID(["https://botafogo.epfl.ch/analyse-1/", "https://moodle.epfl.ch/course/view.php?id=14840"]) === 14840,
    "le lien Moodle retenu se relit");
});

describe("Import Moodle : corrections de l'audit", () => {
  const res = (id: string, name: string, module = "resource"): MoodleActivity => {
    const activity = new MoodleActivity({ id, name, module, url: `https://moodle.epfl.ch/mod/${module}/view.php?id=${id}` });
    activity.target = `https://moodle.epfl.ch/pluginfile.php/1/${id}.pdf`;
    return activity;
  };
  const seriesOf = (draftValue: ContentDraft, number: number): { week: number; url: string; solution: string }[] =>
    draftValue.sections.flatMap((entry) => entry.items
      .filter((itemEntry) => itemEntry.kind === "series" && itemEntry.seriesNumber === number)
      .map((itemEntry) => ({ week: itemEntry.plannedWeek(entry), url: itemEntry.pdfURL === "" ? itemEntry.url : itemEntry.pdfURL, solution: itemEntry.solutionURL })));

  const nextWeek = new MoodleCourseSnapshot({ title: "Analyse I", url: "u", sections: [
    new MoodleSection({ number: 3, title: "Semaine 3", activities: [res("31", "Série 3")] }),
    new MoodleSection({ number: 4, title: "Semaine 4", activities: [res("41", "Série 4"), res("42", "Corrigé série 3")] }),
  ] });
  const joined = seriesOf(MoodleCourseAnalyzer.draft(nextWeek, null, 14), 3);
  check(joined.length === 1 && joined[0].week === 3 && joined[0].solution.endsWith("42.pdf"),
    "corrigé publié la semaine suivante : une seule « Série 3 », en semaine 3, avec son corrigé");

  const writerCourse = new Course({ code: "AUDIT-101", name: "Audit" });
  store.insert(writerCourse);
  const split = new ContentDraft({ source: "moodle", courseTitle: "", url: "", sections: [] });
  const statement = new ContentDraftItem({ kind: "series", number: "3", title: "Série 3", url: "https://x/s3.pdf",
    videoCount: 0, seriesNumber: 3, theoryKind: "reading" });
  statement.pdfURL = "https://x/s3.pdf";
  const onlySolution = new ContentDraftItem({ kind: "series", number: "3", title: "Série 3", url: "",
    videoCount: 0, seriesNumber: 3, theoryKind: "reading" });
  onlySolution.solutionURL = "https://x/s3-sol.pdf";
  split.sections = [
    new ContentDraftSection({ title: "S3", week: 3, weekIsInferred: false, isIncluded: true, items: [statement] }),
    new ContentDraftSection({ title: "S4", week: 4, weekIsInferred: false, isIncluded: true, items: [onlySolution] }),
  ];
  ContentDraftWriter.apply(split, writerCourse, store);
  const writtenSeries = writerCourse.series.find((entry) => entry.seriesNumber === 3);
  check(writtenSeries?.plannedWeek === 3 && writtenSeries?.solutionURLString === "https://x/s3-sol.pdf",
    "écriture : la série reste en semaine 3, le corrigé est rattaché");

  const folder = new MoodleActivity({ id: "9", name: "Séries", module: "folder", url: "f" });
  folder.target = "https://moodle.epfl.ch/pluginfile.php/1/Serie_01.pdf";
  const files = [1, 2, 3].map((n) => ({ title: `Serie_0${n}.pdf`, url: `https://moodle.epfl.ch/pluginfile.php/1/Serie_0${n}.pdf` }))
    .concat([1, 2, 3].map((n) => ({ title: `Serie_0${n}_sol.pdf`, url: `https://moodle.epfl.ch/pluginfile.php/1/Serie_0${n}_sol.pdf` })));
  const expanded = MoodleFolderExpander.expand(folder, files);
  const general = MoodleCourseAnalyzer.draft(new MoodleCourseSnapshot({ title: "X", url: "u", sections: [
    new MoodleSection({ number: 0, title: "Général", activities: expanded }),
    new MoodleSection({ number: 1, title: "Semaine 1", activities: [res("11", "Cours 1 slides")] }),
  ] }), null, 14);
  check([1, 2, 3].every((n) => eq(seriesOf(general, n).map((entry) => entry.week), [n]) && seriesOf(general, n)[0].solution.includes("_sol")),
    "dossier « Séries » en section générale : séries 1, 2, 3 suivies, chacune à sa semaine, avec son corrigé");
  check(!general.sections.flatMap((entry) => entry.items).some((entry) => entry.kind === "resource" && entry.title.startsWith("Serie")),
    "… et plus rangées en « documents non suivis »");

  const firstWeek = MoodleCourseAnalyzer.draft(new MoodleCourseSnapshot({ title: "X", url: "u", sections: [
    new MoodleSection({ number: 1, title: "Semaine 1", activities: expanded.concat([res("11", "Cours 1 slides")]) }),
  ] }), null, 14);
  check([1, 2, 3].every((n) => eq(seriesOf(firstWeek, n).map((entry) => entry.week), [n])),
    "dossier de toutes les séries en semaine 1 : chacune à la semaine de son numéro");
  const single = MoodleCourseAnalyzer.draft(new MoodleCourseSnapshot({ title: "X", url: "u", sections: [
    new MoodleSection({ number: 2, title: "Semaine 2", activities: [res("21", "Série 1")] }),
  ] }), null, 14);
  check(eq(seriesOf(single, 1).map((entry) => entry.week), [2]), "une série seule reste dans sa section (série 1 posée en semaine 2)");

  const catalog = [
    ["Mon cours d'analyse", "https://botafogo.epfl.ch/analyse-1/"],
    ["Mon cours d'analyse pour GM", "https://botafogo.epfl.ch/analyse-1-GM/"],
    ["Mon cours d'analyse classe inversée", "https://botafogo.epfl.ch/analyse-1-flipped/"],
    ["Le polycopié d'Algèbre linéaire et Géométrie", "https://botafogo.epfl.ch/algebre-lineaire-geometrie/"],
    ["Le polycopié d'analyse-b", "https://botafogo.epfl.ch/analyse-b/matiere/m_suites_intro"],
    ["Mon cours d'algèbre linéaire", "https://botafogo.epfl.ch/algebre-lineaire/index.html"],
  ].map(([title, url]) => ({ title, url: new URL(url) }));
  const site = (name: string): string => BotafogoCatalog.match(name, catalog)?.toString().replace("https://botafogo.epfl.ch", "") ?? "aucun";
  check(site("Analyse I (MATH-101(e))") === "/analyse-1/", `Analyse I → analyse-1 (${site("Analyse I (MATH-101(e))")})`);
  check(site("Analyse I (classe inversée) (MATH-101(pi))") === "/analyse-1-flipped/", "Analyse I classe inversée → analyse-1-flipped");
  check(site("Algèbre linéaire (MATH-111(e))") === "/algebre-lineaire/index.html", "Algèbre linéaire → algebre-lineaire");
  check(site("Analyse numérique (MATH-251(a))") === "aucun" && site("Analyse II (MATH-106(en))") === "aucun"
    && site("Algèbre linéaire avancée I (MATH-110)") === "aucun" && site("Physique générale I") === "aucun",
    "Analyse numérique, Analyse II, Algèbre linéaire avancée : aucun polycopié (et plus celui d'Analyse I)");
  check(site("Analyse B (MATH-105)") === "/analyse-b/matiere/m_suites_intro", "Analyse B → analyse-b");

  const now = new Date();
  check(MoodleCourseAnalyzer.shortDate("Projet 1.2 — consignes", now) === null
    && MoodleCourseAnalyzer.shortDate("Partie 3.1", now) === null, "« Projet 1.2 », « Partie 3.1 » ne sont pas des échéances");
  check(MoodleCourseAnalyzer.shortDate("Sélection d'un groupe (DÉLAI 13.10, 18:00)", now) !== null
    && MoodleCourseAnalyzer.shortDate("Examen Final (samedi 12.12, 09:00-12:00)", now) !== null
    && MoodleCourseAnalyzer.shortDate("Rendu le 4.11", now) !== null,
    "les vraies dates courtes restent lues (délai, examen, « le 4.11 »)");

  const functionPath = resolve(process.cwd(), "..", "supabase", "functions", "analyze-course", "index.ts");
  const source = readFileSync(functionPath, "utf8");
  const start = source.indexOf("const INSTRUCTIONS = ");
  const end = source.indexOf('";\n', start + "const INSTRUCTIONS = ".length);
  if (start >= 0 && end > start) {
    const literal = source.slice(start + "const INSTRUCTIONS = ".length, end) + '"';
    const serverText = JSON.parse(literal) as string;
    check(serverText === MoodleCourseAI.instructions,
      "analyze-course : la consigne du serveur est celle de l'app (sinon : la recopier et redéployer)");
  } else {
    check(false, `analyze-course : consigne du serveur introuvable dans ${functionPath}`);
  }

  const base = new MoodleCourseSnapshot({ title: "X", url: "u", sections: [
    new MoodleSection({ number: 3, title: "Semaine 3 (semaine courante)", activities: [res("31", "Série 3")], text: "Rendu lundi" }),
  ] });
  const before = MoodleCourseAI.structure(base, [], true);
  base.sections[0].text = "Rendu mardi";
  base.sections[0].activities[0].preview = "Dernière mise à jour : 3 octobre";
  base.sections[0].activities[0].target = "https://moodle.epfl.ch/pluginfile.php/1/mod_resource/content/7/31.pdf?forcedownload=1";
  const moved = new MoodleCourseSnapshot({ title: "X", url: "u", sections: [
    new MoodleSection({ number: 3, title: "Semaine 3", activities: base.sections[0].activities, text: "Rendu mardi" }),
  ] });
  check(MoodleCourseAI.structure(base, [], true) === MoodleCourseAI.structure(moved, [], true),
    "structure : ni texte de section, ni aperçu, ni révision de fichier, ni « semaine courante »");
  base.sections[0].activities.push(res("32", "Corrigé série 3"));
  check(MoodleCourseAI.structure(base, [], true) !== before, "structure : une activité publiée la change");
  const day = 86_400;
  const t0 = new Date(1_790_000_000_000);
  check(MoodleCourseAI.reuses("s", "f", t0, "s", "f", new Date(t0.getTime() + 30 * day * 1000))
    && MoodleCourseAI.reuses("s", "f", t0, "s", "g", new Date(t0.getTime() + 3 * day * 1000))
    && !MoodleCourseAI.reuses("s", "f", t0, "s", "g", new Date(t0.getTime() + 8 * day * 1000))
    && !MoodleCourseAI.reuses("s", "f", t0, "t", "f", t0)
    && !MoodleCourseAI.reuses(null, "f", t0, "s", "f", t0),
    "réanalyse : structure nouvelle → toujours ; texte changé → au plus une fois par semaine ; rien → jamais");
  store.delete(writerCourse);
  // NON PORTÉ : ImportFeed.source et ImportProgress.stage (fichiers d'un autre domaine).
});

describe("Accueil : les cours lus sur Moodle (MoodleOnboarding)", () => {
  const refs = [
    new MoodleCourseRef({ id: 15221, fullname: "Analyse I (classe inversée) (MATH-101(pi))", shortname: "MATH-101(pi)" }),
    new MoodleCourseRef({ id: 15272, fullname: "Algèbre linéaire (classe inversée) (MATH-111(pi))", shortname: "MATH-111(pi)" }),
    new MoodleCourseRef({ id: 99, fullname: "Aide Moodle pour les étudiants", shortname: "AIDE-ETU" }),
    new MoodleCourseRef({ id: 14847, fullname: "Introduction à la programmation", shortname: "CS-107" }),
    new MoodleCourseRef({ id: 15000, fullname: "Analyse I (MATH-101(e))", shortname: "MATH-101(e)" }),
    new MoodleCourseRef({ id: 18568, fullname: "CS-101 Advanced information, computation, communication I", shortname: "AICC-I" }),
  ];
  const planned = MoodleOnboarding.courses(refs);
  check(eq(planned.map((entry) => entry.code), ["MATH-101", "MATH-111", "CS-107", "CS-101"]),
    "les cours EPFL seulement, une fois chacun (deux sections Moodle du même cours → un cours)");
  check(eq(planned.map((entry) => entry.name), ["Analyse I (classe inversée)", "Algèbre linéaire (classe inversée)",
    "Introduction à la programmation", "Advanced information, computation, communication I"]),
    "noms nettoyés du code et de la section");
  check(planned[0]?.ref.id === 15221, "le cours garde **sa** page Moodle (la première inscription)");
});

describe("Dossiers Moodle dépliés (MoodleFolderExpander)", () => {
  const folder = new MoodleActivity({ id: "1377178", name: "Séries", module: "folder",
    url: "https://moodle.epfl.ch/mod/folder/view.php?id=1377178" });
  const base = "https://moodle.epfl.ch/pluginfile.php/1/mod_folder/content/0/";
  const files = [
    { title: "Serie_01.pdf", url: base + "Serie_01.pdf" },
    { title: "Serie_02.pdf", url: base + "Serie_02.pdf" },
    { title: "Corrigé série 1.pdf", url: base + "Corrige_01.pdf" },
    { title: "", url: base + "S%C3%A9rie%2003.pdf" },
    { title: "Serie_02.pdf", url: base + "Serie_02.pdf" },
    { title: "Solution 7.pdf", url: base + "sol7.pdf" },
  ];
  const out = MoodleFolderExpander.expand(folder, files);
  check(out.length === 4, "un dossier de 3 séries + 2 corrigés donne 4 éléments (doublon retiré, corrigé orphelin gardé)");
  check(eq(out.map((entry) => entry.name), ["Serie 01", "Serie 02", "Série 03", "Solution 7"]),
    "noms lisibles, tirés du fichier quand le lien n'a pas de texte (accents décodés)");
  check(out[0]?.solutionTarget === base + "Corrige_01.pdf" && out[1]?.solutionTarget === null,
    "le corrigé rejoint l'énoncé du même numéro");
  check(out.every((entry) => entry.module === "resource" && entry.destination === "pdf" && entry.target?.startsWith(base) === true)
    && new Set(out.map((entry) => entry.id)).size === 4, "chaque fichier devient un PDF à part, d'identifiant unique");
  const unchanged = MoodleFolderExpander.expand(folder, [files[0], files[2]]);
  check(unchanged.length === 1 && unchanged[0] === folder, "un dossier d'un énoncé et de son corrigé reste tel quel");
  check(MoodleFolderExpander.number({ title: "ex03_2026.pdf", url: "x" }) === 3
    && MoodleFolderExpander.number({ title: "Week-12 exercises", url: "x" }) === 12,
    "numéro de série lu dans « ex03_2026 » et « Week-12 », pas l'année");
});

describe("Nouveautés Moodle (notifications)", () => {
  const course = (sections: MoodleSection[]): MoodleCourseSnapshot => new MoodleCourseSnapshot({ title: "Analyse I", url: "x", sections });
  const before = course([new MoodleSection({ number: 0, title: "Généralités", activities: [
    new MoodleActivity({ id: "9", name: "Annonces", module: "forum", url: "u9" }),
    new MoodleActivity({ id: "10", name: "Série 3", module: "resource", url: "u10" }),
    new MoodleActivity({ id: "11", name: "Caché", module: "resource", url: "u11", isVisible: false }),
  ] })]);
  const first = MoodleNews.diff(before, null);
  check(eq([...first.seen], ["10"]) && first.new.length === 0, `premier relevé : on retient, on n'annonce rien (${[...first.seen]})`);
  const after = course([new MoodleSection({ number: 0, title: "Généralités", activities: [
    new MoodleActivity({ id: "10", name: "Série 3", module: "resource", url: "u10" }),
    new MoodleActivity({ id: "11", name: "Corrigé série 3", module: "resource", url: "u11" }),
    new MoodleActivity({ id: "12", name: "Série 4", module: "resource", url: "u12" }),
    new MoodleActivity({ id: "13", name: "Rendu 2", module: "assign", url: "u13" }),
    new MoodleActivity({ id: "14", name: "Forum", module: "forum", url: "u14" }),
  ] })]);
  const second = MoodleNews.diff(after, first.seen);
  check(eq(second.new.map((entry) => entry.id), ["11", "12", "13"]), `les nouveautés, dans l'ordre du cours (${second.new.map((entry) => entry.id)})`);
  check(eq(second.new.map((entry) => entry.kind), ["solution", "series", "deadline"]), "…et leur nature");
  check(MoodleNews.diff(before, second.seen).new.length === 0, "ce qui a disparu ne se réannonce pas");
  check(MoodleNews.diff(after, first.seen).seen.has("11") && MoodleNews.diff(after, first.seen).seen.has("14") === false,
    "on retient ce qui est visible, forum compris comme ignoré");
  const single = MoodleNews.message("MATH-101", [second.new[1]])!;
  check(single.title === "Nouvelle série · MATH-101" && single.body === "Série 4", "une nouveauté : un titre et son nom");
  check(MoodleNews.message("X", []) === null, "rien de neuf, pas de notification");
  const many = MoodleNews.message("MATH-101", [...second.new, second.new[0]])!;
  check(many.title === "4 nouveautés · MATH-101" && many.body.endsWith(" · +1") && many.body.includes("Corrigé série 3"),
    "plusieurs : les trois premiers noms, puis « +N »");
  check(eq([...MoodleNewsKind.decode("series,deadline")], ["series", "deadline"])
    && MoodleNewsKind.encode(new Set(["deadline", "series"])) === "series,deadline", "le réglage tient en une chaîne");
  check(eq([...MoodleNewsKind.decode(null)], ["series", "solution", "deadline"]), "défaut : séries, corrigés, rendus");
  check(eq([...MoodleNewsKind.decode("")], []), "tout décoché reste tout décoché");
  check(eq([...MoodleNewsKind.decode(MoodleNewsKind.encode(new Set(["lecture", "series"])))], ["series", "lecture"]),
    "le choix se relit");

  const at = (day: number, hour: number): Date => new Date(2026, 9, day, hour);
  check(MoodleNews.deliveryDate(at(3, 14), 22, 8) === null, "l'après-midi : tout de suite");
  check(MoodleNews.deliveryDate(at(3, 7), 22, 8)?.getTime() === at(3, 8).getTime(), "heures calmes 22 h → 8 h : à 7 h, on attend 8 h");
  check(MoodleNews.deliveryDate(at(4, 3), 22, 8)?.getTime() === at(4, 8).getTime(), "3 h 30 : à 8 h le jour même");
  check(MoodleNews.deliveryDate(at(3, 13), 12, 14) !== null, "fenêtre en journée respectée");
  check(MoodleNews.deliveryDate(at(3, 23), 22, 8)?.getTime() === at(4, 8).getTime(), "…le lendemain à 8 h");
  check(MoodleNews.deliveryDate(at(3, 9), 22, 8) === null, "hors des heures calmes : tout de suite");
  check(MoodleNews.deliveryDate(at(3, 0), 22, 8)?.getTime() === at(3, 8).getTime(), "la fenêtre passe minuit");
  check(MoodleNews.deliveryDate(at(3, 23), 8, 8) === null, "début = fin : pas d'heures calmes");
});

describe("Moodle : du lien d'activité au PDF", () => {
  const page = new URL("https://moodle.epfl.ch/mod/page/view.php?id=77");
  check(MoodleLinks.activityModule(page) === "page", "une page Moodle est reconnue");
  check(MoodleLinks.activityModule(new URL("https://moodle.epfl.ch/course/view.php?id=1")) === null,
    "la page d'un cours n'est pas une activité");
  check(SiteLinks.normalize(new URL("https://moodle.epfl.ch/mod/url/view.php?id=9")).toString()
    === "https://moodle.epfl.ch/mod/url/view.php?id=9&redirect=1", "un lien Moodle s'ouvre sur sa cible");
  check(SiteLinks.normalize(page).toString() === page.toString(), "une page Moodle n'a pas de redirection à demander");
  check(MoodleLinks.workaroundPage(new URL("https://moodle.epfl.ch/mod/resource/view.php?id=4&redirect=1")).toString()
    === "https://moodle.epfl.ch/mod/resource/view.php?id=4&forceview=1", "la page « cliquez ici » d'un fichier");

  const aicc = `
    <div id="region-main"><h2>Série 3</h2>
    <p>Voir le <a href="https://moodle.epfl.ch/course/view.php?id=1">cours</a>.</p>
    <p><a href="https://moodle.epfl.ch/pluginfile.php/123/mod_page/content/4/serie3_sol.pdf">Corrigé</a></p>
    <p><a href="/pluginfile.php/123/mod_page/content/4/serie3.pdf?time=1&amp;forcedownload=1"><span>Énoncé</span> de la série</a></p>
    </div>`;
  const found = MoodleLinks.statementLink(aicc, page);
  check(found.statement === "https://moodle.epfl.ch/pluginfile.php/123/mod_page/content/4/serie3.pdf?time=1&forcedownload=1",
    "l'énoncé est le PDF qui n'est pas le corrigé");
  check(found.solution?.endsWith("serie3_sol.pdf") === true, "le corrigé est rangé à part");
  const workaround = `
    <div class="urlworkaround">Cliquez sur le lien
      <a href="https://ipg.epfl.ch/aicc/serie_04.pdf" onclick="this.target='_blank'">serie_04.pdf</a></div>`;
  check(MoodleLinks.statementLink(workaround, page).statement === "https://ipg.epfl.ch/aicc/serie_04.pdf",
    "le lien « cliquez ici » d'une activité lien");
  check(MoodleLinks.statementLink("<p>Rien ici</p>", page).statement === null, "pas de document : rien d'inventé");

  const aiccActivity = new MoodleActivity({ id: "77", name: "Série 3", module: "page", url: page.toString() });
  aiccActivity.target = found.statement;
  aiccActivity.solutionTarget = found.solution;
  const aiccSnapshot = new MoodleCourseSnapshot({ title: "AICC", url: "https://moodle.epfl.ch/course/view.php?id=1", sections: [
    new MoodleSection({ number: 3, title: "Semaine 3", activities: [aiccActivity] }),
  ] });
  const aiccDraft = MoodleCourseAnalyzer.draft(aiccSnapshot, null);
  const aiccSeries = aiccDraft.sections.flatMap((entry) => entry.items).find((entry) => entry.kind === "series");
  check(aiccSeries?.pdfURL.endsWith("forcedownload=1") === true, "la série pointe sur le PDF, pas sur la page");
  check(aiccSeries?.solutionURL.endsWith("serie3_sol.pdf") === true, "et son corrigé vient de la même page");
});
