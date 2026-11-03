import { DateUtils } from "../domain/dateUtils.ts";
import { CalendarEventKind } from "./enums.ts";
import { countsEvent, readCounting } from "../domain/studyCounting.ts";
import { defineToOne, newId } from "./relations.ts";
import type { Course } from "./course.ts";


export interface LinkedCalendarEventInit {
  id?: string;
  externalEventID?: string | null;
  sourceCalendarID?: string | null;
  title: string;
  startsAt: Date;
  endsAt: Date;
  location?: string;
  kind?: CalendarEventKind;
  isAttended?: boolean;
}

/** Miroir local d'un événement du calendrier (calendrier système côté Apple, Google/ICS ici). */
export class LinkedCalendarEvent {
  static readonly modelName = "LinkedCalendarEvent";

  id: string;
  externalEventID: string | null;
  sourceCalendarID: string | null;
  title: string;
  startsAt: Date;
  endsAt: Date;
  location: string;
  kindRaw: string;
  declare course: Course | null;
  isAttended: boolean;
  /**
   * Cours magistral **manqué**, signalé à la main. Un cours de l'horaire compte dès
   * qu'il est fini, sauf s'il est marqué ici.
   */
  isSkipped = false;
  /**
   * Le type a été choisi **à la main** : aucune synchronisation ne le recalcule, et les
   * autres semaines du même créneau le reprennent.
   */
  kindIsManual = false;
  notes: string;
  lastSyncedAt: Date | null = null;

  constructor(o: LinkedCalendarEventInit) {
    this.id = o.id ?? newId();
    this.externalEventID = o.externalEventID ?? null;
    this.sourceCalendarID = o.sourceCalendarID ?? null;
    this.title = o.title;
    this.startsAt = o.startsAt;
    this.endsAt = o.endsAt;
    this.location = o.location ?? "";
    this.kindRaw = o.kind ?? "other";
    this.isAttended = o.isAttended ?? false;
    this.notes = "";
  }

  get kind(): CalendarEventKind {
    return CalendarEventKind.fromRaw(this.kindRaw) ?? "other";
  }
  set kind(value: CalendarEventKind) {
    this.kindRaw = value;
  }

  get durationSeconds(): number {
    return Math.max(0, Math.trunc((this.endsAt.getTime() - this.startsAt.getTime()) / 1000));
  }
  get durationLabel(): string { return DateUtils.durationLabel(this.durationSeconds); }
  get isLecture(): boolean { return this.kind === "lecture"; }

  /** Le cours magistral compte dans les heures (la règle choisie : `studyCounting.ts`). */
  get countsAsAttendedLecture(): boolean {
    return this.isLecture && countsEvent(readCounting(), this);
  }

  /** Ce qui a sa place dans l'agenda : l'horaire, les évaluations, les sessions de révision — pas l'agenda personnel. */
  get isAcademic(): boolean {
    switch (this.kind) {
      case "lecture": case "exerciseSession": case "midterm": case "exam": case "study": return true;
      default: return this.course !== null;
    }
  }
}

defineToOne(LinkedCalendarEvent, "course", "linkedEvents");
