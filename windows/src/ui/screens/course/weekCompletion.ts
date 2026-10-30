// « Marquer la semaine faite » d'un geste (StudyTrack/Domain/WeekCompletion.swift).
//
// Le fichier Swift n'est pas porté dans `src/domain` : il vit ici, avec l'écran
// qui s'en sert, et suit la règle exacte de `mark` / `undo` / `summary`.

import "../../../domain/exerciseFlow.ts";
import type { Course } from "../../../models/course.ts";
import type { Exercise } from "../../../models/exercise.ts";
import { Plural } from "../../../domain/plural.ts";

export type WeekScope = "all" | "allCorrected" | "theoryOnly";

/** Ce qui a changé : de quoi le défaire exactement. */
export interface WeekChange {
  theory: string[];
  exercises: string[];
  corrected: string[];
}

export const isEmptyChange = (change: WeekChange): boolean =>
  change.theory.length === 0 && change.exercises.length === 0 && change.corrected.length === 0;

/** « 4 théorie, 7 exercices » — le résumé de la barre « Annuler ». */
export function changeSummary(change: WeekChange): string {
  const parts: string[] = [];
  if (change.theory.length > 0) parts.push(`${change.theory.length} théorie`);
  if (change.exercises.length > 0) {
    parts.push(Plural.count(change.exercises.length,
      `${change.exercises.length} exercice`, `${change.exercises.length} exercices`));
  }
  if (change.corrected.length > 0 && change.corrected.length !== change.exercises.length) {
    parts.push(Plural.count(change.corrected.length,
      `${change.corrected.length} corrigé`, `${change.corrected.length} corrigés`));
  }
  return parts.length === 0 ? "rien à cocher" : parts.join(", ");
}

/** Ce que contient la semaine, pour dire combien de lignes seront cochées. */
export function pendingWeeks(range: [number, number], course: Course): { theory: number; exercises: number } {
  const [from, to] = range;
  const inRange = (week: number) => week >= from && week <= to;
  const theory = course.theoryItems.filter((item) => inRange(item.plannedWeek) && !item.isWatched).length;
  const exercises = course.series
    .filter((series) => inRange(series.plannedWeek))
    .flatMap((series) => series.requiredExercises)
    .filter((exercise) => !exercise.isDone).length;
  return { theory, exercises };
}

export interface MarkResult {
  change: WeekChange;
  /** Les objets touchés, à enregistrer (sous-questions comprises). */
  touched: object[];
}

/** Coche les semaines `range`. Les bonus ne sont pas touchés : facultatifs, ils ne sont pas dus. */
export function markWeeks(
  range: [number, number],
  course: Course,
  scope: WeekScope,
  now: Date = new Date(),
): MarkResult {
  const change: WeekChange = { theory: [], exercises: [], corrected: [] };
  const touched: object[] = [];
  const [from, to] = range;
  const inRange = (week: number) => week >= from && week <= to;

  for (const item of course.theoryItems) {
    if (!inRange(item.plannedWeek) || item.isWatched) continue;
    item.watchedAt = now;
    change.theory.push(item.id);
    touched.push(item);
  }
  if (scope === "theoryOnly") return { change, touched };

  for (const series of course.series.filter((entry) => inRange(entry.plannedWeek))) {
    for (const exercise of series.requiredExercises) {
      if (!exercise.isDone) {
        exercise.setDone(true);
        change.exercises.push(exercise.id);
        touched.push(exercise, ...exercise.subQuestions);
      }
      if (scope === "allCorrected" && !exercise.isCorrected && !exercise.redoRequired) {
        exercise.correct("correct");
        change.corrected.push(exercise.id);
        if (!touched.includes(exercise)) touched.push(exercise, ...exercise.subQuestions);
      }
    }
  }
  return { change, touched };
}

/** Défait exactement `change` : ce qui était coché avant le reste. */
export function undoWeeks(change: WeekChange, course: Course): object[] {
  const touched: object[] = [];
  const theory = new Set(change.theory);
  for (const item of course.theoryItems) {
    if (!theory.has(item.id)) continue;
    item.watchedAt = null;
    touched.push(item);
  }
  const done = new Set(change.exercises);
  const corrected = new Set(change.corrected);
  for (const exercise of course.allExercises) {
    if (done.has(exercise.id)) {
      exercise.setDone(false);
      touched.push(exercise, ...exercise.subQuestions);
    } else if (corrected.has(exercise.id)) {
      exercise.clearCorrection();
      touched.push(exercise);
    }
  }
  return touched;
}

/** Les exercices obligatoires d'une semaine, pour les ramasser dans les listes. */
export function requiredInWeeks(course: Course, range: [number, number]): Exercise[] {
  const [from, to] = range;
  return course.series
    .filter((series) => series.plannedWeek >= from && series.plannedWeek <= to)
    .flatMap((series) => series.requiredExercises);
}
