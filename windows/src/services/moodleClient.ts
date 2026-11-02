// Moodle, par les appels AJAX de ses propres pages (StudyTrack/Services/
// CourseSiteClients.swift › MoodleClient).
//
// Vérifié côté Mac sur moodle.epfl.ch (Moodle 4.5) :
//   • `core_course_search_courses` répond **sans connexion** — l'app trouve le cours
//     Moodle d'un code (MATH-101) sans rien demander ;
//   • `core_course_get_enrolled_courses_by_timeline_classification` dit à quels cours
//     on est inscrit·e, une fois connecté·e ;
//   • `core_courseformat_get_state` rend le plan du cours en JSON.
//
// Différence avec le Mac : les scripts que le navigateur invisible exécutait dans la
// page (`fetch` + `DOMParser`) sont ici écrits en TypeScript, au-dessus de
// `siteRequest` (session de la fenêtre de connexion) ; la logique, les sélecteurs et
// les limites (400 activités, lots de 18, six à la fois) sont les mêmes.
// Pas portés : `CourseEvidence.peekTargets` (ouvrir les cibles externes), les liens MOOC
// des pages Moodle, `activity`/`coursePage`/`discussion` du mode étude.

import { Institution } from "../domain/institution.ts";
import {
  ContentLink, MoodleCourseAnalyzer, MoodleCourseSnapshot, MoodleFolderExpander, MoodleSection,
  MoocReference, type ContentLinkKind,
} from "../domain/moodleCourseAnalyzer.ts";
import { MoodleCourseMatcher, MoodleStateParser, type MoodleCourseRef } from "../domain/moodleImport.ts";
import { SiteError, openSiteLogin, parseHTML, siteRequest } from "./siteSession.ts";

/** Le nombre d'activités ouvertes par cours, au plus. */
export const openLimit = 400;

export const MOODLE_LOGIN_LABEL = "moodle";

/** La nature d'une adresse, sans l'ouvrir : un MOOC Open edX, une vidéo, un PDF (`CourseEvidence.linkKind`). */
export function linkKind(address: string): ContentLinkKind {
  const lower = address.toLowerCase();
  if (/(mediaspace|youtube\.com|youtu\.be|vimeo|tube\.switch|kaltura|\/video\/|\.mp4)/.test(lower)) return "video";
  let pathname = "";
  try { pathname = new URL(address).pathname.toLowerCase(); } catch { /* adresse illisible */ }
  if (pathname.endsWith(".pdf") || lower.includes("pluginfile.php")) return "pdf";
  return "page";
}

function home(): string { return `${Institution.current.moodleBase}/my/`; }
function login(): string { return `${Institution.current.moodleBase}/login/index.php`; }

/** Les extraits que `readActivities` rend pour une activité ouverte. */
export interface Found {
  target?: string;
  solution?: string;
  dates?: string;
  kind?: string;
  preview?: string;
  files?: { title: string; url: string }[];
}

const SOLUTION = /(corrig|solution|\bsol\b|_sol\b|-sol\b|loesung|answers?\b|reponses|réponses)/i;
const isDocument = (href: string) => /\/pluginfile\.php\//.test(href) || /\.pdf($|[?#])/i.test(href);
const squash = (text: string) => text.replace(/\s+/g, " ").trim();

export class MoodleClient {
  /** Le client des lectures **en arrière-plan** : une seule session pour toutes. */
  static readonly background = new MoodleClient();

  private sesskey: string | null = null;

  static get home(): string { return home(); }
  static get login(): string { return login(); }

  /** Ouvre la fenêtre de connexion (Tequila / Microsoft, selon l'école) — une seule fois. */
  static async openLogin(): Promise<void> {
    await openSiteLogin(MOODLE_LOGIN_LABEL, login(), `Connexion à ${Institution.current.name}`);
  }

  /** Charge le tableau de bord, une fois : c'est lui qui porte la clé de session. */
  async prepare(force = false): Promise<void> {
    if (this.sesskey !== null && !force) return;
    const page = await siteRequest(home());
    const key = /"sesskey"\s*:\s*"([^"]+)"/.exec(page.body);
    this.sesskey = key ? key[1] : null;
    this.lastPage = page;
  }
  private lastPage: { url: string; body: string } | null = null;

  /**
   * Connecté·e ? (le menu de l'utilisateur n'existe qu'une fois connecté·e ; un
   * visiteur anonyme a une clé de session, mais pas de menu.)
   */
  async isSignedIn(): Promise<boolean> {
    try {
      await this.prepare(true);
      const page = this.lastPage;
      if (!page) return false;
      const doc = parseHTML(page.body);
      const user = doc.querySelector("#user-menu-toggle, .usermenu .userbutton") !== null;
      const onLogin = new URL(page.url).pathname.startsWith("/login");
      return user && !onLogin;
    } catch {
      return false;
    }
  }

  /** Les cours Moodle dont le nom contient `query` (« MATH-101 »). */
  async search(query: string): Promise<MoodleCourseRef[]> {
    const json = await this.call("core_course_search_courses", { criterianame: "search", criteriavalue: query, page: 0, perpage: 30 });
    return MoodleStateParser.courses(json);
  }

  /**
   * Les cours où l'on est inscrit·e (vide sans connexion). `classification` : `all`
   * (défaut), ou `inprogress` — les cours du semestre en cours seulement.
   */
  async enrolled(classification = "all"): Promise<MoodleCourseRef[]> {
    const json = await this.call("core_course_get_enrolled_courses_by_timeline_classification",
      { offset: 0, limit: 0, classification, sort: "fullname" });
    return MoodleStateParser.courses(json);
  }

  /** Le cours Moodle d'un cours de l'app. */
  async resolve(code: string, enrolled: MoodleCourseRef[]): Promise<ReturnType<typeof MoodleCourseMatcher.match>> {
    const found = await this.search(MoodleCourseMatcher.baseCode(code));
    return MoodleCourseMatcher.match(code, found, enrolled);
  }

  /**
   * Le cours tel qu'un·e étudiant·e le lit : chaque activité, **où elle mène vraiment**
   * et, pour un devoir, son échéance. Ni la cible d'un lien ni l'échéance ne sont dans
   * le plan : elles sont sur la page de l'activité. On lit ces pages dans la session,
   * six à la fois — c'est ce que ferait l'étudiant·e en cliquant.
   */
  async snapshot(course: MoodleCourseRef, on: {
    outline?: (sections: number[]) => void;
    activities?: (done: number, total: number) => void;
    sections?: (sections: MoodleSection[]) => void;
    opened?: (labels: Record<string, string>) => void;
    signal?: AbortSignal;
  } = {}): Promise<MoodleCourseSnapshot> {
    const json = await this.call("core_courseformat_get_state", { courseid: course.id });
    const state = decodeString(json);
    const snapshot = MoodleStateParser.snapshot(state, `${course.fullname} (${course.shortname})`, course.url.href);
    if (snapshot === null) throw new SiteError("failed", "Cette page ne contient rien d'importable.");
    const shown = snapshot.sections.filter((section) => section.activities.length > 0);
    on.outline?.(shown.map((section) => section.number));
    on.sections?.(shown);
    const openable = snapshot.sections.flatMap((section) => section.activities)
      .filter((activity) => activity.isVisible && ["url", "assign", "resource", "page", "folder"].includes(activity.module));
    // Au-delà de 400, les dernières activités ne sont pas ouvertes (le cours le dit).
    snapshot.unopened = Math.max(0, openable.length - openLimit);
    const wanted = openable.slice(0, openLimit).map((activity) => ({ id: activity.id, module: activity.module }));
    // La page du cours, lue une fois : texte et liens des sections, et les liens Courseware.
    snapshot.moocLinks = await this.addSectionTexts(course.id, snapshot);
    if (wanted.length === 0) return snapshot;
    // Par lots de 18 (trois vagues de six) : l'accueil voit avancer le compteur.
    on.activities?.(0, wanted.length);
    const merged: Record<string, Found> = {};
    for (let start = 0; start < wanted.length; start += 18) {
      if (on.signal?.aborted) throw new SiteError("failed", "Lecture arrêtée.");
      const chunk = wanted.slice(start, start + 18);
      const part = await this.readActivities(chunk);
      Object.assign(merged, part);
      on.opened?.(Object.fromEntries(Object.entries(part).map(([id, found]) => [id, openedLabel(found)])));
      on.activities?.(Math.min(start + 18, wanted.length), wanted.length);
    }
    return this.finish(snapshot, merged);
  }

  /** Le plan seul (sections et activités), sans ouvrir chaque activité. */
  async outline(courseID: number, title = ""): Promise<MoodleCourseSnapshot> {
    const json = await this.call("core_courseformat_get_state", { courseid: courseID });
    const snapshot = MoodleStateParser.snapshot(decodeString(json), title, `${Institution.current.moodleBase}/course/view.php?id=${courseID}`);
    if (snapshot === null) throw new SiteError("failed", "Cette page ne contient rien d'importable.");
    return snapshot;
  }

  /** Ouvre un lot d'activités dans la session Moodle (`{id: trouvaille}`). */
  private async readActivities(items: { id: string; module: string }[]): Promise<Record<string, Found>> {
    const out: Record<string, Found> = {};
    const one = async (item: { id: string; module: string }) => {
      try {
        // `forceview=1` : la page « cliquez ici » d'un lien ou d'un fichier, sans la
        // redirection qu'on ne peut pas suivre hors de Moodle.
        const force = item.module === "url" || item.module === "resource" ? "&forceview=1" : "";
        const base = Institution.current.moodleBase;
        const response = await siteRequest(`${base}/mod/${item.module}/view.php?id=${item.id}${force}`);
        const type = response.contentType;
        const redirected = !response.url.includes(`/mod/${item.module}/view.php`);
        if (item.module === "resource" && /\/pluginfile\.php\//.test(response.url)) {
          out[item.id] = { target: response.url, kind: type.includes("pdf") ? "pdf" : "fichier" };
          return;
        }
        if (!type.includes("html")) {
          out[item.id] = { target: redirected ? response.url : "", kind: type.includes("pdf") ? "pdf" : "fichier" };
          return;
        }
        const doc = parseHTML(response.body);
        if (item.module === "assign") {
          const dates = doc.querySelector('[data-region="activity-dates"], .activity-dates');
          out[item.id] = { dates: dates?.textContent ?? "" };
          return;
        }
        const main = doc.querySelector("#region-main") ?? doc;
        const absolute = (href: string | null) => new URL(href ?? "", response.url).href;
        const work = main.querySelector(".urlworkaround a, .resourceworkaround a");
        if (work) { out[item.id] = { target: absolute(work.getAttribute("href")) }; return; }
        const embedded = main.querySelector('.resourcecontent iframe[src], .resourcecontent object[data], .resourcecontent embed[src], iframe[src*="pluginfile"], object[data*="pluginfile"]');
        if (embedded) { out[item.id] = { target: absolute(embedded.getAttribute("src") ?? embedded.getAttribute("data")) }; return; }
        const links = [...main.querySelectorAll("a[href]")].map((a) => ({ a, href: absolute(a.getAttribute("href")) }));
        const docs = links.filter((l) => isDocument(l.href));
        const textOf = (a: Element) => a.textContent ?? "";
        const statement = docs.find((l) => !SOLUTION.test(textOf(l.a) + " " + l.href));
        const solution = docs.find((l) => SOLUTION.test(textOf(l.a) + " " + l.href));
        const text = (main.querySelector('.box.generalbox, .no-overflow, [role="main"]') ?? main).textContent ?? "";
        const preview = squash(text).slice(0, 500);
        if (statement || solution) {
          // Un dossier (ou une page) peut porter **toutes** les séries : la liste
          // complète part avec, l'app la déplie en activités.
          const files = docs.slice(0, 80).map((l) => ({
            title: squash(textOf(l.a)) || safeDecode((l.href.split("?")[0].split("/").pop() ?? "")),
            url: l.href,
          }));
          out[item.id] = {
            target: (statement ?? solution)!.href,
            solution: statement && solution ? solution.href : "",
            kind: item.module === "folder" ? "dossier" : "pdf",
            preview: item.module === "page" ? preview : "",
            files: item.module === "folder" || item.module === "page" ? files : [],
          };
          return;
        }
        if (item.module === "url") {
          const hostName = Institution.current.moodleHostName;
          const external = [...main.querySelectorAll('a[href^="http"]')].find((a) => !(a.getAttribute("href") ?? "").includes(hostName));
          out[item.id] = { target: external ? absolute(external.getAttribute("href")) : "" };
          return;
        }
        out[item.id] = { kind: item.module === "folder" ? "dossier" : "page moodle", preview };
      } catch {
        out[item.id] = {};
      }
    };
    for (let i = 0; i < items.length; i += 6) await Promise.all(items.slice(i, i + 6).map(one));
    return out;
  }

  /** Range les trouvailles dans le plan : cibles, corrigés, échéances, dossiers. */
  private finish(input: MoodleCourseSnapshot, found: Record<string, Found>): MoodleCourseSnapshot {
    const snapshot = input;
    for (const section of snapshot.sections) {
      for (const activity of section.activities) {
        const info = found[activity.id];
        if (!info) continue;
        if (info.target && info.target.startsWith("http")) activity.target = info.target;
        if (info.solution && info.solution.startsWith("http")) activity.solutionTarget = info.solution;
        if (info.dates) {
          const due = MoodleCourseAnalyzer.dueDate(info.dates);
          if (due) activity.dueDate = due;
        }
        if (info.kind) activity.destination = info.kind;
        if (info.preview) activity.preview = info.preview;
      }
      // Les dossiers de plusieurs PDF, dépliés en un élément par fichier : chaque série
      // d'un dossier « Séries » devient visible et importable.
      section.activities = section.activities.flatMap((activity) => {
        const files = found[activity.id]?.files;
        if (activity.module !== "folder" || !files || files.length <= 1) return [activity];
        return MoodleFolderExpander.expand(activity, files.map((f) => ({ title: f.title, url: f.url })));
      });
    }
    return snapshot;
  }

  /**
   * Le texte de chaque section (résumé, étiquettes) et ses liens, lus sur la page du
   * cours : la consigne de la semaine y est souvent écrite (« regardez les vidéos du
   * module 2, la série est sur le site du cours »).
   */
  private async addSectionTexts(courseID: number, snapshot: MoodleCourseSnapshot): Promise<MoocReference[]> {
    let doc: Document;
    try {
      const response = await siteRequest(`${Institution.current.moodleBase}/course/view.php?id=${courseID}`);
      doc = parseHTML(response.body);
    } catch {
      return [];
    }
    const moodleHost = Institution.current.moodleHostName.replace(/\./g, "\\.");
    const skip = new RegExp(`${moodleHost}/(user|course/view|login)`);
    const mooc: MoocReference[] = [];
    const coursewareHost = Institution.current.coursewareHostName;
    doc.querySelectorAll(`a[href*="${coursewareHost}"]`).forEach((a) => {
      const holder = a.closest("[data-sectionnumber], [data-number], li.section");
      const n = holder && (holder.getAttribute("data-sectionnumber") ?? holder.getAttribute("data-number") ?? (holder.id || "").replace("section-", ""));
      const section = n !== null && n !== "" && !Number.isNaN(Number(n)) ? Number(n) : null;
      mooc.push(new MoocReference({ url: (a as HTMLAnchorElement).href, title: squash(a.textContent ?? ""), sectionNumber: section }));
    });
    doc.querySelectorAll('li.section[data-sectionnumber], li.section[data-number], [data-for="section"][data-number]').forEach((element) => {
      const n = Number(element.getAttribute("data-sectionnumber") ?? element.getAttribute("data-number"));
      if (Number.isNaN(n)) return;
      const parts: string[] = [];
      const links: ContentLink[] = [];
      element.querySelectorAll(".summarytext, .course-description-item, .activity.modtype_label .activity-altcontent, .activity.label .contentwithoutlink, .activity.modtype_label .no-overflow").forEach((holder) => {
        const text = squash(holder.textContent ?? "");
        if (text && !parts.includes(text)) parts.push(text);
        holder.querySelectorAll('a[href^="http"]').forEach((a) => {
          const href = (a as HTMLAnchorElement).getAttribute("href") ?? "";
          if (skip.test(href) || links.some((l) => l.url === href)) return;
          links.push({ url: href, title: squash(a.textContent ?? "").slice(0, 120), kind: linkKind(href) });
        });
      });
      const target = snapshot.sections.find((section) => section.number === n);
      if (!target) return;
      target.text = parts.join(" · ").slice(0, 2000);
      target.links = links.slice(0, 25);
    });
    const seen = new Set<string>();
    return mooc.filter((row) => MoocReference.courseKey(row.url) !== null && seen.add(`${row.url}|${row.sectionNumber ?? -1}`));
  }

  /**
   * Un appel AJAX. Rend le champ `data` en JSON, ou lève l'erreur de Moodle
   * (`requireloginerror` = pas connecté·e).
   */
  async call(method: string, args: Record<string, unknown>): Promise<string> {
    await this.prepare();
    if (this.sesskey === null) throw new SiteError("notSignedIn");
    const base = Institution.current.moodleBase;
    const response = await siteRequest(`${base}/lib/ajax/service.php?sesskey=${this.sesskey}&info=${method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify([{ index: 0, methodname: method, args }]),
    });
    let body: unknown;
    try { body = JSON.parse(response.body); } catch { throw new SiteError("notSignedIn"); }
    const first = (Array.isArray(body) ? body[0] : body) as { error?: boolean; data?: unknown; errorcode?: string; message?: string; exception?: { errorcode?: string; message?: string } } | undefined;
    if (!first || first.error) {
      const code = first?.errorcode ?? first?.exception?.errorcode ?? "inconnu";
      if (code === "requireloginerror" || code === "nosesskey") throw new SiteError("notSignedIn");
      throw new SiteError("failed", `Moodle : ${first?.message ?? first?.exception?.message ?? code}`);
    }
    const data = first.data;
    if (data === undefined) throw new SiteError("failed", "Réponse de Moodle illisible.");
    return JSON.stringify(data);
  }
}

/** `try? JSONDecoder().decode(String.self, …) ?? json` : le plan arrive parfois encodé en chaîne JSON. */
function decodeString(json: string): string {
  try {
    const value: unknown = JSON.parse(json);
    return typeof value === "string" ? value : json;
  } catch {
    return json;
  }
}

function safeDecode(text: string): string {
  try { return decodeURIComponent(text); } catch { return text; }
}

/** Ce qu'une activité ouverte s'est révélée être, pour l'accueil (`ImportFeed.openedLabel`). */
export function openedLabel(found: Found): string {
  if (found.dates && found.dates !== "") return "Devoir";
  const files = found.files?.length ?? 0;
  if (files > 1) return `Dossier · ${files} PDF`;
  const target = (found.target ?? "").toLowerCase();
  if (["mediaspace", "kaltura", "youtu", "switch.tube", "tube.switch"].some((needle) => target.includes(needle))) return "Vidéo";
  if (target.includes("courseware")) return "MOOC";
  switch (found.kind) {
    case "pdf": return "PDF";
    case "dossier": return "Dossier";
    case "fichier": return "Fichier";
    default: return target === "" ? "Page" : "Lien";
  }
}
