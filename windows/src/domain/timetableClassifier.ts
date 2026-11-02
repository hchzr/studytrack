// Amphi, exercices ou autre : le type d'une séance de l'horaire, décidé une fois
// pour toutes au même endroit (StudyTrack/Domain/TimetableClassifier.swift).
//
// Le bilan affichait 35 h d'amphi pour une semaine qui en compte une douzaine. Deux
// causes, cumulées :
//   • l'horaire était lu **deux fois** — l'import `.ics` (qui connaît le type de
//     séance par `CATEGORIES`) et le calendrier abonné au même flux (qui ne le
//     connaît pas) ;
//   • un calendrier système ne transmet pas `CATEGORIES` : toute séance d'un cours
//     sans mot-clé dans l'intitulé (« Analyse I (classe inversée) ») devenait un
//     cours magistral, exercices compris.
//
// Les signaux, du plus sûr au moins sûr :
//   1. un choix fait à la main pour ce créneau (« c'est une séance d'exercices ») ;
//   2. `CATEGORIES` de l'horaire EPFL (`Cours`, `Exercices`, `Labo`) ;
//   3. ce que l'horaire importé dit **du même créneau** (même cours, même jour, même
//      heure) ;
//   4. les mots de l'intitulé (« exercices », « TP », « midterm ») ;
//   5. **le nombre de salles** : une séance d'exercices de l'EPFL se tient dans
//      plusieurs salles à la fois (« CE1101, CE1105, CO010… »), un cours magistral
//      dans une seule. Vérifié sur tout un horaire de BA1 : aucune exception sur 165
//      séances ;
//   6. à défaut, un événement rattaché à un cours reste un cours.

import type { CalendarEventKind } from "../models/enums.ts";
import { characters, isLetter, isNumber, trimWhitespaces } from "./textRepair.ts";
import { addCalendarDays, wallTime } from "./zonedTime.ts";

/** `folding(options: [.diacriticInsensitive, .caseInsensitive])`. */
function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}

/// Le type de séance est-il celui d'un **cours magistral** ?
///
/// Le « Mon horaire » de l'EPFL le dit explicitement dans `CATEGORIES` : `Cours`,
/// `Exercices`, `Labo`. C'est infiniment plus fiable que de le deviner depuis
/// l'intitulé. `null` quand `CATEGORIES` ne se prononce pas.
export function isLectureCategory(categories: string): boolean | null {
  const values = categories.split(",").filter((value) => value !== "").map((value) => value.trim().toLowerCase());
  if (values.includes("cours")) return true;
  if (values.includes("exercices") || values.includes("labo")) return false;
  return null;
}

/** Le nombre de salles d'un lieu (« CE1106, CE1515 » → 2, « » → 0). */
export function roomCount(location: string): number {
  return location.split(/[,;/]/).map((room) => room.trim()).filter((room) => room !== "").length;
}

/** Un intitulé d'agenda personnel : il commence par un symbole — l'horaire EPFL commence toujours par le nom du cours. */
export function isPersonal(title: string): boolean {
  const first = characters(trimWhitespaces(title))[0];
  if (first === undefined) return false;
  return !(isLetter(first) || isNumber(first));
}

/** Une échéance, pas une séance : rendu, remise, défense, deadline. */
export function isDeadline(title: string): boolean {
  const folded = fold(title);
  return ["rendu", "remise", "deadline", "due ", "defense", "soumission", "a rendre"].some((word) => folded.includes(word));
}

/** Le type d'une séance sans indication explicite : intitulé, puis salles. */
export function kindOfTitle(title: string, location: string, hasCourse: boolean): CalendarEventKind {
  const haystack = title.toLowerCase();
  if (haystack.includes("midterm") || haystack.includes("mid-term") || haystack.includes("contrôle")) return "midterm";
  if (haystack.includes("examen") || haystack.includes("exam") || haystack.includes("final")) return "exam";
  // L'agenda **personnel** qui cite un cours n'est pas l'horaire : un bloc « 🧠 MATH-111
  // — finir la série », une échéance « [CS-107] Rendu du projet ».
  if (isDeadline(title)) return "other";
  if (isPersonal(title)) return "study";
  if (haystack.includes("exercice") || haystack.includes("exercise") || haystack.includes("série")
    || haystack.includes("serie") || haystack.includes(" tp") || haystack.includes("labo")) {
    return "exerciseSession";
  }
  // Plusieurs salles : des groupes d'exercices, jamais un amphi.
  if (roomCount(location) >= 2) return "exerciseSession";
  if (haystack.includes("cours") || haystack.includes("lecture") || haystack.includes("amphi")) return "lecture";
  if (haystack.includes("révision") || haystack.includes("revision") || haystack.includes("étude")) return "study";
  return hasCourse ? "lecture" : "other";
}

/** Le type d'une séance de l'horaire EPFL : `CATEGORIES` d'abord, puis le reste. */
export function kindOfCategories(categories: string, title: string, location: string, hasCourse: boolean): CalendarEventKind {
  const lecture = isLectureCategory(categories);
  if (lecture === true) return "lecture";
  if (lecture === false) return "exerciseSession";
  return kindOfTitle(title, location, hasCourse);
}

// MARK: Créneaux

/// Un créneau hebdomadaire : le même cours, le même jour, à la même heure. C'est
/// l'unité qu'on corrige : dire « le lundi 8 h 15 d'Analyse est une séance
/// d'exercices » vaut pour tout le semestre, pas pour une occurrence.
export interface Slot {
  /** Le cours (son identifiant), sinon l'intitulé replié. */
  owner: string;
  /** 1 = dimanche … 7 = samedi. */
  weekday: number;
  /** Minutes depuis minuit. */
  minute: number;
}

/** Une clé stable pour un `Set`/`Map` (le `Hashable` de `Slot`). */
export function slotKey(slot: Slot): string {
  return `${slot.owner}|${slot.weekday}|${slot.minute}`;
}

export function slot(owner: string, start: Date, timeZone: string | null = null): Slot {
  const parts = wallTime(start, timeZone);
  return { owner, weekday: parts.weekday, minute: parts.hour * 60 + parts.minute };
}

/** Le propriétaire d'un créneau : le cours quand on le connaît. */
export function owner(courseID: string | null, title: string): string {
  if (courseID !== null) return courseID.toUpperCase();
  return trimWhitespaces(fold(title));
}

/// Deux événements sont-ils la **même** séance, lue par deux sources ? Même cours,
/// même début à la minute près.
export function isSameSession(courseA: string | null, startA: Date, courseB: string | null, startB: Date): boolean {
  if (courseA === null || courseB === null || courseA !== courseB) return false;
  return Math.abs(startA.getTime() - startB.getTime()) / 1000 < 90;
}

export interface KnownSession {
  slot: Slot;
  kind: CalendarEventKind;
  isManual: boolean;
}

/// Ce que les séances connues disent de chaque créneau. Un choix manuel l'emporte ;
/// sinon le type le plus fréquent parmi les séances au type **sûr** (`.ics` ou manuel).
/// Un créneau où les sources se contredisent à égalité n'est pas tranché.
export function learnedKinds(sessions: KnownSession[]): Map<string, CalendarEventKind> {
  const manual = new Map<string, CalendarEventKind>();
  const votes = new Map<string, Map<CalendarEventKind, number>>();
  for (const session of sessions) {
    const key = slotKey(session.slot);
    if (session.isManual) {
      manual.set(key, session.kind);
    } else {
      const counts = votes.get(key) ?? new Map<CalendarEventKind, number>();
      counts.set(session.kind, (counts.get(session.kind) ?? 0) + 1);
      votes.set(key, counts);
    }
  }
  const result = new Map<string, CalendarEventKind>();
  for (const [key, counts] of votes) {
    const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1]);
    const best = sorted[0];
    if (!best) continue;
    if (sorted.length > 1 && sorted[1][1] === best[1]) continue;
    result.set(key, best[0]);
  }
  for (const [key, kind] of manual) result.set(key, kind);
  return result;
}

// MARK: Heures hebdomadaires

/// Les heures d'amphi et d'exercices d'une semaine type, lues dans l'horaire.
///
/// Les cours créés par l'import recevaient « 2 h de cours, 1 h d'exercices » quel que
/// soit l'horaire. On prend la **médiane** des semaines où le cours a lieu : une
/// semaine tronquée (jour férié, rentrée) ne fait pas la règle. Arrondi au quart d'heure.
export function weeklyHours(sessions: { start: Date; seconds: number; kind: CalendarEventKind }[],
  timeZone: string | null = null): { lecture: number; exercise: number } {
  const lecture = new Map<string, number>();
  const exercise = new Map<string, number>();
  const weeks = new Set<string>();
  for (const session of sessions) {
    // La semaine (du dimanche, comme le `Calendar` de Foundation à `firstWeekday = 1`).
    const w = wallTime(session.start, timeZone);
    const first = addCalendarDays(session.start, -(w.weekday - 1), timeZone);
    const f = wallTime(first, timeZone);
    const week = `${f.year}-${f.month}-${f.day}`;
    weeks.add(week);
    if (session.kind === "lecture") lecture.set(week, (lecture.get(week) ?? 0) + session.seconds);
    else if (session.kind === "exerciseSession") exercise.set(week, (exercise.get(week) ?? 0) + session.seconds);
  }
  const median = (totals: Map<string, number>): number => {
    const values = [...weeks].map((week) => totals.get(week) ?? 0).sort((a, b) => a - b);
    if (values.length === 0) return 0;
    const middle = Math.trunc(values.length / 2);
    const seconds = values.length % 2 === 0 ? (values[middle - 1] + values[middle]) / 2 : values[middle];
    // `rounded()` : la moitié s'éloigne de zéro.
    return Math.round((seconds / 3600) * 4) / 4;
  };
  return { lecture: median(lecture), exercise: median(exercise) };
}

export const TimetableClassifier = {
  isLectureCategory, roomCount, isPersonal, isDeadline, kindOfTitle, kindOfCategories,
  slot, slotKey, owner, isSameSession, learnedKinds, weeklyHours,
};
