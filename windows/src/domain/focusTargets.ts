// Ce que le chrono propose dans « Sur » (StudyTrack/Domain/FocusTargets.swift),
// la géométrie des exercices dans le PDF de leur série, et ce que l'horaire dit
// du moment.
//
// `ExerciseStage` (Domain/ExerciseFlow.swift) n'est pas encore porté par ce
// fichier : ses quatre états utiles ici sont recalculés tels quels.

import type { CalendarEventKind } from "../models/enums.ts";
import { TaskType } from "../models/enums.ts";
import type { Exercise, ExerciseSeries } from "../models/exercise.ts";
import type { TheoryItem } from "../models/theoryItem.ts";
import { DateUtils } from "./dateUtils.ts";
import { ExerciseStage } from "./exerciseFlow.ts";

// MARK: - Ordre des exercices

/** À faire, dans l'ordre où on les ferait ; faits ensuite. */
export interface OrderedExercises {
  upNext: Exercise[];
  done: Exercise[];
}

function compareArrays(left: number[], right: number[]): number {
  for (let i = 0; i < Math.min(left.length, right.length); i++) {
    if (left[i] !== right[i]) return left[i] - right[i];
  }
  return left.length - right.length;
}

/** Plus petit = plus pressé : une série commencée, l'échéance la plus proche, la semaine prévue. */
function urgency(series: ExerciseSeries, now: Date): number[] {
  const required = series.requiredExercises;
  const finished = required.length > 0 && required.every((exercise) => ExerciseStage.isDone(ExerciseStage(exercise)));
  const started = series.exercises.some((exercise) => exercise.isDone || exercise.subQuestionDoneCount > 0);
  const due = series.dueDate ? (series.dueDate.getTime() - now.getTime()) / 1000 : Number.MAX_VALUE;
  const week = series.plannedWeek > 0 ? series.plannedWeek : 99;
  return [finished ? 1 : 0, started && !finished ? 0 : 1, week, due];
}

/** Les exercices d'un cours, rangés pour un travail donné. */
export function exercises(series: ExerciseSeries[], taskType: TaskType, now: Date = new Date()): OrderedExercises {
  const ordered = series
    .filter((entry) => entry.exercises.length > 0)
    .sort((left, right) => {
      const order = compareArrays(urgency(left, now), urgency(right, now));
      if (order !== 0) return order;
      return left.seriesNumber - right.seriesNumber;
    })
    .flatMap((entry) => [...entry.exercises].sort((left, right) => {
      if (left.isBonus !== right.isBonus) return left.isBonus ? 1 : -1;
      return left.sortOrder - right.sortOrder;
    }));
  const canonical = TaskType.canonical(taskType);
  const isPending = canonical === "correction"
    ? (exercise: Exercise) => {
        const stage = ExerciseStage(exercise);
        return stage.kind === "toCorrect" || stage.kind === "redo";
      }
    : (exercise: Exercise) => !ExerciseStage.isDone(ExerciseStage(exercise));
  let upNext = ordered.filter(isPending);
  if (canonical === "correction") {
    // Corriger avant de refaire.
    upNext = upNext.filter((exercise) => ExerciseStage(exercise).kind === "toCorrect")
      .concat(upNext.filter((exercise) => ExerciseStage(exercise).kind === "redo"));
  }
  const pendingIds = new Set(upNext.map((exercise) => exercise.id));
  return { upNext, done: ordered.filter((exercise) => !pendingIds.has(exercise.id)) };
}

/** Les éléments de théorie, pas vus d'abord. */
export function theory(items: TheoryItem[]): { upNext: TheoryItem[]; done: TheoryItem[] } {
  return { upNext: items.filter((item) => !item.isWatched), done: items.filter((item) => item.isWatched) };
}

export const FocusTargets = { exercises, theory };

// MARK: - Où se trouve chaque exercice dans le PDF

/** Une bande de page : de `top` à `bottom` (0 = haut, 1 = bas). */
export interface ExerciseSlice {
  page: number;
  top: number;
  bottom: number;
}

/** Le début d'un exercice : son numéro, sa page, sa position. */
export interface ExerciseHeading {
  number: string;
  page: number;
  top: number;
}

/** La marge gardée au-dessus d'un titre. */
export const headingMargin = 0.02;
/** Où s'arrête un exercice : juste au-dessus du titre suivant. */
export const endMargin = 0.011;
/** Le haut d'une page : une suite qui n'en dépasse pas n'est que l'en-tête. */
export const pageHeader = 0.15;

/** Les bandes de chaque exercice, indexées par numéro **court**. */
export function slices(headings: ExerciseHeading[], pageCount: number): Record<string, ExerciseSlice[]> {
  const sorted = [...headings].sort((left, right) => {
    if (left.page !== right.page) return left.page - right.page;
    return left.top - right.top;
  });
  const result: Record<string, ExerciseSlice[]> = {};
  sorted.forEach((heading, index) => {
    const start = { page: heading.page, top: Math.max(0, heading.top - headingMargin) };
    const end = index + 1 < sorted.length
      ? { page: sorted[index + 1].page, top: Math.max(0, sorted[index + 1].top - endMargin) }
      : { page: Math.max(heading.page, pageCount - 1), top: 1 };
    const entry: ExerciseSlice[] = [];
    const lastPage = Math.max(start.page, end.page);
    for (let page = start.page; page <= lastPage; page++) {
      const top = page === start.page ? start.top : 0;
      const bottom = page === end.page ? end.top : 1;
      // Une bande vide, ou réduite à l'en-tête de la page suivante, n'est pas montrée.
      const headerOnly = page !== start.page && bottom < pageHeader;
      if (bottom - top > 0.02 && !headerOnly) entry.push({ page, top, bottom });
    }
    const key = shortNumber(heading.number);
    if (result[key] === undefined && entry.length > 0) result[key] = entry;
  });
  return result;
}

/** « 4.3 » → « 3 », « 3b » → « 3b », « Ex-02-03 » → « 3 ». */
export function shortNumber(number: string): string {
  const parts = number.split(/[.-]/).filter((part) => part !== "");
  const last = parts.length > 0 ? parts[parts.length - 1] : number;
  const trimmed = last.replace(/^0+/, "");
  return trimmed === "" ? last : trimmed;
}

export const ExerciseRegions = { headingMargin, endMargin, pageHeader, slices, shortNumber };

// MARK: - Ce que l'horaire dit du moment

export interface FocusContextSlot {
  courseID: string;
  courseCode: string;
  kind: CalendarEventKind;
  start: Date;
  end: Date;
}

export interface FocusSuggestion {
  courseID: string;
  taskType: TaskType;
  /** « Séance d'exercices de MATH-101 en cours » : dit pourquoi. */
  reason: string;
}

/** Avant une séance d'exercices, on la prépare. */
export const leadTime = 45 * 60;
/** Après un cours, on le relit. */
export const afterLecture = 2 * 3600;

export function suggestion(now: Date, slots: FocusContextSlot[]): FocusSuggestion | null {
  const exercisesSlots = slots.filter((slot) => slot.kind === "exerciseSession");
  const current = exercisesSlots.find((slot) => slot.start.getTime() - 10 * 60_000 <= now.getTime() && now < slot.end);
  if (current) {
    return {
      courseID: current.courseID,
      taskType: "exercise",
      reason: `Séance d'exercices de ${current.courseCode} en cours`,
    };
  }
  const next = exercisesSlots
    .filter((slot) => slot.start > now && (slot.start.getTime() - now.getTime()) / 1000 <= leadTime)
    .sort((left, right) => left.start.getTime() - right.start.getTime())[0];
  if (next) {
    return {
      courseID: next.courseID,
      taskType: "exercise",
      reason: `Séance d'exercices de ${next.courseCode} à ${DateUtils.time(next.start)}`,
    };
  }
  const lectures = slots.filter((slot) => slot.kind === "lecture" && slot.end <= now
    && (now.getTime() - slot.end.getTime()) / 1000 <= afterLecture);
  let last: FocusContextSlot | null = null;
  for (const slot of lectures) if (last === null || slot.end > last.end) last = slot;
  if (last) {
    return { courseID: last.courseID, taskType: "theory", reason: `Juste après le cours de ${last.courseCode}` };
  }
  return null;
}

export const FocusContext = { leadTime, afterLecture, suggestion };
