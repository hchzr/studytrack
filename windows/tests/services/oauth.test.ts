import { describe, expect, it, vi } from "vitest";
import { loopbackRedirect, authorizeURL, callbackMessage, challengeS256, exchangeBody, makeVerifier, oauthMessage, parseCallback } from "../../src/services/oauth.ts";
import { SupabaseError } from "../../src/services/supabase.ts";
import { SyncService } from "../../src/services/syncService.ts";

const BASE = "https://x.supabase.co";
function memStorage(): Storage {
  const map = new Map<string, string>();
  return { get length() { return map.size; }, clear: () => map.clear(), key: (i: number) => [...map.keys()][i] ?? null,
    getItem: (k: string) => map.get(k) ?? null, setItem: (k: string, v: string) => { map.set(k, v); }, removeItem: (k: string) => { map.delete(k); } };
}

describe("PKCE", () => {
  it("le vecteur de la RFC 7636, annexe B", async () => {
    expect(await challengeS256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")).toBe("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
  });
  it("un verifier tiré a 43 caractères de l'alphabet permis, et change à chaque fois", () => {
    const a = makeVerifier(), b = makeVerifier();
    expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(a).not.toBe(b);
  });
});

describe("adresses", () => {
  it("l'adresse d'autorisation porte provider, rappel et défi S256", () => {
    const u = new URL(authorizeURL(BASE, "google", "CHAL", loopbackRedirect(54321)));
    expect(u.origin + u.pathname).toBe(`${BASE}/auth/v1/authorize`);
    expect(u.searchParams.get("provider")).toBe("google");
    expect(u.searchParams.get("redirect_to")).toBe("http://127.0.0.1:54321/auth-callback");
    expect(u.searchParams.get("code_challenge")).toBe("CHAL");
    expect(u.searchParams.get("code_challenge_method")).toBe("s256");
  });
  it("Apple passe par le même chemin, et les messages le nomment", () => {
    const u = new URL(authorizeURL(BASE, "apple", "C", loopbackRedirect(1)));
    expect(u.searchParams.get("provider")).toBe("apple");
    expect(oauthMessage(new SupabaseError(400, "Unsupported provider: provider is not enabled"), false, "apple"))
      .toBe("La connexion Apple n'est pas encore activée sur le serveur.");
    expect(callbackMessage("identity_already_exists", false, "apple")).toContain("compte Apple");
  });
  it("lier une identité passe par /user/identities/authorize", () => {
    const u = new URL(authorizeURL(BASE, "google", "C", loopbackRedirect(1), { link: true, skipRedirect: true }));
    expect(u.pathname).toBe("/auth/v1/user/identities/authorize");
    expect(u.searchParams.get("skip_http_redirect")).toBe("true");
  });
});

describe("retour", () => {
  it("lit le code de la boucle locale (dans la requête)", () => {
    expect(parseCallback("http://127.0.0.1:54321/auth-callback?code=abc123")).toEqual({ code: "abc123" });
    expect(parseCallback("polymestre://auth-callback?code=abc123")).toEqual({ code: "abc123" });
  });
  it("le redirect_to de la boucle locale porte le port", () => {
    expect(loopbackRedirect(8080)).toBe("http://127.0.0.1:8080/auth-callback");
  });
  it("lit une erreur en requête ou en fragment", () => {
    expect(parseCallback("http://127.0.0.1:9/auth-callback?error=access_denied&error_description=Nope")).toEqual({ error: "Nope" });
    expect(parseCallback("polymestre://auth-callback#error_code=400&error_description=bad")).toEqual({ error: "bad" });
  });
  it("ignore ce qui n'est pas notre retour", () => {
    expect(parseCallback("https://x.supabase.co/?code=1")).toBeNull();
    expect(parseCallback("http://127.0.0.1:1/favicon.ico")).toBeNull();
    expect(parseCallback("http://evil.example/auth-callback?code=1")).toBeNull();
    expect(parseCallback("polymestre://auth-callback")).toBeNull();
    expect(parseCallback("n'importe quoi")).toBeNull();
  });
  it("la requête d'échange", () => expect(exchangeBody("c", "v")).toEqual({ auth_code: "c", code_verifier: "v" }));
});

describe("messages", () => {
  it("fournisseur éteint → message clair", () => {
    expect(oauthMessage(new SupabaseError(400, '{"msg":"Unsupported provider: provider is not enabled"}'))).toBe("La connexion Google n'est pas encore activée sur le serveur.");
    expect(callbackMessage("Unsupported provider: provider is not enabled")).toContain("pas encore activée");
  });
  it("liaison manuelle éteinte → message clair", () => {
    expect(oauthMessage(new SupabaseError(400, "Manual linking is disabled"), true)).toContain("Lier un compte Google");
  });
});

describe("flux complet", () => {
  const session = { access_token: "at", refresh_token: "rt", expires_in: 3600, user: { id: "u", email: "a@b.c" } };
  function service(over: (url: string, init?: RequestInit) => Response | null) {
    const calls: { url: string; method: string; body?: any }[] = [];
    const fetchImpl = (async (input: string | URL | RequestInfo, init?: RequestInit) => {
      const url = String(input);
      calls.push({ url, method: init?.method ?? "GET", body: init?.body ? JSON.parse(String(init.body)) : undefined });
      return over(url, init) ?? new Response("{}", { status: 404 });
    }) as typeof fetch;
    return { calls, fetchImpl };
  }

  function loop(result: string | Error, port = 7777) {
    let cancelled = 0;
    return { cancelled: () => cancelled, make: async () => ({
      redirect: `http://127.0.0.1:${port}/auth-callback`,
      callback: result instanceof Error ? Promise.reject(result) : Promise.resolve(result.replace("PORT", String(port))),
      cancel: () => { cancelled++; },
    }) };
  }

  it("ouvre l'adresse du fournisseur, échange le code avec le verifier, garde la session", async () => {
    let challenge = "";
    const { calls, fetchImpl } = service((url) => {
      if (url.includes("/auth/v1/authorize")) { challenge = new URL(url).searchParams.get("code_challenge")!; return new Response(JSON.stringify({ url: "https://accounts.google.com/x" }), { status: 200 }); }
      if (url.endsWith("/auth/v1/token?grant_type=pkce")) return new Response(JSON.stringify(session), { status: 200 });
      return null;
    });
    let opened = "";
    const l = loop("http://127.0.0.1:PORT/auth-callback?code=CODE9");
    const svc = new SyncService({ config: { url: BASE, anonKey: "anon" }, storage: memStorage(), fetchImpl, oauthLoopback: l.make, openBrowser: async (u) => { opened = u; } });
    await svc.signInWithGoogle();
    expect(opened).toBe("https://accounts.google.com/x");
    expect(calls[0].url).toContain("redirect_to=http%3A%2F%2F127.0.0.1%3A7777%2Fauth-callback");
    expect(l.cancelled()).toBeGreaterThan(0);
    const exchange = calls.find((c) => c.url.endsWith("grant_type=pkce"))!;
    expect(exchange.method).toBe("POST");
    expect(exchange.body.auth_code).toBe("CODE9");
    expect(await challengeS256(exchange.body.code_verifier)).toBe(challenge);
    expect((await svc.status()).signedIn).toBe(true);
  });

  it("fournisseur éteint : message clair, aucune fenêtre ouverte", async () => {
    const { fetchImpl } = service((url) => url.includes("/authorize") ? new Response('{"msg":"Unsupported provider: provider is not enabled"}', { status: 400 }) : null);
    let opened = false;
    const l = loop("x");
    const svc = new SyncService({ config: { url: BASE, anonKey: "anon" }, storage: memStorage(), fetchImpl, oauthLoopback: l.make, openBrowser: async () => { opened = true; } });
    await expect(svc.signInWithGoogle()).rejects.toThrow("La connexion Google n'est pas encore activée sur le serveur.");
    expect(opened).toBe(false);
  });

  it("retour en erreur : message", async () => {
    const { fetchImpl } = service((url) => url.includes("/authorize") ? new Response('{"url":"https://g/x"}', { status: 200 }) : null);
    const l = loop("http://127.0.0.1:PORT/auth-callback?error_description=access_denied");
    const svc = new SyncService({ config: { url: BASE, anonKey: "anon" }, storage: memStorage(), fetchImpl, oauthLoopback: l.make, openBrowser: async () => {} });
    await expect(svc.signInWithGoogle()).rejects.toThrow();
    expect(l.cancelled()).toBeGreaterThan(0);
    expect((await svc.status()).signedIn).toBe(false);
  });
});

describe("annulation", () => {
  it("Annuler pendant l'attente rejette et ferme l'écoute", async () => {
    let reject!: (e: Error) => void;
    let cancelled = 0;
    const make = async () => ({
      redirect: "http://127.0.0.1:1/auth-callback",
      callback: new Promise<string>((_, r) => { reject = r; }),
      cancel: () => { cancelled++; reject(new Error("Connexion Google annulée.")); },
    });
    const fetchImpl = (async () => new Response('{"url":"https://g/x"}', { status: 200 })) as typeof fetch;
    const svc = new SyncService({ config: { url: BASE, anonKey: "anon" }, storage: memStorage(), fetchImpl, oauthLoopback: make, openBrowser: async () => {} });
    const run = svc.signInWithGoogle();
    await vi.waitFor(() => expect(svc.oauthWaiting).toBe(true));
    svc.cancelOAuth();
    await expect(run).rejects.toThrow("Connexion Google annulée.");
    expect(svc.oauthWaiting).toBe(false);
    expect(cancelled).toBeGreaterThan(0);
  });
});
