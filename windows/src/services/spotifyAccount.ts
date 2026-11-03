// Ton compte Spotify piloté comme Music (StudyKit/Music/SpotifyAccount.swift) : ce qui joue sur
// n'importe quel appareil du compte, les commandes, la position, l'aléatoire, la répétition, le
// volume, l'appareil, à suivre, tes playlists — gratuit ou Premium, sans compte développeur.
//
// Le protocole est celui du lecteur web (`domain/spotifyWire.ts`, d'après SpotAPI). Les requêtes
// partent de Rust avec la session de la fenêtre de connexion (`site_request`, cookies WebView2) ;
// le « dealer » (WebSocket) pousse chaque changement. Rien ne tourne quand le volet est fermé.
// Si le dealer refuse la webview, l'état se relit toutes les 5 s, volet ouvert seulement.

import { callNativeOrThrow, inNative } from "../native/tauri.ts";
import { nativeFetch } from "../native/http.ts";
import { openSiteLogin, siteRequest } from "./siteSession.ts";
import {
  SpotifyWire, clientToken as readClientToken, clientTokenBody, clientVersion as readClientVersion, clusterPayloads, commandBody, commandURL,
  connectionID, dealerURL, emptyNow, latestSecret, nowFromCluster, nowFromWebAPI, observerBody, observerURL, playlists as readPlaylists,
  randomHex, tokenURL, totp, trackDetails, trackID, trackURL, transferBody, transferURL, volumeBody, volumeURL, webToken,
  type Command, type Now, type Playlist, type Secret, type WebToken,
} from "../domain/spotifyWire.ts";

export type SpotifyState = { kind: "unknown" | "checking" | "signedOut" | "ready" } | { kind: "failed"; message: string };

export interface SpotifySnapshot { state: SpotifyState; now: Now; playlists: Playlist[]; error: string | null }

class Failure extends Error {}

let cachedSecret: { value: Secret; until: number } | null = null;
async function secret(): Promise<Secret> {
  if (cachedSecret && cachedSecret.until > Date.now()) return cachedSecret.value;
  let value: Secret = { version: SpotifyWire.fallbackSecret.version, bytes: [...SpotifyWire.fallbackSecret.bytes] };
  try {
    const response = await nativeFetch(SpotifyWire.secretsURL);
    if (response.ok) value = latestSecret(await response.json()) ?? value;
  } catch { /* clé de secours */ }
  cachedSecret = { value, until: Date.now() + 15 * 60_000 };
  return value;
}

class SpotifyAccount {
  private snapshot: SpotifySnapshot = { state: { kind: "unknown" }, now: emptyNow(), playlists: [], error: null };
  private listeners = new Set<() => void>();
  private token: WebToken | null = null;
  private client: string | null = null;
  private version: string = SpotifyWire.fallbackClientVersion;
  private readonly deviceID = randomHex(40);
  private socket: WebSocket | null = null;
  private ping: ReturnType<typeof setInterval> | null = null;
  private poll: ReturnType<typeof setInterval> | null = null;
  private retry: ReturnType<typeof setTimeout> | null = null;
  private attempts = 0;
  private watchers = 0;
  private details = new Map<string, { artist: string; album: string; artwork: string | null }>();

  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  get = () => this.snapshot;
  private set(patch: Partial<SpotifySnapshot>) { this.snapshot = { ...this.snapshot, ...patch }; this.listeners.forEach((l) => l()); }
  private setNow(now: Now) { this.set({ now }); }

  /** La fenêtre de connexion de Spotify ; elle se ferme seule une fois connecté·e. */
  async signIn(): Promise<void> { await openSiteLogin("spotify", SpotifyWire.login, "Connexion à Spotify"); }

  async signOut(): Promise<void> {
    this.stopListening();
    this.token = null; this.client = null;
    this.set({ state: { kind: "signedOut" }, now: emptyNow(), playlists: [] });
    // La session reste dans WebView2 ; se déconnecter de Spotify se fait dans sa fenêtre.
    try { await openSiteLogin("spotify", "https://www.spotify.com/logout/", "Spotify"); } catch { /* fenêtre indisponible */ }
  }

  async refresh(): Promise<void> {
    if (!inNative()) { this.set({ state: { kind: "signedOut" } }); return; }
    if (this.snapshot.state.kind !== "ready") this.set({ state: { kind: "checking" } });
    let cookie: string | null = null;
    try { cookie = await callNativeOrThrow<string | null>("site_cookie", { url: SpotifyWire.site, name: "sp_dc" }); } catch { cookie = null; }
    if (!cookie) { this.set({ state: { kind: "signedOut" } }); return; }
    try {
      await this.authenticate();
      this.set({ state: { kind: "ready" } });
    } catch (e) {
      if (e instanceof Failure && e.message === "signedOut") this.set({ state: { kind: "signedOut" } });
      else this.set({ state: { kind: "failed", message: e instanceof Error ? e.message : String(e) } });
    }
  }

  private async authenticate(): Promise<void> {
    if (this.token && this.token.expires - Date.now() > 60_000 && this.client) return;
    try {
      const page = await siteRequest(SpotifyWire.site);
      this.version = readClientVersion(page.body) ?? this.version;
    } catch { /* version de secours */ }
    const s = await secret();
    const response = await siteRequest(tokenURL(await totp(s.bytes, new Date()), s.version));
    let parsed: WebToken | null = null;
    try { parsed = webToken(JSON.parse(response.body)); } catch { parsed = null; }
    if (response.status !== 200 || !parsed) throw new Failure("Spotify a répondu autrement que prévu (jeton) : son lecteur web a peut-être changé.");
    if (parsed.anonymous) throw new Failure("signedOut");
    this.token = parsed;
    const granted = await siteRequest(SpotifyWire.clientTokenURL, {
      method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(clientTokenBody(this.version, parsed.clientID, this.deviceID)),
    });
    try { this.client = readClientToken(JSON.parse(granted.body)); } catch { this.client = null; }
    if (!this.client) throw new Failure("Spotify a répondu autrement que prévu (jeton client).");
  }

  private async authorized(url: string, method = "GET", body?: unknown, connection?: string): Promise<{ status: number; json: unknown }> {
    await this.authenticate();
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.token?.accessToken ?? ""}`, "Client-Token": this.client ?? "",
      "Spotify-App-Version": this.version, Origin: "https://open.spotify.com",
    };
    if (connection) headers["x-spotify-connection-id"] = connection;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const response = await siteRequest(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    if (response.status === 401) this.token = null;
    let json: unknown = null;
    try { json = response.body ? JSON.parse(response.body) : null; } catch { json = null; }
    return { status: response.status, json };
  }

  // ── Écouter, volet ouvert seulement ──

  startWatching(): void {
    this.watchers += 1;
    if (this.watchers === 1) void this.listen();
  }

  stopWatching(): void {
    this.watchers = Math.max(0, this.watchers - 1);
    if (this.watchers === 0) this.stopListening();
  }

  private stopListening(): void {
    if (this.ping) clearInterval(this.ping);
    if (this.poll) clearInterval(this.poll);
    if (this.retry) clearTimeout(this.retry);
    this.ping = this.poll = this.retry = null;
    const socket = this.socket;
    this.socket = null;
    socket?.close();
  }

  private async listen(): Promise<void> {
    if (this.watchers === 0) return;
    if (this.snapshot.state.kind !== "ready") await this.refresh();
    if (this.snapshot.state.kind !== "ready" || !this.token || this.watchers === 0) return;
    const socket = new WebSocket(dealerURL(this.token.accessToken));
    this.socket = socket;
    let opened = false;
    socket.onopen = () => {
      opened = true;
      this.ping = setInterval(() => { if (socket.readyState === WebSocket.OPEN) socket.send('{"type":"ping"}'); }, 30_000);
    };
    socket.onmessage = (event) => { void this.receive(String(event.data)); };
    socket.onclose = () => {
      if (this.socket !== socket) return;
      if (this.ping) clearInterval(this.ping);
      this.socket = null;
      if (this.watchers === 0) return;
      if (!opened) { this.startPolling(); return; }
      this.token = null;
      this.attempts += 1;
      this.retry = setTimeout(() => { void this.listen(); }, Math.min(60, 2 ** Math.min(this.attempts, 5)) * 1000);
    };
  }

  private async receive(text: string): Promise<void> {
    let message: unknown;
    try { message = JSON.parse(text); } catch { return; }
    const connection = connectionID(message);
    if (connection) {
      try {
        const { status, json } = await this.authorized(observerURL(this.deviceID), "PUT", observerBody, connection);
        if (status >= 200 && status < 300 && json && typeof json === "object") this.apply(json as Record<string, unknown>);
        else this.startPolling();
        this.attempts = 0;
        void this.loadPlaylists();
      } catch { this.startPolling(); }
      return;
    }
    for (const payload of await clusterPayloads(message)) this.apply(payload);
  }

  /** Repli : la Web API toutes les 5 s, volet ouvert seulement. */
  private startPolling(): void {
    if (this.poll || this.watchers === 0) return;
    const read = async () => {
      try {
        const { status, json } = await this.authorized(SpotifyWire.playerURL);
        if (status === 204) this.setNow({ ...emptyNow(), devices: this.snapshot.now.devices });
        else if (status === 200) this.applyNow(nowFromWebAPI(json));
      } catch { /* réessayé au prochain tour */ }
    };
    void read();
    void this.loadPlaylists();
    this.poll = setInterval(() => { void read(); }, 5000);
  }

  private apply(cluster: Record<string, unknown>): void {
    this.applyNow(nowFromCluster(cluster));
  }

  private applyNow(next: Now): void {
    if (next.devices.length === 0) next.devices = this.snapshot.now.devices;
    const id = trackID(next.track);
    const known = id ? this.details.get(id) : undefined;
    if (next.track && known) {
      next.track = { ...next.track, artist: next.track.artist || known.artist, album: next.track.album || known.album, artwork: next.track.artwork ?? known.artwork };
    }
    this.setNow(next);
    if (id && next.track && (!next.track.artist || !next.track.artwork) && !this.details.has(id)) void this.loadDetails(id);
  }

  private async loadDetails(id: string): Promise<void> {
    try {
      const { status, json } = await this.authorized(trackURL(id));
      const found = status === 200 ? trackDetails(json) : null;
      if (!found) return;
      this.details.set(id, found);
      const now = this.snapshot.now;
      if (now.track && trackID(now.track) === id) {
        this.setNow({ ...now, track: { ...now.track, artist: now.track.artist || found.artist, album: now.track.album || found.album, artwork: now.track.artwork ?? found.artwork } });
      }
    } catch { /* sans détails */ }
  }

  async loadPlaylists(): Promise<void> {
    try {
      const { status, json } = await this.authorized(SpotifyWire.playlistsURL);
      if (status === 200) this.set({ playlists: readPlaylists(json) });
    } catch { /* sans playlists */ }
  }

  // ── Gestes ──

  private target(): string | null {
    const now = this.snapshot.now;
    return now.activeDevice ?? now.devices.find((d) => d.canPlay)?.id ?? null;
  }

  private async send(command: Command): Promise<void> {
    try {
      const target = this.target();
      if (!target) throw new Error("Aucun appareil Spotify n'est ouvert. Ouvre Spotify sur ton ordinateur ou ton téléphone.");
      let { status } = await this.authorized(commandURL(this.deviceID, target), "POST", commandBody(command));
      // Comme SpotAPI : depuis l'appareil d'origine si l'observateur est refusé.
      if (status < 200 || status >= 300) ({ status } = await this.authorized(commandURL(this.snapshot.now.originDevice ?? "local", target), "POST", commandBody(command)));
      if (status < 200 || status >= 300) throw new Error(`Spotify a refusé la commande (code ${status}).`);
      this.set({ error: null });
      if (this.poll) setTimeout(() => { void this.authorized(SpotifyWire.playerURL).then(({ status: s, json }) => { if (s === 200) this.applyNow(nowFromWebAPI(json)); }); }, 600);
    } catch (e) {
      this.set({ error: e instanceof Error ? e.message : String(e) });
    }
  }

  togglePlayPause(): void {
    const now = this.snapshot.now;
    const at = Date.now();
    this.setNow(now.isPlaying ? { ...now, isPlaying: false, position: Math.min(now.position + (at - now.measuredAt) / 1000, now.duration), measuredAt: at } : { ...now, isPlaying: true, measuredAt: at });
    void this.send({ kind: now.isPlaying ? "pause" : "resume" });
  }
  next(): void { void this.send({ kind: "next" }); }
  previous(): void { void this.send({ kind: "previous" }); }
  seek(seconds: number): void {
    this.setNow({ ...this.snapshot.now, position: seconds, measuredAt: Date.now() });
    void this.send({ kind: "seek", ms: Math.round(seconds * 1000) });
  }
  setShuffle(on: boolean): void { this.setNow({ ...this.snapshot.now, shuffle: on }); void this.send({ kind: "shuffle", on }); }
  /** Désactivé → toute la liste → ce morceau → désactivé. */
  cycleRepeat(): void {
    const now = this.snapshot.now;
    const [context, track] = now.repeatTrack ? [false, false] : now.repeatContext ? [true, true] : [true, false];
    this.setNow({ ...now, repeatContext: context, repeatTrack: track });
    void this.send({ kind: "repeat", context, track });
  }
  play(uri: string): void { void this.send({ kind: "play", uri }); }

  setVolume(fraction: number): void {
    const target = this.target();
    if (!target) return;
    const now = this.snapshot.now;
    this.setNow({ ...now, devices: now.devices.map((d) => (d.id === target ? { ...d, volume: fraction } : d)) });
    void this.authorized(volumeURL(this.deviceID, target), "PUT", volumeBody(fraction)).catch(() => {});
  }

  move(device: string): void {
    const now = this.snapshot.now;
    const from = now.activeDevice ?? now.originDevice;
    if (!from || from === device) return;
    void this.authorized(transferURL(from, device), "POST", transferBody(now.isPlaying)).then(({ status }) => {
      this.set({ error: status >= 200 && status < 300 ? null : `Spotify a refusé le changement d'appareil (code ${status}).` });
    }, (e: unknown) => this.set({ error: e instanceof Error ? e.message : String(e) }));
  }
}

export const spotifyAccount = new SpotifyAccount();
