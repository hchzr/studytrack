// L'horaire du jour, pour le bureau du mode étude (StudyKit/DeskServices.swift).
//
// Une lecture, la même partout : le bureau du mode étude, l'accueil, la barre
// des menus. Les créneaux viennent de l'agenda académique (cours suivis, pas
// manqués) ; la pause du cours et les minutes pour la finir, de `LectureClock`.

import type { LinkedCalendarEvent } from "../models/linkedCalendarEvent.ts";
import type { Course } from "../models/course.ts";
import type { TaskType } from "../models/enums.ts";
import { CalendarEventKind } from "../models/enums.ts";
import { DeskMoment, LectureClock, type FocusContextSlot } from "./deskMoment.ts";

/** Un créneau de l'horaire, avec ce que le bureau en montre (la salle). */
export interface ScheduledClass {
  id: string;
  slot: FocusContextSlot;
  title: string;
  location: string;
  colorHex: string;
}

/** `ScheduledClass.kindLabel` : le nom du créneau (« Cours », « Séance »…). */
export function kindLabelOf(slot: FocusContextSlot): string {
  return CalendarEventKind.label(slot.kind);
}

export const DeskSchedule = {
  /** Les créneaux de cours de la journée de `now` (cours suivis, pas manqués). */
  classes(events: readonly LinkedCalendarEvent[]): ScheduledClass[] {
    return events.flatMap((event) => {
      if (!event.isAcademic || event.isSkipped) return [];
      const course = event.course;
      if (!course || !course.isTracked) return [];
      return [{
        id: event.id,
        slot: {
          courseID: course.id,
          courseCode: course.displayCode,
          kind: event.kind,
          start: event.startsAt,
          end: event.endsAt,
        },
        title: course.name,
        location: event.location,
        colorHex: course.colorHex,
      }];
    });
  },

  /** Les créneaux du jour de `now`, triés. */
  today(events: readonly LinkedCalendarEvent[], now: Date): ScheduledClass[] {
    const start = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const end = new Date(start.getTime() + 24 * 3600 * 1000);
    const ofTheDay = events.filter((event) =>
      event.startsAt.getTime() >= start.getTime() && event.startsAt.getTime() < end.getTime());
    return DeskSchedule.classes(ofTheDay).sort((a, b) => a.slot.start.getTime() - b.slot.start.getTime());
  },

  /** Le cours en cours (ou qui commence dans dix minutes). */
  current(inClasses: ScheduledClass[], at: Date = new Date()): ScheduledClass | null {
    const slot = LectureClock.current(at, inClasses.map((entry) => entry.slot));
    if (!slot) return null;
    return inClasses.find((entry) => sameSlot(entry.slot, slot)) ?? null;
  },

  /** Le prochain créneau du jour. */
  next(inClasses: ScheduledClass[], after: Date = new Date()): ScheduledClass | null {
    const slot = LectureClock.next(after, inClasses.map((entry) => entry.slot));
    if (!slot) return null;
    return inClasses.find((entry) => sameSlot(entry.slot, slot)) ?? null;
  },

  /** Le créneau de ce cours qui a commencé le plus récemment aujourd'hui. */
  latest(courseID: string | null | undefined, inClasses: ScheduledClass[], at: Date = new Date()): ScheduledClass | null {
    const started = inClasses.filter((entry) =>
      entry.slot.courseID === courseID
      && entry.slot.start.getTime() - LectureClock.lead * 1000 <= at.getTime());
    return started.reduce<ScheduledClass | null>(
      (best, entry) => (best === null || entry.slot.start.getTime() > best.slot.start.getTime() ? entry : best),
      null);
  },

  /** La forme du bureau pour cette session. */
  moment(taskType: TaskType, inGroup: boolean, course: Course | null): DeskMoment {
    const daysToExam = course?.nextSitting?.daysUntil ?? null;
    return DeskMoment.resolve(taskType, inGroup, daysToExam);
  },
};

/** Deux créneaux identiques (même cours, même type, mêmes bornes). */
export function sameSlot(a: FocusContextSlot, b: FocusContextSlot): boolean {
  return a.courseID === b.courseID && a.kind === b.kind
    && a.start.getTime() === b.start.getTime() && a.end.getTime() === b.end.getTime();
}
