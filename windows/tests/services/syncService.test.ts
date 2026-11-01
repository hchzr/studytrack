import { afterEach, describe, expect, it, vi } from "vitest";
import { LocalStore } from "../../src/sync/store.ts";
import { SyncService, syncService as singleton } from "../../src/services/syncService.ts";
import { LocalSessionStore, SESSION_KEY } from "../../src/services/sessionStore.ts";
import type { SupabaseConfig } from "../../src/services/syncConfig.ts";
import { memoryDb } from "../data/helpers.ts";

const BASE = "https://x.supabase.co";
const CONFIG: SupabaseConfig = { url: BASE, anonKey: "anon" };
const SESSION_OK = { access_token: "at", refresh_token: "r1", expires_in: 3600, user: { id: "u1", email: "hugo@epfl.ch" } };

/** `localStorage` en mémoire : ce que la webview donne à l'app, sans navigateur. */
function fakeStorage(): Storage {
  const map = new Map<string, string>();
  return {
    get length() { return map.size; },
    clear: () => map.clear(),
    key: (index: number) => [...map.keys()][index] ?? null,
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => { map.set(key, value); },
    removeItem: (key: string) => { map.delete(key); },
  };
}

/**
 * Le serveur simulé, dans l'esprit du FakeServer de tests/sync.test.ts :
 * l'authentification répond (le mot de passe « bon » seulement), un envoi
 * renvoie la version gardée avec sa marque de serveur, une lecture ne renvoie
 * rien. `state.failRest` fait échouer PostgREST — pour voir l'échec s'afficher
 * sans lever ; `state.confirmSignUp` renvoie l'utilisateur sans jeton, comme
 * un projet qui exige la confirmation de l'adresse.
 */
function makeServer() {
  const state = { failRest: false, confirmSignUp: true };
  const calls: { method: string; url: string; body?: unknown }[] = [];
  let clock = Date.parse("2026-11-01T10:00:00Z");
  const json = (value: unknown, status = 200) =>
    new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
  const fetchImpl = (async (input: string | URL | RequestInfo, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? "GET";
    const body = init?.body === undefined ? undefined : JSON.parse(String(init.body));
    calls.push({ method, url, body });

    if (url === `${BASE}/auth/v1/token?grant_type=password`) {
      if ((body as { password?: string })?.password === "bon") return json(SESSION_OK);
      return json({ code: "invalid_credentials", msg: "Invalid login credentials" }, 400);
    }
    if (url === `${BASE}/auth/v1/signup`) {
      // Sans jeton : l'adresse attend sa confirmation.
      if (!state.confirmSignUp) return json({ id: "u1", email: "hugo@epfl.ch" });
      return json(SESSION_OK);
    }
    if (url === `${BASE}/auth/v1/logout`) return new Response(null, { status: 204 });
    if (url.startsWith(`${BASE}/rest/`)) {
      if (state.failRest) return json("boom", 500);
      if (method === "POST") {
        // La garde du serveur garde la plus récente ; ici l'envoyée, avec la
        // marque du serveur (microsecondes, « +00:00 », comme PostgREST).
        clock += 1;
        const stamp = new Date(clock).toISOString().replace("Z", "123+00:00");
        return json((body as Record<string, unknown>[]).map((r) => ({ ...r, server_updated_at: stamp })));
      }
      return json([]);
    }
    return new Response(null, { status: 404 });
  }) as typeof fetch;
  return {
    state,
    calls,
    fetchImpl,
    rest: () => calls.filter((c) => c.url.includes("/rest/")),
    pushes: () => calls.filter((c) => c.method === "POST" && c.url.includes("/rest/")),
  };
}

/** Une base locale migrée, comme celle que la SqliteSource ouvre au démarrage. */
async function localStore(): Promise<LocalStore> {
  const store = new LocalStore(memoryDb());
  await store.migrate();
  return store;
}

/** Un service prêt à l'emploi : configuré, branché, avec son rechargement espion. */
async function setup() {
  const server = makeServer();
  const storage = fakeStorage();
  const service = new SyncService({ config: CONFIG, storage, fetchImpl: server.fetchImpl });
  const local = await localStore();
  const reloaded = vi.fn(async () => {});
  service.attach({ local, reload: reloaded });
  return { server, storage, service, local, reloaded };
}

/** Laisse tourner les microtâches : les fetch simulés résolvent tout de suite. */
async function drain(): Promise<void> {
  for (let i = 0; i < 50; i++) await Promise.resolve();
}

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
});

describe("syncService", () => {
  it("non configuré : tout est un no-op qui se dit", async () => {
    const server = makeServer();
    const service = new SyncService({ config: null, storage: fakeStorage(), fetchImpl: server.fetchImpl });
    await expect(service.signIn("hugo@epfl.ch", "bon")).rejects.toThrow(/pas configur/);
    expect(await service.syncNow()).toBeNull();
    expect(server.calls).toEqual([]);
    const status = await service.status();
    expect(status.configured).toBe(false);
    expect(status.signedIn).toBe(false);
    expect(status.enabled).toBe(false);

    // Le singleton de l'app, construit par l'environnement de build : sans
    // VITE_SUPABASE_URL (les tests), il se dit non configuré pareil.
    expect((await singleton.status()).configured).toBe(false);
    expect(await singleton.syncNow()).toBeNull();
  });

  it("connecté mais pas activé : la connexion marche, aucune passe ne part", async () => {
    const { server, service } = await setup();
    await service.signIn("hugo@epfl.ch", "bon");
    const status = await service.status();
    expect(status.signedIn).toBe(true);
    expect(status.email).toBe("hugo@epfl.ch");
    expect(status.enabled).toBe(false); // l'opt-in, off par défaut

    expect(await service.syncNow()).toBeNull();
    expect(server.rest()).toEqual([]); // aucune requête PostgREST
  });

  it("mauvais mot de passe : le refus du serveur, dit en français", async () => {
    const { service } = await setup();
    await expect(service.signIn("hugo@epfl.ch", "mauvais")).rejects.toThrow(/E-mail ou mot de passe refusé/);
    expect((await service.status()).signedIn).toBe(false);
  });

  it("inscription : la session arrive toute seule (auto sign-in)", async () => {
    const { server, service, storage } = await setup();
    await service.signUp("hugo@epfl.ch", "bon");
    const status = await service.status();
    expect(status.signedIn).toBe(true);
    expect(status.email).toBe("hugo@epfl.ch");
    expect(storage.getItem(SESSION_KEY)).not.toBeNull();
    expect(server.calls.some((c) => c.url === `${BASE}/auth/v1/signup`)).toBe(true);
  });

  it("inscription avec adresse à confirmer : pas de session, un message clair", async () => {
    const { server, service } = await setup();
    server.state.confirmSignUp = false;
    await expect(service.signUp("hugo@epfl.ch", "bon")).rejects.toThrow(/confirme l'adresse e-mail/);
    expect((await service.status()).signedIn).toBe(false);
  });

  it("activé et connecté : la passe pousse les lignes à envoyer, puis recharge", async () => {
    const { server, storage, service, local, reloaded } = await setup();
    await service.signIn("hugo@epfl.ch", "bon");
    service.setEnabled(true);
    await local.write("sync_courses", { id: "c1", name: "Analyse I" });

    const report = await service.syncNow();
    expect(report).toEqual({ pushed: 1, pulled: 0, keptLocal: 0, orphans: 0 });
    expect(reloaded).toHaveBeenCalledTimes(1);
    // L'envoi est passé par le transport : upsert avec on_conflict=id.
    const push = server.pushes()[0];
    expect(push.url).toContain("/rest/v1/sync_courses?on_conflict=id");
    expect(push.body).toEqual([expect.objectContaining({ id: "c1", name: "Analyse I", deleted_at: null })]);
    // La ligne est acquittée : plus rien à envoyer.
    expect((await local.get("sync_courses", "c1"))!.dirty).toBe(0);

    // L'état garde la passe, et il survit dans localStorage.
    const status = await service.status();
    expect(status.lastReport?.pushed).toBe(1);
    expect(status.lastSyncAt).not.toBeNull();
    expect(status.lastError).toBeNull();
    const persisted = JSON.parse(storage.getItem("studytrack.sync.status")!);
    expect(persisted.lastReport.pushed).toBe(1);

    // Une deuxième passe n'a plus rien à envoyer.
    expect((await service.syncNow())!.pushed).toBe(0);
    expect(server.pushes()).toHaveLength(1);
  });

  it("deux passes lancées ensemble n'en font qu'une", async () => {
    const { server, service, local, reloaded } = await setup();
    await service.signIn("hugo@epfl.ch", "bon");
    service.setEnabled(true);
    await local.write("sync_courses", { id: "c1", name: "Analyse I" });
    const [r1, r2] = await Promise.all([service.syncNow(), service.syncNow()]);
    expect(r1).toBe(r2);
    expect(r1!.pushed).toBe(1);
    expect(server.pushes()).toHaveLength(1);
    expect(reloaded).toHaveBeenCalledTimes(1);
  });

  it("un échec de passe s'affiche, ne lève pas, et garde la ligne à envoyer", async () => {
    const { server, service, local } = await setup();
    await service.signIn("hugo@epfl.ch", "bon");
    service.setEnabled(true);
    await local.write("sync_courses", { id: "c1", name: "Analyse I" });

    server.state.failRest = true;
    expect(await service.syncNow()).toBeNull(); // jamais d'exception à l'appelant
    const status = await service.status();
    expect(status.lastError).toMatch(/500/);
    expect(status.lastSyncAt).toBeNull(); // rien de réussi à afficher
    expect((await local.get("sync_courses", "c1"))!.dirty).toBe(1); // à renvoyer

    server.state.failRest = false;
    expect((await service.syncNow())!.pushed).toBe(1);
    expect((await service.status()).lastError).toBeNull();
  });

  it("se déconnecter efface la session (et révoque côté serveur)", async () => {
    const { server, service, storage } = await setup();
    await service.signIn("hugo@epfl.ch", "bon");
    await service.signOut();
    const status = await service.status();
    expect(status.signedIn).toBe(false);
    expect(status.email).toBeNull();
    expect(storage.getItem(SESSION_KEY)).toBeNull();
    expect(server.calls.some((c) => c.url === `${BASE}/auth/v1/logout`)).toBe(true);

    // Déjà déconnecté : un deuxième appel ne fait rien, sans lever.
    const before = server.calls.length;
    await service.signOut();
    expect(server.calls).toHaveLength(before);
  });

  it("le drapeau et l'état survivent à un relancement", async () => {
    const first = await setup();
    await first.service.signIn("hugo@epfl.ch", "bon");
    first.service.setEnabled(true);
    await first.local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await first.service.syncNow();

    // Un nouveau service sur le même stockage : le relancement de l'app.
    const second = new SyncService({ config: CONFIG, storage: first.storage, fetchImpl: first.server.fetchImpl });
    second.attach({ local: first.local, reload: first.reloaded });
    const status = await second.status();
    expect(status.signedIn).toBe(true); // la session a survécu
    expect(status.enabled).toBe(true); // l'opt-in aussi
    expect(status.lastReport?.pushed).toBe(1); // et la dernière passe
  });

  it("une écriture locale part seule trois secondes plus tard, groupée", async () => {
    vi.useFakeTimers();
    const { server, service, local, reloaded } = await setup();
    await service.signIn("hugo@epfl.ch", "bon");
    service.setEnabled(true);
    // L'opt-in part une passe tout de suite (l'envoi initial) : on la laisse finir
    // avant d'écrire, pour ne mesurer que le groupement des saisies.
    await service.syncNow();
    await drain();
    expect(reloaded).toHaveBeenCalledTimes(1);

    await local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await local.write("sync_courses", { id: "c2", name: "Physique" });

    service.noteLocalWrite();
    await drain();
    expect(reloaded).toHaveBeenCalledTimes(1); // pas avant les trois secondes

    await vi.advanceTimersByTimeAsync(3_000);
    await drain();
    expect(reloaded).toHaveBeenCalledTimes(2);
    // Les deux saisies n'ont fait qu'un envoi, d'un lot.
    expect(server.pushes()).toHaveLength(1);
    expect(server.pushes()[0].body as unknown[]).toHaveLength(2);
    expect((await local.dirty("sync_courses")).length).toBe(0);
  });

  it("le rattrapage tourne toutes les cinq minutes", async () => {
    vi.useFakeTimers();
    const { service, local, reloaded } = await setup();
    await service.signIn("hugo@epfl.ch", "bon");
    service.setEnabled(true);
    service.startAutoSync();
    await service.syncNow(); // la passe immédiate (la même promesse)
    expect(reloaded).toHaveBeenCalledTimes(1);

    await local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    await drain();
    expect(reloaded).toHaveBeenCalledTimes(2);
    expect((await local.dirty("sync_courses")).length).toBe(0);
  });

  it("la session du relancement passe bien par le sessionStore", async () => {
    // Le service et son client partagent le même LocalSessionStore : ce que
    // l'un garde, l'autre le relit (le client y rafraîchit ses jetons).
    const { storage, service } = await setup();
    await service.signIn("hugo@epfl.ch", "bon");
    const session = await new LocalSessionStore(storage).load();
    expect(session?.user.email).toBe("hugo@epfl.ch");
    expect(session?.refresh_token).toBe("r1");
  });
});
