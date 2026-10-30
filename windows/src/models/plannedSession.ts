import { DateUtils } from "../domain/dateUtils.ts";
import { RSVPStatus } from "./enums.ts";
import { defineToOne, newId } from "./relations.ts";
import type { Course } from "./course.ts";

export interface PlannedSessionInit {
  id?: string;
  course?: Course | null;
  groupRemoteID?: string | null;
  groupName?: string;
  title?: string;
  startsAt?: Date;
  durationMinutes?: number;
  location?: string;
  createdByUserID?: string;
  goingCount?: number;
  maybeCount?: number;
  myRSVP?: string;
}

/** Session d'étude planifiée (personnelle ou partagée avec un groupe). */
export class PlannedSession {
  static readonly modelName = "PlannedSession";

  id: string;
  declare course: Course | null;
  /** Identifiant distant du groupe (Supabase) — `null` = session personnelle. */
  groupRemoteID: string | null;
  groupName: string;
  title: string;
  startsAt: Date;
  durationMinutes: number;
  location: string;
  createdByUserID: string;
  goingCount: number;
  maybeCount: number;
  myRSVP: string;
  externalCalendarEventID: string;

  constructor(o: PlannedSessionInit = {}) {
    this.id = o.id ?? newId();
    this.course = o.course ?? null;
    this.groupRemoteID = o.groupRemoteID ?? null;
    this.groupName = o.groupName ?? "";
    this.title = (o.title ?? "") === "" ? "Session d'étude" : o.title!;
    this.startsAt = o.startsAt ?? new Date();
    this.durationMinutes = o.durationMinutes ?? 90;
    this.location = o.location ?? "";
    this.createdByUserID = o.createdByUserID ?? "";
    this.goingCount = o.goingCount ?? 0;
    this.maybeCount = o.maybeCount ?? 0;
    this.myRSVP = o.myRSVP ?? "going";
    this.externalCalendarEventID = "";
  }

  get isGroupSession(): boolean { return this.groupRemoteID !== null; }
  get endsAt(): Date { return new Date(this.startsAt.getTime() + this.durationMinutes * 60_000); }
  get isToday(): boolean { return DateUtils.isSameDay(this.startsAt, new Date()); }
  get isPast(): boolean { return this.endsAt.getTime() < Date.now(); }
  get durationLabel(): string { return DateUtils.durationLabel(this.durationMinutes * 60); }

  get rsvp(): RSVPStatus {
    return RSVPStatus.fromRaw(this.myRSVP) ?? "going";
  }
  set rsvp(value: RSVPStatus) {
    this.myRSVP = value;
  }
}

defineToOne(PlannedSession, "course", "plannedSessionsStore");
