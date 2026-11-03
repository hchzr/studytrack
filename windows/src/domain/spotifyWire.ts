// Spotify comme son lecteur web se parle à lui-même (StudyTrack/Domain/SpotifyWire.swift, d'après
// SpotAPI) : session du site (`sp_dc`), jeton du lecteur web protégé par un TOTP, jeton client,
// puis Spotify Connect (`connect-state`) pour lire ce qui joue et piloter n'importe quel appareil
// du compte, gratuit ou Premium. Pur : aucun réseau (il vit dans `services/spotifyAccount.ts`).

export const SpotifyWire = {
  site: "https://open.spotify.com/",
  /** Après la connexion, la page « connecté·e » du même hôte : la fenêtre se ferme seule. */
  login: "https://accounts.spotify.com/login?continue=https%3A%2F%2Faccounts.spotify.com%2Fstatus",
  secretsURL: "https://code.thetadev.de/ThetaDev/spotify-secrets/raw/branch/main/secrets/secretDict.json",
  clientTokenURL: "https://clienttoken.spotify.com/v1/clienttoken",
  spclient: "https://gue1-spclient.spotify.com",
  fallbackClientVersion: "1.2.70.61.g856ccd63",
  fallbackSecret: { version: 61, bytes: [44, 55, 47, 42, 70, 40, 34, 114, 76, 74, 50, 111, 120, 97, 75, 76, 94, 102, 43, 69, 49, 120, 118, 80, 64, 78] },
  playlistsURL: "https://api.spotify.com/v1/me/playlists?limit=50",
  playerURL: "https://api.spotify.com/v1/me/player",
} as const;

export interface Secret { version: number; bytes: number[] }

export function latestSecret(json: unknown): Secret | null {
  if (!json || typeof json !== "object") return null;
  let best: Secret | null = null;
  for (const [key, value] of Object.entries(json as Record<string, unknown>)) {
    const version = Number(key);
    if (!Number.isInteger(version) || !Array.isArray(value) || value.length === 0) continue;
    if (!best || version > best.version) best = { version, bytes: value.map((n) => Number(n) & 0xff) };
  }
  return best;
}

/** La clé HMAC : chaque octet transformé (`e ^ (t % 33 + 9)`), en décimal, bout à bout. */
export function totpKey(secret: number[]): Uint8Array {
  return new TextEncoder().encode(secret.map((e, t) => String(e ^ ((t % 33) + 9))).join(""));
}

/** TOTP standard (HMAC-SHA1, 30 s, 6 chiffres). */
export async function totp(secret: number[], at: Date): Promise<string> {
  const counter = Math.floor(at.getTime() / 1000 / 30);
  const message = new Uint8Array(8);
  new DataView(message.buffer).setUint32(0, Math.floor(counter / 2 ** 32));
  new DataView(message.buffer).setUint32(4, counter >>> 0);
  const key = await crypto.subtle.importKey("raw", totpKey(secret) as BufferSource, { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
  const offset = mac[mac.length - 1] & 0x0f;
  const code = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
  return String(code % 1_000_000).padStart(6, "0");
}

export function tokenURL(code: string, version: number): string {
  const q = new URLSearchParams({ reason: "init", productType: "web-player", totp: code, totpServer: code, totpVer: String(version) });
  return `https://open.spotify.com/api/token?${q}`;
}

export interface WebToken { accessToken: string; clientID: string; expires: number; anonymous: boolean }

export function webToken(json: unknown): WebToken | null {
  const j = json as Record<string, unknown> | null;
  if (!j || typeof j.accessToken !== "string" || !j.accessToken) return null;
  const ms = Number(j.accessTokenExpirationTimestampMs ?? 0);
  return { accessToken: j.accessToken, clientID: String(j.clientId ?? ""), expires: ms > 0 ? ms : Date.now() + 3_000_000, anonymous: j.isAnonymous === true };
}

export function clientVersion(html: string): string | null {
  const m = /<script id="appServerConfig" type="text\/plain">([^<]+)<\/script>/.exec(html);
  if (!m) return null;
  try { return (JSON.parse(atob(m[1].trim())) as { clientVersion?: string }).clientVersion ?? null; } catch { return null; }
}

export function clientTokenBody(version: string, clientID: string, deviceID: string) {
  return { client_data: { client_version: version, client_id: clientID, js_sdk_data: { device_brand: "unknown", device_model: "unknown", os: "windows", os_version: "NT 10.0", device_id: deviceID, device_type: "computer" } } };
}

export function clientToken(json: unknown): string | null {
  const j = json as { response_type?: string; granted_token?: { token?: string } } | null;
  return j?.response_type === "RESPONSE_GRANTED_TOKEN_RESPONSE" ? j.granted_token?.token ?? null : null;
}

export const dealerURL = (token: string) => `wss://dealer.spotify.com/?access_token=${encodeURIComponent(token)}`;

export function connectionID(message: unknown): string | null {
  const headers = (message as { headers?: Record<string, unknown> } | null)?.headers;
  const id = headers?.["Spotify-Connection-Id"];
  return typeof id === "string" ? id : null;
}

export const observerURL = (deviceID: string) => `${SpotifyWire.spclient}/connect-state/v1/devices/hobs_${deviceID}`;
export const observerBody = { member_type: "CONNECT_STATE", device: { device_info: { capabilities: { can_be_player: false, hidden: true, needs_full_player_state: true } } } };
export const commandURL = (from: string, to: string) => `${SpotifyWire.spclient}/connect-state/v1/player/command/from/${from}/to/${to}`;
export const transferURL = (from: string, to: string) => `${SpotifyWire.spclient}/connect-state/v1/connect/transfer/from/${from}/to/${to}`;
export const volumeURL = (from: string, to: string) => `${SpotifyWire.spclient}/connect-state/v1/connect/volume/from/${from}/to/${to}`;

export function randomHex(count: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(Math.ceil(count / 2)));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("").slice(0, count);
}

export type Command =
  | { kind: "pause" } | { kind: "resume" } | { kind: "next" } | { kind: "previous" }
  | { kind: "seek"; ms: number } | { kind: "shuffle"; on: boolean }
  | { kind: "repeat"; context: boolean; track: boolean } | { kind: "play"; uri: string };

export function commandBody(command: Command): { command: Record<string, unknown> } {
  const body: Record<string, unknown> = { logging_params: { page_instance_ids: [], interaction_ids: [], command_id: randomHex(32) } };
  switch (command.kind) {
    case "pause": body.endpoint = "pause"; break;
    case "resume": body.endpoint = "resume"; break;
    case "next": body.endpoint = "skip_next"; break;
    case "previous": body.endpoint = "skip_prev"; break;
    case "seek": body.endpoint = "seek_to"; body.value = command.ms; break;
    case "shuffle": body.endpoint = "set_shuffling_context"; body.value = command.on; break;
    case "repeat": body.endpoint = "set_options"; body.repeating_context = command.context; body.repeating_track = command.track; break;
    case "play":
      body.endpoint = "play";
      body.context = { uri: command.uri, url: `context://${command.uri}`, metadata: {} };
      body.play_origin = { feature_identifier: command.uri.split(":")[1] ?? "playlist", referrer_identifier: "home" };
      body.options = { license: "tft", player_options_override: {} };
      break;
  }
  return { command: body };
}

export const transferBody = (resume: boolean) => ({ transfer_options: { restore_paused: resume ? "resume" : "pause" }, command_id: randomHex(32) });
export const volumeBody = (fraction: number) => ({ volume: Math.round(Math.min(Math.max(fraction, 0), 1) * 65535) });

export interface Device { id: string; name: string; type: string; volume: number | null; canPlay: boolean }
export interface Track { uri: string; title: string; artist: string; album: string; artwork: string | null }
export interface Now {
  track: Track | null;
  isPlaying: boolean;
  /** Position en secondes, mesurée à `measuredAt` (ms). */
  position: number;
  measuredAt: number;
  duration: number;
  shuffle: boolean;
  repeatContext: boolean;
  repeatTrack: boolean;
  contextURI: string | null;
  originDevice: string | null;
  activeDevice: string | null;
  devices: Device[];
  upNext: Track[];
}

export const emptyNow = (): Now => ({ track: null, isPlaying: false, position: 0, measuredAt: Date.now(), duration: 0, shuffle: false, repeatContext: false, repeatTrack: false, contextURI: null, originDevice: null, activeDevice: null, devices: [], upNext: [] });

export function elapsed(now: Now, at: number): number {
  if (!now.isPlaying) return Math.min(now.position, now.duration);
  return Math.min(now.position + (at - now.measuredAt) / 1000, Math.max(now.duration, 0));
}

export function imageURL(raw: unknown): string | null {
  if (typeof raw !== "string" || !raw) return null;
  return raw.startsWith("spotify:image:") ? `https://i.scdn.co/image/${raw.slice("spotify:image:".length)}` : raw;
}

const num = (v: unknown): number | null => (typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" && !Number.isNaN(Number(v)) ? Number(v) : null);

export function track(raw: unknown): Track | null {
  const r = raw as { uri?: string; metadata?: Record<string, unknown> } | null;
  if (!r || typeof r.uri !== "string" || !r.uri) return null;
  const meta = r.metadata ?? {};
  const str = (k: string) => (typeof meta[k] === "string" ? (meta[k] as string) : "");
  return { uri: r.uri, title: str("title"), artist: str("artist_name") || str("album_artist_name"), album: str("album_title"), artwork: imageURL(meta.image_large_url ?? meta.image_url ?? meta.image_xlarge_url) };
}

export const trackID = (t: Track | null) => (t?.uri.startsWith("spotify:track:") ? t.uri.slice("spotify:track:".length) : null);

/** L'état Connect (`{active_device_id, player_state, devices}`, ou `{cluster: …}` du dealer). */
export function nowFromCluster(object: Record<string, unknown>, at = Date.now()): Now {
  const cluster = (object.cluster as Record<string, unknown> | undefined) ?? object;
  const now = emptyNow();
  now.measuredAt = at;
  now.activeDevice = typeof cluster.active_device_id === "string" ? cluster.active_device_id : null;
  const devices = cluster.devices as Record<string, Record<string, unknown>> | undefined;
  if (devices) {
    now.devices = Object.entries(devices)
      .filter(([, d]) => (d.capabilities as { hidden?: boolean } | undefined)?.hidden !== true)
      .map(([id, d]) => ({
        id: typeof d.device_id === "string" ? d.device_id : id,
        name: typeof d.name === "string" ? d.name : "Appareil",
        type: typeof d.device_type === "string" ? d.device_type : "computer",
        volume: num(d.volume) === null ? null : (num(d.volume) as number) / 65535,
        canPlay: d.can_play !== false,
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }
  const state = cluster.player_state as Record<string, unknown> | undefined;
  if (!state) return now;
  now.track = track(state.track);
  now.isPlaying = state.is_playing === true && state.is_paused !== true && now.activeDevice !== null;
  now.duration = (num(state.duration) ?? 0) / 1000;
  let position = (num(state.position_as_of_timestamp) ?? 0) / 1000;
  const stamp = num(state.timestamp);
  const server = num(cluster.server_timestamp_ms);
  if (now.isPlaying && stamp !== null && server !== null) position += Math.max(0, (server - stamp) / 1000);
  now.position = Math.max(0, position);
  const options = (state.options as Record<string, unknown> | undefined) ?? {};
  now.shuffle = options.shuffling_context === true;
  now.repeatContext = options.repeating_context === true;
  now.repeatTrack = options.repeating_track === true;
  now.contextURI = typeof state.context_uri === "string" ? state.context_uri : null;
  const origin = (state.play_origin as { device_identifier?: unknown } | undefined)?.device_identifier;
  now.originDevice = typeof origin === "string" ? origin : null;
  now.upNext = ((state.next_tracks as unknown[] | undefined) ?? []).map(track)
    .filter((t): t is Track => t !== null && !t.uri.startsWith("spotify:delimiter")).slice(0, 20);
  return now;
}

/** La Web API (`/v1/me/player`), quand le dealer ne répond pas : même forme. */
export function nowFromWebAPI(json: unknown, at = Date.now()): Now {
  const now = emptyNow();
  now.measuredAt = at;
  const j = json as Record<string, unknown> | null;
  if (!j) return now;
  const item = j.item as Record<string, unknown> | undefined;
  if (item && typeof item.uri === "string") {
    const album = item.album as { name?: string; images?: { url?: string }[] } | undefined;
    now.track = {
      uri: item.uri, title: String(item.name ?? ""),
      artist: ((item.artists as { name?: string }[] | undefined) ?? []).map((a) => a.name).filter(Boolean).join(", "),
      album: album?.name ?? "", artwork: album?.images?.[0]?.url ?? null,
    };
    now.duration = Number(item.duration_ms ?? 0) / 1000;
  }
  now.isPlaying = j.is_playing === true;
  now.position = Number(j.progress_ms ?? 0) / 1000;
  now.shuffle = j.shuffle_state === true;
  now.repeatContext = j.repeat_state === "context" || j.repeat_state === "track";
  now.repeatTrack = j.repeat_state === "track";
  now.contextURI = (j.context as { uri?: string } | undefined)?.uri ?? null;
  const device = j.device as { id?: string; name?: string; type?: string; volume_percent?: number } | undefined;
  if (device?.id) {
    now.activeDevice = device.id;
    now.devices = [{ id: device.id, name: device.name ?? "Appareil", type: device.type ?? "computer", volume: typeof device.volume_percent === "number" ? device.volume_percent / 100 : null, canPlay: true }];
  }
  return now;
}

/** Les charges utiles (JSON) d'un message du dealer, si c'est une mise à jour de l'état. */
export async function clusterPayloads(message: unknown): Promise<Record<string, unknown>[]> {
  const m = message as { uri?: string; headers?: Record<string, string>; payloads?: unknown[] } | null;
  if (!m || typeof m.uri !== "string" || !m.uri.startsWith("hm://connect-state/v1/cluster") || !Array.isArray(m.payloads)) return [];
  const gzip = (m.headers?.["Transfer-Encoding"] ?? "").toLowerCase() === "gzip";
  const out: Record<string, unknown>[] = [];
  for (const payload of m.payloads) {
    try {
      if (payload && typeof payload === "object") { out.push(payload as Record<string, unknown>); continue; }
      if (typeof payload !== "string") continue;
      const bytes = Uint8Array.from(atob(payload), (c) => c.charCodeAt(0));
      const text = gzip ? await gunzip(bytes) : new TextDecoder().decode(bytes);
      out.push(JSON.parse(text) as Record<string, unknown>);
    } catch { /* charge illisible : ignorée */ }
  }
  return out;
}

async function gunzip(bytes: Uint8Array): Promise<string> {
  const stream = new Blob([bytes as BlobPart]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Response(stream).text();
}

export interface Playlist { uri: string; name: string; image: string | null; owner: string }

export function playlists(json: unknown): Playlist[] {
  const items = (json as { items?: unknown[] } | null)?.items;
  if (!Array.isArray(items)) return [];
  return items.flatMap((raw) => {
    const i = raw as { uri?: string; name?: string; images?: { url?: string }[] | null; owner?: { display_name?: string } } | null;
    if (!i || typeof i.uri !== "string" || typeof i.name !== "string") return [];
    return [{ uri: i.uri, name: i.name, image: i.images?.[0]?.url ?? null, owner: i.owner?.display_name ?? "" }];
  });
}

export const trackURL = (id: string) => `https://api.spotify.com/v1/tracks/${id}`;

export function trackDetails(json: unknown): { artist: string; album: string; artwork: string | null } | null {
  const j = json as { artists?: { name?: string }[]; album?: { name?: string; images?: { url?: string }[] } } | null;
  if (!j) return null;
  return { artist: (j.artists ?? []).map((a) => a.name).filter(Boolean).join(", "), album: j.album?.name ?? "", artwork: j.album?.images?.[0]?.url ?? null };
}

/** `https://open.spotify.com/playlist/…` ou `spotify:playlist:…` → l'URI. */
export function spotifyURI(text: string): string | null {
  const value = text.trim();
  if (/^spotify:(playlist|album|artist|track|show|episode):[A-Za-z0-9]+$/.test(value)) return value;
  const web = /open\.spotify\.com\/(?:intl-[a-z-]+\/)?(playlist|album|artist|track|show|episode)\/([A-Za-z0-9]+)/.exec(value);
  return web ? `spotify:${web[1]}:${web[2]}` : null;
}

export function deviceIcon(type: string): string {
  switch (type.toLowerCase()) {
    case "smartphone": return "iphone";
    case "tablet": return "ipad";
    case "speaker": case "cast_audio": case "audio_dongle": return "hifispeaker";
    case "tv": case "cast_video": case "stb": return "tv";
    default: return "laptopcomputer";
  }
}
