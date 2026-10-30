import { TaskType } from "../models/enums.ts";
import type { PomodoroSettings } from "./pomodoroEngine.ts";

/** Le petit magasin clé-valeur qui remplace `UserDefaults` : l'app le branche sur un fichier. */
export interface KeyValueStore {
  get(key: string): string | null;
  set(key: string, value: string): void;
  /** Sans `remove`, effacer écrit une chaîne vide (qui se relit comme « rien »). */
  remove?(key: string): void;
}

/** `date.addingTimeInterval(seconds)`, à la milliseconde. */
const adding = (date: Date, seconds: number) => new Date(Math.round(date.getTime() + seconds * 1000));
const secondsBetween = (later: Date, earlier: Date) => (later.getTime() - earlier.getTime()) / 1000;

/** La session de groupe à laquelle ce chrono est lié : son horloge est celle du groupe. */
export interface GroupSessionLink {
  sessionID: string;
  groupID: string;
  groupName: string;
}

/** Un morceau de session passé sur une cible précise. */
export interface FocusSegment {
  courseID?: string;
  taskTypeRaw: string;
  targetID?: string;
  seconds: number;
  /** Le temps d'une session de groupe **avant** qu'on la rejoigne : compté par
   * l'horloge commune, jamais enregistré pour soi. Optionnel (états d'avant). */
  excluded?: boolean;
}

/** `FocusSegment.taskType` : la valeur brute relue comme `TaskType`, « other » si elle est inconnue.
 * Le champ stocké reste `taskTypeRaw` (une chaîne), comme côté Swift : c'est lui que le JSON écrit. */
export function segmentTaskType(segment: FocusSegment): TaskType {
  return TaskType.fromRaw(segment.taskTypeRaw) ?? "other";
}

export function sameTarget(a: FocusSegment, b: FocusSegment): boolean {
  return (a.courseID ?? null) === (b.courseID ?? null)
    && a.taskTypeRaw === b.taskTypeRaw
    && (a.targetID ?? null) === (b.targetID ?? null)
    && (a.excluded ?? false) === (b.excluded ?? false);
}

/** L'état du chrono, tel qu'il survit à une fermeture de l'app.
 *
 * Le chrono vivait en mémoire, dans l'écran Focus : une app tuée par le système
 * (ou par l'étudiant·e, par réflexe) perdait la session en cours — une heure de
 * travail réel, disparue sans un mot. Cet objet **valeur** est écrit à chaque
 * changement d'état (démarrage, pause, reprise) et relu au lancement suivant : le
 * temps écoulé se déduit des dates, pas d'un compteur qui aurait dû tourner.
 *
 * Les champs absents (`undefined`) sont les `nil` de Swift ; les fonctions qui
 * changent l'état le font en place, comme les méthodes `mutating`. Copier une
 * session, c'est `{ ...state }`.
 */
export interface FocusTimerState {
  /** Secondes accumulées avant la période en cours. */
  accumulated: number;
  /** Début de la période en cours ; absent quand le chrono est en pause. */
  runningSince?: Date;
  /** Premier démarrage de la session (sert au journal et à la présence). */
  sessionStartedAt: Date;
  courseID?: string;
  taskTypeRaw: string;
  targetID?: string;
  note: string;
  contextLabel: string;
  pomodoro: boolean;
  /** Le temps de travail compté quand le cycle Pomodoro a commencé : allumé **en cours
   * de séance**, le premier bloc part de ce moment (et non du dernier multiple d'une
   * durée de bloc). Absent : depuis le début — les états écrits avant ce champ. */
  cycleOrigin?: number;
  /** Pause Pomodoro en cours : son type et ses bornes.
   *
   * Optionnels : un état écrit par une version précédente se relit, et
   * « pas de pause » est exactement l'absence. */
  breakKindRaw?: string;
  breakStartedAt?: Date;
  breakEndsAt?: Date;
  /** Le temps déjà passé sur les cibles **précédentes** de la session.
   *
   * On fait une série exercice après exercice, sans arrêter le chrono entre
   * deux : une heure notée « Exercices sur MATH-101 » ne disait pas que 3.2 a
   * pris quarante minutes et 3.3 dix. Chaque changement de cible clôt un
   * segment ; « Terminer » enregistre une session par cible. */
  segments?: FocusSegment[];
  /** Temps compté au moment où la cible actuelle a commencé. */
  currentTargetSince?: number;
  /** Mode étude : jusqu'à cette date, chaque appareil n'ouvre que ce qui sert
   * à travailler (Moodle, Claude, GoodNotes…). Voyage avec l'état du chrono :
   * lancé sur le Mac, il verrouille aussi l'iPhone. Absent : pas de mode étude. */
  studyUntil?: Date;
  /** Le début du mode étude (l'anneau de l'écran se remplit de là à `studyUntil`). */
  studySince?: Date;
  /** Le mode étude bloque-t-il le reste (apps, sites) ? `false` : un simple
   * écran de travail, rien n'est fermé. Absent vaut oui — les états publiés
   * avant ce champ, et un appareil plus ancien qui l'ignore, bloquent. */
  studyLocks?: boolean;
  /** Les durées du cycle Pomodoro **de cette session**, fixées par l'appareil
   * qui l'a démarrée et publiées avec elle.
   *
   * Chaque appareil lisait ses propres réglages : un Mac en 50/10 et un
   * iPhone en 25/5 ne coupaient pas le bloc au même instant, et l'îlot (bâti
   * par le Mac) contredisait l'app. Absent : un état publié avant ce champ —
   * les réglages de l'appareil s'appliquent, comme avant. */
  cycle?: PomodoroSettings;
  /** La session de groupe à laquelle ce chrono est lié, s'il l'est : son
   * horloge (marche, pause, pauses Pomodoro) est celle du groupe. */
  groupSession?: GroupSessionLink;
}

/** `FocusTimerState(...)` : les mêmes paramètres et valeurs par défaut que l'`init` de Swift. */
export function newFocusTimerState(init: Partial<Pick<FocusTimerState,
  "accumulated" | "runningSince" | "sessionStartedAt" | "courseID" | "taskTypeRaw" | "targetID"
  | "note" | "contextLabel" | "pomodoro">> = {}): FocusTimerState {
  const state: FocusTimerState = {
    accumulated: init.accumulated ?? 0,
    sessionStartedAt: init.sessionStartedAt ?? new Date(),
    taskTypeRaw: init.taskTypeRaw ?? "exercise",
    note: init.note ?? "",
    contextLabel: init.contextLabel ?? "",
    pomodoro: init.pomodoro ?? false,
  };
  if (init.runningSince) state.runningSince = init.runningSince;
  if (init.courseID !== undefined) state.courseID = init.courseID;
  if (init.targetID !== undefined) state.targetID = init.targetID;
  return state;
}

export function isRunning(state: FocusTimerState): boolean {
  return state.runningSince !== undefined;
}

/** Les durées du cycle de la session, sinon celles de l'appareil. */
export function cycleOr(state: FocusTimerState, local: PomodoroSettings): PomodoroSettings {
  return state.cycle ?? local;
}

/** `FocusTimerState.taskType` : la valeur brute relue comme `TaskType`, « other » si elle est inconnue. */
export function taskType(state: FocusTimerState): TaskType {
  return TaskType.fromRaw(state.taskTypeRaw) ?? "other";
}

/** Secondes écoulées à l'instant `now`. */
export function elapsed(state: FocusTimerState, now: Date = new Date()): number {
  return state.accumulated + (state.runningSince ? Math.max(0, secondsBetween(now, state.runningSince)) : 0);
}

/** Une session restaurée trop ancienne n'est plus une session : un chrono
 * oublié pendant trois jours ne vaut pas 72 h de travail. */
export const maxRestorableAge = 18 * 3600;

/** Faut-il proposer cette session à la reprise ?
 *
 * Une pause en cours compte comme une session vivante, même au tout
 * premier bloc : le chrono est arrêté, mais la session ne l'est pas.
 */
export function isRestorable(state: FocusTimerState, now: Date = new Date()): boolean {
  return (elapsed(state, now) >= 1 || state.breakEndsAt !== undefined)
    && secondsBetween(now, state.sessionStartedAt) < maxRestorableAge;
}

/** Reprendre le travail met fin à toute pause Pomodoro en cours. */
export function start(state: FocusTimerState, now: Date = new Date()): void {
  state.breakKindRaw = undefined;
  state.breakStartedAt = undefined;
  state.breakEndsAt = undefined;
  if (state.runningSince !== undefined) return;
  state.runningSince = now;
}

export function pause(state: FocusTimerState, now: Date = new Date()): void {
  if (!state.runningSince) return;
  state.accumulated += Math.max(0, secondsBetween(now, state.runningSince));
  state.runningSince = undefined;
}

// MARK: Segments

/** Change de cours, de type ou de cible **sans** couper le chrono : le temps
 * passé sur la cible précédente devient un segment.
 *
 * Rien ne change si la cible est la même — cocher une question n'ouvre pas
 * un segment de plus.
 */
export function switchContext(
  state: FocusTimerState,
  target: { courseID?: string; taskTypeRaw: string; targetID?: string },
  now: Date = new Date(),
): void {
  if ((target.courseID ?? null) === (state.courseID ?? null)
    && target.taskTypeRaw === state.taskTypeRaw
    && (target.targetID ?? null) === (state.targetID ?? null)) return;
  const total = elapsed(state, now);
  const since = Math.min(state.currentTargetSince ?? 0, total);
  const spent = total - since;
  if (spent >= 1) {
    const list = [...(state.segments ?? [])];
    list.push({ courseID: state.courseID, taskTypeRaw: state.taskTypeRaw, targetID: state.targetID, seconds: spent });
    state.segments = list;
  }
  state.currentTargetSince = total;
  state.courseID = target.courseID;
  state.taskTypeRaw = target.taskTypeRaw;
  state.targetID = target.targetID;
}

/** Temps passé sur la cible **actuelle** depuis qu'elle l'est. */
export function currentTargetElapsed(state: FocusTimerState, now: Date = new Date()): number {
  const total = elapsed(state, now);
  return Math.max(0, total - Math.min(state.currentTargetSince ?? 0, total));
}

/** La répartition du temps de la session, cible par cible, dans l'ordre.
 *
 * Deux passages sur la même cible (3.2, 3.3, retour à 3.2) sont fusionnés.
 * Si le total a été corrigé **à la baisse** sous la somme des segments, ils
 * sont réduits en proportion : la somme des sessions enregistrées est
 * toujours exactement le temps affiché.
 */
export function allocation(state: FocusTimerState, now: Date = new Date()): FocusSegment[] {
  const total = elapsed(state, now);
  let parts = (state.segments ?? []).map((segment) => ({ ...segment }));
  const prior = parts.reduce((sum, part) => sum + part.seconds, 0);
  if (prior > total && prior > 0) {
    const factor = total / prior;
    parts = parts.map((part) => ({ ...part, seconds: part.seconds * factor }));
  }
  const used = parts.reduce((sum, part) => sum + part.seconds, 0);
  parts.push({ courseID: state.courseID, taskTypeRaw: state.taskTypeRaw, targetID: state.targetID,
    seconds: Math.max(0, total - used) });
  const merged: FocusSegment[] = [];
  for (const part of parts) {
    const index = merged.findIndex((candidate) => sameTarget(candidate, part));
    if (index >= 0) {
      merged[index].seconds += part.seconds;
    } else {
      merged.push(part);
    }
  }
  return merged.filter((segment) => segment.seconds >= 1);
}

/** Les durées **entières** à enregistrer, dont la somme vaut le total arrondi.
 *
 * Arrondir chaque segment séparément perdait ou inventait des secondes.
 */
export function allocatedSeconds(
  state: FocusTimerState,
  now: Date = new Date(),
): { segment: FocusSegment; seconds: number }[] {
  const parts = allocation(state, now);
  const total = Math.trunc(elapsed(state, now));
  const result: { segment: FocusSegment; seconds: number }[] = [];
  let assigned = 0;
  parts.forEach((part, index) => {
    const seconds = index === parts.length - 1 ? Math.max(0, total - assigned) : Math.floor(part.seconds);
    assigned += seconds;
    result.push({ segment: part, seconds });
  });
  return result.filter((entry) => entry.seconds >= 1);
}

/** L'instant de référence des secondes affichées.
 *
 * Le temps compté change de seconde à des instants précis (quand
 * `elapsed` passe un entier ; une pause, à `breakEndsAt` moins un nombre
 * entier de secondes). Rafraîchir **sur ces frontières** — et non toutes
 * les secondes depuis l'ouverture de l'écran — fait changer les appareils à la
 * même seconde. Les 50 ms évitent de tomber pile sur la frontière
 * (et d'afficher la seconde d'avant par arrondi).
 */
export function tickAnchor(state: FocusTimerState | null | undefined, now: Date = new Date()): Date {
  if (!state) return now;
  let anchor: Date;
  if (state.breakEndsAt) {
    anchor = state.breakEndsAt;
  } else if (state.runningSince) {
    anchor = adding(state.runningSince, -state.accumulated);
  } else {
    anchor = state.sessionStartedAt;
  }
  return adding(anchor, 0.05);
}

// MARK: - Persistance

/** Date → « 2023-11-14T22:13:20Z », comme `.iso8601` de Swift (sans fractions de seconde). */
export function dateToJSON(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Une date lue : texte ISO 8601, ou nombre de secondes depuis 2001 (le format par défaut de `JSONEncoder`). */
export function dateFromJSON(value: unknown): Date | undefined {
  if (typeof value === "string") {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? undefined : date;
  }
  if (typeof value === "number" && Number.isFinite(value)) return new Date(Math.round((value + 978_307_200) * 1000));
  return undefined;
}

/** `JSON.stringify` avec les dates au format `.iso8601` ; les champs absents sont omis, comme les `nil`. */
export function encodeJSON(value: unknown): string {
  return JSON.stringify(value, function (this: Record<string, unknown>, key: string, v: unknown) {
    const original = this[key];
    return original instanceof Date ? dateToJSON(original) : v;
  });
}

/** `JSON.parse` qui traite `null` comme absent (un `Optional` de Swift). */
export function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text, (_key, v) => (v === null ? undefined : v));
  } catch {
    return undefined;
  }
}

const dateKeys = ["runningSince", "sessionStartedAt", "breakStartedAt", "breakEndsAt", "studyUntil", "studySince"] as const;

export function encodeFocusTimerState(state: FocusTimerState): string {
  return encodeJSON(state);
}

/** Relit un état ; `null` si les champs obligatoires manquent (comme un `decode` qui échoue). */
export function decodeFocusTimerState(text: string): FocusTimerState | null {
  const raw = parseJSON(text);
  if (typeof raw !== "object" || raw === null) return null;
  const object = raw as Record<string, unknown>;
  for (const key of dateKeys) {
    if (object[key] === undefined) continue;
    const date = dateFromJSON(object[key]);
    if (!date) return null;
    object[key] = date;
  }
  if (typeof object.accumulated !== "number" || !(object.sessionStartedAt instanceof Date)
    || typeof object.taskTypeRaw !== "string" || typeof object.note !== "string"
    || typeof object.contextLabel !== "string" || typeof object.pomodoro !== "boolean") return null;
  const segments = object.segments;
  if (segments !== undefined) {
    if (!Array.isArray(segments)) return null;
  }
  return object as unknown as FocusTimerState;
}

/** Persistance du chrono.
 *
 * Séparée de l'état pour que la logique reste testable sans toucher au disque.
 */
export const FocusTimerStore = {
  key: "focus.timerState",

  listeners: new Set<() => void>(),

  /** Appelé à chaque écriture (équivalent de la notification `didSave`) : le bandeau
   * « chrono en cours » suit l'état sans que l'écran Focus soit ouvert. */
  onDidSave(listener: () => void): () => void {
    FocusTimerStore.listeners.add(listener);
    return () => FocusTimerStore.listeners.delete(listener);
  },

  load(store: KeyValueStore): FocusTimerState | null {
    const text = store.get(FocusTimerStore.key);
    if (!text) return null;
    return decodeFocusTimerState(text);
  },

  save(state: FocusTimerState | null, store: KeyValueStore): void {
    try {
      if (!state) {
        if (store.remove) store.remove(FocusTimerStore.key);
        else store.set(FocusTimerStore.key, "");
        return;
      }
      store.set(FocusTimerStore.key, encodeFocusTimerState(state));
    } finally {
      FocusTimerStore.listeners.forEach((listener) => listener());
    }
  },
};

// MARK: - Session de groupe

/** L'horloge **commune** d'une session de groupe : ce qui se partage (la
 * marche, les pauses, le cycle Pomodoro), sans ce qui est à chacun (le cours,
 * l'exercice, la note). Tous les chronos liés ont la même : les blocs et les
 * pauses tombent au même instant chez tout le monde.
 */
export interface GroupClock {
  sessionStartedAt: Date;
  accumulated: number;
  runningSince?: Date;
  pomodoro: boolean;
  cycleOrigin?: number;
  cycle?: PomodoroSettings;
  breakKindRaw?: string;
  breakStartedAt?: Date;
  breakEndsAt?: Date;
}

export const GroupClock = {
  /** L'horloge d'un chrono. */
  from(state: FocusTimerState): GroupClock {
    return {
      sessionStartedAt: state.sessionStartedAt,
      accumulated: state.accumulated,
      runningSince: state.runningSince,
      pomodoro: state.pomodoro,
      cycleOrigin: state.cycleOrigin,
      cycle: state.cycle,
      breakKindRaw: state.breakKindRaw,
      breakStartedAt: state.breakStartedAt,
      breakEndsAt: state.breakEndsAt,
    };
  },

  /** Le temps compté par l'horloge à l'instant `now`. */
  elapsed(clock: GroupClock, now: Date = new Date()): number {
    return clock.accumulated + (clock.runningSince ? Math.max(0, secondsBetween(now, clock.runningSince)) : 0);
  },

  /** Pose l'horloge sur un chrono, sans toucher à son cours, sa cible ni ses segments. */
  apply(clock: GroupClock, state: FocusTimerState): void {
    state.sessionStartedAt = clock.sessionStartedAt;
    state.accumulated = clock.accumulated;
    state.runningSince = clock.runningSince;
    state.pomodoro = clock.pomodoro;
    state.cycleOrigin = clock.cycleOrigin;
    state.cycle = clock.cycle;
    state.breakKindRaw = clock.breakKindRaw;
    state.breakStartedAt = clock.breakStartedAt;
    state.breakEndsAt = clock.breakEndsAt;
  },

  /** Le chrono de quelqu'un qui **rejoint** la session maintenant : l'horloge
   * du groupe, son propre travail, et le temps déjà écoulé mis de côté (il
   * n'a pas travaillé avant d'arriver). */
  joining(
    clock: GroupClock,
    link: GroupSessionLink,
    own: { courseID?: string; taskTypeRaw: string; targetID?: string },
    now: Date = new Date(),
  ): FocusTimerState {
    const state = newFocusTimerState({
      sessionStartedAt: clock.sessionStartedAt,
      courseID: own.courseID,
      taskTypeRaw: own.taskTypeRaw,
      targetID: own.targetID,
      pomodoro: clock.pomodoro,
    });
    GroupClock.apply(clock, state);
    const before = GroupClock.elapsed(clock, now);
    if (before >= 1) {
      state.segments = [{ courseID: undefined, taskTypeRaw: "other", targetID: undefined, seconds: before, excluded: true }];
    }
    state.currentTargetSince = before;
    state.groupSession = link;
    return state;
  },
};
