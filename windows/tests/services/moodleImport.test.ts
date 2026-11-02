// L'import de contenu depuis Moodle : l'appel AJAX, la nature des liens, ce que dit
// l'accueil d'une activité ouverte, et le rangement par le modèle (réponse gardée).
// Les lectures de pages (DOMParser) n'ont pas d'équivalent sous Node : elles se vérifient
// dans l'app. Aucun check de Validation/main.swift ne touche ces clients (réseau, WebKit).

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const requests: { url: string; init?: { method?: string; body?: string } }[] = [];
let handler: (url: string) => { status?: number; url?: string; contentType?: string; body: string } = () => ({ body: "" });

vi.mock("../../src/services/siteSession.ts", async (original) => {
  const actual = await original<typeof import("../../src/services/siteSession.ts")>();
  return {
    ...actual,
    siteRequest: async (url: string, init?: { method?: string; body?: string }) => {
      requests.push({ url, init });
      const reply = handler(url);
      return { status: reply.status ?? 200, url: reply.url ?? url, contentType: reply.contentType ?? "text/html", body: reply.body };
    },
  };
});

import { MoodleClient, linkKind, openedLabel } from "../../src/services/moodleClient.ts";
import { SiteError } from "../../src/services/siteSession.ts";
import { MoodleCourseAIService } from "../../src/services/moodleCourseAIService.ts";
import { MoodleCourseSnapshot, MoodleSection, MoodleActivity } from "../../src/domain/moodleCourseAnalyzer.ts";
import { ContentDraft, ContentDraftItem, ContentDraftSection } from "../../src/domain/courseContentImport.ts";
import { summaryLine } from "../../src/ui/screens/course/import/ContentDraftSections.tsx";
import { resetSharedVerdict } from "../../src/services/seriesAIExtractor.ts";

const dashboard = `<html><script>M.cfg = {"wwwroot":"https:\\/\\/moodle.epfl.ch","sesskey":"abc123"};</script></html>`;

beforeEach(() => {
  requests.length = 0;
  handler = (url) => (url.includes("/my/") ? { body: dashboard } : { body: "[]" });
});

describe("MoodleClient", () => {
  it("l'appel AJAX porte la clé de session et la méthode, et rend le champ data", async () => {
    handler = (url) => url.includes("/my/") ? { body: dashboard }
      : { body: JSON.stringify([{ error: false, data: { courses: [{ id: 15221, fullname: "Algorithms I", shortname: "CS-250(e)" }] } }]) };
    const client = new MoodleClient();
    const courses = await client.search("CS-250");
    expect(courses.map((c) => [c.id, c.shortname])).toEqual([[15221, "CS-250(e)"]]);
    const call = requests.find((r) => r.url.includes("service.php"))!;
    expect(call.url).toContain("sesskey=abc123");
    expect(call.url).toContain("info=core_course_search_courses");
    expect(JSON.parse(call.init!.body!)[0]).toMatchObject({ index: 0, methodname: "core_course_search_courses", args: { criteriavalue: "CS-250" } });
  });

  it("sans clé de session : pas connecté·e", async () => {
    handler = () => ({ body: "<html>login</html>" });
    await expect(new MoodleClient().call("x", {})).rejects.toMatchObject({ kind: "notSignedIn" });
  });

  it("une page de connexion à la place du JSON : pas connecté·e", async () => {
    handler = (url) => (url.includes("/my/") ? { body: dashboard } : { body: "<html>Se connecter</html>" });
    await expect(new MoodleClient().call("x", {})).rejects.toMatchObject({ kind: "notSignedIn" });
  });

  it("requireloginerror = pas connecté·e ; une autre erreur garde le message de Moodle", async () => {
    handler = (url) => (url.includes("/my/") ? { body: dashboard }
      : { body: JSON.stringify([{ error: true, exception: { errorcode: "requireloginerror", message: "x" } }]) });
    await expect(new MoodleClient().call("x", {})).rejects.toBeInstanceOf(SiteError);
    handler = (url) => (url.includes("/my/") ? { body: dashboard }
      : { body: JSON.stringify([{ error: true, errorcode: "invalidparameter", message: "Cours inconnu" }]) });
    await expect(new MoodleClient().call("x", {})).rejects.toThrow("Moodle : Cours inconnu");
  });

  it("une réponse en chaîne JSON (le plan du cours) reste une chaîne", async () => {
    handler = (url) => (url.includes("/my/") ? { body: dashboard } : { body: JSON.stringify([{ error: false, data: "{\"section\":[]}" }]) });
    expect(JSON.parse(await new MoodleClient().call("core_courseformat_get_state", { courseid: 1 }))).toBe("{\"section\":[]}");
  });
});

describe("liens et activités ouvertes", () => {
  it("la nature d'une adresse, sans l'ouvrir", () => {
    expect(linkKind("https://mediaspace.epfl.ch/media/abc")).toBe("video");
    expect(linkKind("https://youtu.be/xyz")).toBe("video");
    expect(linkKind("https://moodle.epfl.ch/pluginfile.php/1/mod_resource/content/0/serie.pdf")).toBe("pdf");
    expect(linkKind("https://exemple.ch/serie.PDF")).toBe("pdf");
    expect(linkKind("https://exemple.ch/page.html")).toBe("page");
  });

  it("l'accueil dit ce que chaque activité s'est révélée être", () => {
    expect(openedLabel({ dates: "Due: lundi" })).toBe("Devoir");
    expect(openedLabel({ files: [{ title: "a", url: "u" }, { title: "b", url: "v" }] })).toBe("Dossier · 2 PDF");
    expect(openedLabel({ target: "https://mediaspace.epfl.ch/x" })).toBe("Vidéo");
    expect(openedLabel({ target: "https://courseware.epfl.ch/course-v1:x" })).toBe("MOOC");
    expect(openedLabel({ kind: "pdf" })).toBe("PDF");
    expect(openedLabel({ target: "https://exemple.ch" })).toBe("Lien");
    expect(openedLabel({})).toBe("Page");
  });
});

describe("ContentDraft", () => {
  it("le résumé d'un brouillon en une ligne", () => {
    const empty = new ContentDraft({ source: "moodle", courseTitle: "", url: "", sections: [] });
    expect(summaryLine(empty)).toBe("rien de reconnaissable");
    const item = (kind: "theory" | "series") => new ContentDraftItem({ kind, number: "1", title: "t", url: "", videoCount: 2, seriesNumber: 1, theoryKind: "video" });
    const draft = new ContentDraft({
      source: "moodle", courseTitle: "CS-250", url: "",
      sections: [new ContentDraftSection({ title: "S1", week: 1, weekIsInferred: false, isIncluded: true, items: [item("theory"), item("series")] })],
    });
    expect(summaryLine(draft)).toBe("1 élément de théorie · 2 vidéos · 1 série");
  });
});

describe("MoodleCourseAIService", () => {
  const snapshot = new MoodleCourseSnapshot({
    title: "Algorithms I (CS-250)", url: "https://moodle.epfl.ch/course/view.php?id=1",
    sections: [new MoodleSection({ number: 1, title: "Semaine 1", activities: [
      new MoodleActivity({ id: "10", name: "Série 1", module: "assign", url: "https://moodle.epfl.ch/mod/assign/view.php?id=10" })] })],
  });
  const answer = JSON.stringify({ activities: [{ id: "10", kind: "series", week: 1, series: 1 }], weeks: [{ week: 1, todo: "Faire la série 1." }] });

  beforeEach(() => {
    resetSharedVerdict();
    vi.stubEnv("VITE_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon");
    const store = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); },
      removeItem: (k: string) => { store.delete(k); },
    });
  });
  afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });

  it("le modèle range le cours ; la réponse est gardée, une seconde demande ne rappelle pas le service", async () => {
    const fetchMock = vi.fn(async () => new Response(answer, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const first = await MoodleCourseAIService.analyze(snapshot, { termStart: null, totalWeeks: 14 });
    expect(first.hints["10"]).toMatchObject({ kind: "series", week: 1, seriesNumber: 1 });
    expect(first.guide[1]).toBe("Faire la série 1.");
    expect(String(fetchMock.mock.calls[0][0])).toBe("https://example.supabase.co/functions/v1/analyze-course");
    const second = await MoodleCourseAIService.analyze(snapshot, { termStart: null, totalWeeks: 14 });
    expect(second.hints["10"]).toMatchObject({ kind: "series" });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("le service indisponible : une réponse vide, l'import par règles continue", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("boom", { status: 500 })));
    const result = await MoodleCourseAIService.analyze(snapshot, { termStart: null, totalWeeks: 14 });
    expect(result.hints).toEqual({});
    expect(result.guide).toEqual({});
  });
});
