// Le bureau prend la forme du moment (StudyTrack/Domain/DeskMoment.swift).
//
// `Calendar.current` devient l'heure locale de la machine. Les dates sont des `Date` ;
// les intervalles de temps, des secondes. `Data` (l'encodage des repères) devient une
// chaîne JSON. `FocusContext.Slot` (FocusTargets.swift, pas encore porté) est décrit ici
// par `FocusContextSlot`, et `StudyMode.minuteRange` (StudyMode.swift) par une constante
// locale : il n'y a que ces deux bornes dont le bureau ait besoin.

import type { CalendarEventKind, ConfidenceLevel } from "../models/enums.ts";
import { TaskType } from "../models/enums.ts";
import { newId } from "../models/relations.ts";
import { isSameDay } from "./dateUtils.ts";

/// Le bureau prend la forme du moment.
///
/// Le mode étude ne savait faire qu'une chose : une série. En amphi, il n'y
/// avait rien pour suivre le cours ; avant un examen, rien pour réviser ; en
/// groupe, rien du groupe. Le bureau garde ses outils (le cours, la série,
/// Claude, le calcul, le web) mais son accueil — ce qu'on voit en entrant —
/// dépend de ce qu'on fait : l'horaire, le travail choisi, l'examen qui
/// approche, la session de groupe. Une décision pure, ici, testée.
export type DeskMoment =
  /** En cours (amphi ou séance) : le contenu de la semaine, l'horloge du cours. */
  | "lecture"
  /** Une série : l'exercice, la suite. */
  | "series"
  /** Un examen approche : annales, théorie à revoir, exercices à refaire. */
  | "revision"
  /** Une session de groupe : le chrono commun, chacun son travail. */
  | "together";

export const DeskMoment = {
  allCases: ["lecture", "series", "revision", "together"] as readonly DeskMoment[],

  fromRaw(raw: string | null | undefined): DeskMoment | undefined {
    return DeskMoment.allCases.find((c) => c === raw);
  },

  title(moment: DeskMoment): string {
    switch (moment) {
      case "lecture": return "En cours";
      case "series": return "Séries";
      case "revision": return "Révision";
      case "together": return "Ensemble";
    }
  },

  /// Le nom du symbole SF de la pastille.
  icon(moment: DeskMoment): string {
    switch (moment) {
      case "lecture": return "person.wave.2";
      case "series": return "doc.text";
      case "revision": return "checklist";
      case "together": return "person.2";
    }
  },

  /// Un examen à moins de deux semaines fait passer le bureau en révision
  /// (sauf pour une série, qui reste une série — avec l'examen en tête).
  revisionWindowDays: 14,

  resolve(taskType: TaskType, inGroup: boolean, daysToExam: number | null): DeskMoment {
    if (inGroup) return "together";
    if (taskType === "lecture") return "lecture";
    if (daysToExam !== null && daysToExam >= 0 && daysToExam <= DeskMoment.revisionWindowDays
      && TaskType.canonical(taskType) !== "exercise") {
      return "revision";
    }
    return "series";
  },
};

/// `FocusContext.Slot` : un créneau de l'horaire, vu du chrono.
export interface FocusContextSlot {
  courseID: string;
  courseCode: string;
  kind: CalendarEventKind;
  start: Date;
  end: Date;
}

/// `DateInterval` : un intervalle fermé entre deux instants.
export interface DateInterval {
  start: Date;
  end: Date;
}

/// `StudyMode.minuteRange` : les bornes d'une durée choisie à la main (5 min à 12 h).
const studyMinuteRange = { lowerBound: 5, upperBound: 720 };

const adding = (date: Date, seconds: number) => new Date(Math.round(date.getTime() + seconds * 1000));
const secondsBetween = (later: Date, earlier: Date) => (later.getTime() - earlier.getTime()) / 1000;

/// `LectureClock.Phase`.
export type LectureClockPhase =
  /// Pas encore commencé : dans `minutes`.
  | { kind: "before"; minutes: number }
  | { kind: "running" }
  | { kind: "pause"; untilMinutes: number }
  | { kind: "over" };

/// Le cours de l'horaire, vu du bureau : où on en est, la pause, la suite.
export const LectureClock = {
  /// On ouvre le bureau du cours dix minutes avant qu'il commence.
  lead: 10 * 60,

  /// Le cours (ou la séance) en cours à `now`, ou qui commence dans les dix
  /// minutes. Le plus proche s'il y en a deux.
  current(now: Date, slots: FocusContextSlot[]): FocusContextSlot | null {
    const open = slots.filter((slot) => {
      const inClass = slot.kind === "lecture" || slot.kind === "exerciseSession";
      return inClass && adding(slot.start, -LectureClock.lead).getTime() <= now.getTime() && now.getTime() < slot.end.getTime();
    });
    let best: FocusContextSlot | null = null;
    for (const slot of open) {
      if (best === null || Math.abs(secondsBetween(slot.start, now)) < Math.abs(secondsBetween(best.start, now))) best = slot;
    }
    return best;
  },

  /// Le prochain créneau du jour après `now`.
  next(now: Date, slots: FocusContextSlot[]): FocusContextSlot | null {
    let best: FocusContextSlot | null = null;
    for (const slot of slots) {
      if (!(slot.start.getTime() > now.getTime() && isSameDay(slot.start, now) && slot.kind !== "personal")) continue;
      if (best === null || slot.start.getTime() < best.start.getTime()) best = slot;
    }
    return best;
  },

  /// La pause : à l'EPFL, deux fois 45 minutes et un quart d'heure entre
  /// les deux. Un créneau d'au moins 1 h 45 a sa pause à +45 min.
  breakWindow(slot: FocusContextSlot): DateInterval | null {
    if (!(secondsBetween(slot.end, slot.start) >= 105 * 60)) return null;
    const start = adding(slot.start, 45 * 60);
    return { start, end: adding(start, 15 * 60) };
  },

  phase(slot: FocusContextSlot, now: Date): LectureClockPhase {
    if (now.getTime() < slot.start.getTime()) return { kind: "before", minutes: Math.ceil(secondsBetween(slot.start, now) / 60) };
    if (now.getTime() >= slot.end.getTime()) return { kind: "over" };
    const pause = LectureClock.breakWindow(slot);
    // `DateInterval.contains` : bornes comprises.
    if (pause && pause.start.getTime() <= now.getTime() && now.getTime() <= pause.end.getTime()) {
      return { kind: "pause", untilMinutes: Math.ceil(secondsBetween(pause.end, now) / 60) };
    }
    return { kind: "running" };
  },

  /// La fraction écoulée du créneau (0 → 1).
  progress(slot: FocusContextSlot, now: Date): number {
    const total = secondsBetween(slot.end, slot.start);
    if (!(total > 0)) return 1;
    return Math.min(1, Math.max(0, secondsBetween(now, slot.start) / total));
  },

  /// Les minutes du mode étude pour tenir jusqu'à la fin du créneau.
  studyMinutes(slot: FocusContextSlot, now: Date): number {
    const minutes = Math.ceil(secondsBetween(slot.end, now) / 60);
    return Math.min(Math.max(minutes, studyMinuteRange.lowerBound), studyMinuteRange.upperBound);
  },
};

/// Un repère : un instant du cours à revoir, d'un toucher, sans rien écrire.
///
/// On décroche, une démonstration passe trop vite : on touche « Repère ». Une
/// fois l'enregistrement en ligne, chaque repère l'ouvre à cette minute-là.
/// Ce n'est pas une prise de notes — les notes restent dans GoodNotes.
export interface LectureMark {
  id: string;
  courseID: string;
  /// Le début du créneau : l'origine de l'enregistrement.
  classStart: Date;
  at: Date;
}

export const LectureMark = {
  /// `LectureMark(courseID:classStart:at:)` : l'identifiant est tiré au sort.
  make(courseID: string, classStart: Date, at: Date, id: string = newId()): LectureMark {
    return { id, courseID, classStart, at };
  },

  /// Le moment dans l'enregistrement (qui commence avec le cours), en secondes.
  offset(mark: LectureMark): number {
    return Math.max(0, secondsBetween(mark.at, mark.classStart));
  },

  /// « 12:34 », « 1:02:03 ».
  offsetLabel(mark: LectureMark): string {
    const total = Math.trunc(LectureMark.offset(mark));
    const hours = Math.trunc(total / 3600), minutes = Math.trunc((total % 3600) / 60), seconds = total % 60;
    const two = (n: number) => String(n).padStart(2, "0");
    return hours > 0 ? `${hours}:${two(minutes)}:${two(seconds)}` : `${minutes}:${two(seconds)}`;
  },
};

/// Une valeur fractionnaire telle que Swift la lit (`Double("754")`) : rien d'autre que des nombres.
function swiftDouble(text: string): number | null {
  return /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(text) ? Number(text) : null;
}

export const LectureMarks = {
  /// On garde un mois de repères, deux cents au plus.
  keepDays: 30,
  limit: 200,
  /// Deux touchers à moins de 20 s : un seul repère.
  debounce: 20,

  adding(mark: LectureMark, marks: LectureMark[], now: Date = new Date()): LectureMark[] {
    const cutoff = adding(now, -LectureMarks.keepDays * 86_400);
    const kept = marks.filter((m) => m.at.getTime() >= cutoff.getTime());
    let last: LectureMark | undefined;
    for (let i = kept.length - 1; i >= 0; i--) {
      if (kept[i].courseID === mark.courseID) { last = kept[i]; break; }
    }
    if (last && Math.abs(secondsBetween(mark.at, last.at)) < LectureMarks.debounce) return kept;
    kept.push(mark);
    return kept.slice(-LectureMarks.limit);
  },

  /// Les repères d'un créneau.
  of(courseID: string, classStart: Date, marks: LectureMark[]): LectureMark[] {
    return marks
      .filter((m) => m.courseID === courseID && Math.abs(secondsBetween(m.classStart, classStart)) < 60)
      .sort((a, b) => a.at.getTime() - b.at.getTime());
  },

  /// Les derniers créneaux qui ont des repères, du plus récent au plus ancien.
  classes(courseID: string, marks: LectureMark[]): Date[] {
    const seen: Date[] = [];
    const ofCourse = marks.filter((m) => m.courseID === courseID).sort((a, b) => b.classStart.getTime() - a.classStart.getTime());
    for (const mark of ofCourse) {
      if (!seen.some((d) => Math.abs(secondsBetween(d, mark.classStart)) < 60)) seen.push(mark.classStart);
    }
    return seen;
  },

  /// L'adresse d'un enregistrement ouverte à `offset` : `st=` pour MediaSpace
  /// (Kaltura), `t=` pour YouTube, `#t=` sinon (lecteurs HTML5).
  seekURL(url: URL, offset: number): URL {
    const seconds = Math.trunc(offset);
    if (!(seconds > 0)) return url;
    const result = new URL(url.href);
    const host = result.hostname.toLowerCase();
    if (host.includes("mediaspace") || host.includes("kaltura") || host.includes("switch.ch")) {
      result.searchParams.delete("st");
      result.searchParams.append("st", String(seconds));
    } else if (host.includes("youtu")) {
      result.searchParams.delete("t");
      result.searchParams.append("t", String(seconds));
    } else {
      result.hash = `t=${seconds}`;
    }
    return result;
  },

  /// `…?st=754` ou `…#t=754` → 754 (le lecteur natif s'y place).
  startOffset(address: string): number | null {
    let components: URL;
    try {
      components = new URL(address, "https://adresse-relative.invalid/");
    } catch {
      return null;
    }
    for (const [name, value] of components.searchParams) {
      if (name === "st" || name === "t") {
        const seconds = swiftDouble(value);
        if (seconds !== null) return seconds;
        break;
      }
    }
    const fragment = components.hash.startsWith("#") ? components.hash.slice(1) : components.hash;
    if (fragment.startsWith("t=")) {
      const seconds = swiftDouble(fragment.slice(2));
      if (seconds !== null) return seconds;
    }
    return null;
  },

  /// `JSONEncoder` avec `.secondsSince1970` ; `nil` si l'encodage échoue (jamais ici).
  encode(marks: LectureMark[]): string | null {
    return JSON.stringify(marks.map((m) => ({
      id: m.id,
      courseID: m.courseID,
      classStart: m.classStart.getTime() / 1000,
      at: m.at.getTime() / 1000,
    })));
  },

  decode(data: string | null | undefined): LectureMark[] {
    if (data === null || data === undefined) return [];
    try {
      const parsed: unknown = JSON.parse(data);
      if (!Array.isArray(parsed)) return [];
      return parsed.map((item) => {
        if (typeof item?.id !== "string" || typeof item?.courseID !== "string"
          || typeof item?.classStart !== "number" || typeof item?.at !== "number") throw new Error("repère illisible");
        return {
          id: item.id,
          courseID: item.courseID,
          classStart: new Date(Math.round(item.classStart * 1000)),
          at: new Date(Math.round(item.at * 1000)),
        };
      });
    } catch {
      return [];
    }
  },
};

/// Une annale à classer.
export interface RevisionItem {
  id: string;
  year: number;
  worked: boolean;
  confidence: ConfidenceLevel | null;
}

/// Avant un examen : par quoi commencer.
export const RevisionFocus = {
  /// Les annales dans l'ordre où les travailler : jamais faites d'abord (les
  /// plus récentes en tête), puis celles qu'on ne sait pas (rouge, orange),
  /// les sues en dernier.
  pastExamOrder(items: RevisionItem[]): string[] {
    const rank = (item: RevisionItem): number => {
      if (!item.worked) return 0;
      switch (item.confidence) {
        case "red": return 1; // .low
        case "orange": case null: return 2; // .medium
        case "green": return 3; // .high
      }
    };
    return [...items].sort((a, b) => {
      const ra = rank(a), rb = rank(b);
      return ra !== rb ? ra - rb : b.year - a.year;
    }).map((item) => item.id);
  },
};
