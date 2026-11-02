// Le modèle de la semaine de l'agenda (MacAgendaView + AgendaView).
//
// On y range les deux familles d'entrées horodatées — les cours du calendrier et
// les sessions planifiées — dans une même ligne de temps, et on calcule leur
// géométrie de colonne. Pur : ni store ni React, donc testable et réutilisable.

import { DateUtils } from "../../../domain/dateUtils.ts";
import type { Deadline, DeadlineKind } from "../../../domain/deadline.ts";
import { CalendarEventKind, type Tint } from "../../../models/enums.ts";
import type { LinkedCalendarEvent } from "../../../models/linkedCalendarEvent.ts";
import type { PlannedSession } from "../../../models/plannedSession.ts";

/** Les heures montrées par la grille : 8 h à 19 h, comme le Mac. */
export const FIRST_HOUR = 8;
export const LAST_HOUR = 19;
export const HOUR_HEIGHT = 52;
export const HOURS = Array.from({ length: LAST_HOUR - FIRST_HOUR + 1 }, (_, index) => FIRST_HOUR + index);
export const GRID_HEIGHT = HOURS.length * HOUR_HEIGHT;

/** Une entrée de la grille : un événement du calendrier ou une session planifiée. */
export interface WeekEntry {
  id: string;
  start: Date;
  end: Date;
  title: string;
  kindLabel: string;
  location: string;
  courseCode: string | null;
  colorHex: string | null;
  isLecture: boolean;
  isSkipped: boolean;
  event: LinkedCalendarEvent | null;
  session: PlannedSession | null;
}

/** Les entrées horodatées de la semaine, triées comme la grille les empile. */
export function buildWeekEntries(
  events: LinkedCalendarEvent[],
  sessions: PlannedSession[],
  start: Date,
  end: Date,
): WeekEntry[] {
  const result: WeekEntry[] = [];
  const from = start.getTime();
  const to = end.getTime();

  for (const event of events) {
    const at = event.startsAt.getTime();
    if (at < from || at >= to) continue;
    // L'agenda n'est pas le calendrier personnel : pas de journée entière.
    if (!event.isAcademic || event.durationSeconds >= 20 * 3600) continue;
    result.push({
      id: `event:${event.id}`,
      start: event.startsAt,
      end: event.endsAt,
      title: event.title,
      kindLabel: CalendarEventKind.label(event.kind),
      location: event.location,
      courseCode: event.course?.displayCode ?? null,
      colorHex: event.course?.colorHex ?? null,
      isLecture: event.isLecture,
      isSkipped: event.isSkipped,
      event,
      session: null,
    });
  }

  for (const session of sessions) {
    const at = session.startsAt.getTime();
    if (at < from || at >= to) continue;
    result.push({
      id: `session:${session.id}`,
      start: session.startsAt,
      end: session.endsAt,
      title: session.title,
      kindLabel: "Session d'étude",
      location: session.location,
      courseCode: session.course?.displayCode ?? null,
      colorHex: session.course?.colorHex ?? null,
      isLecture: false,
      isSkipped: false,
      event: null,
      session,
    });
  }

  return result.sort((a, b) => {
    const delta = a.start.getTime() - b.start.getTime();
    return delta !== 0 ? delta : a.title.localeCompare(b.title);
  });
}

/** Les sept jours de la semaine, lundi d'abord. */
export function weekDays(start: Date): Date[] {
  return Array.from({ length: 7 }, (_, index) => DateUtils.addDays(index, start));
}

/**
 * Le week-end n'apparaît que s'il s'y passe quelque chose — sinon deux colonnes
 * vides mangent la largeur des cinq jours de cours.
 */
export function visibleWeekDays(days: Date[], entries: WeekEntry[], deadlines: Deadline[]): Date[] {
  return days.filter((day) => {
    const weekday = day.getDay();
    if (weekday !== 0 && weekday !== 6) return true;
    return entries.some((entry) => DateUtils.isSameDay(entry.start, day))
      || deadlines.some((item) => DateUtils.isSameDay(item.date, day));
  });
}

/** Position verticale d'un instant : heures depuis `firstHour`, minutes en fraction. */
export function yFor(date: Date, firstHour: number = FIRST_HOUR): number {
  const hours = date.getHours() - firstHour + date.getMinutes() / 60;
  return Math.max(0, hours) * HOUR_HEIGHT;
}

/** Position et hauteur d'une entrée ; 18 px au minimum pour rester lisible. */
export function entryLayout(entry: WeekEntry, firstHour: number = FIRST_HOUR): { top: number; height: number } {
  const top = yFor(entry.start, firstHour);
  return { top, height: Math.max(18, yFor(entry.end, firstHour) - top - 2) };
}

/**
 * Les heures réellement montrées : la bande utile de la semaine (première heure
 * de cours → dernière), une heure de marge, six heures au moins. Le Mac fige
 * 8 h–19 h ; ici une semaine qui commence à 13 h ne gaspille pas cinq heures
 * vides. `null` quand rien n'est horodaté : la grille n'a alors rien à montrer.
 */
export function hourRange(entries: WeekEntry[]): { first: number; last: number } | null {
  if (entries.length === 0) return null;
  let first = Math.min(...entries.map((entry) => entry.start.getHours()));
  let last = Math.max(...entries.map((entry) => {
    const end = entry.end.getHours() + (entry.end.getMinutes() > 0 ? 1 : 0);
    // Une entrée qui passe minuit s'arrête à la dernière heure du jour.
    return DateUtils.isSameDay(entry.start, entry.end) ? end : 23;
  }));
  first = Math.max(6, first - 1);
  last = Math.min(23, last + 1);
  while (last - first < 6) {
    if (first > 6 && (last >= 23 || (last - first) % 2 === 0)) first -= 1;
    else last += 1;
  }
  return { first, last };
}

/** La couleur d'une entrée : celle du cours, sinon celle de son type. */
export function entryColor(entry: WeekEntry): string {
  if (entry.colorHex !== null) return entry.colorHex;
  const kind = entry.event?.kind ?? "study";
  return tintColor(CalendarEventKind.color(kind));
}

/** Une teinte nommée devient la variable CSS correspondante (jamais un hex en dur). */
export function tintColor(tint: Tint): string {
  switch (tint) {
    case "red": return "var(--wrong)";
    case "orange": case "yellow": case "brown": return "var(--review)";
    case "green": return "var(--correct)";
    case "blue": case "teal": case "purple": case "pink": case "indigo": return "var(--selection)";
    default: return "var(--ink-secondary)";
  }
}

/**
 * Un fond translucide : `#RRGGBB` reçoit son canal alpha, une variable CSS passe
 * par `color-mix` (le navigateur de Tauri le comprend).
 */
export function withAlpha(color: string, alpha: number): string {
  const six = /^#[0-9a-f]{6}$/i.exec(color);
  if (six) {
    const byte = Math.round(Math.min(1, Math.max(0, alpha)) * 255).toString(16).padStart(2, "0");
    return `${color}${byte}`;
  }
  const three = /^#([0-9a-f])([0-9a-f])([0-9a-f])$/i.exec(color);
  if (three) return withAlpha(`#${three[1]}${three[1]}${three[2]}${three[2]}${three[3]}${three[3]}`, alpha);
  return `color-mix(in srgb, ${color} ${Math.round(alpha * 100)}%, transparent)`;
}

/** Le glyphe des échéances, faute de SF Symbols sur Windows. */
export function deadlineGlyph(kind: DeadlineKind): string {
  switch (kind) {
    case "exam": return "◆";
    case "due": return "↥";
    case "solutions": return "✓";
  }
}

/** « lun. » → « Lun. » (le Mac capitalise l'abréviation du jour). */
export function weekdayAbbrev(day: Date): string {
  const label = new Intl.DateTimeFormat(DateUtils.appLocale(), { weekday: "short" }).format(day);
  return label.charAt(0).toUpperCase() + label.slice(1);
}

/** « Du 28 septembre au 4 octobre » (`setLocalizedDateFormatFromTemplate("d MMMM")`). */
export function weekLabel(start: Date): string {
  const format = new Intl.DateTimeFormat("fr-CH", { day: "numeric", month: "long" });
  return `Du ${format.format(start)} au ${format.format(DateUtils.addDays(6, start))}`;
}

/**
 * Le numéro de semaine du semestre, ou `null` hors semestre. On prend midi pour
 * éviter qu'un changement d'heure ne fasse basculer la semaine.
 */
export function weekNumberFor(
  weekStart: Date,
  term: { startDate: Date; endDate: Date; totalWeeks: number } | null,
): number | null {
  if (!term) return null;
  if (weekStart.getTime() < DateUtils.startOfWeek(term.startDate).getTime()) return null;
  if (weekStart.getTime() >= term.endDate.getTime()) return null;
  return DateUtils.clampedWeek(new Date(weekStart.getTime() + 12 * 3600_000), term);
}

/**
 * Le filet de `Course.currentWeek` quand aucun semestre n'est rattaché : on
 * compte depuis la rentrée EPFL déduite du mois, sans jamais afficher « 1 »
 * pour une semaine qui n'existe pas.
 */
export function fallbackWeekNumber(weekStart: Date, now: Date = new Date()): number | null {
  const start = DateUtils.currentAutumnOrSpringStart(now);
  const startMonday = DateUtils.startOfWeek(start.start);
  const end = DateUtils.addTeachingWeeks(start.weeks, startMonday);
  if (weekStart.getTime() < startMonday.getTime() || weekStart.getTime() >= end.getTime()) return null;
  return DateUtils.weekNumber(startMonday, new Date(weekStart.getTime() + 12 * 3600_000));
}
