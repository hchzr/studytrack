// Courseware (Open edX) lu dans l'app (CourseSiteClients.swift › CoursewareClient) : le plan
// complet d'un cours (chapitres, séquences, unités, blocs avec leurs vidéos), le HTML d'un
// bloc, un problème et sa vérification, l'achèvement d'une vidéo. Les requêtes portent la
// session de la fenêtre de connexion (`siteRequest`, côté Rust) ; les scripts du Mac sont ici
// la même logique en TypeScript.

import { Institution } from "../domain/institution.ts";
import { EdXOutline, EdXProblem, type EdXProblemResult } from "../domain/siteContent.ts";
import { callNativeOrThrow } from "../native/tauri.ts";
import { SiteError, openSiteLogin, parseHTML, siteRequest } from "./siteSession.ts";

const base = (): string => Institution.current.coursewareBase;

export async function coursewareSignIn(): Promise<void> {
  await openSiteLogin("courseware", base() + "/login", `Connexion à Courseware`);
}

async function getJSON(path: string): Promise<string | null> {
  const response = await siteRequest(base() + path, { headers: { Accept: "application/json" }, timeout: 30 });
  if (response.status === 401 || response.status === 403 || /\/login/.test(new URL(response.url).pathname)) return null;
  return response.status >= 200 && response.status < 300 ? response.body : null;
}

const outlines = new Map<string, EdXOutline>();

export const Courseware = {
  async outline(key: string): Promise<EdXOutline> {
    const cached = outlines.get(key);
    if (cached) return cached;
    const meText = await getJSON("/api/user/v1/me");
    if (!meText) throw new SiteError("notSignedIn");
    const me = JSON.parse(meText) as { username?: string };
    const tree = await getJSON(`/api/courses/v2/blocks/?course_id=${encodeURIComponent(key)}&username=${encodeURIComponent(me.username ?? "")}`
      + "&depth=all&requested_fields=children,display_name,type,student_view_url,student_view_data,completion&student_view_data=video");
    const outline = tree ? EdXOutline.parse(tree) : null;
    if (!outline) throw new SiteError("failed", "Plan du cours illisible.");
    outlines.set(key, outline);
    return outline;
  },

  /** Le HTML d'un bloc seul (`student_view_url`). */
  async blockHTML(address: string): Promise<string> {
    const response = await siteRequest(new URL(address, base()).toString(), { timeout: 30 });
    if (/\/login/.test(new URL(response.url).pathname)) throw new SiteError("notSignedIn");
    return response.status < 300 ? response.body : "";
  },

  /** Un problème prêt à répondre ; `null` si le bloc n'en est pas un. */
  async problem(address: string): Promise<EdXProblem | null> {
    const response = await siteRequest(new URL(address, base()).toString(), { timeout: 30 });
    const doc = parseHTML(response.body);
    const wrapper = doc.querySelector(".problems-wrapper");
    if (!wrapper) return null;
    const inner = parseHTML(wrapper.getAttribute("data-content") ?? "");
    const problem = inner.querySelector(".problem") ?? inner.body;
    const groups: Record<string, { name: string; type: string; options: { value: string; label: string; checked?: boolean }[]; value?: string }> = {};
    problem.querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>("input, select, textarea").forEach((input) => {
      const type = input.tagName === "SELECT" ? "select" : (input as HTMLInputElement).type || "text";
      if (type === "hidden" || !input.name) return;
      const group = groups[input.name] ?? (groups[input.name] = { name: input.name, type, options: [] });
      if (input.tagName === "SELECT") {
        [...(input as HTMLSelectElement).options].forEach((option) => { if (option.value) group.options.push({ value: option.value, label: option.textContent?.trim() ?? "" }); });
      } else if (type === "checkbox" || type === "radio") {
        const label = input.closest("label") ?? inner.querySelector(`label[for="${input.id}"]`);
        group.options.push({ value: input.value, label: label ? label.innerHTML : input.value, checked: (input as HTMLInputElement).checked });
      } else {
        group.value = input.value || "";
      }
    });
    const copy = problem.cloneNode(true) as Element;
    copy.querySelectorAll("input, select, textarea, label, .action, .notification, .problem-action-buttons-wrapper, .submission-feedback, .sr, script, .indicator-container, .status, .solution-span, .problem-hint")
      .forEach((element) => element.remove());
    copy.querySelectorAll("[src]").forEach((element) => {
      try { element.setAttribute("src", new URL(element.getAttribute("src") ?? "", response.url).href); } catch { /* telle quelle */ }
    });
    const title = inner.querySelector(".problem-header, h3")?.textContent?.trim() ?? "";
    return EdXProblem.decode(JSON.stringify({
      url: new URL(wrapper.getAttribute("data-url") ?? "", response.url).href, title, prompt: copy.innerHTML, groups: Object.values(groups),
      score: Number(wrapper.getAttribute("data-problem-score") || 0), total: Number(wrapper.getAttribute("data-problem-total-possible") || 0),
      attempts: Number(wrapper.getAttribute("data-attempts-used") || 0),
    }));
  },

  async check(problem: EdXProblem, answers: Record<string, string[]>): Promise<EdXProblemResult | null> {
    const csrf = await callNativeOrThrow<string | null>("site_cookie", { url: base() + "/", name: "csrftoken" });
    const response = await siteRequest(problem.url + "/problem_check", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8", "X-CSRFToken": csrf ?? "",
        "X-Requested-With": "XMLHttpRequest", Referer: base() + "/",
      },
      body: EdXProblem.formBody(answers),
    });
    return EdXProblem.result(response.body);
  },

  /** Une vidéo regardée dans l'app compte aussi sur Courseware. */
  async complete(block: string, key: string): Promise<void> {
    try {
      const csrf = await callNativeOrThrow<string | null>("site_cookie", { url: base() + "/", name: "csrftoken" });
      await siteRequest(`${base()}/courses/${key}/xblock/${block}/handler/publish_completion`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRFToken": csrf ?? "", "X-Requested-With": "XMLHttpRequest", Referer: base() + "/" },
        body: JSON.stringify({ completion: 1.0 }),
      });
    } catch {
      // L'avancement sur le site ne bloque rien ici.
    }
  },
};
