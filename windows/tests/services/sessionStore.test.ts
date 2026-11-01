import { describe, expect, it } from "vitest";
import { StoredSession } from "../../src/domain/supabaseSession.ts";
import type { Session } from "../../src/services/supabase.ts";
import { LocalSessionStore, SESSION_KEY } from "../../src/services/sessionStore.ts";

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

/** Une session valable une heure, la forme exacte que renvoie Supabase. */
function liveSession(): Session {
  return {
    access_token: "at",
    refresh_token: "r1",
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    user: { id: "u1", email: "hugo@epfl.ch" },
  };
}

describe("sessionStore", () => {
  it("garde la session sous la forme que les apps Apple reliraient", async () => {
    const storage = fakeStorage();
    const store = new LocalSessionStore(storage);
    const session = liveSession();
    await store.save(session);

    // La clé du plan, et le JSON de `StoredSession` (Codable Swift) : jetons,
    // identifiant, adresse, date — pas les champs `access_token` de l'API.
    const raw = storage.getItem(SESSION_KEY);
    expect(raw).not.toBeNull();
    const stored = StoredSession.decode(raw!);
    expect(stored!.equals(new StoredSession({
      accessToken: "at",
      refreshToken: "r1",
      userID: "u1",
      email: "hugo@epfl.ch",
      expiresAt: new Date(session.expires_at * 1000),
    }))).toBe(true);

    // Et le chemin inverse rend au client ce qu'il avait.
    expect(await store.load()).toEqual(session);
  });

  it("une session expirée mais rafraîchissable survit (isUsable, pas isExpired)", async () => {
    const storage = fakeStorage();
    const store = new LocalSessionStore(storage);
    const expired = { ...liveSession(), expires_at: Math.floor(Date.now() / 1000) - 60 };
    await store.save(expired);
    // Le jeton d'accès est mort, le jeton de rafraîchissement non : la garder
    // vaut mieux que déconnecter à chaque relance — le client la rafraîchira.
    const loaded = await store.load();
    expect(loaded).not.toBeNull();
    expect(loaded!.refresh_token).toBe("r1");
    expect(loaded!.expires_at).toBeLessThan(Math.floor(Date.now() / 1000));
    // Et côté domaine, la même session : expirée, pourtant utilisable.
    const stored = StoredSession.decode(storage.getItem(SESSION_KEY)!)!;
    expect(stored.isExpired()).toBe(true);
    expect(stored.isUsable).toBe(true);
  });

  it("une session au jeton vide vaut une absence", async () => {
    const storage = fakeStorage();
    const store = new LocalSessionStore(storage);
    await store.save({ ...liveSession(), access_token: "" });
    expect(await store.load()).toBeNull();
  });

  it("un contenu illisible vaut une absence, pas une erreur", async () => {
    const storage = fakeStorage();
    storage.setItem(SESSION_KEY, "{pas du json");
    const store = new LocalSessionStore(storage);
    expect(await store.load()).toBeNull();
  });

  it("save(null) efface, et une absence relue est une absence", async () => {
    const storage = fakeStorage();
    const store = new LocalSessionStore(storage);
    await store.save(liveSession());
    await store.save(null);
    expect(storage.getItem(SESSION_KEY)).toBeNull();
    expect(await store.load()).toBeNull();
  });

  it("sans localStorage (tests sous Node), tout est un no-op qui ne lève pas", async () => {
    const store = new LocalSessionStore(null);
    await store.save(liveSession());
    expect(await store.load()).toBeNull();
    await store.save(null);
    const parDefaut = new LocalSessionStore();
    await parDefaut.save(liveSession());
    expect(await parDefaut.load()).toBeNull();
  });
});
