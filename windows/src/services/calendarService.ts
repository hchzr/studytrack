// L'horaire lié aux cours (Polymestre/Services/CalendarService.swift, **sans** EventKit).
//
// Le calendrier système (EventKit) n'a pas d'équivalent sur Windows : l'horaire arrive
// par l'abonnement `.ics` (`timetableImport.ts`). Ce qui est portable est ici : le type
// des séances appris de l'horaire, la réparation des doublons, le choix manuel d'un
// créneau, et le rattachement d'un événement ou d'une tâche à son cours.

import type { Course } from "../models/course.ts";
import { LinkedCalendarEvent } from "../models/linkedCalendarEvent.ts";
import type { CalendarEventKind } from "../models/enums.ts";
import type { ModelStore } from "../models/store.ts";
import { TimetableClassifier } from "../domain/timetableClassifier.ts";

const slotOf = (event: LinkedCalendarEvent) =>
  TimetableClassifier.slot(TimetableClassifier.owner(event.course?.id ?? null, event.title), event.startsAt);

/**
 * Le type d'un événement du calendrier : ce que l'on sait de son créneau, sinon son
 * intitulé et ses salles (`TimetableClassifier`).
 */
export function classify(title: string, location: string, course: Course | null, start: Date,
  learned: Map<string, CalendarEventKind>): CalendarEventKind {
  const base = TimetableClassifier.kindOfTitle(title, location, course !== null);
  // Une évaluation se lit dans l'intitulé : un créneau d'exercices peut accueillir un
  // midterm, qui reste un midterm.
  if (base === "midterm" || base === "exam") return base;
  // Un bloc personnel ou une échéance au même créneau qu'un cours reste ce qu'il est : le
  // créneau appris ne vaut que pour l'horaire.
  if (TimetableClassifier.isPersonal(title) || TimetableClassifier.isDeadline(title)) return base;
  const slot = TimetableClassifier.slot(TimetableClassifier.owner(course?.id ?? null, title), start);
  return learned.get(TimetableClassifier.slotKey(slot)) ?? base;
}

/** Ce que les séances au type sûr (horaire `.ics`, choix manuel) disent de chaque créneau. */
export function learnedKinds(events: LinkedCalendarEvent[]): Map<string, CalendarEventKind> {
  return TimetableClassifier.learnedKinds(events
    .filter((e) => e.sourceCalendarID === "ics" || e.kindIsManual)
    .filter((e) => e.kind === "lecture" || e.kind === "exerciseSession")
    .map((e) => ({ slot: slotOf(e), kind: e.kind, isManual: e.kindIsManual })));
}

/**
 * Remet l'horaire d'aplomb : retire les doublons (même séance lue par l'`.ics` et par un
 * calendrier abonné) et reclasse ce qui n'a pas de type sûr. Idempotent.
 * @returns le nombre d'événements retirés ou reclassés.
 */
export function repair(store: ModelStore): number {
  const events = [...store.fetch(LinkedCalendarEvent)];
  // Les séances importées, rangées par cours.
  const imported = new Map<string, LinkedCalendarEvent[]>();
  for (const event of events.filter((e) => e.sourceCalendarID === "ics" && e.course !== null)) {
    const list = imported.get(event.course!.id) ?? [];
    list.push(event);
    imported.set(event.course!.id, list);
  }
  const learned = learnedKinds(events);
  let changes = 0;
  for (const event of events.filter((e) => e.sourceCalendarID !== "ics")) {
    const twin = (event.course ? imported.get(event.course.id) : undefined)?.find((candidate) =>
      TimetableClassifier.isSameSession(candidate.course?.id ?? null, candidate.startsAt, event.course?.id ?? null, event.startsAt));
    if (twin) {
      // Le doublon garde ce qu'on y avait noté : un amphi marqué manqué le reste.
      if (event.isSkipped) twin.isSkipped = true;
      if (event.kindIsManual && !twin.kindIsManual) { twin.kind = event.kind; twin.kindIsManual = true; }
      store.delete(event);
      changes++;
      continue;
    }
    if (event.kindIsManual || !["lecture", "exerciseSession", "other"].includes(event.kind)) continue;
    const kind = classify(event.title, event.location, event.course, event.startsAt, learned);
    if (kind !== event.kind) { event.kind = kind; changes++; }
  }
  return changes;
}

/**
 * « C'est une séance d'exercices » : le type choisi pour **tout le créneau** (même cours,
 * même jour, même heure), semaines passées et à venir.
 * @returns le nombre de séances changées.
 */
export function setKind(kind: CalendarEventKind, event: LinkedCalendarEvent, store: ModelStore): number {
  const key = TimetableClassifier.slotKey(slotOf(event));
  let count = 0;
  for (const other of store.fetch(LinkedCalendarEvent)) {
    if (TimetableClassifier.slotKey(slotOf(other)) !== key) continue;
    other.kind = kind;
    other.kindIsManual = true;
    count++;
  }
  if (kind === "lecture" && event.course && !event.course.hasLectures) event.course.hasLectures = true;
  return count;
}

/** Devine le cours d'un événement à partir de son titre (code ou nom). */
export function matchCourse(title: string, courses: Course[]): Course | null {
  const haystack = title.toUpperCase();
  for (const course of courses) if (haystack.includes(course.code.toUpperCase())) return course;
  for (const course of courses) {
    const tokens = course.name.toUpperCase().split(" ").filter((token) => [...token].length >= 4);
    if (tokens.length > 0 && tokens.every((token) => haystack.includes(token))) return course;
  }
  return null;
}

export const CalendarSync = { classify, learnedKinds, repair, setKind, matchCourse };
