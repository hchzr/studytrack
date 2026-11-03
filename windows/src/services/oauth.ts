// Connexion par un fournisseur (Google, Apple) : GoTrue en OAuth avec PKCE, sans supabase-js.
//
//   1. un `code_verifier` tiré au hasard et son `code_challenge` (S256) ;
//   2. la commande Rust `oauth_start` écoute un port libre de 127.0.0.1 (RFC 8252) ;
//   3. `{URL}/auth/v1/authorize?provider=google&redirect_to=http://127.0.0.1:<port>/auth-callback
//      &code_challenge=…&code_challenge_method=s256` s'ouvre dans le **navigateur du système**
//      (Google refuse les webviews intégrées) ;
//   4. GoTrue renvoie vers `http://127.0.0.1:<port>/auth-callback?code=…` (événement `oauth:callback`) ;
//   5. `POST /auth/v1/token?grant_type=pkce` `{auth_code, code_verifier}` rend la session.
//
// Même flux que `StudyTrack/Domain/OAuthPKCE.swift` (iPhone, Mac). Lier Google à un compte
// déjà connecté passe par `GET /auth/v1/user/identities/authorize` avec le jeton de l'utilisateur.

import { SupabaseError, type SupabaseClient } from "./supabase.ts";

// Le chemin que GoTrue rappelle sur la boucle locale. À déclarer dans Authentication › URL Configuration
// › Redirect URLs : `http://127.0.0.1:*/auth-callback` (avec `studytrack://auth-callback` pour Apple).
export const OAUTH_CALLBACK_PATH = "/auth-callback";

/** L'adresse de rappel pour un port donné. */
export function loopbackRedirect(port: number): string {
  return `http://127.0.0.1:${port}${OAUTH_CALLBACK_PATH}`;
}

export type OAuthProvider = "google" | "apple";

/** Le nom du fournisseur, pour les messages. */
export function providerName(provider: OAuthProvider): string {
  return provider === "apple" ? "Apple" : "Google";
}

/** Le résultat d'un retour de GoTrue. */
export type OAuthCallback = { code: string } | { error: string };

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** 32 octets aléatoires → 43 caractères, dans l'alphabet permis par la RFC 7636. */
export function makeVerifier(): string {
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  return base64url(bytes);
}

/** `BASE64URL(SHA256(verifier))` — la méthode S256 de la RFC 7636. */
export async function challengeS256(verifier: string): Promise<string> {
  const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64url(new Uint8Array(digest));
}

/** L'adresse d'autorisation (connexion). `link` : lier une identité au compte connecté. */
export function authorizeURL(baseURL: string, provider: OAuthProvider, challenge: string, redirect: string, opts: { link?: boolean; skipRedirect?: boolean } = {}): string {
  const path = opts.link ? "/auth/v1/user/identities/authorize" : "/auth/v1/authorize";
  const q = new URLSearchParams({
    provider,
    redirect_to: redirect,
    code_challenge: challenge,
    code_challenge_method: "s256",
  });
  if (opts.skipRedirect) q.set("skip_http_redirect", "true");
  return `${baseURL}${path}?${q}`;
}

/**
 * Ce que GoTrue renvoie sur la boucle locale : `?code=…` (PKCE met le code dans la requête), ou
 * `?error_description=…`. Le fragment (`#…`) ne parvient jamais à un serveur, mais on le lit si
 * l'adresse en porte un. `null` : ce n'est pas notre retour.
 */
export function parseCallback(raw: string): OAuthCallback | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  const ours = (url.protocol === "http:" && url.hostname === "127.0.0.1" && url.pathname === OAUTH_CALLBACK_PATH)
    || (url.protocol === "studytrack:" && url.hostname === "auth-callback");
  if (!ours) return null;
  const params = new URLSearchParams(url.search);
  if (url.hash.length > 1) for (const [k, v] of new URLSearchParams(url.hash.slice(1))) if (!params.has(k)) params.set(k, v);
  const error = params.get("error_description") ?? params.get("error");
  if (error) return { error };
  const code = params.get("code");
  return code ? { code } : null;
}

/** Le corps de `POST /auth/v1/token?grant_type=pkce`. */
export function exchangeBody(code: string, verifier: string): { auth_code: string; code_verifier: string } {
  return { auth_code: code, code_verifier: verifier };
}

/** Une erreur de GoTrue ou du flux, dite en français. */
export function oauthMessage(e: unknown, link = false, provider: OAuthProvider = "google"): string {
  const name = providerName(provider);
  const NOT_ENABLED = `La connexion ${name} n'est pas encore activée sur le serveur.`;
  const LINK_DISABLED = `Lier un compte ${name} n'est pas encore activé sur le serveur.`;
  if (e instanceof SupabaseError) {
    const raw = e.message.toLowerCase();
    if (/manual.?linking|linking.*(disabled|not enabled)/.test(raw)) return LINK_DISABLED;
    if (/provider is not enabled|unsupported provider|not enabled/.test(raw)) return link ? LINK_DISABLED : NOT_ENABLED;
    if (/already.*(linked|exists|registered)|identity_already_exists/.test(raw)) return `Ce compte ${name} est déjà lié à un autre compte StudyTrack.`;
    if (e.status >= 500) return `Le serveur a un problème (${e.status}) : réessaie dans un instant.`;
    return `Le serveur a refusé la connexion ${name} (${e.status}).`;
  }
  if (e instanceof TypeError) return "Réseau indisponible : vérifie ta connexion et réessaie.";
  return e instanceof Error ? e.message : `La connexion ${name} a échoué.`;
}

/** Un retour d'erreur de GoTrue (dans l'adresse de rappel), en français. */
export function callbackMessage(description: string, link = false, provider: OAuthProvider = "google"): string {
  return oauthMessage(new SupabaseError(400, description), link, provider);
}

/** Une écoute de rappel sur la boucle locale (voir `native/oauth.ts`). */
export interface Loopback {
  /** `http://127.0.0.1:<port>/auth-callback`. */
  redirect: string;
  /** L'adresse reçue ; rejette si annulée ou expirée. */
  callback: Promise<string>;
  /** Ferme l'écoute (toujours appelé en fin de flux). */
  cancel: () => void;
}

export interface FlowInputs {
  client: SupabaseClient;
  fetchImpl: typeof fetch;
  startLoopback: () => Promise<Loopback>;
  /** Ouvre une adresse https dans le navigateur du système. */
  openBrowser: (url: string) => Promise<void>;
  link?: boolean;
  /** Google par défaut. */
  provider?: OAuthProvider;
  /** Reçoit l'annulation possible pendant l'attente du navigateur. */
  onWaiting?: (cancel: (() => void) | null) => void;
}

/** Le flux complet ; la session est posée sur le client (comme `signInWithPassword`). */
export async function runOAuth({ client, fetchImpl, startLoopback, openBrowser, link = false, provider = "google", onWaiting }: FlowInputs): Promise<void> {
  const verifier = makeVerifier();
  const challenge = await challengeS256(verifier);
  const loopback = await startLoopback();
  try {
    const plain = authorizeURL(client.url, provider, challenge, loopback.redirect, { link });
    const target = await resolveAuthorizeURL(client, fetchImpl, provider, challenge, loopback.redirect, link) ?? plain;
    onWaiting?.(loopback.cancel);
    await openBrowser(target);
    const callback = parseCallback(await loopback.callback);
    if (callback === null) throw new Error(`La connexion ${providerName(provider)} a été interrompue.`);
    if ("error" in callback) throw new Error(callbackMessage(callback.error, link, provider));
    try {
      await client.exchangeCode(callback.code, verifier);
    } catch (e) {
      throw new Error(oauthMessage(e, link, provider));
    }
  } finally {
    onWaiting?.(null);
    loopback.cancel();
  }
}

/**
 * Demande à GoTrue l'adresse du fournisseur (`skip_http_redirect`) : un fournisseur éteint
 * se dit tout de suite, au lieu d'une page d'erreur JSON dans le navigateur. `null` : réponse
 * inattendue (redirection suivie, CORS) — on ouvre alors l'adresse directe.
 */
async function resolveAuthorizeURL(client: SupabaseClient, fetchImpl: typeof fetch, provider: OAuthProvider, challenge: string, redirect: string, link: boolean): Promise<string | null> {
  const url = authorizeURL(client.url, provider, challenge, redirect, { link, skipRedirect: true });
  try {
    if (link) {
      const json = await client.request<{ url?: string }>(url.slice(client.url.length));
      return json?.url ?? null;
    }
    const res = await fetchImpl(url, { headers: { apikey: client.anonKey } });
    const text = await res.text();
    if (res.status >= 400) throw new SupabaseError(res.status, text || res.statusText);
    const json = JSON.parse(text) as { url?: string };
    return typeof json.url === "string" ? json.url : null;
  } catch (e) {
    if (e instanceof SupabaseError) throw new Error(oauthMessage(e, link, provider));
    return null;
  }
}
