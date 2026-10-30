import { DateUtils } from "../domain/dateUtils.ts";
import { TaskProvider } from "./enums.ts";
import { defineToOne, newId } from "./relations.ts";
import type { Course } from "./course.ts";
import type { Exercise } from "./exercise.ts";
import type { TheoryItem } from "./theoryItem.ts";

export interface LinkedTaskInit {
  id?: string;
  provider?: TaskProvider;
  externalID?: string | null;
  title: string;
  note?: string;
  dueDate?: Date | null;
  isDone?: boolean;
  priority?: number;
}

/** Tâche synchronisée depuis un fournisseur externe (Rappels, Todoist). */
export class LinkedTask {
  static readonly modelName = "LinkedTask";

  id: string;
  providerRaw: string;
  externalID: string | null;
  title: string;
  note: string;
  dueDate: Date | null;
  isDone: boolean;
  priority: number;
  declare course: Course | null;
  declare video: TheoryItem | null;
  declare exercise: Exercise | null;
  updatedAt: Date;
  lastSyncedAt: Date | null = null;

  constructor(o: LinkedTaskInit) {
    this.id = o.id ?? newId();
    this.providerRaw = o.provider ?? "reminders";
    this.externalID = o.externalID ?? null;
    this.title = o.title;
    this.note = o.note ?? "";
    this.dueDate = o.dueDate ?? null;
    this.isDone = o.isDone ?? false;
    this.priority = o.priority ?? 1;
    this.updatedAt = new Date();
  }

  get provider(): TaskProvider {
    return TaskProvider.fromRaw(this.providerRaw) ?? "reminders";
  }
  set provider(value: TaskProvider) {
    this.providerRaw = value;
  }

  get isOverdue(): boolean {
    if (this.dueDate === null || this.isDone) return false;
    return this.dueDate.getTime() < Date.now();
  }

  get isDueToday(): boolean {
    return this.dueDate !== null && DateUtils.isSameDay(this.dueDate, new Date());
  }

  get linkLabel(): string | null {
    if (this.exercise) return this.exercise.displayNumber;
    if (this.video) return this.video.displayNumber;
    if (this.course) return this.course.code;
    return null;
  }
}

defineToOne(LinkedTask, "course", "linkedTasks");
defineToOne(LinkedTask, "video", "targetedTasks");
defineToOne(LinkedTask, "exercise", "targetedTasks");
