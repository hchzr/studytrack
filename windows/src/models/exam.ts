import { DateUtils } from "../domain/dateUtils.ts";
import { ExamKind } from "./enums.ts";
import { defineToOne, newId } from "./relations.ts";
import type { Course } from "./course.ts";

export interface ExamInit {
  id?: string;
  course?: Course | null;
  kind?: ExamKind;
  title?: string;
  date?: Date;
  weightPercent?: number | null;
  location?: string;
  notes?: string;
}

/** Évaluation du cours : midterm, examen final, quiz, projet… */
export class Exam {
  static readonly modelName = "Exam";

  id: string;
  declare course: Course | null;
  kindRaw: string;
  title: string;
  date: Date;
  weightPercent: number | null;
  location: string;
  /** La page de l'échéance (le devoir sur Moodle), quand elle vient d'un import. */
  urlString = "";
  notes: string;
  externalCalendarEventID: string | null = null;

  constructor(o: ExamInit = {}) {
    const kind = o.kind ?? "exam";
    this.id = o.id ?? newId();
    this.course = o.course ?? null;
    this.kindRaw = kind;
    this.title = (o.title ?? "") === "" ? ExamKind.label(kind) : o.title!;
    this.date = o.date ?? new Date();
    this.weightPercent = o.weightPercent ?? null;
    this.location = o.location ?? "";
    this.notes = o.notes ?? "";
  }

  get kind(): ExamKind {
    return ExamKind.fromRaw(this.kindRaw) ?? "other";
  }
  set kind(value: ExamKind) {
    this.kindRaw = value;
  }

  get daysUntil(): number {
    return DateUtils.daysBetween(new Date(), this.date);
  }

  get isPast(): boolean { return this.date.getTime() < Date.now(); }

  get weightLabel(): string | null {
    return this.weightPercent === null ? null : `${Math.trunc(this.weightPercent)} %`;
  }
}

defineToOne(Exam, "course", "exams");
