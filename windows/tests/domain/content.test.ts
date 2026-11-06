// Port des sections de Validation/main.swift qui portent sur les sites du cours
// lus en natif, Botafogo, Ed, Courseware et le profil d'école.
//
// Chaque `check` Swift devient un `it` du même libellé ; la condition est
// évaluée à la collecte, dans l'ordre du fichier Swift, parce que les sections
// se suivent sur le même état (comme dans main.swift).

import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  BotafogoFigure, EdDiscussion, EdPoll, EdXOutline, EdXProblem, Kaltura,
  MoodleActivityContent, MoodleCoursePage, SiteBlock, SiteHTML, SiteRouter,
} from "../../src/domain/siteContent.ts";
import { Institution } from "../../src/domain/institution.ts";
import { BotafogoNavigation } from "../../src/domain/botafogoNavigation.ts";
import { BotafogoPage, type BotafogoBlock } from "../../src/domain/botafogoPage.ts";
import { BotafogoNode, BotafogoSite } from "../../src/domain/botafogoProgram.ts";
import { CoursewareTranscripts } from "../../src/domain/coursewareTranscripts.ts";
import { NuxtPayload } from "../../src/domain/nuxtPayload.ts";
import { BotafogoParser, ContentDraftBuilder, ContentDraftItem, ContentDraftSection, ScrapedSection } from "../../src/domain/courseContentImport.ts";
import { MathMarkup } from "../../src/domain/mathMarkup.ts";
import { HTMLLayout } from "../../src/domain/htmlLayout.ts";
import { SeriesLayoutParser } from "../../src/domain/seriesLayout.ts";
import { SeriesPageParser } from "../../src/domain/seriesPageParser.ts";

function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

const eq = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);
const blocks = (...items: SiteBlock[]): SiteBlock[] => items;

// Les extraits réels de Botafogo viennent du fichier de fixtures de Validation,
// au même chemin que côté Swift.
const fixturesPath = resolve(process.cwd(), "..", "Validation", "BotafogoFixtures.swift");
const fixturesSource = readFileSync(fixturesPath, "utf8");
function fixture(name: string): string {
  const match = new RegExp(`static let ${name} = ####"([\\s\\S]*?)"####`).exec(fixturesSource);
  if (match === null) throw new Error(`fixture ${name} introuvable dans ${fixturesPath}`);
  return match[1];
}
const page = (json: string): BotafogoBlock[] => BotafogoPage.blocks(JSON.parse(json));

describe("Sites du cours lus en natif (SiteContent)", () => {
  const base = new URL("https://moodle.epfl.ch/mod/page/view.php?id=5");
  const html = `
    <div class="box generalbox"><h2>Consignes</h2><p>Lire le <strong>chapitre 2</strong> et
    <em>noter</em> \\(x_n\\).</p><script>alert(1)</script>
    <ul><li>un</li><li>deux</li></ul><ol><li>a</li></ol>
    <p>Voir <a href="/pluginfile.php/12/mod_page/content/serie.pdf">la série</a>.</p>
    <img src="/pluginfile.php/12/fig.png" alt="">
    <iframe src="https://api.cast.switch.ch/p/113/embedPlaykitJs/uiconf_id/1?iframeembed=true&amp;entry_id=0_5f16lokn" title="Cours 1"></iframe>
    <table><tr><th>Date</th><th>Salle</th></tr><tr><td>lundi</td><td>CE1</td></tr></table>
    <pre>let x = 1</pre><a href="#main" class="sr-only">Passer au contenu principal</a><p>&eacute;t&eacute; &amp; co</p></div>
    `;
  const parsed = SiteHTML.blocks(html, base);
  check(eq(parsed[0], blocks(SiteBlock.markdown("### Consignes"))[0]), "HTML : un titre");
  check(parsed.some((block) => eq(block, SiteBlock.markdown("Lire le **chapitre 2** et *noter* \\(x_n\\)."))),
    "HTML : gras, italique, formule gardée");
  check(!parsed.some((block) => block.type === "markdown" && block.text.includes("alert")), "HTML : pas de script");
  check(parsed.some((block) => eq(block, SiteBlock.markdown("- un\n- deux\n1. a")))
    || parsed.some((block) => eq(block, SiteBlock.markdown("- un\n- deux"))), "HTML : listes");
  check(parsed.some((block) => eq(block, SiteBlock.file("la série", "https://moodle.epfl.ch/pluginfile.php/12/mod_page/content/serie.pdf"))),
    "HTML : un fichier lié");
  check(parsed.some((block) => eq(block, SiteBlock.image("https://moodle.epfl.ch/pluginfile.php/12/fig.png"))),
    "HTML : une image, adresse résolue");
  check(parsed.some((block) => block.type === "video" && block.title === "Cours 1"), "HTML : une vidéo intégrée");
  check(parsed.some((block) => eq(block, SiteBlock.markdown("- Date · Salle\n- lundi · CE1"))), "HTML : un tableau en lignes");
  check(parsed.some((block) => eq(block, SiteBlock.markdown("```\nlet x = 1\n```"))), "HTML : du code");
  check(eq(parsed[parsed.length - 1], SiteBlock.markdown("été & co")), "HTML : entités décodées");
  const markdownPage = SiteHTML.blocks("<div class=\"md\">\n  ## Objectifs\n  - lire le **chapitre 4**\n  - voir [la vidéo](https://example.org/v)\n</div>");
  check(eq(markdownPage, [SiteBlock.markdown("## Objectifs\n- lire le **chapitre 4**\n- voir [la vidéo](https://example.org/v)")]),
    "HTML : texte Markdown gardé ligne par ligne");
  check(!SiteHTML.looksLikeMarkdown("\n   Soient \\(V\\) un espace\n   vectoriel. "), "HTML : texte indenté ordinaire, pas du Markdown");
  const emptyTags = SiteHTML.blocks("<h2>Contenu de la leçon</h2><h3></h3><p>Dans cette leçon.</p><h2></h2><ol><li>comparer ;<strong></strong></li></ol>");
  check(eq(emptyTags, [SiteBlock.markdown("### Contenu de la leçon"), SiteBlock.markdown("Dans cette leçon."), SiteBlock.markdown("1. comparer ;")]),
    "HTML : pas de « #### » ni « **** » pour des balises vides");

  check(eq(EdDiscussion.pollIDs('<document version="2.0"><paragraph>Soient $S$.</paragraph><poll id="3395"/></document>'), [3395]),
    "Ed : sondage repéré dans le message");
  check(!EdDiscussion.blocks('<document><paragraph>a</paragraph><poll id="1"/></document>')
    .some((block) => block.type === "markdown" && block.text.includes("poll")), "Ed : la balise du sondage n'est pas affichée");
  const pollJSON = `{"poll":{"id":3230,"content":"<document version=\\"1.0\\"><paragraph>Cochez</paragraph></document>","data":{"multiple_choice":true,"options":[{"content":"a","response_count":3},{"content":"b","response_count":115}]},"is_closed":false,"response":{"data":{"option_indices":[1]}},"response_count":116,"reveal_votes":"after_response"}}`;
  const poll = EdDiscussion.poll(pollJSON);
  check(poll?.options.length === 2 && poll?.multipleChoice === true && eq(poll?.chosen, [1]) && poll?.voters === 116,
    "Ed : sondage lu (options, plusieurs réponses, mon vote)");
  check(poll?.showsResults === true && Math.abs((poll?.share(1) ?? 0) - 115 / 116) < 0.001,
    "Ed : votes montrés après ma réponse, part de la classe");
  const unanswered = poll;
  if (unanswered !== null) unanswered.chosen = null;
  check(unanswered?.showsResults === false, "Ed : votes cachés avant de répondre");

  check(eq(SiteRouter.route("https://moodle.epfl.ch/mod/page/view.php?id=42"), { type: "moodle", module: "page", id: 42 }), "lien : page Moodle");
  check(eq(SiteRouter.route("https://moodle.epfl.ch/mod/resource/view.php?id=42"), { type: "pdf" }), "lien : fichier Moodle → PDF");
  check(eq(SiteRouter.route("https://moodle.epfl.ch/pluginfile.php/1/x/slides.pptx"), { type: "file" }), "lien : diapositives");
  check(eq(SiteRouter.route("https://mediaspace.epfl.ch/media/Cours+1/0_5f16lokn"), { type: "mediaspace", entryID: "0_5f16lokn" }),
    "lien : vidéo MediaSpace");
  check(eq(SiteRouter.route("https://www.youtube.com/watch?v=abc123"), { type: "youtube", id: "abc123" })
    && eq(SiteRouter.route("https://youtu.be/xyz"), { type: "youtube", id: "xyz" }), "lien : YouTube");
  check(eq(SiteRouter.route("https://courseware.epfl.ch/courses/course-v1:EPFLx+MATH101+2025/course/"),
    { type: "courseware", courseKey: "course-v1:EPFLx+MATH101+2025" }), "lien : Courseware");
  check(eq(SiteRouter.route("https://botafogo.epfl.ch/analyse-1-GM/"), { type: "botafogo" })
    && eq(SiteRouter.route("https://www.geogebra.org/calculator"), { type: "geogebra" }), "lien : Botafogo, GeoGebra");
  check(eq(SiteRouter.route("https://example.com/a.pdf"), { type: "pdf" })
    && eq(SiteRouter.route("https://example.com/"), { type: "web" }), "lien : PDF ailleurs, page web");

  check(Kaltura.manifestURL("0_5f16lokn")?.toString()
    === "https://api.cast.switch.ch/p/113/sp/11300/playManifest/entryId/0_5f16lokn/format/applehttp/protocol/https/a.m3u8",
    "Kaltura : manifeste HLS d'une vidéo publique");
  check(Kaltura.manifestURL("0_x", undefined, "KEY")?.toString().includes("/ks/KEY/a.m3u8") === true,
    "Kaltura : avec la clé de session");
  const kalturaPage = `<script>var x = {"partnerId":"113","ks":"djJ8MTEzfJfIN6eBQhUqAAAAAAAAAA=="};</script>`;
  check(Kaltura.config(kalturaPage).partnerID === 113 && Kaltura.config(kalturaPage).ks === "djJ8MTEzfJfIN6eBQhUqAAAAAAAAAA==",
    "Kaltura : partenaire et clé lus");
  check(Kaltura.isPlayableManifest("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nx") && !Kaltura.isPlayableManifest("<html>"),
    "Kaltura : manifeste reconnu");

  const edx = `
    {"root":"r","blocks":{
     "r":{"type":"course","display_name":"MOOC","children":["c1"]},
     "c1":{"type":"chapter","display_name":"Semaine 1","children":["s1"]},
     "s1":{"type":"sequential","display_name":"Suites","children":["u1"]},
     "u1":{"type":"vertical","display_name":"Définition","children":["v1","h1","p1"]},
     "v1":{"type":"video","display_name":"Vidéo","student_view_url":"https://c/xblock/v1",
           "student_view_data":{"encoded_videos":{"mobile_low":{"url":"https://v/low.mp4"},"hls":{"url":"https://v/a.m3u8"},"youtube":{"url":"https://www.youtube.com/watch?v=YT1"}}}},
     "h1":{"type":"html","display_name":"Texte","student_view_url":"https://c/xblock/h1"},
     "p1":{"type":"problem","display_name":"Quiz"}}}
    `;
  const outline = EdXOutline.parse(edx);
  if (outline !== null) {
    const unit = outline.chapters[0]?.sequences[0]?.units[0];
    check(eq(outline.chapters.map((chapter) => chapter.title), ["Semaine 1"]) && unit?.title === "Définition",
      "edX : chapitres, séquences, unités");
    check(eq(unit?.blocks.map((block) => block.kind), ["video", "html", "problem"]), "edX : les blocs d'une unité");
    check(unit?.blocks[0]?.videoURL === "https://v/a.m3u8" && unit?.blocks[0]?.youTubeID === "YT1",
      "edX : HLS d'abord, YouTube en secours");
    check(unit?.blocks[1]?.viewURL === "https://c/xblock/h1", "edX : le texte par son adresse seule");
  } else {
    check(false, "edX : plan lisible");
  }
  check(EdXOutline.bestVideo({ all_sources: ["https://a/x.webm", "https://a/x.mp4"] }) === "https://a/x.mp4",
    "edX : mp4 parmi les sources");

  const moodle = MoodleActivityContent.decode(`{"module":"assign","title":"Devoir 1 &amp; 2","html":"<p>Rendre</p>","dates":["À rendre : lundi"],"files":[{"name":"enonce.pdf","url":"https://moodle.epfl.ch/pluginfile.php/1/enonce.pdf"}],"status":["Statut : Aucune remise"]}`);
  check(moodle?.title === "Devoir 1 & 2" && eq(moodle?.dates, ["À rendre : lundi"]) && moodle?.files.length === 1
    && moodle?.status[0] === "Statut : Aucune remise" && eq(moodle?.posts, []), "Moodle : un devoir lu");
  check(MoodleActivityContent.decode(`{"module":"page","needsLogin":true}`)?.needsLogin === true, "Moodle : page de connexion reconnue");
  const hidden = MoodleActivityContent.decode(`{"module":"url","title":"","unavailable":true,"notice":"Pas disponible avant le 17 octobre"}`);
  check(hidden?.unavailable === true && hidden?.notice === "Pas disponible avant le 17 octobre" && hidden?.target === null,
    "Moodle : activité pas encore ouverte, pas la page du cours");
  check(MoodleActivityContent.decode(`{"module":"url","title":"x","notice":""}`)?.notice === null, "Moodle : avis vide ignoré");
  check(BotafogoFigure.imagePath("/media/jsxgraph/jsx_suite_divergente.js") === "/media/jsxgraph/jsx_suite_divergente.png",
    "Botafogo : l'image fixe d'une figure interactive");
});

describe("Moodle : la page du cours", () => {
  const json = `{"title":"PHYS-101","sections":[{"number":0,"title":"General","summary":"<p>Bienvenue</p>","activities":[{"id":1,"module":"label","name":"Organisation","url":"","html":"<p>Chaque semaine…</p>"}]},{"number":6,"title":"12 October- 18 October","activities":[{"id":2,"module":"resource","name":"Problem Set 6: Momentum","url":"https://moodle.epfl.ch/mod/resource/view.php?id=2"},{"id":3,"module":"url","name":"Lecture 6a recording","url":"https://moodle.epfl.ch/mod/url/view.php?id=3","completed":true}]}]}`;
  const coursePage = MoodleCoursePage.decode(json);
  if (coursePage !== null) {
    check(coursePage.sections.length === 2 && coursePage.sections[1].activities[0].isSeries
      && coursePage.sections[1].activities[1].isVideo && coursePage.sections[1].activities[1].completed,
      "Moodle : sections, série, vidéo, achèvement");
    const today = new Date(2026, 9, 14);
    check(coursePage.currentSection(today)?.number === 6, "Moodle : la semaine en cours d'après le titre");
    check(MoodleCoursePage.range("7 septembre - 13 septembre", 2026) !== null
      && MoodleCoursePage.range("General", 2026) === null, "Moodle : dates en français, titre sans dates");
  } else {
    check(false, "Moodle : page du cours lisible");
  }
  check(MoodleCoursePage.decode(`{"title":"x","sections":[]}`) === null, "Moodle : page vide refusée");
});

describe("Ed Discussion", () => {
  const user = `{"user":{"id":1},"courses":[{"course":{"id":101,"code":"CS-101","name":"AICC I"},"role":{"role":"student"}},{"course":{"id":200,"code":"CS-101 2026","name":"AICC I"}},{"course":{"id":7,"code":"MATH-111","name":"Algèbre"}}]}`;
  const courses = EdDiscussion.courses(user);
  check(eq(courses.map((course) => course.id), [101, 200, 7]), "Ed : les cours de l'utilisateur·rice");
  check(EdDiscussion.match("CS-101", courses)?.id === 200 && EdDiscussion.match("MATH-111", courses)?.id === 7
    && EdDiscussion.match("PHYS-101(c)", courses) === null, "Ed : le cours du même code, le plus récent");
  const list = `{"threads":[{"id":5,"number":12,"title":"Série 3, ex 2","category":"Séries","type":"question","is_pinned":false,"is_answered":true,"reply_count":2,"created_at":"2026-10-10T10:00:00Z","document":"Bonjour"}]}`;
  check(EdDiscussion.threads(list)[0]?.isAnswered === true, "Ed : la liste des fils");
  const thread = `{"thread":{"id":5,"user_id":1,"content":"<document version=\\"2.0\\"><paragraph>Pourquoi <math>x_n \\\\to 0</math> ?</paragraph></document>","answers":[{"user_id":2,"is_endorsed":true,"content":"<document version=\\"2.0\\"><paragraph>Par <bold>encadrement</bold>.</paragraph></document>","comments":[{"user_id":1,"content":"<document version=\\"2.0\\"><paragraph>Merci</paragraph></document>"}]}],"comments":[]},"users":[{"id":1,"name":"Hugo"},{"id":2,"name":"Assistant"}]}`;
  const post = EdDiscussion.thread(thread);
  if (post !== null) {
    check(post.author === "Hugo" && post.replies[0]?.author === "Assistant" && post.replies[0]?.isEndorsed === true
      && post.replies[0]?.replies[0]?.author === "Hugo", "Ed : fil, réponse validée, commentaire");
    check(eq(EdDiscussion.blocks(post.content), [SiteBlock.markdown("Pourquoi \\(x_n \\to 0\\) ?")]), "Ed : formule gardée");
    check(eq(EdDiscussion.blocks(post.replies[0].content), [SiteBlock.markdown("Par **encadrement**.")]), "Ed : gras");
  } else {
    check(false, "Ed : fil lisible");
  }
  const doc = `<document version="2.0"><heading level="2">Titre</heading><list style="bullet"><list-item><paragraph>un</paragraph></list-item></list><snippet language="py">print(1)</snippet></document>`;
  check(eq(EdDiscussion.blocks(doc), [SiteBlock.markdown("### Titre"), SiteBlock.markdown("- un"), SiteBlock.markdown("```\nprint(1)\n```")]),
    "Ed : titre, liste, code");
});

describe("Ed : écrire, leçons, quiz", () => {
  const doc = EdDiscussion.document("Pourquoi **ça** marche si $x_n < 1$ ?\n\n- un\n- deux\n\n```\nprint(1)\n```");
  check(doc === `<document version="2.0"><paragraph>Pourquoi <bold>ça</bold> marche si <math>x_n &lt; 1</math> ?</paragraph><list style="bullet"><list-item><paragraph>un</paragraph></list-item><list-item><paragraph>deux</paragraph></list-item></list><snippet language="none" runnable="false" line-numbers="true">print(1)</snippet></document>`,
    "Ed : Markdown → document");
  check(eq(EdDiscussion.blocks(doc)[0], SiteBlock.markdown("Pourquoi **ça** marche si \\(x_n < 1\\) ?")), "Ed : aller-retour du document");
  check(eq(EdDiscussion.categories(`{"course":{"settings":{"discussion":{"categories":[{"name":"General"},{"name":"Exercises"}]}}}}`), ["General", "Exercises"]),
    "Ed : catégories du forum");
  const lessons = EdDiscussion.lessons(`{"lessons":[{"id":9,"title":"Quiz 1","module_id":3,"status":"attempted"}],"modules":[{"id":3,"name":"Semaine 1"}]}`);
  check(eq(lessons, [{ id: 9, title: "Quiz 1", module: "Semaine 1", status: "attempted" }]), "Ed : leçons et modules");
  const slides = EdDiscussion.slides(`{"lesson":{"slides":[{"id":1,"type":"document","title":"Intro","content":"<document/>","status":"completed"},{"id":2,"type":"quiz","title":"Q"}]}}`);
  check(eq(slides.map((slide) => slide.type), ["document", "quiz"]) && slides[0].isCompleted, "Ed : diapositives");
  const questions = EdDiscussion.questions(`{"questions":[{"id":7,"data":{"type":"multiple-choice","content":"<document/>","answers":["<document>A</document>","<document>B</document>"],"multiple_selection":true}},{"id":8,"data":{"type":"true-false","content":"x"}},{"id":10,"data":{"type":"numerical","content":"y"}}]}`);
  check(eq(questions.map((question) => question.kind), ["choice-multiple", "choice-single", "number"])
    && eq(questions[1].answers, ["Vrai", "Faux"]), "Ed : questions de quiz");
  check(eq(EdDiscussion.response(new Set([2, 0]), "", "choice-multiple"), [0, 2])
    && EdDiscussion.response(new Set(), "3,5", "number") === 3.5, "Ed : la réponse envoyée");
});

describe("Courseware : problèmes et navigation", () => {
  const problem = EdXProblem.decode(`{"url":"https://c/handler/xmodule_handler","title":"Question 1","prompt":"<p>?</p>","groups":[{"name":"input_x_2_1[]","type":"checkbox","options":[{"value":"choice_0","label":"A"},{"value":"choice_1","label":"B"}]}],"score":0,"total":1,"attempts":2}`);
  check(problem?.groups[0]?.options.length === 2 && problem?.attempts === 2, "Courseware : un problème lu");
  check(EdXProblem.formBody({ "input_x_2_1[]": ["choice_0", "choice_1"] }) === "input_x_2_1%5B%5D=choice_0&input_x_2_1%5B%5D=choice_1",
    "Courseware : le formulaire envoyé");
  check(EdXProblem.result(`{"success":"correct","current_score":1.0,"total_possible":1.0}`)?.isCorrect === true
    && EdXProblem.result(`{"success":"incorrect"}`)?.isCorrect === false, "Courseware : le verdict");
  const edx = `{"root":"r","blocks":{"r":{"type":"course","children":["c"]},"c":{"type":"chapter","display_name":"Ch","children":["s"]},"s":{"type":"sequential","display_name":"S","children":["u0","u1","u2"]},"u0":{"type":"vertical","display_name":"Accueil","completion":0,"children":[]},"u1":{"type":"vertical","display_name":"U1","completion":1,"children":[]},"u2":{"type":"vertical","display_name":"U2","completion":0,"children":[]}}}`;
  const outline = EdXOutline.parse(edx);
  if (outline !== null) {
    check(eq(outline.units.map((unit) => unit.id), ["u0", "u1", "u2"]) && outline.units[1].completed
      && outline.resumeUnit?.id === "u2", "Courseware : reprise après la dernière unité faite");
    check(outline.place("u2")?.sequence.title === "S", "Courseware : chapitre et séquence d'une unité");
  } else {
    check(false, "Courseware : plan lisible");
  }
});

describe("Profil d'école (Institution)", () => {
  check(Institution.current === Institution.epfl, "l'EPFL par défaut : rien ne change");
  check(Institution.detect("prenom.nom@epfl.ch")?.id === "epfl" && Institution.detect("a@gmail.com") === null,
    "l'école d'une adresse");
  const other = new Institution({
    id: "uni", name: "Université fictive", emailDomains: ["uni.example"],
    moodle: { base: "https://cours.uni.example", oauthProviderID: null },
    openEdX: { base: "https://mooc.uni.example", loginBackend: null, ssoHost: null, ssoIdP: null },
    video: { host: "video.uni.example", kalturaAPI: "https://api.kaltura.example", kalturaPartner: 42,
             wayfHost: null, identityProvider: null, passwordIdPHost: null },
    ed: { region: "us" }, studyDomains: ["uni.example"],
  });
  const saved = Institution.current;
  Institution.current = other;
  check(eq(SiteRouter.route("https://cours.uni.example/mod/page/view.php?id=7"), { type: "moodle", module: "page", id: 7 }),
    "autre école : son Moodle");
  check(eq(SiteRouter.route("https://moodle.epfl.ch/mod/page/view.php?id=7"), { type: "web" }),
    "autre école : le Moodle de l'EPFL n'est plus le sien");
  check(eq(SiteRouter.route("https://video.uni.example/media/t/0_abcdefgh"), { type: "mediaspace", entryID: "0_abcdefgh" }),
    "autre école : ses vidéos");
  check(eq(SiteRouter.route("https://mooc.uni.example/courses/course-v1:UNI+X+2026/course/"),
    { type: "courseware", courseKey: "course-v1:UNI+X+2026" }), "autre école : son Open edX");
  check(!eq(SiteRouter.route("https://botafogo.epfl.ch/x/"), { type: "botafogo" }), "autre école : pas de Botafogo");
  check(Kaltura.manifestURL("0_x")?.toString().startsWith("https://api.kaltura.example/p/42/sp/4200/") === true,
    "autre école : son Kaltura");
  Institution.current = saved;
  check(eq(SiteRouter.route("https://moodle.epfl.ch/mod/page/view.php?id=7"), { type: "moodle", module: "page", id: 7 }),
    "retour à l'EPFL");
  const encoded = JSON.stringify(Institution.epfl.toJSON());
  check(eq(Institution.fromJSON(JSON.parse(encoded))?.toJSON(), Institution.epfl.toJSON()), "un profil s'écrit et se relit");

  // NON PORTÉ : StudyMode.defaultSites / StudyMode.tools (moteur d'un autre domaine).
});

describe("Botafogo : noms et macros", () => {
  check(MathMarkup.plain("$x \\in \\bR$") === "x ∈ ℝ", "macro Botafogo \\bR → ℝ");
  check(new BotafogoNode({ type: "session", name: "seance-HY-03" }).displayName === "Séance 3", "séance : nom lisible");
  check(new BotafogoNode({ type: "weekContent", name: "week-HY-02" }).displayName === "La semaine", "contenu de semaine : nom lisible");
  check(new BotafogoNode({ type: "series", name: "Suites réelles" }).displayName === "Suites réelles", "une série garde son nom");
});

describe("Botafogo : les quatre parties (polycopié, séances, exercices, infos)", () => {
  const nav = `[{"title":"I Préface","path":"/handout/analyse-1","children":[{"title":"I Préface","path":"#i-préface","children":[{"title":"I.1 Un cours d'Analyse 1","path":"/handout/matiere/m_intro_objectifs"}]},{"title":"1 Nombres: $\\\\mathbb{R}$","path":"#_1-nombres-mathbbr","children":[{"title":"1.1 Introduction","path":"/handout/matiere/m_reels_intro"},{"title":"1.2 Règles de calcul","path":"/handout/matiere/m_reels_r_est_un_corps"}]},{"title":"Vide","path":"#vide","children":[]}]}]`;
  const chapters = BotafogoSite.chapters(nav);
  check(eq(chapters.map((chapter) => chapter.title), ["I Préface", "1 Nombres: $\\mathbb{R}$"]), "Botafogo : chapitres du polycopié (vides écartés)");
  check(eq(chapters[chapters.length - 1]?.sections.map((section) => section.path),
    ["/handout/matiere/m_reels_intro", "/handout/matiere/m_reels_r_est_un_corps"]), "Botafogo : sections d'un chapitre");
  check(BotafogoSite.handoutCollection(`latex:{collections:{handout:{url:"/handout/analyse-1",author:""}}}`) === "/handout/analyse-1",
    "Botafogo : collection du polycopié lue dans la page");
  check(BotafogoSite.isHandout("/handout/matiere/m_reels_intro") && !BotafogoSite.isHandout("series/AN_serie_01"),
    "Botafogo : polycopié ou cours");

  const week = (name: string, date: string): BotafogoNode => new BotafogoNode({
    type: "week", name, children: [
      new BotafogoNode({ type: "session", name: "seance-HY-01", url: "seances/seance-HY-01", metadata: { date } }),
      new BotafogoNode({ type: "series", name: "Fonctions", url: "series/AN_serie_01" }),
    ],
  });
  const weeks = [week("Nombres réels", "2026-09-07T12:00:00.000Z"), week("Suites réelles", "2026-09-14T12:00:00.000Z"),
                 week("Séries", "2026-09-21T12:00:00.000Z")];
  const mid = new Date("2026-09-16T08:00:00.000Z");
  check(BotafogoSite.currentWeek(weeks, mid) === 1, "Botafogo : la semaine en cours d'après la séance");
  check(BotafogoSite.currentWeek(weeks, new Date("2026-09-19T20:00:00.000Z")) === 2, "Botafogo : le week-end montre la semaine qui vient");
  check(BotafogoSite.currentWeek(weeks, new Date("2026-08-01T08:00:00.000Z")) === null, "Botafogo : avant la rentrée, pas de semaine");
  check(BotafogoSite.seriesTitle(new BotafogoNode({ type: "series", name: "Fonctions", url: "series/AN_serie_01" })) === "Série 1",
    "Botafogo : « Série 1 »");
  check(BotafogoSite.isSessionPart(new BotafogoNode({ type: "weekContent" }))
    && !BotafogoSite.isSessionPart(new BotafogoNode({ type: "series" })), "Botafogo : séance et exercices séparés");
});

describe("Botafogo : les documents lus comme le site les montre", () => {
  const first = page(fixture("quiz_vf"))[0];

  if (first?.type === "quiz") {
    check(first.title === "Quiz 0.9", "quiz : son titre");
    check(eq(first.choices.map((choice) => choice.text), ["VRAI", "FAUX"])
      && eq(first.choices.map((choice) => choice.correct), [true, false]), "quiz : VRAI juste, FAUX faux");
    check(first.prompt.some((block) => block.type === "paragraph" && block.text.includes("$z\\neq 0$")),
      "quiz : l'énoncé et ses formules");
  } else {
    check(false, "quiz : lu comme un quiz");
  }

  const expl = page(fixture("quiz_expl"))[0];
  if (expl?.type === "quiz") {
    check(expl.choices.length >= 3 && expl.choices.filter((choice) => choice.correct).length >= 1,
      "QCM : plusieurs choix, au moins un juste");
    check(expl.choices.some((choice) => choice.text.includes("$a_{n}\\leqslant x_{n}\\leqslant b_{n}$")),
      "QCM : le texte du choix, pas l'attribut aux espaces mangés");
    check(expl.choices.some((choice) => (choice.explanation ?? "") !== ""), "QCM : l'explication suit son choix");
  } else {
    check(false, "QCM : lu comme un quiz");
  }

  const ex = page(fixture("ex"))[0];
  if (ex?.type === "exercise") {
    check(ex.label.startsWith("Ex-"), "exercice : son étiquette « Ex-… » à part");
    check(ex.content.some((block) => block.type === "math"), "exercice : la formule isolée (displayMode vide = oui)");
    check(ex.content.some((block) => block.type === "folded" && block.fold === "hint" && block.content.length > 0),
      "exercice : l'indication, avec son contenu");
    check(ex.content.some((block) => block.type === "folded" && block.fold === "solution" && block.content.length > 0),
      "exercice : la solution, avec son contenu");
  } else {
    check(false, "exercice : lu comme un exercice");
  }

  const theorem = page(fixture("theo"));
  const firstTheorem = theorem[0];
  if (firstTheorem?.type === "theorem") {
    check(firstTheorem.kind === "theorem" && firstTheorem.title.includes("Théorème"),
      `théorème : son genre et son titre (${firstTheorem.title})`);
    check(firstTheorem.content.length > 0, "théorème : son énoncé");
  } else {
    check(false, "théorème : lu comme un encadré");
  }

  check(page(fixture("mc")).some((block) => block.type === "list" && block.ordered && block.columns === 3 && block.items.length >= 3),
    "multicols : une liste numérotée en trois colonnes");

  const grouped = BotafogoPage.groupingExercises([
    { type: "heading", text: "Aujourd'hui", level: 4 },
    { type: "paragraph", text: "**Exercice.** (3) Expliquer pourquoi." },
    { type: "math", tex: "P(z)" },
    { type: "folded", fold: "solution", title: "Solution", content: [{ type: "paragraph", text: "Car." }] },
    { type: "paragraph", text: "**Exercice.** (4)" },
    { type: "heading", text: "Extras", level: 4 },
  ]);
  check(grouped.length === 4, "séance : deux cartes d'exercice entre les titres");
  const groupedExercise = grouped[1];
  if (groupedExercise?.type === "exercise") {
    check(groupedExercise.label === "Exercice 3" && groupedExercise.content.length === 3,
      "séance : l'exercice 3 garde son texte, sa formule, sa solution");
  } else {
    check(false, "séance : une carte d'exercice");
  }

  const ref = page(fixture("ref"))[0];
  if (ref?.type === "paragraph") {
    check(ref.text === "[Suites de Cauchy](polymestre-poly:///handout/matiere/m_suites_cauchy)",
      `renvoi : lien vers la section du polycopié (${ref.text})`);
  } else {
    check(false, "renvoi : lu comme un lien");
  }
  check(BotafogoPage.handoutPathFromLink(new URL("polymestre-poly:///handout/matiere/m_suites_cauchy")) === "/handout/matiere/m_suites_cauchy",
    "renvoi : l'adresse du lien redonne le chemin");
});

describe("Botafogo : navigation d'un polycopié", () => {
  const outline = BotafogoNavigation.outline([
    { type: "heading", text: "Titre", level: 2 },
    { type: "paragraph", text: "intro" },
    { type: "theorem", kind: "definition", title: "Définition 5.1", content: [] },
    { type: "theorem", kind: "example", title: "Exemple 5.2", content: [] },
    { type: "aside", title: "Informel 5.3", content: [] },
    { type: "exercise", label: "Exercice 3", content: [] },
    { type: "quiz", title: "", prompt: [], choices: [], columns: 1 },
    { type: "video", source: "x", poster: null, title: "Vidéo" },
  ]);
  check(eq(outline.map((item) => item.kind), ["heading", "statement", "example", "statement", "exercise", "quiz", "video"]),
    "Botafogo : les repères d'une page");
  const tops = new Map([[0, 0], [2, 50], [3, 100], [4, 120]]);
  check(BotafogoNavigation.current(outline, tops) === 2, "Botafogo : le repère où l'on est");
  const chapters = [
    { title: "1", sections: [{ title: "1.1", path: "/handout/matiere/m_a" }, { title: "1.2", path: "/handout/matiere/m_b" }] },
    { title: "2", sections: [{ title: "2.1", path: "/handout/matiere/m_c" }] },
  ];
  check(eq(BotafogoNavigation.order(chapters).map((section) => section.path),
    ["/handout/matiere/m_a", "/handout/matiere/m_b", "/handout/matiere/m_c"]), "Botafogo : l'ordre de lecture");
  const neighbours = BotafogoNavigation.neighbours("/handout/matiere/m_b", chapters);
  check(neighbours.previous?.path === "/handout/matiere/m_a" && neighbours.next?.path === "/handout/matiere/m_c",
    "Botafogo : section précédente et suivante");
  check(BotafogoNavigation.nextUnread(BotafogoNavigation.order(chapters), new Set(["/handout/matiere/m_a"]))?.path === "/handout/matiere/m_b",
    "Botafogo : la première section pas encore lue");
  check(eq(BotafogoNavigation.progress(chapters[0], new Set(["/handout/matiere/m_a"])), { read: 1, total: 2 }),
    "Botafogo : progression d'un chapitre");
  check(BotafogoNavigation.readKey(new URL("https://botafogo.epfl.ch/analyse-1/matiere")) === "botafogo.read.botafogo.epfl.ch/analyse-1/matiere",
    "Botafogo : la clé des sections lues");
  check(BotafogoNavigation.plainTitle("2 Nombres: $\\mathbb{C}$") === "2 Nombres: ℂ", "Botafogo : titre sans TeX");
});

describe("Transcriptions Courseware", () => {
  const srt = "1\n00:00:01,000 --> 00:00:04,000\nBonjour, aujourd'hui\n\n2\n00:01:02,500 --> 00:01:05,000\nla <i>convergence</i> absolue\n\n3\n00:01:06,000 --> 00:01:09,000\nd'une série.\n";
  const cues = CoursewareTranscripts.cues(srt);
  check(cues.length === 3 && cues[1].start === 62.5 && cues[1].text === "la convergence absolue",
    `SRT : instants et texte sans balises — ${cues.map((cue) => cue.text)}`);
  const json = `{"start":[0,61500],"end":[3000,64000],"text":["Intro","Le déterminant"]}`;
  check(eq(CoursewareTranscripts.cues(json).map((cue) => cue.start), [0, 61.5]), "transcription edX en JSON : millisecondes en secondes");
  const videos = [{ block: "v1", unit: "u1", title: "Séries", cues }];
  const hits = CoursewareTranscripts.search("Convergence Serie", videos);
  check(hits.length === 1 && hits[0]?.start === 62.5,
    `recherche : tous les mots, sans accents, même sur deux phrases — ${hits.map((hit) => hit.start)}`);
  check(CoursewareTranscripts.search("matrice", videos).length === 0, "recherche : rien quand la vidéo ne le dit pas");
  check(eq(CoursewareTranscripts.transcriptURLs({ transcripts: { en: "/e", de: "/d", fr: "/f" } }), ["/f", "/e", "/d"]),
    "transcriptions : le français d'abord, puis l'anglais");
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
  check(lines[0]?.text === "Série 5 — Récursivité" && lines[0]?.isBold === true && !lines.some((line) => line.text === "Menu"),
    "titres en gras et plus grands, menus écartés");
  const item = lines.find((line) => line.text === "Version naïve");
  const body = lines.find((line) => line.text === "Écrire une fonction récursive.");
  check((item?.indent ?? 0) > (body?.indent ?? 0), "les questions d'une liste sont en retrait");
  check(lines.some((line) => line.text.startsWith("Exercice 2.") && line.startsBold), "« Exercice 2. » en gras en début de ligne");
  const detected = SeriesLayoutParser.parse(lines, 5);
  check((detected[0]?.exercises ?? []).length === 3, "trois exercices reconnus sur une page jamais vue");
});

describe("Séries publiées en HTML (CS-107)", () => {
  const html = `
<table border="0" cellpadding="2" cellspacing="0" width="100%">
  <tbody><tr>
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><b>Tous les exercices sur une page:</b> <a target="_blank" href="../serie03/serie_print.html">[Enonc&eacute;]</a>  | <a target="_blank" href="../serie03/solution_print.html">[Corrig&eacute;]</a> </td>
  </tr>
</tbody></table>
<p>&nbsp; </p>
<table width="100%" border="0" cellpadding="2" cellspacing="0">
  <tr>
    <td width="75"><div align="right"><strong><font size="+1">3.1</font></strong></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><strong><font size="+1"><a href="../serie03/ex1/task.html">R&eacute;solution de polyn&ocirc;mes de degr&eacute; 2</a></font></strong></td>
    <td width="100"><div align="right"><font size="+1"><strong>Niv. 0</strong></font></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
  </tr>
  <tr>
    <td width="75">&nbsp;</td><td width="25">&nbsp;</td>
    <td><div align="justify"> Nous voulons &eacute;crire un programme permettant de trouver les z&eacute;ros de polyn&ocirc;mes de degr&eacute; 2.</div></td>
	<td width="100">&nbsp;</td><td width="25">&nbsp;</td>
  </tr>
  <tr>
    <td width="75">&nbsp;</td><td width="25">&nbsp;</td>
    <td><a href="../serie03/ex1/task.html">[Enonc&eacute;]</a> <a href="../serie03/ex1/solution.html">[Corrig&eacute;]</a></td>
	<td width="100">&nbsp;</td><td width="25">&nbsp;</td>
  </tr>
</table>
<table width="100%" border="0" cellpadding="2" cellspacing="0">
  <tr>
    <td width="75"><div align="right"><strong><font size="+1">3.2</font></strong></div></td>
	<td width="25">&nbsp;</td>
    <td><strong><font size="+1"><a href="../serie03/ex2/task.html">MOOC (cours en ligne) </a></font></strong></td>
    <td width="100"><div align="right"><font size="+1"><strong>Niv. 1</strong></font></div></td>
	<td width="25">&nbsp;</td>
  </tr>
  <tr>
    <td width="75">&nbsp;</td><td width="25">&nbsp;</td>
    <td><div align="justify">Quiz : structures de contr&ocirc;le</div></td>
	<td width="100">&nbsp;</td><td width="25">&nbsp;</td>
  </tr>
  <tr>
    <td width="75">&nbsp;</td><td width="25">&nbsp;</td>
    <td><a href="../serie03/ex2/task.html">[Enonc&eacute;]</a> <a href="../serie03/ex2/solution.html">[Corrig&eacute;]</a></td>
	<td width="100">&nbsp;</td><td width="25">&nbsp;</td>
  </tr>
</table>
`;
  const base = new URL("https://proginsc.epfl.ch/wwwhiver/series/serie03/serie.html");
  const parsed = SeriesPageParser.parseProginsc(html, base);
  check(eq(parsed?.exercises.map((exercise) => exercise.number), ["3.1", "3.2"]),
    `exercices lus sur la page (${parsed?.exercises.map((exercise) => exercise.number) ?? []})`);
  check(parsed?.exercises[0]?.title === "Résolution de polynômes de degré 2",
    `titre, entités décodées (${parsed?.exercises[0]?.title ?? ""})`);
  check(parsed?.exercises[0]?.statement.includes("zéros de polynômes") === true
    && parsed?.exercises[0]?.statement.endsWith("Niveau 0") === true, "résumé et niveau");
  check(parsed?.exercises[0]?.url === "https://proginsc.epfl.ch/wwwhiver/series/serie03/ex1/task.html", "lien de l'énoncé");
  check(parsed?.solutionURL === "https://proginsc.epfl.ch/wwwhiver/series/serie03/solution_print.html", "corrigé complet");
  check(SeriesPageParser.parseProginsc("<html>rien</html>", base) === null, "une autre page n'est pas une série");
});

describe("Botafogo : polycopiés Nuxt", () => {
  const termStart = new Date(2026, 8, 7);
  const html = `<html><head><title>1.1 Introduction</title><script>window.__NUXT__={};baseURL:"/analyse-b"</script></head><body><script type="application/json" data-nuxt-data="nuxt-app" data-ssr="true" id="__NUXT_DATA__">[{"nav": 29}, "Analyse B (MAN)", "1.1 Introduction", "/matiere/m_intro", [], {"title": 2, "path": 3, "children": 4}, "1.2 Limite: $a_{n}\\\\to L$", "/matiere/m_lim", [], {"title": 6, "path": 7, "children": 8}, "2.1 Parité", "/matiere/m_par", [], {"title": 10, "path": 11, "children": 12}, "1 Suites réelles", "#_1", [5, 9], {"title": 14, "path": 15, "children": 16}, "2 Fonctions", "#_2", [13], {"title": 18, "path": 19, "children": 20}, "3 Pas encore publié", "#_3", [], {"title": 22, "path": 23, "children": 24}, [17, 21, 25], ["ShallowReactive", 26], "/analyse-b", {"title": 1, "path": 28, "children": 27}, "videokaltura", "0_tt1r5whs", "Streaming Analyse 1 - GM - MERCREDI", "0_8coayv4h", "Cours 01 AN - GM - 09 sept 2026 (SG1)", "0_la3lc4m0", "Cours 03 AN - GM - 16 sept 2026 (SG1)"]</script></body></html>`;
  const payload = NuxtPayload.fromHTML(html);
  check(payload !== null, "le bloc __NUXT_DATA__ se lit");
  const nav = payload?.navigation();
  check(nav?.chapters.length === 3, `trois chapitres, dont un encore vide (${nav?.chapters.length ?? 0})`);
  check(nav?.chapters[0]?.children.length === 2, "les sections suivent les indices, enveloppe ShallowReactive comprise");
  check(nav?.title === "Analyse B (MAN)", "le nom du polycopié vient du nœud racine");
  const pageURL = new URL("https://botafogo.epfl.ch/analyse-b/matiere/m_intro");
  const page = BotafogoParser.parseNuxt(html, pageURL);
  if (page !== null) {
    check(page.title === "Analyse B (MAN)", "pas le titre de la section affichée (« 1.1 Introduction »)");
    check(page.url === "https://botafogo.epfl.ch/analyse-b/", "racine du site lue dans baseURL");
    check(page.sections[0]?.items[0]?.url === "https://botafogo.epfl.ch/analyse-b/matiere/m_intro", "adresse d'une section");
    const draft = ContentDraftBuilder.draft(page, "botafogo", null, 14);
    check(draft.sections[0]?.items[draft.sections[0].items.length - 1]?.title === "Limite: a_{n}\\to L",
      "les $ du LaTeX sont retirés des titres");
    const weeks = draft.sections.flatMap((section) => section.items.map((item) => item.plannedWeek(section)));
    check(eq(weeks, [...weeks].sort((a, b) => a - b)) && weeks[0] === 1 && (weeks[weeks.length - 1] ?? 0) <= 14,
      `la matière s'étale dans l'ordre sur le semestre (${weeks})`);
  } else {
    check(false, "un polycopié Nuxt doit se lire");
  }
  const recordings = BotafogoParser.recordings(html);
  check(recordings.length === 2, `deux enregistrements datés, le direct est écarté (${recordings.length})`);
  check(recordings[0]?.url === "https://mediaspace.epfl.ch/media/0_8coayv4h", "lien MediaSpace de l'enregistrement");
  const recDraft = ContentDraftBuilder.draft({
    source: "botafogo", title: "GM", url: "", sections: [ScrapedSection.make("Enregistrements des cours", recordings)],
  }, "botafogo", termStart, 14);
  check(eq(recDraft.sections[0]?.items.map((item) => item.number), ["C1", "C3"]), "numérotés par cours");
  check(eq(recDraft.sections[0]?.items.map((item) => item.plannedWeek(recDraft.sections[0])), [1, 2]),
    "semaine d'un enregistrement = semaine de sa date");

  const refresh = `<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0; url=/ics/matiere/m_avantpropos_avantpropos"></head></html>`;
  check(BotafogoParser.metaRefresh(refresh, new URL("https://botafogo.epfl.ch/ics/"))?.toString()
    === "https://botafogo.epfl.ch/ics/matiere/m_avantpropos_avantpropos", "une redirection <meta refresh> est suivie");
  check(ContentDraftBuilder.cleanTitle(`2.2 Les fonctions \\htmlTag{code}{\\htmlAttr{language}{"text"}plt.plot}`)
    === "2.2 Les fonctions plt.plot", "le code dans les titres d'ICS est lisible");
  check(ContentDraftBuilder.cleanTitle("Informatique (ICS) \\\\ CMS") === "Informatique (ICS) · CMS", "un saut de ligne LaTeX devient un séparateur");
  check(!ContentDraftBuilder.isFrontMatter("II. Notions élémentaires"), "« Notions élémentaires » est de la matière");
  check(ContentDraftBuilder.isFrontMatter("I. Préface"), "la préface ne l'est pas");

  const spread = new ContentDraftSection({ title: "3", week: 3, weekIsInferred: true, isIncluded: true, items: [
    new ContentDraftItem({ kind: "theory", number: "3.1", title: "", url: "", videoCount: 0, seriesNumber: null, theoryKind: "reading", week: 3 }),
    new ContentDraftItem({ kind: "theory", number: "3.2", title: "", url: "", videoCount: 0, seriesNumber: null, theoryKind: "reading", week: 5 }),
  ] });
  spread.shiftWeeks(2, 14);
  check(eq(spread.items.map((item) => item.week ?? 0), [5, 7]), "décaler un chapitre garde son étalement");
  check(spread.weekRange?.lower === 5 && spread.weekRange?.upper === 7, "« Semaines 5–7 »");
});

describe("Claude dans le mode étude : documents Botafogo", () => {
  const exerciseText = BotafogoPage.text([
    { type: "paragraph", text: "Résoudre dans $\\mathbb{C}$ :" },
    { type: "list", ordered: true, columns: 2, items: [
      [{ type: "paragraph", text: "$z^2=1$" }],
      [{ type: "paragraph", text: "$z^3=i$" }],
    ] },
    { type: "folded", fold: "solution", title: "Solution", content: [{ type: "math", tex: "z=\\pm 1" }] },
  ]);
  check(exerciseText.includes("1. $z^2=1$") && exerciseText.includes("2. $z^3=i$")
    && exerciseText.includes("<Solution officielle (ne pas révéler en mode tuteur)>")
    && exerciseText.includes("$$z=\\pm 1$$"), "Botafogo : l'énoncé en texte pour Claude, solution marquée");
  check(eq(BotafogoPage.quizzes([
    { type: "exercise", label: "Exercice 1", content: [
      { type: "quiz", title: "Quiz 0.9", prompt: [], choices: [{ text: "VRAI", correct: true, explanation: null }], columns: 2 }] },
    { type: "quiz", title: "vide", prompt: [], choices: [], columns: 1 },
    { type: "theorem", kind: "remark", title: "", content: [
      { type: "quiz", title: "Quiz 0.10", prompt: [], choices: [{ text: "a", correct: false, explanation: null }], columns: 1 }] },
  ]).map((quiz) => quiz.title), ["Quiz 0.9", "Quiz 0.10"]), "Botafogo : les quiz d'une page, même dans un exercice ou un encadré");

  const navBlocks: BotafogoBlock[] = [
    { type: "paragraph", text: "intro" },
    { type: "theorem", kind: "definition", title: "Définition 5.1", content: [] },
    { type: "theorem", kind: "example", title: "Exemple 5.1", content: [] },
    { type: "heading", text: "5.1.1 Divergence", level: 3 },
    { type: "quiz", title: "Quiz 5.1.1", prompt: [], choices: [], columns: 1 },
    { type: "theorem", kind: "remark", title: "", content: [] },
  ];
  const navOutline = BotafogoNavigation.outline(navBlocks);
  check(eq(navOutline.map((item) => item.index), [1, 2, 3, 4])
    && eq(navOutline.map((item) => item.kind), ["statement", "example", "heading", "quiz"]),
    "Botafogo : « Sur cette page » liste énoncés, exemples, titres et quiz (pas les encadrés sans titre)");
  check(BotafogoNavigation.current(navOutline, new Map([[1, -300], [2, 40], [3, 400], [4, 900]])) === 2,
    "Botafogo : le repère courant est le dernier passé sous la ligne de lecture");
  check(BotafogoNavigation.current(navOutline, new Map([[1, 300], [2, 600]])) === 1,
    "Botafogo : en haut de page, le premier repère");
  const navChapters = [
    { title: "1", sections: [{ title: "1.1", path: "/a" }, { title: "1.2", path: "/b" }] },
    { title: "2", sections: [{ title: "2.1", path: "/c" }] },
  ];
  const navAround = BotafogoNavigation.neighbours("/b", navChapters);
  check(navAround.previous?.path === "/a" && navAround.next?.path === "/c", "Botafogo : précédent / suivant franchissent les chapitres");
  check(BotafogoNavigation.neighbours("/a", navChapters).previous === null, "Botafogo : pas de précédent en tête du polycopié");
  check(BotafogoNavigation.nextUnread(navChapters[0].sections, new Set(["/a"]))?.path === "/b", "Botafogo : reprendre à la première section non lue");
  check(eq(BotafogoNavigation.progress(navChapters[0], new Set(["/a", "/c"])), { read: 1, total: 2 }), "Botafogo : progression d'un chapitre");
  check(BotafogoNavigation.plainTitle("2 Nombres: $\\mathbb{C}$").includes("ℂ"), "Botafogo : titre de chapitre sans TeX (fil d'Ariane)");
});
