// Ce que le blocage du Mac change dans le système, et comment le défaire
// (Polymestre/Domain/StudyLockPlan.swift).
//
// Tant qu'une autre app est devant, les raccourcis du système marchent comme
// d'habitude. Pendant un blocage, on les éteint un par un — et il faut pouvoir
// les rallumer à coup sûr : le changement vit dans le système, pas dans l'app,
// et un raccourci que l'utilisateur·rice avait lui-même éteint ne doit jamais
// être rallumé à sa place.
//
// Tout ce qui décide est ici, pur et testé ; l'écriture dans le système est
// propre à macOS.

/** Les raccourcis du système éteints pendant un blocage (numéros `SLSSymbolicHotKeyName`). */
const ids: number[] = [
  1, 2,                       // ⌘Tab, ⇧⌘Tab
  64, 65, 100, 101, 187,      // Spotlight, ⌥⌘Espace, la touche Spotlight
  32, 33, 34, 35, 36, 37,     // Mission Control, fenêtres de l'app, bureau
  52,                         // Dock
  79, 80, 81, 82,             // bureaux à gauche / droite
  160, 161, 173, 174,         // Launchpad / Apps
  163,                        // Centre de notifications
  190,                        // Note rapide
  192, 193, 194, 195,         // bureaux (variantes)
  222,                        // Stage Manager
];
for (let id = 108; id <= 117; id++) ids.push(id); // Exposé, ancien clavier
for (let id = 118; id <= 149; id++) ids.push(id); // aller au bureau N

export const shortcutIDs: number[] = ids;

/** Jamais touchés : captures d'écran, ⌘` (changer de fenêtre de l'app). */
export const neverTouched = new Set([27, 28, 29, 30, 31, 184, 185]);

// MARK: Gestes du trackpad

/** Une préférence qui commande un geste : ce qu'on y écrit pour le bloquer. */
export interface GestureTarget {
  domain: string;
  key: string;
  /** La valeur qui bloque (0 / faux). */
  blocked: number;
  isBool: boolean;
}

export const trackpadDomains = [
  "com.apple.AppleMultitouchTrackpad",
  "com.apple.driver.AppleBluetoothMultitouch.trackpad",
];

export const gestureTargets: GestureTarget[] = (() => {
  const targets: GestureTarget[] = [];
  for (const domain of trackpadDomains) {
    for (const key of [
      "TrackpadThreeFingerVertSwipeGesture", "TrackpadFourFingerVertSwipeGesture",
      "TrackpadThreeFingerHorizSwipeGesture", "TrackpadFourFingerHorizSwipeGesture",
      "TrackpadFourFingerPinchGesture", "TrackpadFiveFingerPinchGesture",
      "TrackpadTwoFingerFromRightEdgeSwipeGesture",
    ]) {
      targets.push({ domain, key, blocked: 0, isBool: false });
    }
  }
  for (const key of [
    "showMissionControlGestureEnabled", "showAppExposeGestureEnabled",
    "showDesktopGestureEnabled", "showLaunchpadGestureEnabled",
  ]) {
    targets.push({ domain: "com.apple.dock", key, blocked: 0, isBool: true });
  }
  // Mission Control entier (clavier compris), pour le Dock.
  targets.push({ domain: "com.apple.dock", key: "mcx-expose-disabled", blocked: 1, isBool: true });
  return targets;
})();

/** La valeur d'origine d'une préférence de geste (`value: null` : elle n'existait pas). */
export interface GestureOriginal {
  domain: string;
  key: string;
  value: number | null;
}

/** Les valeurs d'origine à garder : celles d'une fiche existante gagnent. */
export function mergeGestures(
  existing: GestureOriginal[] | null | undefined,
  current: GestureOriginal[],
): GestureOriginal[] {
  return existing ?? current;
}

/** Ce que le blocage a changé, écrit **avant** de changer quoi que ce soit. */
export interface RecordInit {
  version?: number;
  shortcuts?: number[];
  dockAutohide?: boolean | null;
  menuBarAutohide?: boolean | null;
  gestures?: GestureOriginal[] | null;
  createdAt: Date;
}

export class StudyLockRecord {
  version: number;
  shortcuts: number[];
  /** `null` : pas touché. */
  dockAutohide: boolean | null;
  menuBarAutohide: boolean | null;
  gestures: GestureOriginal[] | null;
  createdAt: Date;

  constructor(o: RecordInit) {
    this.version = o.version ?? 1;
    this.shortcuts = [...(o.shortcuts ?? [])];
    this.dockAutohide = o.dockAutohide ?? null;
    this.menuBarAutohide = o.menuBarAutohide ?? null;
    this.gestures = o.gestures ? o.gestures.map((gesture) => ({ ...gesture })) : null;
    this.createdAt = o.createdAt;
  }
}

function cloneRecord(record: StudyLockRecord): StudyLockRecord {
  return new StudyLockRecord({
    version: record.version,
    shortcuts: record.shortcuts,
    dockAutohide: record.dockAutohide,
    menuBarAutohide: record.menuBarAutohide,
    gestures: record.gestures,
    createdAt: record.createdAt,
  });
}

/**
 * Les raccourcis à éteindre maintenant et la fiche à écrire d'abord.
 *
 * - Un raccourci déjà éteint qui n'est pas sur la fiche est celui de
 *   l'utilisateur·rice : on n'y touche pas.
 * - **Une fiche existante gagne** : ses valeurs d'origine restent.
 * - `dockNow` / `menuBarNow` ne servent que s'il n'y a pas de fiche.
 */
export function plan(
  wanted: number[],
  enabledNow: (id: number) => boolean,
  existing: StudyLockRecord | null,
  dockNow: boolean | null,
  menuBarNow: boolean | null,
  now: Date = new Date(),
): { disable: number[]; record: StudyLockRecord } {
  const record = existing
    ? cloneRecord(existing)
    : new StudyLockRecord({ dockAutohide: dockNow, menuBarAutohide: menuBarNow, createdAt: now });
  for (const id of wanted) {
    if (!neverTouched.has(id) && !record.shortcuts.includes(id) && enabledNow(id)) record.shortcuts.push(id);
  }
  return { disable: record.shortcuts.filter((id) => !neverTouched.has(id)), record };
}

/** Les raccourcis à rallumer : ceux de la fiche, rien d'autre. */
export function restore(record: StudyLockRecord): number[] {
  return record.shortcuts.filter((id) => !neverTouched.has(id));
}

// MARK: Fiche sur disque

/** `JSONEncoder` avec `.secondsSince1970` : les dates sont des secondes décimales. */
export function encode(record: StudyLockRecord): string {
  const object: Record<string, unknown> = {
    version: record.version,
    shortcuts: record.shortcuts,
    createdAt: record.createdAt.getTime() / 1000,
  };
  if (record.dockAutohide !== null) object.dockAutohide = record.dockAutohide;
  if (record.menuBarAutohide !== null) object.menuBarAutohide = record.menuBarAutohide;
  if (record.gestures !== null) {
    object.gestures = record.gestures.map((gesture) => {
      const encoded: Record<string, unknown> = { domain: gesture.domain, key: gesture.key };
      if (gesture.value !== null) encoded.value = gesture.value;
      return encoded;
    });
  }
  return JSON.stringify(object);
}

/** Relit une fiche ; `null` si le JSON est illisible. */
export function decode(data: string | null | undefined): StudyLockRecord | null {
  if (data === null || data === undefined) return null;
  let raw: unknown;
  try {
    raw = JSON.parse(data);
  } catch {
    return null;
  }
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const object = raw as Record<string, unknown>;
  if (!Array.isArray(object.shortcuts) || !object.shortcuts.every((id) => typeof id === "number")) return null;
  if (typeof object.createdAt !== "number" || !Number.isFinite(object.createdAt)) return null;
  if (typeof object.version !== "number") return null;
  let gestures: GestureOriginal[] | null = null;
  if (object.gestures !== undefined && object.gestures !== null) {
    if (!Array.isArray(object.gestures)) return null;
    gestures = [];
    for (const entry of object.gestures) {
      if (entry === null || typeof entry !== "object") return null;
      const gesture = entry as Record<string, unknown>;
      if (typeof gesture.domain !== "string" || typeof gesture.key !== "string") return null;
      if (gesture.value !== undefined && gesture.value !== null && typeof gesture.value !== "number") return null;
      gestures.push({ domain: gesture.domain, key: gesture.key, value: typeof gesture.value === "number" ? gesture.value : null });
    }
  }
  const booleanOrNull = (value: unknown): boolean | null | undefined =>
    value === undefined || value === null || typeof value === "boolean" ? (value ?? null) : undefined;
  const dock = booleanOrNull(object.dockAutohide);
  const menuBar = booleanOrNull(object.menuBarAutohide);
  if (dock === undefined || menuBar === undefined) return null;
  return new StudyLockRecord({
    version: object.version,
    shortcuts: object.shortcuts as number[],
    dockAutohide: dock,
    menuBarAutohide: menuBar,
    gestures,
    createdAt: new Date(object.createdAt * 1000),
  });
}

export const StudyLockPlan = {
  shortcutIDs,
  neverTouched,
  trackpadDomains,
  gestureTargets,
  mergeGestures,
  Record: StudyLockRecord,
  plan,
  restore,
  encode,
  decode,
};

// MARK: - Permission brève

/** Une app permise **un moment** : elle redevient bloquée à l'heure dite. */
export class TemporaryAllowance {
  private until = new Map<string, Date>();

  allow(bundleID: string, forSeconds: number, now: Date = new Date()): void {
    this.until.set(bundleID, new Date(now.getTime() + forSeconds * 1000));
  }

  /** Les apps encore permises à `now`. */
  allowed(at: Date = new Date()): Set<string> {
    const result = new Set<string>();
    for (const [bundleID, until] of this.until) if (until > at) result.add(bundleID);
    return result;
  }

  /** Quand la plus proche permission prend fin. */
  nextExpiry(after: Date = new Date()): Date | null {
    let next: Date | null = null;
    for (const until of this.until.values()) {
      if (until > after && (next === null || until < next)) next = until;
    }
    return next;
  }
}
