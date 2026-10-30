import { DateUtils } from "../domain/dateUtils.ts";
import { TaskType } from "./enums.ts";
import { defineToOne, newId } from "./relations.ts";
import type { Course } from "./course.ts";
import type { Exercise } from "./exercise.ts";
import type { TheoryItem } from "./theoryItem.ts";

export interface StudySessionInit {
  id?: string;
  course?: Course | null;
  taskType?: TaskType;
  startedAt?: Date;
  durationSeconds?: number;
  isManual?: boolean;
  note?: string;
  exercise?: Exercise | null;
  theoryItem?: TheoryItem | null;
}

/** Session de travail enregistrée (chrono ou saisie manuelle). */
export class StudySession {
  static readonly modelName = "StudySession";

  id: string;
  declare course: Course | null;
  taskTypeRaw: string;
  startedAt: Date;
  durationSeconds: number;
  isManual: boolean;
  note: string;
  createdAt: Date;

  /**
   * Sur **quoi** portait exactement la session, quand l'étudiant·e l'a précisé. `null`
   * reste normal — un cours plus un type de travail suffisent.
   */
  declare exercise: Exercise | null;
  declare theoryItem: TheoryItem | null;

  /**
   * Provenance d'une session importée (« anki »), vide pour un chrono ou une saisie.
   * C'est l'**étiquette** qui distingue le temps Anki.
   */
  sourceRaw = "";
  /** Clé stable de la session d'origine, pour qu'un second import ne la double pas. */
  externalKey = "";

  constructor(o: StudySessionInit = {}) {
    this.id = o.id ?? newId();
    this.course = o.course ?? null;
    this.taskTypeRaw = o.taskType ?? "other";
    this.startedAt = o.startedAt ?? new Date();
    this.durationSeconds = Math.max(0, o.durationSeconds ?? 0);
    this.isManual = o.isManual ?? false;
    this.note = o.note ?? "";
    this.exercise = o.exercise ?? null;
    this.theoryItem = o.theoryItem ?? null;
    this.createdAt = new Date();
  }

  get isFromAnki(): boolean { return this.sourceRaw === "anki"; }

  get taskType(): TaskType {
    return TaskType.fromRaw(this.taskTypeRaw) ?? "other";
  }
  set taskType(value: TaskType) {
    this.taskTypeRaw = value;
  }

  /** Libellé de la cible précise : « Exercice 3.2 », « Théorie 1.1 »… `null` si non précisée. */
  get targetLabel(): string | null {
    return this.exercise?.displayNumber ?? this.theoryItem?.displayNumber ?? null;
  }

  get endedAt(): Date { return new Date(this.startedAt.getTime() + this.durationSeconds * 1000); }
  get durationMinutes(): number { return Math.trunc(this.durationSeconds / 60); }
  get durationLabel(): string { return DateUtils.durationLabel(this.durationSeconds); }
}

defineToOne(StudySession, "course", "sessions");
defineToOne(StudySession, "exercise", "targetedSessions");
defineToOne(StudySession, "theoryItem", "targetedSessions");
