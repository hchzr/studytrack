// Moodle lu dans l'app, comme un·e étudiant·e le voit (CourseSiteClients.swift › MoodleClient
// .coursePage / .activity / .discussion) : la page du cours (sections, leur texte, activités,
// achèvement, semaine en cours), et chaque activité (page, dossier, devoir, lien, forum).
//
// Les scripts que le Mac exécute dans un navigateur invisible sont ici la même logique en
// TypeScript, au-dessus de `siteRequest` (les cookies de la fenêtre de connexion, côté Rust) et
// de `DOMParser`. Le JSON produit est celui du Mac : les décodeurs purs (`MoodleCoursePage`,
// `MoodleActivityContent`) sont partagés.

import { Institution } from "../domain/institution.ts";
import { MoodleActivityContent, MoodleCoursePage } from "../domain/siteContent.ts";
import { SiteError, parseHTML, siteRequest } from "./siteSession.ts";

const clean = (text: string | null | undefined): string => (text ?? "").replace(/\s+/g, " ").trim();

function base(): string {
  return Institution.current.moodleBase;
}

interface Loaded { url: string; doc: Document }

/** Une page Moodle, ses liens et images rendus absolus. */
async function load(path: string): Promise<Loaded> {
  const response = await siteRequest(base() + path, { timeout: 25 });
  const doc = parseHTML(response.body);
  absolutize(doc, response.url);
  return { url: response.url, doc };
}

function absolutize(root: ParentNode, pageURL: string): void {
  root.querySelectorAll("[href]").forEach((node) => {
    try { node.setAttribute("href", new URL(node.getAttribute("href") ?? "", pageURL).href); } catch { /* telle quelle */ }
  });
  root.querySelectorAll("[src]").forEach((node) => {
    try { node.setAttribute("src", new URL(node.getAttribute("src") ?? "", pageURL).href); } catch { /* idem */ }
  });
}

const isLogin = (page: Loaded): boolean => /\/(login|enrol)\//.test(page.url) || page.doc.querySelector("form#login, #login") !== null;

const titleOf = (doc: Document): string =>
  clean(doc.querySelector(".page-header-headings h1, #page-header h1, h1")?.textContent ?? doc.title);

function strip(node: Element | null): string {
  if (!node) return "";
  const copy = node.cloneNode(true) as Element;
  copy.querySelectorAll('.activity-header, .activity-information, .completion-info, [data-region="activity-information"], nav, .sr-only, .visually-hidden, .accesshide, script, style')
    .forEach((element) => element.remove());
  return copy.innerHTML;
}

function files(root: ParentNode | null): { name: string; url: string }[] {
  if (!root) return [];
  const all = [...root.querySelectorAll<HTMLAnchorElement>('a[href*="pluginfile.php"]')].map((a) => {
    const href = a.getAttribute("href") ?? "";
    let fallback = href;
    try { fallback = decodeURIComponent(href.split("/").pop()?.split("?")[0] ?? href); } catch { /* brut */ }
    return { name: clean(a.textContent) || fallback, url: href };
  });
  return all.filter((file, index) => all.findIndex((other) => other.url === file.url) === index);
}

const mainOf = (doc: Document): Element =>
  doc.querySelector('#region-main [role="main"], [role="main"], #region-main') ?? doc.body;

/** La page du cours ; lève `SiteError("notSignedIn")` si Moodle demande la connexion. */
export async function moodleCoursePage(courseID: number): Promise<MoodleCoursePage> {
  const page = await load(`/course/view.php?id=${courseID}`);
  if (isLogin(page)) throw new SiteError("notSignedIn");
  const doc = page.doc;
  const sectionNodes = [...doc.querySelectorAll("li.section, li.course-section")].filter((node) => !node.closest(".activity"));
  const sections = sectionNodes.map((section, i) => {
    const number = parseInt(section.getAttribute("data-number") ?? section.getAttribute("data-sectionid") ?? String(i), 10);
    const titleNode = section.querySelector("h3.sectionname a, h3.sectionname");
    const name = clean(section.getAttribute("data-sectionname") ?? (titleNode ? titleNode.textContent : section.getAttribute("aria-label")));
    const summaryNode = section.querySelector(":scope .summarytext, :scope > .content > .summary, :scope .course-description-item.summarytext");
    const summary = summaryNode ? (summaryNode.cloneNode(true) as Element).innerHTML : "";
    const activities = [...section.querySelectorAll("li.activity")]
      .filter((activity) => activity.closest("li.section, li.course-section") === section)
      .map((activity) => {
        const module = /modtype_(\w+)/.exec(activity.className)?.[1] ?? "";
        const id = parseInt((activity.id || "").replace("module-", "") || activity.getAttribute("data-id") || "0", 10);
        const link = activity.querySelector<HTMLAnchorElement>('a.aalink, a[href*="/mod/"]');
        let name = clean(activity.getAttribute("data-activityname") ?? activity.querySelector("[data-activityname]")?.getAttribute("data-activityname"));
        if (!name) {
          const node = activity.querySelector(".instancename");
          if (node) {
            const copy = node.cloneNode(true) as Element;
            copy.querySelectorAll(".accesshide, .sr-only, .visually-hidden").forEach((element) => element.remove());
            name = clean(copy.textContent);
          }
        }
        const body = activity.querySelector(".activity-altcontent, .contentwithoutlink, .activity-description, .description");
        const html = body ? (body.cloneNode(true) as Element).innerHTML : "";
        const dates = [...activity.querySelectorAll('[data-region="activity-dates"] div, .activity-dates div')]
          .map((node) => clean(node.textContent)).filter(Boolean);
        const toggle = activity.querySelector('[data-action="toggle-manual-completion"]');
        const completed = toggle ? toggle.getAttribute("data-toggletype") === "manual:undo"
          : /\b(Done|Terminé|Fait)\b/.test(clean(activity.querySelector('[data-region="completion-info"], .activity-completion')?.textContent));
        return { id, module, name, url: link?.getAttribute("href") ?? "", html, dates, completed };
      })
      .filter((activity) => activity.id && (activity.name || activity.html));
    return {
      number: Number.isNaN(number) ? i : number,
      title: name || (i === 0 ? "Général" : `Section ${i}`),
      summary,
      isCurrent: section.classList.contains("current"),
      activities,
    };
  });
  const decoded = MoodleCoursePage.decode(JSON.stringify({ title: titleOf(doc), sections }));
  if (!decoded) throw new SiteError("failed", "Page Moodle illisible.");
  return decoded;
}

/** Une activité (page, dossier, devoir, lien, forum…) ou une discussion (`module: "discussion"`). */
export async function moodleActivity(module: string, id: number): Promise<MoodleActivityContent> {
  const out: Record<string, unknown> = { module, title: "" };
  if (module === "discussion") {
    const page = await load(`/mod/forum/discuss.php?d=${id}`);
    if (isLogin(page)) throw new SiteError("notSignedIn");
    out.title = titleOf(page.doc);
    out.posts = [...page.doc.querySelectorAll('[data-region="post"], .forumpost')].map((post) => ({
      subject: clean(post.querySelector('[data-region-content="forum-post-core-subject"], h3, h4, .subject')?.textContent),
      author: clean(post.querySelector('[data-region="author-name"], .author a, .author')?.textContent),
      date: clean(post.querySelector("time")?.textContent),
      html: post.querySelector(".post-content-container, .posting, .content")?.innerHTML ?? "",
    })).filter((post) => post.html || post.subject);
    return decode(out);
  }
  const force = module === "url" || module === "resource" ? "&forceview=1" : "";
  const page = await load(`/mod/${module}/view.php?id=${id}${force}`);
  if (isLogin(page)) throw new SiteError("notSignedIn");
  const doc = page.doc;
  const host = new URL(base()).host;
  // Un lien qui part tout de suite ailleurs : sa cible, c'est l'adresse d'arrivée.
  if (module === "url" && new URL(page.url).host !== host) return decode({ module, title: "", target: page.url });
  const noticeOf = (d: Document) => clean(d.querySelector('.alert, .errorbox, #notice, [role="alert"], .availabilityinfo')?.textContent);
  if (!new RegExp(`/mod/${module}/`).test(new URL(page.url).pathname) || doc.querySelector('.errorbox, [data-rel="fatalerror"]')) {
    return decode({ module, title: "", unavailable: true, notice: noticeOf(doc) });
  }
  out.title = clean(doc.querySelector('[data-region="activity-header"] h2, .activity-header h2, [role="main"] h2')?.textContent) || titleOf(doc);
  const main = mainOf(doc);
  const intro = main.querySelector(".activity-description, #intro, .box.generalbox");
  if (module === "page") {
    out.html = strip(doc.querySelector('#region-main .box.generalbox:not(.activity-description), [role="main"] .generalbox, [role="main"] .no-overflow') ?? main);
    out.files = files(main);
  } else if (module === "folder") {
    out.html = strip(intro);
    out.files = files(doc.querySelector('.foldertree, .filemanager, [role="main"]') ?? doc.body);
  } else if (module === "assign") {
    out.html = strip(intro);
    out.dates = [...doc.querySelectorAll('[data-region="activity-dates"] > div, .activity-dates > div, .description-inner > div')]
      .map((node) => clean(node.textContent)).filter(Boolean);
    out.files = files(doc.querySelector('.activity-description, #intro, .introattachments, [role="main"]'));
    out.status = [...doc.querySelectorAll(".submissionstatustable tr, .generaltable.submissionsummarytable tr")].map((row) => {
      const th = row.querySelector("th");
      const td = row.querySelector("td");
      return th && td ? `${clean(th.textContent)} : ${clean(td.textContent)}` : "";
    }).filter(Boolean);
  } else if (module === "url") {
    const link = doc.querySelector<HTMLAnchorElement>(`.urlworkaround a, [role="main"] a[href]:not([href*="${host}"])`);
    out.target = link?.getAttribute("href") ?? "";
    out.html = strip(intro);
  } else if (module === "forum") {
    out.html = strip(intro);
    const seen = new Set<number>();
    out.discussions = [...doc.querySelectorAll('[data-region="discussion-list-item"], tr.discussion, a[href*="discuss.php?d="]')].map((node) => {
      const a = (node.matches("a") ? node : node.querySelector('a[href*="discuss.php?d="]')) as HTMLAnchorElement | null;
      if (!a) return null;
      const d = parseInt(/[?&]d=(\d+)/.exec(a.getAttribute("href") ?? "")?.[1] ?? "0", 10);
      if (!d || seen.has(d)) return null;
      seen.add(d);
      const row = a.closest('tr, [data-region="discussion-list-item"]') ?? a;
      return {
        id: d, title: clean(a.textContent) || "Discussion",
        author: clean(row.querySelector('.author-info .text-truncate, .author, [data-region="author-name"]')?.textContent),
        date: clean(row.querySelector('time, .lastpost, [data-region="last-post-date"]')?.textContent),
      };
    }).filter((d): d is { id: number; title: string; author: string; date: string } => d !== null && d.title.length > 1);
  } else {
    out.html = strip(main);
    out.files = files(main);
  }
  return decode(out);
}

function decode(raw: Record<string, unknown>): MoodleActivityContent {
  const content = MoodleActivityContent.decode(JSON.stringify(raw));
  if (!content) throw new SiteError("failed", "Page Moodle illisible.");
  return content;
}
