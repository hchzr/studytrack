import { afterEach, describe, expect, it, vi } from "vitest";
import { LocalStore } from "../../src/sync/store.ts";
import { SyncService, syncService as singleton } from "../../src/services/syncService.ts";
import { LocalSessionStore, SESSION_KEY } from "../../src/services/sessionStore.ts";
import type { SupabaseConfig } from "../../src/services/syncConfig.ts";
import { memoryDb } from "../data/helpers.ts";
import { memoryRelay } from "../helpers/memoryRelay.ts";
import { fromBytea, deriveKeys, openRow, decodeRecoveryKey, toHex } from "../../src/domain/syncCrypto.ts";
import { ACCOUNT_KEY } from "../../src/services/syncService.ts";

const BASE = "https://x.supabase.co";
const CONFIG: SupabaseConfig = { url: BASE, anonKey: "anon" };
/** Le relais d'appairage en mémoire, partagé par les appareils d'un test. */
let relay = memoryRelay();
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
  const state = { failRest: false, confirmSignUp: true, vault: null as { key_id: string } | null };
  /** Les lignes chiffrées du serveur : table → id → enveloppe (ce que Postgres garde). */
  const rows = new Map<string, Map<string, Record<string, unknown>>>();
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
      if ((body as { email?: string }).email === "deja@epfl.ch") return json({ id: "u0", email: "deja@epfl.ch", identities: [] });
      if (!state.confirmSignUp) return json({ id: "u1", email: "hugo@epfl.ch", identities: [{ id: "i1" }] });
      return json(SESSION_OK);
    }
    if (url === `${BASE}/auth/v1/verify`) {
      if ((body as { token?: string }).token === "123456") return json(SESSION_OK);
      return json({ code: "otp_expired", msg: "Token has expired or is invalid" }, 403);
    }
    if (url === `${BASE}/auth/v1/resend`) return json({});
    if (url === `${BASE}/auth/v1/logout`) return new Response(null, { status: 204 });
    if (url.startsWith(`${BASE}/rest/`)) {
      if (state.failRest) return json("boom", 500);
      // Le coffre : un par compte, écrit une fois (409 si l'autre appareil a été plus vite).
      if (url.startsWith(`${BASE}/rest/v1/sync_vault`)) {
        if (method === "POST") {
          if (state.vault) return json({ code: "23505", message: "duplicate key" }, 409);
          state.vault = { key_id: (body as { key_id: string }).key_id };
          return new Response(null, { status: 201 });
        }
        return json(state.vault ? [state.vault] : []);
      }
      if (url === `${BASE}/rest/v1/rpc/sync_reset_vault`) {
        state.vault = null;
        rows.clear();
        return new Response(null, { status: 204 });
      }
      const table = /\/rest\/v1\/([a-z_]+)/.exec(url)![1];
      const t = rows.get(table) ?? new Map();
      rows.set(table, t);
      if (method === "POST") {
        // La garde du serveur garde la plus récente ; ici l'envoyée, avec la
        // marque du serveur (microsecondes, « +00:00 », comme PostgREST).
        return json((body as Record<string, unknown>[]).map((r) => {
          const old = t.get(String(r.id));
          if (old && String(r.updated_at) < String(old.updated_at)) return old;
          clock += 1;
          const kept = { ...r, server_updated_at: new Date(clock).toISOString().replace("Z", "123+00:00") };
          t.set(String(r.id), kept);
          return kept;
        }));
      }
      return json([...t.values()]);
    }
    return new Response(null, { status: 404 });
  }) as typeof fetch;
  return {
    state,
    calls,
    fetchImpl,
    rows,
    rest: () => calls.filter((c) => c.url.includes("/rest/")),
    pushes: () => calls.filter((c) => c.method === "POST" && c.url.includes("/rest/v1/sync_") && !c.url.includes("sync_vault")),
  };
}

/** Connecté, chiffrement activé (clé rangée, synchronisation allumée), première passe vidée. */
async function activate(service: SyncService): Promise<string> {
  await service.signIn("hugo@epfl.ch", "bon");
  const recovery = await service.enableEncryption();
  await service.syncNow();
  return recovery;
}

/** Une base locale migrée, comme celle que la SqliteSource ouvre au démarrage. */
async function localStore(): Promise<LocalStore> {
  const store = new LocalStore(memoryDb());
  await store.migrate();
  return store;
}

/** Un service prêt à l'emploi : configuré, branché, avec son rechargement espion. */
async function setup(shared?: ReturnType<typeof makeServer>) {
  const server = shared ?? makeServer();
  const storage = fakeStorage();
  const service = new SyncService({ config: CONFIG, storage, fetchImpl: server.fetchImpl, relayHost: "relay.test", makeSocket: relay.factory });
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
  relay = memoryRelay();
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
    // Aucune passe : seul le coffre est lu (pour dire à l'écran où en est le chiffrement).
    expect(server.rest().filter((c) => !c.url.includes("sync_vault"))).toEqual([]);
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

  it("inscription avec adresse à confirmer : pas de session, puis le code connecte", async () => {
    const { server, service } = await setup();
    server.state.confirmSignUp = false;
    expect(await service.signUp("hugo@epfl.ch", "bon")).toBe("confirm");
    expect((await service.status()).signedIn).toBe(false);
    await expect(service.verifySignUp("hugo@epfl.ch", "000000")).rejects.toThrow(/Code faux ou expiré/);
    await service.verifySignUp("hugo@epfl.ch", "123 456");
    expect((await service.status()).signedIn).toBe(true);
    await service.resendSignUp("hugo@epfl.ch");
    expect(server.calls.some((c) => c.url === `${BASE}/auth/v1/resend`)).toBe(true);
  });

  it("inscription d'une adresse qui a déjà un compte : on le dit", async () => {
    const { service } = await setup();
    await expect(service.signUp("deja@epfl.ch", "bon")).rejects.toThrow(/déjà un compte/);
  });

  it("activé et connecté : la passe pousse les lignes à envoyer, puis recharge", async () => {
    const { server, storage, service, local, reloaded } = await setup();
    await activate(service);
    await local.write("sync_courses", { id: "c1", name: "Analyse I" });

    const report = await service.syncNow();
    expect(report).toEqual({ pushed: 1, pulled: 1, keptLocal: 0, orphans: 0 }); // la relecture rend notre propre ligne
    expect(reloaded).toHaveBeenCalledTimes(2); // la passe vide de l'activation, puis celle-ci
    // L'envoi est passé par le transport : upsert avec on_conflict=id.
    const push = server.pushes()[0];
    expect(push.url).toContain("/rest/v1/sync_courses?on_conflict=id");
    // Le serveur ne reçoit que l'enveloppe : aucun champ du modèle en clair.
    const envelope = (push.body as Record<string, unknown>[])[0];
    expect(Object.keys(envelope).sort()).toEqual(["deleted_at", "id", "key_id", "payload", "updated_at"]);
    expect(envelope).toMatchObject({ id: "c1", deleted_at: null });
    expect(JSON.stringify(push.body)).not.toContain("Analyse");
    expect(String(envelope.payload).startsWith("\\x")).toBe(true);
    // La ligne est acquittée : plus rien à envoyer.
    expect((await local.get("sync_courses", "c1"))!.dirty).toBe(0);

    // L'état garde la passe, et il survit dans localStorage.
    const status = await service.status();
    expect(status.lastReport?.pushed).toBe(1);
    expect(status.lastSyncAt).not.toBeNull();
    expect(status.lastError).toBeNull();
    const persisted = JSON.parse(storage.getItem("polymestre.sync.status")!);
    expect(persisted.lastReport.pushed).toBe(1);

    // Une deuxième passe n'a plus rien à envoyer.
    expect((await service.syncNow())!.pushed).toBe(0);
    expect(server.pushes()).toHaveLength(1);
  });

  it("deux passes lancées ensemble n'en font qu'une", async () => {
    const { server, service, local, reloaded } = await setup();
    await activate(service);
    await local.write("sync_courses", { id: "c1", name: "Analyse I" });
    const [r1, r2] = await Promise.all([service.syncNow(), service.syncNow()]);
    expect(r1).toBe(r2);
    expect(r1!.pushed).toBe(1);
    expect(server.pushes()).toHaveLength(1);
    expect(reloaded).toHaveBeenCalledTimes(2);
  });

  it("un échec de passe s'affiche, ne lève pas, et garde la ligne à envoyer", async () => {
    const { server, service, local } = await setup();
    await activate(service);
    await local.write("sync_courses", { id: "c1", name: "Analyse I" });

    server.state.failRest = true;
    expect(await service.syncNow()).toBeNull(); // jamais d'exception à l'appelant
    const status = await service.status();
    expect(status.lastError).toMatch(/500/);
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
    await activate(first.service);
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
    await activate(service);
    // L'opt-in part une passe tout de suite (l'envoi initial) : on la laisse finir
    // avant d'écrire, pour ne mesurer que le groupement des saisies.
    await service.syncNow();
    await drain();
    expect(reloaded).toHaveBeenCalledTimes(2);

    await local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await local.write("sync_courses", { id: "c2", name: "Physique" });

    service.noteLocalWrite();
    await drain();
    expect(reloaded).toHaveBeenCalledTimes(2); // pas avant les trois secondes

    await vi.advanceTimersByTimeAsync(3_000);
    // WebCrypto répond hors des microtâches : on attend la fin de la passe.
    await vi.waitFor(() => expect(reloaded).toHaveBeenCalledTimes(3));
    // Les deux saisies n'ont fait qu'un envoi, d'un lot.
    expect(server.pushes()).toHaveLength(1);
    expect(server.pushes()[0].body as unknown[]).toHaveLength(2);
    expect((await local.dirty("sync_courses")).length).toBe(0);
  });

  it("le rattrapage tourne toutes les cinq minutes", async () => {
    vi.useFakeTimers();
    const { service, local, reloaded } = await setup();
    await activate(service);
    service.startAutoSync();
    await service.syncNow(); // la passe immédiate (la même promesse)
    expect(reloaded).toHaveBeenCalledTimes(2);

    await local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    await vi.waitFor(() => expect(reloaded).toHaveBeenCalledTimes(3));
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

describe("synchronisation chiffrée de bout en bout", () => {
  /** Un second appareil sur le même serveur : stockage, base et service propres. */
  async function secondDevice(first: Awaited<ReturnType<typeof setup>>) {
    return setup(first.server);
  }

  it("l'activation crée le coffre, range la clé ici, et ne l'envoie nulle part", async () => {
    const a = await setup();
    expect((await a.service.status()).encryption).toBe("signedOut");
    await a.service.signIn("hugo@epfl.ch", "bon");
    await a.service.refreshVault();
    expect((await a.service.status()).encryption).toBe("noVault");

    const recovery = await a.service.enableEncryption();
    const akHex = a.storage.getItem(ACCOUNT_KEY)!.split(":")[1];
    expect((await a.service.status()).encryption).toBe("ready");
    expect(a.storage.getItem(ACCOUNT_KEY)!.startsWith("u1:")).toBe(true);
    // La clé de secours est la clé du compte, et le coffre ne porte que son identifiant public.
    expect(toHex(await decodeRecoveryKey(recovery))).toBe(akHex);
    const { keyId, dataKey } = await deriveKeys(await decodeRecoveryKey(recovery));
    expect(a.server.state.vault).toEqual({ key_id: keyId });

    await a.local.write("sync_courses", { id: "c1", name: "Analyse I", credits: 8 });
    await a.service.syncNow();
    // Rien de ce que le serveur a reçu ne contient la clé, ni le contenu.
    const everything = JSON.stringify(a.server.calls);
    expect(everything).not.toContain(akHex);
    expect(everything).not.toContain(toHex(dataKey));
    expect(everything).not.toContain("Analyse");
    // Mais le contenu s'ouvre avec la clé dérivée, avec les mêmes noms de colonnes.
    const stored = a.server.rows.get("sync_courses")!.get("c1")!;
    expect(stored.key_id).toBe(keyId);
    const fields = await openRow(dataKey, "sync_courses", "c1", fromBytea(stored.payload)!);
    expect(fields).toMatchObject({ name: "Analyse I", credits: 8 });
    expect(Object.keys(fields)).not.toContain("updated_at");
  });

  it("un compte chiffré : le nouvel appareil attend sa clé, sans rien envoyer ni lire", async () => {
    const a = await setup();
    await activate(a.service);
    await a.local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await a.service.syncNow();

    const b = await secondDevice(a);
    await b.service.signIn("hugo@epfl.ch", "bon");
    await b.service.refreshVault();
    expect((await b.service.status()).encryption).toBe("needsKey");
    b.service.setEnabled(true);
    expect(await b.service.syncNow()).toBeNull();
    expect((await b.service.status()).lastError).toMatch(/Ce compte est chiffré/);
    expect(b.server.pushes().length).toBe(1); // celui de A seulement
    expect(await b.local.get("sync_courses", "c1")).toBeUndefined();
    // Activer le chiffrement ici ne doit pas écraser le coffre existant.
    await expect(b.service.enableEncryption()).rejects.toThrow(/déjà chiffré/);
  });

  it("appairage : B reçoit la clé de A, puis lit ses données ; le relais ne voit pas la clé", async () => {
    const a = await setup();
    await activate(a.service);
    await a.local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await a.service.syncNow();
    const akHex = a.storage.getItem(ACCOUNT_KEY)!.split(":")[1];

    const b = await secondDevice(a);
    await b.service.signIn("hugo@epfl.ch", "bon");
    await b.service.refreshVault();

    const states: string[] = [];
    const host = await a.service.startPairing((s) => states.push(s));
    expect(host.code).toMatch(/^[0-9A-Z]{4}(-[0-9A-Z]{4}){5}-[0-9A-Z]{2}$/);
    expect(host.qr).toBe(`polymestre-pair:${host.code}`);
    await b.service.joinPairing(host.code);

    await vi.waitFor(() => expect(states).toContain("done"));
    expect(b.storage.getItem(ACCOUNT_KEY)).toBe(a.storage.getItem(ACCOUNT_KEY));
    expect((await b.service.status()).encryption).toBe("ready");
    // B a été allumé par l'appairage : il lit ce que A a envoyé.
    await vi.waitFor(async () => expect(await b.local.get("sync_courses", "c1")).toMatchObject({ name: "Analyse I" }));

    // Le relais n'a vu que des clés publiques et des chiffrés : ni la clé, ni le code.
    const seen = relay.log.join("\n") + relay.urls.join("\n");
    expect(seen).not.toContain(akHex);
    expect(seen).not.toContain(host.code);
    expect(relay.log.map((m) => JSON.parse(m).step)).toEqual(expect.arrayContaining(["hello", "offer", "ok"]));
    // Les sockets d'appairage sont fermées une fois l'écran fini.
    expect(relay.openSockets()).toBe(0);
  });

  it("un code d'un autre compte est refusé : la clé reçue doit être celle du coffre", async () => {
    const a = await setup();
    await activate(a.service);
    // Un autre serveur (un autre compte) avec son propre coffre, qui partage le relais.
    const other = await setup();
    await activate(other.service);
    other.server.state.vault = { key_id: "0".repeat(32) }; // le coffre de B dit autre chose que la clé de A
    const host = await a.service.startPairing(() => {});
    await expect(other.service.joinPairing(host.code)).rejects.toThrow(/autre compte/);
    expect(other.storage.getItem(ACCOUNT_KEY)!.split(":")[1]).not.toBe(a.storage.getItem(ACCOUNT_KEY)!.split(":")[1]);
    host.cancel();
  });

  it("clé de secours : restaure, vérifie la somme de contrôle et le coffre", async () => {
    const a = await setup();
    const recovery = await activate(a.service);
    const b = await secondDevice(a);
    await b.service.signIn("hugo@epfl.ch", "bon");

    const typo = recovery.replace(/^./, recovery[0] === "A" ? "B" : "A");
    await expect(b.service.restoreFromRecoveryKey(typo)).rejects.toThrow(/faute/);
    await expect(b.service.restoreFromRecoveryKey("1234")).rejects.toThrow(/pas valide/);
    // Une clé bien formée mais d'un autre coffre.
    const wrong = await (await import("../../src/domain/syncCrypto.ts")).encodeRecoveryKey(new Uint8Array(32).fill(7));
    await expect(b.service.restoreFromRecoveryKey(wrong)).rejects.toThrow(/pas celle de ce compte/);
    expect(b.storage.getItem(ACCOUNT_KEY)).toBeNull();

    await b.service.restoreFromRecoveryKey(recovery.toLowerCase().replace(/-/g, " "));
    expect((await b.service.status()).encryption).toBe("ready");
    expect(b.storage.getItem(ACCOUNT_KEY)).toBe(a.storage.getItem(ACCOUNT_KEY));
  });

  it("une ligne d'une autre clé est ignorée, signalée, jamais écrasée", async () => {
    const a = await setup();
    await activate(a.service);
    // Une ligne d'une autre clé, posée sur le serveur.
    a.server.rows.set("sync_courses", new Map([["c9", {
      id: "c9", updated_at: "2026-11-01T10:00:00.000Z", deleted_at: null,
      server_updated_at: "2026-11-01T10:00:01.123+00:00", key_id: "f".repeat(32), payload: "\\x0102",
    }]]));
    await a.service.syncNow();
    const status = await a.service.status();
    expect(status.skippedForeignKey).toBe(1);
    expect(status.lastError).toMatch(/Clé différente/);
    expect(await a.local.get("sync_courses", "c9")).toBeUndefined();
    expect(a.server.rows.get("sync_courses")!.get("c9")!.payload).toBe("\\x0102"); // intacte
  });

  it("une pierre tombale part sans payload, et se propage", async () => {
    const a = await setup();
    await activate(a.service);
    await a.local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await a.service.syncNow();
    await a.local.remove("sync_courses", "c1");
    await a.service.syncNow();
    const stored = a.server.rows.get("sync_courses")!.get("c1")!;
    expect(stored.payload).toBeNull();
    expect(stored.deleted_at).not.toBeNull();
    expect((await a.local.get("sync_courses", "c1"))!.dirty).toBe(0);
  });

  it("réinitialiser le coffre : le serveur est vidé, un coffre neuf est créé, les données repartent", async () => {
    const a = await setup();
    await activate(a.service);
    await a.local.write("sync_courses", { id: "c1", name: "Analyse I" });
    await a.service.syncNow();
    const b = await secondDevice(a);
    await b.service.signIn("hugo@epfl.ch", "bon");
    await b.service.restoreFromRecoveryKey((await a.service.recoveryKey())!);
    await b.service.syncNow();
    const oldKey = a.server.state.vault!.key_id;

    const fresh = await a.service.resetVault();
    expect(a.server.state.vault!.key_id).not.toBe(oldKey);
    expect(fresh).not.toBe(await b.service.recoveryKey());
    await a.service.syncNow();
    // Les lignes de A ont été renvoyées avec la nouvelle clé.
    expect(a.server.rows.get("sync_courses")!.get("c1")!.key_id).toBe(a.server.state.vault!.key_id);

    // L'ancien appareil le voit : sa clé n'est plus celle du coffre, il n'envoie rien.
    await b.local.write("sync_courses", { id: "c2", name: "Physique" });
    expect(await b.service.syncNow()).toBeNull();
    expect((await b.service.status()).encryption).toBe("keyMismatch");
    expect((await b.service.status()).lastError).toMatch(/Clé différente/);
    expect(a.server.rows.get("sync_courses")!.has("c2")).toBe(false);
  });
});
