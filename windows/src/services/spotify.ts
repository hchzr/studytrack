// Spotify Connect (API web de Spotify) : ce qui joue sur n'importe lequel de tes appareils
// Spotify (ce PC, le téléphone, une enceinte), le piloter, le déplacer, lancer une playlist —
// et la bande-son des sessions. Connexion PKCE dans le navigateur du système (aucun secret
// dans l'app), retour par la boucle locale sur un port fixe déclaré chez Spotify.
// Le jeton de rafraîchissement est rangé dans le coffre du système, jamais en clair.
// Le pilotage demande Spotify Premium (règle de Spotify).

import { challengeS256, makeVerifier, parseCallback } from "./oauth.ts";
import { openInBrowser, startLoopback } from "../native/oauth.ts";
import { callNative } from "../native/tauri.ts";
import { nativeFetch } from "../native/http.ts";

/** Le port déclaré chez Spotify : `http://127.0.0.1:43827/auth-callback`. */
export const SPOTIFY_PORT = 43827;
const REDIRECT = `http://127.0.0.1:${SPOTIFY_PORT}/auth-callback`;
const SCOPES = [
  "user-read-playback-state", "user-modify-playback-state", "user-read-currently-playing",
  "playlist-read-private", "playlist-read-collaborative", "user-library-read",
].join(" ");
const SECRET = "spotify.refresh";
const CLIENT_KEY = "spotify.clientID";

/** L'identifiant de l'app Spotify : celui du build, ou celui collé dans les réglages. */
export function spotifyClientID(): string {
  try {
    const own = localStorage.getItem(CLIENT_KEY);
    if (own) return own;
  } catch { /* le build */ }
  return import.meta.env.VITE_SPOTIFY_CLIENT_ID ?? "";
}

export function setSpotifyClientID(value: string): void {
  try { localStorage.setItem(CLIENT_KEY, value.trim()); } catch { /* idem */ }
}

export interface SpotifyDevice { id: string; name: string; type: string; isActive: boolean; volume: number | null }
export interface SpotifyTrack { title: string; artists: string; album: string; artwork: string | null; durationMs: number }
export interface SpotifyPlayback {
  isPlaying: boolean;
  device: SpotifyDevice | null;
  track: SpotifyTrack | null;
  progressMs: number;
  contextURI: string | null;
}
export interface SpotifyPlaylist { id: string; uri: string; name: string; owner: string; image: string | null; tracks: number }

let access: { token: string; expires: number } | null = null;
let refresh: string | null | undefined;
const listeners = new Set<() => void>();
const changed = () => { for (const listener of listeners) listener(); };

export function onSpotifyChange(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

async function refreshToken(): Promise<string | null> {
  if (refresh === undefined) {
    const found = await callNative<Record<string, string>>("secrets_load", { keys: [SECRET] });
    refresh = found?.[SECRET] ?? null;
  }
  return refresh;
}

async function storeTokens(json: { access_token?: string; refresh_token?: string; expires_in?: number }): Promise<void> {
  if (!json.access_token) throw new Error("Spotify n'a pas rendu de jeton.");
  access = { token: json.access_token, expires: Date.now() + ((json.expires_in ?? 3600) - 60) * 1000 };
  if (json.refresh_token) {
    refresh = json.refresh_token;
    await callNative("secret_set", { key: SECRET, value: json.refresh_token });
  }
}

async function tokenRequest(form: Record<string, string>): Promise<void> {
  const response = await nativeFetch("https://accounts.spotify.com/api/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form).toString(),
  });
  const json = await response.json() as { access_token?: string; refresh_token?: string; expires_in?: number; error_description?: string; error?: string };
  if (!response.ok) throw new Error(json.error_description ?? json.error ?? `Spotify a refusé (${response.status}).`);
  await storeTokens(json);
}

export async function spotifyConnected(): Promise<boolean> {
  return (await refreshToken()) !== null;
}

/** La connexion, dans le navigateur du système. */
export async function spotifySignIn(): Promise<void> {
  const clientID = spotifyClientID();
  if (!clientID) throw new Error("Il manque l'identifiant de l'app Spotify (Réglages › Musique).");
  const verifier = makeVerifier();
  const challenge = await challengeS256(verifier);
  const loopback = await startLoopback(SPOTIFY_PORT);
  try {
    const url = new URL("https://accounts.spotify.com/authorize");
    url.search = new URLSearchParams({
      client_id: clientID, response_type: "code", redirect_uri: REDIRECT, scope: SCOPES,
      code_challenge_method: "S256", code_challenge: challenge,
    }).toString();
    await openInBrowser(url.toString());
    const callback = parseCallback(await loopback.callback);
    if (!callback) throw new Error("La connexion à Spotify a été interrompue.");
    if ("error" in callback) throw new Error(callback.error === "access_denied" ? "Connexion à Spotify refusée." : callback.error);
    await tokenRequest({ grant_type: "authorization_code", code: callback.code, redirect_uri: REDIRECT, client_id: clientID, code_verifier: verifier });
    changed();
  } finally {
    loopback.cancel();
  }
}

export async function spotifySignOut(): Promise<void> {
  access = null;
  refresh = null;
  await callNative("secret_set", { key: SECRET, value: null });
  changed();
}

async function token(): Promise<string> {
  if (access && access.expires > Date.now()) return access.token;
  const stored = await refreshToken();
  if (!stored) throw new Error("Connecte-toi à Spotify.");
  try {
    await tokenRequest({ grant_type: "refresh_token", refresh_token: stored, client_id: spotifyClientID() });
  } catch (error) {
    // Jeton révoqué : on oublie, l'écran redemande la connexion.
    await spotifySignOut();
    throw error;
  }
  return access!.token;
}

async function api<T = unknown>(path: string, method = "GET", body?: unknown): Promise<T | null> {
  const response = await nativeFetch(`https://api.spotify.com/v1${path}`, {
    method,
    headers: { Authorization: `Bearer ${await token()}`, ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
  if (response.status === 204 || response.status === 202) return null;
  const text = await response.text();
  if (!response.ok) {
    let message = text;
    try { message = (JSON.parse(text) as { error?: { message?: string; reason?: string } }).error?.reason ?? message; } catch { /* brut */ }
    if (/PREMIUM_REQUIRED/i.test(message)) throw new Error("Piloter Spotify demande un compte Premium.");
    if (/NO_ACTIVE_DEVICE/i.test(message) || response.status === 404) throw new Error("Aucun appareil Spotify actif : ouvre Spotify sur un appareil.");
    throw new Error(`Spotify : ${message.slice(0, 160)}`);
  }
  return text ? JSON.parse(text) as T : null;
}

/* eslint-disable @typescript-eslint/no-explicit-any */
function device(raw: any): SpotifyDevice {
  return { id: raw.id, name: raw.name, type: raw.type, isActive: raw.is_active === true, volume: typeof raw.volume_percent === "number" ? raw.volume_percent : null };
}

export const Spotify = {
  async playback(): Promise<SpotifyPlayback | null> {
    const raw = await api<any>("/me/player?additional_types=track,episode");
    if (!raw) return null;
    const item = raw.item;
    return {
      isPlaying: raw.is_playing === true,
      device: raw.device ? device(raw.device) : null,
      progressMs: raw.progress_ms ?? 0,
      contextURI: raw.context?.uri ?? null,
      track: item ? {
        title: item.name ?? "",
        artists: (item.artists ?? (item.show ? [item.show] : [])).map((a: any) => a?.name).filter(Boolean).join(", "),
        album: item.album?.name ?? item.show?.name ?? "",
        artwork: (item.album?.images ?? item.images ?? [])[0]?.url ?? null,
        durationMs: item.duration_ms ?? 0,
      } : null,
    };
  },
  async devices(): Promise<SpotifyDevice[]> {
    return ((await api<any>("/me/player/devices"))?.devices ?? []).map(device);
  },
  async playlists(): Promise<SpotifyPlaylist[]> {
    const raw = await api<any>("/me/playlists?limit=50");
    return (raw?.items ?? []).filter(Boolean).map((p: any) => ({
      id: p.id, uri: p.uri, name: p.name, owner: p.owner?.display_name ?? "", image: p.images?.[0]?.url ?? null, tracks: p.tracks?.total ?? 0,
    }));
  },
  /** Déplace la lecture vers un appareil (Spotify Connect). */
  transfer: async (deviceID: string, play = true) => { await api("/me/player", "PUT", { device_ids: [deviceID], play }); },
  /** Lance une playlist (sur l'appareil choisi, sinon l'actif), mélangée ou non. */
  async play(contextURI?: string, deviceID?: string, shuffle?: boolean): Promise<void> {
    const query = deviceID ? `?device_id=${encodeURIComponent(deviceID)}` : "";
    if (shuffle !== undefined) await api(`/me/player/shuffle?state=${shuffle}${deviceID ? `&device_id=${encodeURIComponent(deviceID)}` : ""}`, "PUT").catch(() => null);
    await api(`/me/player/play${query}`, "PUT", contextURI ? { context_uri: contextURI } : undefined);
  },
  pause: async () => { await api("/me/player/pause", "PUT"); },
  next: async () => { await api("/me/player/next", "POST"); },
  previous: async () => { await api("/me/player/previous", "POST"); },
  volume: async (percent: number) => { await api(`/me/player/volume?volume_percent=${Math.round(Math.max(0, Math.min(100, percent)))}`, "PUT"); },
};
