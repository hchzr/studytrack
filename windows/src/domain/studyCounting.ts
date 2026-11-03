// Ce qui compte dans les « heures travaillées » (StudyTime.Counting, StudyTrack/Domain/StudyTime.swift) :
// l'étudiant·e choisit — cours en amphi de l'horaire (tout seuls, si confirmés, jamais), séances
// d'exercices de l'horaire, chrono, saisies à la main, Anki. Même clé et même JSON que le Mac.

export type LectureCounting = "automatic" | "confirmed" | "off";

export interface Counting {
  lectures: LectureCounting;
  exerciseSessions: boolean;
  timer: boolean;
  manual: boolean;
  anki: boolean;
}

export const COUNTING_KEY = "settings.counting";
export const standardCounting: Counting = { lectures: "automatic", exerciseSessions: false, timer: true, manual: true, anki: true };
/** Le plus long amphi de l'EPFL tient en 4 h : au-delà, ce n'est pas une séance. */
const longest = 4.5 * 3600;

export function readCounting(): Counting {
  try {
    const raw = globalThis.localStorage?.getItem(COUNTING_KEY);
    if (!raw) return standardCounting;
    const value = JSON.parse(raw) as Partial<Counting>;
    return {
      lectures: value.lectures === "confirmed" || value.lectures === "off" ? value.lectures : "automatic",
      exerciseSessions: value.exerciseSessions === true,
      timer: value.timer !== false,
      manual: value.manual !== false,
      anki: value.anki !== false,
    };
  } catch {
    return standardCounting;
  }
}

export function writeCounting(value: Counting): void {
  try { globalThis.localStorage?.setItem(COUNTING_KEY, JSON.stringify(value)); } catch { /* pour la session */ }
}

/** Une session (chrono, saisie, Anki) compte-t-elle ? */
export function countsSession(c: Counting, s: { taskTypeRaw: string; isManual: boolean; isFromAnki: boolean }): boolean {
  if (s.taskTypeRaw === "lecture" && c.lectures === "off") return false;
  if (s.isFromAnki) return c.anki;
  return s.isManual ? c.manual : c.timer;
}

export interface CountableEvent {
  kind: string;
  isSkipped: boolean;
  isAttended: boolean;
  durationSeconds: number;
  startsAt: Date;
  endsAt: Date;
  course: { isTracked: boolean } | null;
}

/** Une séance de l'horaire compte-t-elle d'elle-même ? (Fini, pas manqué, cours suivi.) */
export function countsEvent(c: Counting, e: CountableEvent, now = new Date()): boolean {
  if (e.isSkipped || e.durationSeconds <= 0 || e.durationSeconds > longest) return false;
  if (!e.course || !e.course.isTracked) return false;
  const over = e.endsAt.getTime() <= now.getTime() || e.isAttended;
  if (e.kind === "lecture") {
    if (c.lectures === "off") return false;
    return c.lectures === "confirmed" ? e.isAttended : over;
  }
  if (e.kind === "exerciseSession") return c.exerciseSessions && over;
  return false;
}

/** La séance peut-elle être cochée (« j'y étais » / « manqué ») ? */
export function isCheckable(c: Counting, e: CountableEvent, now = new Date()): boolean {
  if (!e.course || e.startsAt.getTime() > now.getTime()) return false;
  if (e.kind === "lecture") return c.lectures !== "off";
  if (e.kind === "exerciseSession") return c.exerciseSessions;
  return false;
}

/** Le geste de la coche : confirmer en mode « si confirmés », sinon manqué / compté de nouveau. */
export function toggleChecked(c: Counting, e: CountableEvent, now = new Date()): void {
  const on = countsEvent(c, e, now);
  if (e.kind === "lecture" && c.lectures === "confirmed") {
    e.isAttended = !on;
    if (!on) e.isSkipped = false;
  } else {
    e.isSkipped = on;
    if (on) e.isAttended = false;
    else if (e.endsAt.getTime() > now.getTime()) e.isAttended = true;
  }
}
