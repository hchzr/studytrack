// Charge de travail EPFL (Polymestre/Domain/WorkloadEngine.swift).
//
// Modèle : charge totale attendue = `crédits × heuresParCrédit`. La part
// « cours » correspond aux heures d'amphi planifiées ; le reste est le travail
// personnel. Le réel vient de `StudyTime` (sessions + amphi suivis).

import type { Course } from "../models/course.ts";
import { DateUtils } from "./dateUtils.ts";
import { StudyTime } from "./studyTime.ts";

/** Différence entre le temps attendu par l'EPFL et le temps réellement effectué. */
export class WorkloadDelta {
  constructor(init: Partial<WorkloadDelta> = {}) { Object.assign(this, init); }

  expectedSeconds = 0;
  actualSeconds = 0;
  classSeconds = 0;
  /** Part « cours » du temps attendu (heures de présence en amphi). */
  lectureSeconds = 0;
  /** Part « exercices / travail personnel » du temps attendu. */
  exerciseSeconds = 0;

  /** Réel − attendu (négatif = en retard sur la charge EPFL). */
  get deltaSeconds(): number { return this.actualSeconds - this.expectedSeconds; }

  /** Ratio réel / attendu (1.0 = pile dans les temps). */
  get completion(): number {
    return this.expectedSeconds <= 0 ? 0 : this.actualSeconds / this.expectedSeconds;
  }

  get isBehind(): boolean { return this.completion < 0.75; }

  get expectedLabel(): string { return DateUtils.hoursLabel(this.expectedSeconds); }
  get actualLabel(): string { return DateUtils.hoursLabel(this.actualSeconds); }
}

/** Charge attendue bornée à `weeks` semaines : total, amphi, personnel. */
export interface ExpectedWorkload {
  total: number;
  lecture: number;
  exercise: number;
}

export function totalWeeks(course: Course): number {
  return Math.max(course.term?.totalWeeks ?? 14, 1);
}

/** Charge totale attendue sur tout le semestre (secondes). */
export function expectedTotalSeconds(course: Course, hoursPerCredit: number): number {
  return Math.round(course.credits * hoursPerCredit * 3600);
}

/** Charge attendue bornée à `weeks` semaines écoulées / à venir. */
export function expectedSeconds(course: Course, hoursPerCredit: number, weeks: number): ExpectedWorkload {
  const total = expectedTotalSeconds(course, hoursPerCredit);
  const allWeeks = totalWeeks(course);
  const clampedWeeks = Math.max(0, Math.min(weeks, allWeeks));
  const fraction = clampedWeeks / allWeeks;
  const proportional = Math.round(total * fraction);
  const weeklyLecture = course.hasLectures ? course.weeklyLectureHours : 0;
  const lecture = Math.round(weeklyLecture * clampedWeeks * 3600);
  return { total: proportional, lecture, exercise: Math.max(0, proportional - lecture) };
}

/** Heures de travail **personnel** attendues par semaine pour ce cours. */
export function weeklySelfStudyHours(course: Course, hoursPerCredit: number): number {
  if (course.weeklySelfStudyHours !== null) return Math.max(0, course.weeklySelfStudyHours);
  const implied = (course.credits * hoursPerCredit) / totalWeeks(course);
  return Math.max(0, implied - framedWeeklyHours(course));
}

/** Heures **encadrées** par semaine : amphi (si le cours en a) + séances d'exos. */
export function framedWeeklyHours(course: Course): number {
  return (course.hasLectures ? course.weeklyLectureHours : 0) + course.weeklyExerciseHours;
}

/** Charge attendue **pour une semaine** (secondes). */
export function expectedWeeklySeconds(course: Course, hoursPerCredit: number): number {
  const total = framedWeeklyHours(course) + weeklySelfStudyHours(course, hoursPerCredit);
  return Math.round(total * 3600);
}

/** Temps de travail personnel enregistré sur le cours (secondes). */
export function studySeconds(course: Course, from?: Date | null, to?: Date | null): number {
  return course.sessions
    .filter((session) => {
      if (from && session.startedAt < from) return false;
      if (to && session.startedAt >= to) return false;
      return true;
    })
    .reduce((sum, session) => sum + session.durationSeconds, 0);
}

/** Heures d'amphi suivies (cours de l'horaire, finis, non manqués). */
export function classSeconds(course: Course, from?: Date | null, to?: Date | null): number {
  const events = course.linkedEvents.filter((event) => {
    if (from && event.startsAt < from) return false;
    if (to && event.startsAt >= to) return false;
    return true;
  });
  return StudyTime.lectureBlocks(events, course.sessions).reduce((sum, block) => sum + block.seconds, 0);
}

/** Delta **hebdomadaire** : l'attendu d'une semaine comparé au réel de cette semaine. */
export function weeklyDelta(course: Course, hoursPerCredit: number, from: Date, to: Date): WorkloadDelta {
  const d = new WorkloadDelta();
  const lecture = course.hasLectures ? course.weeklyLectureHours : 0;
  d.expectedSeconds = expectedWeeklySeconds(course, hoursPerCredit);
  d.lectureSeconds = Math.round(lecture * 3600);
  d.exerciseSeconds = Math.max(0, d.expectedSeconds - d.lectureSeconds);
  const klass = classSeconds(course, from, to);
  d.classSeconds = klass;
  d.actualSeconds = studySeconds(course, from, to) + klass;
  return d;
}

/** Agrégat hebdomadaire sur plusieurs cours. */
export function aggregateWeekly(courses: Course[], hoursPerCredit: number, from: Date, to: Date): WorkloadDelta {
  const total = new WorkloadDelta();
  for (const course of courses) {
    const d = weeklyDelta(course, hoursPerCredit, from, to);
    total.expectedSeconds += d.expectedSeconds;
    total.lectureSeconds += d.lectureSeconds;
    total.exerciseSeconds += d.exerciseSeconds;
    total.classSeconds += d.classSeconds;
    total.actualSeconds += d.actualSeconds;
  }
  return total;
}

function deltaWeeks(course: Course, hoursPerCredit: number, weeks: number): WorkloadDelta {
  const expected = expectedSeconds(course, hoursPerCredit, weeks);
  const study = studySeconds(course);
  const klass = classSeconds(course);
  const d = new WorkloadDelta();
  d.expectedSeconds = expected.total;
  d.lectureSeconds = expected.lecture;
  d.exerciseSeconds = expected.exercise;
  d.classSeconds = klass;
  d.actualSeconds = study + klass;
  return d;
}

function deltaWindow(course: Course, hoursPerCredit: number, from: Date | null, to: Date | null): WorkloadDelta {
  // Proportion de semaines couvertes par la fenêtre.
  const start = from ?? course.term?.startDate ?? new Date();
  const end = to ?? new Date();
  const days = Math.max(1, DateUtils.daysBetween(start, end));
  const weeks = Math.max(1, Math.ceil(days / 7));
  const expected = expectedSeconds(course, hoursPerCredit, weeks);
  const study = studySeconds(course, from, to);
  const klass = classSeconds(course, from, to);
  const d = new WorkloadDelta();
  d.expectedSeconds = expected.total;
  d.lectureSeconds = expected.lecture;
  d.exerciseSeconds = expected.exercise;
  d.classSeconds = klass;
  d.actualSeconds = study + klass;
  return d;
}

/** Delta sur le semestre entier, borné à `weeks`, ou sur une fenêtre de dates. */
export function delta(course: Course, hoursPerCredit: number): WorkloadDelta;
export function delta(course: Course, hoursPerCredit: number, weeks: number): WorkloadDelta;
export function delta(course: Course, hoursPerCredit: number, from: Date | null, to: Date | null): WorkloadDelta;
export function delta(
  course: Course,
  hoursPerCredit: number,
  weeksOrFrom?: number | Date | null,
  to?: Date | null,
): WorkloadDelta {
  // Quatre arguments : la fenêtre de dates, même si `from` est nul.
  if (arguments.length >= 4) return deltaWindow(course, hoursPerCredit, weeksOrFrom as Date | null, to ?? null);
  if (weeksOrFrom === undefined) return deltaWeeks(course, hoursPerCredit, totalWeeks(course));
  if (typeof weeksOrFrom === "number") return deltaWeeks(course, hoursPerCredit, weeksOrFrom);
  return deltaWindow(course, hoursPerCredit, weeksOrFrom, to ?? null);
}

/** Agrégat sur plusieurs cours (semestre entier ou fenêtre). */
export function aggregate(courses: Course[], hoursPerCredit: number): WorkloadDelta;
export function aggregate(courses: Course[], hoursPerCredit: number, from: Date | null, to: Date | null): WorkloadDelta;
export function aggregate(
  courses: Course[],
  hoursPerCredit: number,
  from?: Date | null,
  to?: Date | null,
): WorkloadDelta {
  const total = new WorkloadDelta();
  const window = arguments.length >= 4;
  for (const course of courses) {
    const d = window
      ? delta(course, hoursPerCredit, from ?? null, to ?? null)
      : delta(course, hoursPerCredit);
    total.expectedSeconds += d.expectedSeconds;
    total.actualSeconds += d.actualSeconds;
    total.classSeconds += d.classSeconds;
    total.lectureSeconds += d.lectureSeconds;
    total.exerciseSeconds += d.exerciseSeconds;
  }
  return total;
}

export const WorkloadEngine = {
  WorkloadDelta,
  totalWeeks,
  expectedTotalSeconds,
  expectedSeconds,
  weeklySelfStudyHours,
  framedWeeklyHours,
  expectedWeeklySeconds,
  weeklyDelta,
  aggregateWeekly,
  studySeconds,
  classSeconds,
  delta,
  aggregate,
};
