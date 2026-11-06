// Ce qui tombe à une date : une évaluation, une série à rendre, un corrigé qui
// s'ouvre (Polymestre/Domain/Deadline.swift). Lu dans les cours : l'accueil,
// l'agenda et les widgets.

import { DateUtils } from "./dateUtils.ts";
import { Plural } from "./plural.ts";
import { ExamKind } from "../models/enums.ts";
import type { Course } from "../models/course.ts";

export type DeadlineKind = "exam" | "due" | "solutions";

export const DeadlineKind = {
  icon(kind: DeadlineKind): string {
    switch (kind) {
      case "exam": return "graduationcap.fill";
      case "due": return "tray.and.arrow.up";
      case "solutions": return "checkmark.seal";
    }
  },
};

export interface Deadline {
  id: string;
  kind: DeadlineKind;
  date: Date;
  title: string;
  detail: string;
  courseID: string;
  courseCode: string;
  colorHex: string;
  targetID?: string;
}

export interface DeadlineInit extends Deadline {}

/// Les échéances des `days` prochains jours (et celles du jour), triées.
function upcoming(courses: Course[], days: number, start: Date = DateUtils.startOfDay(new Date())): Deadline[] {
  return between(courses, start, DateUtils.addDays(days, start));
}

function between(courses: Course[], start: Date, end: Date): Deadline[] {
  const result: Deadline[] = [];
  for (const course of courses) {
    for (const exam of course.exams) {
      if (!(exam.date >= start && exam.date < end)) continue;
      const kindLabel = ExamKind.label(exam.kind);
      result.push({
        id: `exam:${exam.id}`,
        kind: "exam",
        date: exam.date,
        title: exam.title === "" ? kindLabel : exam.title,
        detail: [kindLabel, exam.weightLabel, exam.location === "" ? null : exam.location]
          .filter((part): part is string => part !== null).join(" · "),
        courseID: course.id,
        courseCode: course.displayCode,
        colorHex: course.colorHex,
      });
    }
    for (const series of course.series) {
      const name = series.title === "" ? `Série ${series.seriesNumber}` : series.title;
      if (series.dueDate !== null && series.dueDate >= start && series.dueDate < end) {
        const left = series.requiredExercises.length - series.doneCount;
        result.push({
          id: `due:${series.id}`,
          kind: "due",
          date: series.dueDate,
          title: `${name} à rendre`,
          detail: left > 0
            ? Plural.count(left, `${left} exercice à faire`, `${left} exercices à faire`)
            : "tout est fait",
          courseID: course.id,
          courseCode: course.displayCode,
          colorHex: course.colorHex,
          targetID: series.sortedExercises.find((exercise) => !exercise.isDone)?.id,
        });
      }
      if (series.solutionsAt !== null && series.solutionsAt >= start && series.solutionsAt < end) {
        result.push({
          id: `sol:${series.id}`,
          kind: "solutions",
          date: series.solutionsAt,
          title: `Corrigé de la ${name.toLowerCase()}`,
          detail: "à corriger ensuite",
          courseID: course.id,
          courseCode: course.displayCode,
          colorHex: course.colorHex,
        });
      }
    }
  }
  return result.sort((a, b) => a.date.getTime() - b.date.getTime());
}

export const Deadline = {
  upcoming,
  between,
};
