// Un seul lecteur pour le Mac et l'iPhone (StudyTrack/Domain/MusicLink.swift) :
// ce qui joue sur l'un se voit et se pilote depuis l'autre.
//
// Les messages voyagent par le lien du chrono, chiffrés de la même clé. Chaque
// appareil publie **son** état quand il change ; une commande vise un appareil.
// Le chiffrement (WebCrypto) est asynchrone, comme dans `TimerLink`.

import { newId } from "../models/relations.ts";
import { TimerLink } from "./timerLink.ts";

export type MusicPlatform = "mac" | "iphone" | "ipad";

export const MusicPlatform = {
  allCases: ["mac", "iphone", "ipad"] as readonly MusicPlatform[],

  label(platform: MusicPlatform): string {
    switch (platform) {
      case "mac": return "Mac";
      case "iphone": return "iPhone";
      case "ipad": return "iPad";
    }
  },

  icon(platform: MusicPlatform): string {
    switch (platform) {
      case "mac": return "laptopcomputer";
      case "iphone": return "iphone";
      case "ipad": return "ipad";
    }
  },
};

export interface MusicItemInit {
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  duration?: number;
}

export class MusicItem {
  title: string | null;
  artist: string | null;
  album: string | null;
  duration: number;

  constructor(o: MusicItemInit = {}) {
    this.title = o.title ?? null;
    this.artist = o.artist ?? null;
    this.album = o.album ?? null;
    this.duration = o.duration ?? 0;
  }
}

export interface MusicStateInit {
  device: string;
  platform: MusicPlatform;
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  duration?: number;
  elapsed?: number;
  readAt: Date;
  isPlaying?: boolean;
  shuffle?: boolean;
  /** `off`, `all`, `one`. */
  repeatMode?: string;
  volume?: number | null;
  artworkURL?: string | null;
  upNext?: MusicItem[];
  updatedAt: Date;
}

/** Ce qui joue sur un appareil. */
export class MusicState {
  device: string;
  platform: MusicPlatform;
  title: string | null;
  artist: string | null;
  album: string | null;
  duration: number;
  elapsed: number;
  readAt: Date;
  isPlaying: boolean;
  shuffle: boolean;
  repeatMode: string;
  volume: number | null;
  artworkURL: string | null;
  upNext: MusicItem[];
  updatedAt: Date;

  constructor(o: MusicStateInit) {
    this.device = o.device;
    this.platform = o.platform;
    this.title = o.title ?? null;
    this.artist = o.artist ?? null;
    this.album = o.album ?? null;
    this.duration = o.duration ?? 0;
    this.elapsed = o.elapsed ?? 0;
    this.readAt = o.readAt;
    this.isPlaying = o.isPlaying ?? false;
    this.shuffle = o.shuffle ?? false;
    this.repeatMode = o.repeatMode ?? "off";
    this.volume = o.volume ?? null;
    this.artworkURL = o.artworkURL ?? null;
    this.upNext = o.upNext ?? [];
    this.updatedAt = o.updatedAt;
  }

  get hasTrack(): boolean { return hasTrack(this); }

  /** La position à `date` : elle se déduit de l'instant de lecture, pas d'un compteur. */
  elapsedAt(date: Date): number { return elapsedAt(this, date); }

  /** Joue-t-il encore, vraisemblablement ? Un état « en lecture » trop vieux ne compte plus. */
  isLive(date: Date): boolean { return isLive(this, date); }
}

/** Un état, décrit par ses champs (la classe ou un objet littéral). */
export type MusicStateLike = MusicState | MusicStateInit;

/** L'état a-t-il un morceau ? */
export function hasTrack(state: MusicStateLike): boolean {
  return (state.title ?? null) !== null;
}

/** La position à `date`, en secondes. */
export function elapsedAt(state: MusicStateLike, date: Date): number {
  const elapsed = state.elapsed ?? 0;
  if (!(state.isPlaying ?? false)) return elapsed;
  const duration = state.duration ?? 0;
  const limit = duration > 0 ? duration : Infinity;
  return Math.min(limit, Math.max(0, elapsed + (date.getTime() - state.readAt.getTime()) / 1000));
}

/** L'état « en lecture » est-il encore vraisemblable à `date` ? */
export function isLive(state: MusicStateLike, date: Date): boolean {
  if (!(state.isPlaying ?? false)) return false;
  const duration = state.duration ?? 0;
  const elapsed = state.elapsed ?? 0;
  const horizon = duration > 0 ? Math.max(0, duration - elapsed) + 120 : 3600;
  return (date.getTime() - state.readAt.getTime()) / 1000 < horizon;
}

export type MusicAction =
  | { kind: "toggle" }
  | { kind: "play" }
  | { kind: "pause" }
  | { kind: "next" }
  | { kind: "previous" }
  | { kind: "seek"; seconds: number }
  | { kind: "volume"; value: number }
  | { kind: "shuffle"; value: boolean }
  | { kind: "repeatMode"; value: string }
  /** Jouer ces morceaux du catalogue, à partir de `index`. */
  | { kind: "playCatalog"; ids: string[]; index: number; shuffled: boolean }
  /** À suivre (`next`) ou à la fin de la file. */
  | { kind: "enqueue"; ids: string[]; next: boolean }
  /** Reprendre ici ce morceau, à cette seconde (la musique change d'appareil). */
  | { kind: "handoff"; item: MusicItem; elapsed: number; playing: boolean }
  | { kind: "announce" };

export interface MusicCommandInit {
  id?: string;
  from: string;
  /** L'appareil visé (`null` : tous les autres). */
  to?: string | null;
  action: MusicAction;
  sentAt: Date;
}

export class MusicCommand {
  id: string;
  from: string;
  to: string | null;
  action: MusicAction;
  sentAt: Date;

  constructor(o: MusicCommandInit) {
    this.id = o.id ?? newId();
    this.from = o.from;
    this.to = o.to ?? null;
    this.action = o.action;
    this.sentAt = o.sentAt;
  }
}

export type MusicMessage = { kind: "state"; state: MusicState } | { kind: "command"; command: MusicCommand };

// MARK: Codage (`Codable` synthétisé : `{"state":{"_0":…}}`)

/** `Date` → secondes depuis 2001 (le format par défaut de `JSONEncoder`). */
function referenceSeconds(date: Date): number {
  return date.getTime() / 1000 - 978_307_200;
}

function encodeItem(item: MusicItem): Record<string, unknown> {
  const object: Record<string, unknown> = { duration: item.duration };
  if (item.title !== null) object.title = item.title;
  if (item.artist !== null) object.artist = item.artist;
  if (item.album !== null) object.album = item.album;
  return object;
}

function encodeState(state: MusicState): Record<string, unknown> {
  const object: Record<string, unknown> = {
    device: state.device,
    platform: state.platform,
    duration: state.duration,
    elapsed: state.elapsed,
    readAt: referenceSeconds(state.readAt),
    isPlaying: state.isPlaying,
    shuffle: state.shuffle,
    repeatMode: state.repeatMode,
    upNext: state.upNext.map(encodeItem),
    updatedAt: referenceSeconds(state.updatedAt),
  };
  if (state.title !== null) object.title = state.title;
  if (state.artist !== null) object.artist = state.artist;
  if (state.album !== null) object.album = state.album;
  if (state.volume !== null) object.volume = state.volume;
  if (state.artworkURL !== null) object.artworkURL = state.artworkURL;
  return object;
}

function encodeAction(action: MusicAction): Record<string, unknown> {
  switch (action.kind) {
    case "toggle": case "play": case "pause": case "next": case "previous": case "announce":
      return { [action.kind]: {} };
    case "seek": return { seek: { _0: action.seconds } };
    case "volume": return { volume: { _0: action.value } };
    case "shuffle": return { shuffle: { _0: action.value } };
    case "repeatMode": return { repeatMode: { _0: action.value } };
    case "playCatalog":
      return { playCatalog: { _0: action.ids, index: action.index, shuffled: action.shuffled } };
    case "enqueue": return { enqueue: { _0: action.ids, next: action.next } };
    case "handoff":
      return { handoff: { _0: encodeItem(action.item), elapsed: action.elapsed, playing: action.playing } };
  }
}

function encodeCommand(command: MusicCommand): Record<string, unknown> {
  const object: Record<string, unknown> = {
    id: command.id,
    from: command.from,
    action: encodeAction(command.action),
    sentAt: referenceSeconds(command.sentAt),
  };
  if (command.to !== null) object.to = command.to;
  return object;
}

function encodeMessage(message: MusicMessage): string {
  return JSON.stringify(message.kind === "state"
    ? { state: { _0: encodeState(message.state) } }
    : { command: { _0: encodeCommand(message.command) } });
}

function decodeDate(value: unknown): Date | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return new Date((value + 978_307_200) * 1000);
}

function decodeItem(raw: unknown): MusicItem | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const stringOrNull = (value: unknown): string | null | undefined =>
    value === undefined || value === null ? null : typeof value === "string" ? value : undefined;
  const title = stringOrNull(o.title);
  const artist = stringOrNull(o.artist);
  const album = stringOrNull(o.album);
  if (title === undefined || artist === undefined || album === undefined) return null;
  if (typeof o.duration !== "number") return null;
  return new MusicItem({ title, artist, album, duration: o.duration });
}

function decodeState(raw: unknown): MusicState | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.device !== "string") return null;
  if (o.platform !== "mac" && o.platform !== "iphone" && o.platform !== "ipad") return null;
  if (typeof o.duration !== "number" || typeof o.elapsed !== "number") return null;
  const readAt = decodeDate(o.readAt);
  const updatedAt = decodeDate(o.updatedAt);
  if (!readAt || !updatedAt) return null;
  if (typeof o.isPlaying !== "boolean" || typeof o.shuffle !== "boolean" || typeof o.repeatMode !== "string") return null;
  if (!Array.isArray(o.upNext)) return null;
  const upNext: MusicItem[] = [];
  for (const entry of o.upNext) {
    const item = decodeItem(entry);
    if (!item) return null;
    upNext.push(item);
  }
  const optionalString = (value: unknown): string | null | undefined =>
    value === undefined || value === null ? null : typeof value === "string" ? value : undefined;
  const title = optionalString(o.title);
  const artist = optionalString(o.artist);
  const album = optionalString(o.album);
  const artworkURL = optionalString(o.artworkURL);
  if (title === undefined || artist === undefined || album === undefined || artworkURL === undefined) return null;
  let volume: number | null = null;
  if (o.volume !== undefined && o.volume !== null) {
    if (typeof o.volume !== "number") return null;
    volume = o.volume;
  }
  return new MusicState({
    device: o.device,
    platform: o.platform,
    title,
    artist,
    album,
    duration: o.duration,
    elapsed: o.elapsed,
    readAt,
    isPlaying: o.isPlaying,
    shuffle: o.shuffle,
    repeatMode: o.repeatMode,
    volume,
    artworkURL,
    upNext,
    updatedAt,
  });
}

function decodeAction(raw: unknown): MusicAction | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const entries = Object.entries(raw as Record<string, unknown>);
  if (entries.length !== 1) return null;
  const [kind, payload] = entries[0];
  if (payload === null || typeof payload !== "object") return null;
  const p = payload as Record<string, unknown>;
  switch (kind) {
    case "toggle": case "play": case "pause": case "next": case "previous": case "announce":
      return { kind };
    case "seek": return typeof p._0 === "number" ? { kind: "seek", seconds: p._0 } : null;
    case "volume": return typeof p._0 === "number" ? { kind: "volume", value: p._0 } : null;
    case "shuffle": return typeof p._0 === "boolean" ? { kind: "shuffle", value: p._0 } : null;
    case "repeatMode": return typeof p._0 === "string" ? { kind: "repeatMode", value: p._0 } : null;
    case "playCatalog":
      if (!Array.isArray(p._0) || !p._0.every((id) => typeof id === "string")) return null;
      if (typeof p.index !== "number" || typeof p.shuffled !== "boolean") return null;
      return { kind: "playCatalog", ids: p._0 as string[], index: p.index, shuffled: p.shuffled };
    case "enqueue":
      if (!Array.isArray(p._0) || !p._0.every((id) => typeof id === "string")) return null;
      if (typeof p.next !== "boolean") return null;
      return { kind: "enqueue", ids: p._0 as string[], next: p.next };
    case "handoff": {
      const item = decodeItem(p._0);
      if (!item || typeof p.elapsed !== "number" || typeof p.playing !== "boolean") return null;
      return { kind: "handoff", item, elapsed: p.elapsed, playing: p.playing };
    }
    default: return null;
  }
}

function decodeMessage(raw: unknown): MusicMessage | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  if ("state" in o) {
    const payload = o.state as Record<string, unknown> | null;
    const state = payload && typeof payload === "object" ? decodeState(payload._0) : null;
    return state ? { kind: "state", state } : null;
  }
  if ("command" in o) {
    const payload = o.command as Record<string, unknown> | null;
    if (!payload || typeof payload !== "object") return null;
    const c = payload._0 as Record<string, unknown> | undefined;
    if (!c || typeof c !== "object") return null;
    if (typeof c.id !== "string" || typeof c.from !== "string") return null;
    const sentAt = decodeDate(c.sentAt);
    if (!sentAt) return null;
    if (c.to !== undefined && c.to !== null && typeof c.to !== "string") return null;
    const action = decodeAction(c.action);
    if (!action) return null;
    return {
      kind: "command",
      command: new MusicCommand({ id: c.id, from: c.from, to: typeof c.to === "string" ? c.to : null, action, sentAt }),
    };
  }
  return null;
}

// MARK: Chiffrement (la clé du lien du chrono)

/** Chiffre un message ; `null` si le codage échoue. */
export async function seal(message: MusicMessage, key: CryptoKey): Promise<string | null> {
  try {
    return await TimerLink.sealText(encodeMessage(message), key);
  } catch {
    return null;
  }
}

/** Relit un message ; `null` si le texte est illisible ou mal formé. */
export async function open(text: string, key: CryptoKey): Promise<MusicMessage | null> {
  const plain = await TimerLink.openText(text, key);
  if (plain === null) return null;
  try {
    return decodeMessage(JSON.parse(plain));
  } catch {
    return null;
  }
}

// MARK: Quel lecteur montrer

export type MusicRoute = { kind: "local" } | { kind: "remote"; device: string };

const localRoute: MusicRoute = { kind: "local" };
const remoteRoute = (device: string): MusicRoute => ({ kind: "remote", device });

/** Le lecteur à montrer : celui qui joue, ici d'abord, sinon l'autre appareil. */
export function route(
  localPlaying: boolean,
  localHasTrack: boolean,
  remotes: MusicStateLike[],
  pinned: string | null,
  now: Date,
): MusicRoute {
  if (localPlaying) return localRoute;
  let playing: MusicStateLike | null = null;
  for (const state of remotes) {
    if (!isLive(state, now)) continue;
    if (playing === null || state.updatedAt > playing.updatedAt) playing = state;
  }
  if (playing) return remoteRoute(playing.device);
  if (pinned !== null && remotes.some((state) => state.device === pinned && hasTrack(state))) return remoteRoute(pinned);
  if (localHasTrack) return localRoute;
  let other: MusicStateLike | null = null;
  for (const state of remotes) {
    if (!hasTrack(state)) continue;
    if (other === null || state.updatedAt > other.updatedAt) other = state;
  }
  if (other) return remoteRoute(other.device);
  return localRoute;
}

function sameItems(a: MusicItem[], b: MusicItem[]): boolean {
  return JSON.stringify(normalizeItems(a)) === JSON.stringify(normalizeItems(b));
}

function normalizeItems(items: MusicItem[]): unknown[] {
  return items.map((item) => ({ title: item.title ?? null, artist: item.artist ?? null, album: item.album ?? null, duration: item.duration ?? 0 }));
}

/** Faut-il republier ? Pas pour une position qui avance d'elle-même. */
export function changed(old: MusicStateLike | null | undefined, next: MusicStateLike): boolean {
  if (!old) return true;
  const oldTitle = old.title ?? null;
  const nextTitle = next.title ?? null;
  const oldArtist = old.artist ?? null;
  const nextArtist = next.artist ?? null;
  if (oldTitle !== nextTitle || oldArtist !== nextArtist
    || (old.isPlaying ?? false) !== (next.isPlaying ?? false)
    || (old.shuffle ?? false) !== (next.shuffle ?? false)
    || (old.repeatMode ?? "off") !== (next.repeatMode ?? "off")
    || !sameItems(old.upNext ?? [], next.upNext ?? [])
    || (old.artworkURL ?? null) !== (next.artworkURL ?? null)) {
    return true;
  }
  const oldVolume = old.volume ?? null;
  const nextVolume = next.volume ?? null;
  if (oldVolume !== null && nextVolume !== null && Math.abs(oldVolume - nextVolume) > 0.02) return true;
  if ((oldVolume === null) !== (nextVolume === null)) return true;
  // Un saut dans le morceau : la position attendue et la lue divergent.
  return Math.abs(elapsedAt(old, next.readAt) - (next.elapsed ?? 0)) > 3;
}

export const MusicLink = {
  Platform: MusicPlatform,
  Item: MusicItem,
  State: MusicState,
  Command: MusicCommand,
  seal,
  open,
  route,
  changed,
};
