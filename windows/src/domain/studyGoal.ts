// L'objectif d'étude : **un seul**, de la semaine, sur tous les appareils
// (Polymestre/Domain/StudyGoal.swift). Réglé à la main, ou, à défaut, la charge
// EPFL des cours suivis pour la semaine.

import { Course } from "../models/course.ts";
import type { ModelStore } from "../models/store.ts";
import { DateUtils } from "./dateUtils.ts";
import { WorkloadEngine } from "./workloadEngine.ts";

/** L'objectif hebdomadaire (secondes) : le réglage, sinon la charge EPFL. */
export function weeklySeconds(
  goalMinutes: number,
  courses: Course[],
  hoursPerCredit: number,
  now: Date = new Date(),
): number {
  if (goalMinutes > 0) return goalMinutes * 60;
  const start = DateUtils.startOfWeek(now);
  return WorkloadEngine.aggregateWeekly(
    courses.filter((course) => course.isTracked),
    hoursPerCredit,
    start,
    DateUtils.addDays(7, start),
  ).expectedSeconds;
}

/** Le jour vise le septième de la semaine, jamais moins d'un quart d'heure. */
export function dailySeconds(weekly: number): number {
  return Math.max(15 * 60, Math.trunc(weekly / 7));
}

/** `weeklySeconds(in:goalMinutes:hoursPerCredit:)` : lit les cours du magasin. */
export function weeklySecondsIn(
  store: ModelStore,
  goalMinutes: number,
  hoursPerCredit: number,
  now: Date = new Date(),
): number {
  return weeklySeconds(goalMinutes, store.fetch(Course), hoursPerCredit, now);
}

export const StudyGoal = { weeklySeconds, dailySeconds, weeklySecondsIn };
