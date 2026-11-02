// AnkiWeb en lecture : le client du protocole (connexion, redirections, métadonnées,
// téléchargement), la copie locale, la relève des révisions en sessions. Les checks de
// Validation/main.swift sur le regroupement des révisions sont déjà portés (tests/domain/
// anki.test.ts) ; ceux-ci couvrent le réseau et l'orchestration, que Validation n'atteint pas.

import { describe, expect, it } from "vitest";
import {
  AnkiFailure, AnkiWebClient, clientVersion, endpointFromRedirect, type Fetcher,
} from "../../src/services/ankiWebClient.ts";
import { AnkiCollection, type MirrorStore } from "../../src/services/ankiCollection.ts";
import { AnkiWebSync, type KeyValue } from "../../src/services/ankiWebSync.ts";
import { AnkiReviewSync } from "../../src/services/ankiReviewSync.ts";
import { ModelStore } from "../../src/models/store.ts";
import { Course } from "../../src/models/course.ts";
import { StudySession } from "../../src/models/studySession.ts";

const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });
const textOf = async (init?: RequestInit): Promise<string> => new TextDecoder().decode(init?.body as Uint8Array);

describe("endpointFromRedirect", () => {
  it("la racine du serveur du compte", () =>
    expect(endpointFromRedirect("https://sync20.ankiweb.net/", "https://sync.ankiweb.net/sync/meta")).toBe("https://sync20.ankiweb.net/"));
  it("l'adresse complète de la méthode : on garde ce qui précède /sync/", () =>
    expect(endpointFromRedirect("https://sync3.ankiweb.net/sync/meta?x=1", null)).toBe("https://sync3.ankiweb.net/"));
  it("une adresse relative se lit contre la requête", () =>
    expect(endpointFromRedirect("/sync/meta", "https://sync7.ankiweb.net/sync/meta")).toBe("https://sync7.ankiweb.net/"));
  it("une adresse illisible n'est pas une adresse", () => expect(endpointFromRedirect("ftp://x", null)).toBeNull());
});

describe("AnkiWebClient", () => {
  it("la connexion échange identifiant et mot de passe contre une clé, en formulaire multipart", async () => {
    let seen: { url: string; body: string; type: string } | null = null;
    const fetcher: Fetcher = async (url, init) => {
      seen = { url, body: await textOf(init), type: (init?.headers as Record<string, string>)["Content-Type"] };
      return json({ key: "hk-123" });
    };
    const key = await new AnkiWebClient("", null, fetcher).login("eleve@epfl.ch", "secret");
    expect(key).toBe("hk-123");
    expect(seen!.url).toBe("https://sync.ankiweb.net/sync/hostKey");
    expect(seen!.type).toMatch(/^multipart\/form-data; boundary=StudyTrack-/);
    expect(seen!.body).toContain('name="c"\r\n\r\n0');
    expect(seen!.body).toContain('name="data"; filename="data"');
    expect(seen!.body).toContain('{"u":"eleve@epfl.ch","p":"secret"}');
  });

  it("403 : identifiant ou mot de passe incorrect", async () => {
    const client = new AnkiWebClient("", null, async () => new Response("", { status: 403 }));
    await expect(client.login("a", "b")).rejects.toThrow("Identifiant ou mot de passe AnkiWeb incorrect.");
  });

  it("une redirection 308 est suivie à la main, sur la racine du serveur du compte", async () => {
    const urls: string[] = [];
    const fetcher: Fetcher = async (url, init) => {
      urls.push(url);
      expect(init?.maxRedirections).toBe(0);
      return urls.length === 1
        ? new Response("", { status: 308, headers: { Location: "https://sync12.ankiweb.net/" } })
        : json({ mod: 5, scm: 7, usn: 3, hostNum: 0, cont: true });
    };
    const client = new AnkiWebClient("k", null, fetcher);
    const meta = await client.meta();
    expect(urls).toEqual(["https://sync.ankiweb.net/sync/meta", "https://sync12.ankiweb.net/sync/meta"]);
    expect(client.endpoint).toBe("https://sync12.ankiweb.net/");
    expect(meta).toMatchObject({ modified: 5, schema: 7, usn: 3, shouldContinue: true });
  });

  it("400 sur le serveur principal : le format récent trouve le serveur du compte, puis on rejoue", async () => {
    const calls: { url: string; header: string | null }[] = [];
    const fetcher: Fetcher = async (url, init) => {
      const header = (init?.headers as Record<string, string>)["anki-sync"] ?? null;
      calls.push({ url, header });
      if (header !== null) return new Response("", { status: 308, headers: { Location: "https://sync20.ankiweb.net/" } });
      return url.startsWith("https://sync.ankiweb.net/") ? new Response("", { status: 400 }) : json({ mod: 1, scm: 2, usn: 0, cont: true });
    };
    const client = new AnkiWebClient("k", null, fetcher);
    await client.meta();
    expect(client.endpoint).toBe("https://sync20.ankiweb.net/");
    expect(calls.map((c) => c.url)).toEqual([
      "https://sync.ankiweb.net/sync/meta", "https://sync.ankiweb.net/sync/meta", "https://sync20.ankiweb.net/sync/meta"]);
    expect(JSON.parse(calls[1].header!)).toMatchObject({ v: 11, k: "k", c: "25.02.7,6ddc22e5,win" });
  });

  it("le serveur refuse de continuer : son message est rapporté", async () => {
    const client = new AnkiWebClient("k", null, async () => json({ cont: false, msg: "Mise à jour requise" }));
    await expect(client.meta()).rejects.toThrow("Mise à jour requise");
  });

  it("le téléchargement doit être un fichier SQLite", async () => {
    const sqlite = new TextEncoder().encode("SQLite format 3\0...");
    expect(await new AnkiWebClient("k", null, async () => new Response(sqlite)).download()).toHaveLength(sqlite.length);
    await expect(new AnkiWebClient("k", null, async () => new Response("<html>erreur</html>")).download())
      .rejects.toBeInstanceOf(AnkiFailure);
  });

  it("l'identifiant de client a la forme qu'AnkiWeb exige", () =>
    expect(clientVersion).toMatch(/^anki,\d+\.\d+\.\d+ \([0-9a-f]+\),\w+$/));
});

describe("AnkiCollection", () => {
  const db = {
    async select<T>(sql: string, params: unknown[] = []): Promise<T[]> {
      if (sql.includes("FROM col")) {
        return [{ value: JSON.stringify({ "1": { id: 1, name: "EPFL::MATH-101 Analyse I", dyn: 0 }, "2": { id: 2, name: "Filtré", dyn: 1 } }), scm: 99 }] as T[];
      }
      expect(params).toEqual([1000]);
      return [{ id: 1001, time: 20000, did: 1 }, { id: 1002, time: 5000, did: 42 }] as T[];
    },
  };
  const collection = new AnkiCollection(db);
  it("les paquets, triés, avec les paquets filtrés signalés", async () => {
    const decks = await collection.decks();
    expect(decks.map((d) => [d.id, d.isFiltered])).toEqual([[1, false], [2, true]]);
  });
  it("le numéro de schéma", async () => expect(await collection.schema()).toBe(99));
  it("les révisions portent le nom de leur paquet, « Anki » à défaut", async () =>
    expect(await collection.reviews(1000)).toEqual([
      { id: 1001, durationMs: 20000, deck: "EPFL::MATH-101 Analyse I" }, { id: 1002, durationMs: 5000, deck: "Anki" }]));
});

function memoryStore(): KeyValue & { map: Map<string, string> } {
  const map = new Map<string, string>();
  return { map, get: (k) => map.get(k) ?? null, set: (k, v) => { if (v === null) map.delete(k); else map.set(k, v); } };
}

function fakeMirror(reviews: { id: number; durationMs: number; deck: string }[] = []): MirrorStore & { installs: number; has: boolean } {
  const state = { installs: 0, has: false };
  return Object.assign(state, {
    async install() { state.installs++; state.has = true; },
    async open() { return state.has ? ({ reviews: async (after: number) => reviews.filter((r) => r.id > after) } as unknown as AnkiCollection) : null; },
    async remove() { state.has = false; },
  });
}

describe("AnkiWebSync", () => {
  const meta = (mod: number) => ({ mod, scm: 7, usn: 1, cont: true });
  function server(mod: () => number): Fetcher {
    return async (url) => {
      if (url.endsWith("/hostKey")) return json({ key: "K" });
      if (url.endsWith("/meta")) return json(meta(mod()));
      return new Response(new TextEncoder().encode("SQLite format 3\0"));
    };
  }

  it("la connexion garde la clé (jamais le mot de passe) et télécharge la collection", async () => {
    const store = memoryStore();
    const mirror = fakeMirror();
    const web = new AnkiWebSync(store, mirror, server(() => 10));
    expect(await web.signIn("eleve", "pw")).toBe(true);
    expect(web.isSignedIn).toBe(true);
    expect([...store.map.values()].some((v) => v === "pw")).toBe(false);
    expect(mirror.installs).toBe(1);
    expect(web.username).toBe("eleve");
  });

  it("serveur inchangé : « À jour », rien n'est retéléchargé ; changé : retéléchargé", async () => {
    let mod = 10;
    const mirror = fakeMirror();
    const web = new AnkiWebSync(memoryStore(), mirror, server(() => mod));
    await web.signIn("eleve", "pw");
    await web.refreshMirror();
    expect(web.status).toBe("À jour");
    expect(mirror.installs).toBe(1);
    mod = 11;
    await web.refreshMirror();
    expect(mirror.installs).toBe(2);
  });

  it("un mauvais mot de passe : l'erreur est montrée et la connexion échoue", async () => {
    const web = new AnkiWebSync(memoryStore(), fakeMirror(), async () => new Response("", { status: 403 }));
    expect(await web.signIn("a", "b")).toBe(false);
    expect(web.lastError).toBe("Identifiant ou mot de passe AnkiWeb incorrect.");
    expect(web.isSignedIn).toBe(false);
  });

  it("se déconnecter oublie la clé et la copie", async () => {
    const mirror = fakeMirror();
    const web = new AnkiWebSync(memoryStore(), mirror, server(() => 1));
    await web.signIn("eleve", "pw");
    await web.signOut();
    expect(web.isSignedIn).toBe(false);
    expect(mirror.has).toBe(false);
  });

  it("les révisions déjà relevées ne reviennent pas, et rien au-delà de 30 jours", async () => {
    const now = new Date("2026-11-02T12:00:00Z");
    const recent = now.getTime() - 3600_000;
    const old = now.getTime() - 40 * 86_400_000;
    const web = new AnkiWebSync(memoryStore(), fakeMirror([
      { id: old, durationMs: 9000, deck: "X" }, { id: recent, durationMs: 9000, deck: "X" }]), server(() => 1));
    await web.signIn("eleve", "pw");
    expect((await web.newReviews(now)).map((r) => r.id)).toEqual([recent]);
    expect(await web.newReviews(now)).toEqual([]);
  });
});

describe("AnkiReviewSync", () => {
  const T0 = Date.parse("2026-11-02T09:00:00Z");
  const reviews = [
    { id: T0, durationMs: 20000, deck: "EPFL::MATH-101 Analyse I" },
    { id: T0 + 60_000, durationMs: 45000, deck: "EPFL::MATH-101 Analyse I" },
    { id: T0 + 3_000_000, durationMs: 70000, deck: "EPFL::MATH-101 Analyse I" },
  ];

  function setup() {
    const store = new ModelStore();
    store.insert(new Course({ code: "MATH-101", name: "Analyse I" }));
    const mirror = fakeMirror(reviews);
    const kv = memoryStore();
    const web = new AnkiWebSync(kv, mirror, async (url) => url.endsWith("/hostKey") ? json({ key: "K" }) : url.endsWith("/meta") ? json({ mod: 1, scm: 1, usn: 0, cont: true }) : new Response(new TextEncoder().encode("SQLite format 3\0")));
    return { store, web };
  }

  it("deux sessions « flashcards », rattachées au cours par le code du paquet, une seule fois", async () => {
    const { store, web } = setup();
    await web.signIn("eleve", "pw");
    const now = new Date(T0 + 4_000_000);
    const first = await AnkiReviewSync.sync(store, web, now);
    expect(first).toMatchObject({ sessionsAdded: 2, seconds: 135 });
    const sessions = store.fetch(StudySession);
    expect(sessions.every((s) => s.isFromAnki && s.taskType === "flashcards" && s.course?.code === "MATH-101")).toBe(true);
    expect(sessions[0].note).toBe("Anki · EPFL::MATH-101 Analyse I · 2 cartes");
    // Un second relevé ne recompte rien (clé de session connue + dernier identifiant retenu).
    expect((await AnkiReviewSync.sync(store, web, now)).sessionsAdded).toBe(0);
    expect(store.fetch(StudySession)).toHaveLength(2);
  });

  it("pas plus d'un relevé toutes les dix minutes, sauf demande", async () => {
    const { store, web } = setup();
    await web.signIn("eleve", "pw");
    const stored = new Map<string, string>();
    const real = globalThis.localStorage;
    // `localStorage` de la plate-forme de test peut manquer : on en pose un.
    Object.defineProperty(globalThis, "localStorage", { configurable: true, value: {
      getItem: (k: string) => stored.get(k) ?? null, setItem: (k: string, v: string) => { stored.set(k, v); }, removeItem: (k: string) => { stored.delete(k); },
    } });
    try {
      const now = new Date(T0 + 4_000_000);
      expect(await AnkiReviewSync.syncIfDue(store, { web, now })).not.toBeNull();
      expect(await AnkiReviewSync.syncIfDue(store, { web, now: new Date(now.getTime() + 5 * 60_000) })).toBeNull();
      expect(await AnkiReviewSync.syncIfDue(store, { web, now: new Date(now.getTime() + 5 * 60_000), force: true })).not.toBeNull();
      expect(await AnkiReviewSync.syncIfDue(store, { web, now: new Date(now.getTime() + 16 * 60_000) })).not.toBeNull();
    } finally {
      Object.defineProperty(globalThis, "localStorage", { configurable: true, value: real });
    }
  });

  it("pas connecté·e : rien n'est tenté", async () => {
    const { store } = setup();
    const web = new AnkiWebSync(memoryStore(), fakeMirror(), async () => { throw new Error("ne doit pas être appelé"); });
    expect(await AnkiReviewSync.syncIfDue(store, { web })).toBeNull();
  });
});
