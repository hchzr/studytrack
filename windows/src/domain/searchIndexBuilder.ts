// Port de StudyTrack/Domain/SearchIndexBuilder.swift : construit l'index de
// recherche à partir des modèles. Toute la correspondance est dans
// `SearchEngine` (pur) ; ici, seulement la lecture et la mise en forme.

import type { AcademicMilestone } from "../models/academicMilestone.ts";
import type { Course } from "../models/course.ts";
import type { StudySession } from "../models/studySession.ts";
import type { StudyGroup } from "../models/studyGroup.ts";
import type { LinkedTask } from "../models/linkedTask.ts";
import { ConfidenceLevel, ExamKind, TaskProvider, TaskType, TheoryKind } from "../models/enums.ts";
import { DateUtils } from "./dateUtils.ts";
import { MathMarkup } from "./mathMarkup.ts";
import { SearchDocument } from "./searchEngine.ts";

const milestoneLabels: Record<string, string> = {
  teachingStart: "Début des cours", teachingEnd: "Fin des cours", examStart: "Début des examens",
  examEnd: "Fin des examens", break: "Interruption", holiday: "Jour férié", deadline: "Délai",
  opening: "Ouverture", evaluation: "Évaluation des cours", publication: "Publication", other: "Autre",
};

export const SearchIndexBuilder = {
  /**
   * Bornes d'indexation : une année de chrono fait des milliers de lignes ;
   * personne ne cherche une session de novembre par mot-clé.
   */
  sessionLimit: 400,
  taskLimit: 300,

  documents(o: {
    courses: Course[];
    sessions?: StudySession[];
    tasks?: LinkedTask[];
    milestones?: AcademicMilestone[];
    groups?: StudyGroup[];
  }): SearchDocument[] {
    const documents: SearchDocument[] = [];
    for (const course of o.courses) {
      documents.push(courseDocument(course));
      for (const series of course.sortedSeries) {
        documents.push(seriesDocument(series, course));
        for (const exercise of series.sortedExercises) documents.push(exerciseDocument(exercise, series, course));
      }
      for (const item of course.sortedTheoryItems) documents.push(theoryDocument(item, course));
      for (const exam of course.sortedExams) documents.push(examDocument(exam, course));
      for (const past of [...course.pastExams].sort((a, b) => b.year - a.year)) documents.push(pastExamDocument(past, course));
    }
    for (const session of (o.sessions ?? []).slice(0, SearchIndexBuilder.sessionLimit)) documents.push(sessionDocument(session));
    for (const task of (o.tasks ?? []).slice(0, SearchIndexBuilder.taskLimit)) documents.push(taskDocument(task));
    for (const milestone of o.milestones ?? []) documents.push(milestoneDocument(milestone));
    for (const group of o.groups ?? []) documents.push(groupDocument(group));
    return documents;
  },
};

function courseDocument(course: Course): SearchDocument {
  // Le code s'écrit « CS-250 », « CS250 » ou « cs 250 » : les trois tombent sur le cours.
  let detail = [course.name, course.shortName, course.code, course.lecturer, course.notes, course.sectionCode].join(" ");
  detail += " " + course.code.split("-").join("");
  return new SearchDocument({
    id: "course." + course.id,
    kind: "course",
    title: course.name === "" ? course.displayCode : course.name,
    subtitle: [course.displayCode, `${Math.trunc(course.credits)} crédits`, course.term?.displayName ?? ""]
      .filter((part) => part !== "")
      .join(" · "),
    detail,
    courseCode: course.displayCode,
  });
}

function seriesDocument(series: Course["series"][number], course: Course): SearchDocument {
  return new SearchDocument({
    id: "series." + series.id,
    kind: "series",
    title: series.title === "" ? `Série ${series.seriesNumber}` : series.title,
    subtitle: `${course.displayCode} · semaine ${series.plannedWeek} · ${series.exercises.length} exercices`,
    detail: `serie ${series.seriesNumber} ${series.title} ${series.topic}`,
    courseCode: course.displayCode,
    date: series.dueDate ?? series.publishedAt,
  });
}

function exerciseDocument(exercise: Course["allExercises"][number], series: Course["series"][number], course: Course): SearchDocument {
  let detail = `exercice ${exercise.exerciseNumber} ${exercise.title} serie ${series.seriesNumber}`;
  if (exercise.isBonus) detail += " bonus facultatif";
  if (exercise.correctionNote !== null) detail += " " + exercise.correctionNote;
  if (exercise.redoRequired) detail += " a refaire";
  // L'énoncé : « valeurs propres », « Cauchy » retrouvent l'exercice même sans son numéro.
  if (exercise.statement !== "") detail += " " + Array.from(MathMarkup.plain(exercise.statement)).slice(0, 600).join("");

  const parts = [`${course.displayCode} · Série ${series.seriesNumber}`];
  if (exercise.isDone) {
    parts.push(exercise.isCorrected ? "corrigé" : "fait");
  } else {
    parts.push("à faire");
  }
  const confidence = exercise.confidence;
  if (confidence !== null) parts.push(ConfidenceLevel.label(confidence));

  return new SearchDocument({
    id: "exercise." + exercise.id,
    kind: "exercise",
    title: `Exercice ${exercise.exerciseNumber}` + (exercise.title === "" ? "" : ` — ${exercise.title}`),
    subtitle: parts.join(" · "),
    detail,
    courseCode: course.displayCode,
    date: exercise.doneAt,
  });
}

function theoryDocument(item: Course["theoryItems"][number], course: Course): SearchDocument {
  let detail = `${TheoryKind.label(item.kind)} ${item.number} ${item.title} ${item.summaryText ?? ""}`;
  if (item.isWatched) detail += " vu";
  if (item.isSummarized) detail += " resume";

  const parts = [`${course.displayCode} · ${item.displayNumber}`];
  if (item.durationSeconds > 0) parts.push(DateUtils.durationLabel(item.durationSeconds));
  parts.push(item.isWatched ? (item.isSummarized ? "vu et résumé" : "vu") : "à voir");

  return new SearchDocument({
    id: "theory." + item.id,
    kind: "theory",
    title: item.title === "" ? item.displayNumber : item.title,
    subtitle: parts.join(" · "),
    detail,
    courseCode: course.displayCode,
    date: item.watchedAt,
  });
}

/** Une annale : « midterm 2023 », « examen analyse corrigé ». */
function pastExamDocument(exam: Course["pastExams"][number], course: Course): SearchDocument {
  return new SearchDocument({
    id: "pastexam." + exam.id,
    kind: "exam",
    title: exam.title,
    subtitle: `${course.displayCode} · ` + (exam.workedAt === null ? "annale à faire" : "annale faite"),
    detail: `annale ${ExamKind.label(exam.kind)} ${exam.year} ${exam.solutionURLString === "" ? "" : "corrige"} ${exam.notes}`,
    courseCode: course.displayCode,
  });
}

function examDocument(exam: Course["exams"][number], course: Course): SearchDocument {
  return new SearchDocument({
    id: "exam." + exam.id,
    kind: "exam",
    title: exam.title,
    subtitle: `${course.displayCode} · ${DateUtils.shortDay(exam.date)}` + (exam.location === "" ? "" : ` · ${exam.location}`),
    detail: `${ExamKind.label(exam.kind)} ${exam.title} ${exam.location} ${exam.notes}`,
    courseCode: course.displayCode,
    date: exam.date,
  });
}

function sessionDocument(session: StudySession): SearchDocument {
  const parts: string[] = [];
  if (session.course !== null) parts.push(session.course.displayCode);
  parts.push(TaskType.label(session.taskType));
  parts.push(DateUtils.shortDay(session.startedAt));
  if (session.targetLabel !== null) parts.push(session.targetLabel);

  return new SearchDocument({
    id: "session." + session.id,
    kind: "session",
    title: session.note === "" ? `${DateUtils.hoursLabel(session.durationSeconds)} de travail` : session.note,
    subtitle: parts.join(" · "),
    detail: `${session.note} ${TaskType.label(session.taskType)} ${session.targetLabel ?? ""}`,
    courseCode: session.course?.displayCode ?? null,
    date: session.startedAt,
  });
}

function taskDocument(task: LinkedTask): SearchDocument {
  return new SearchDocument({
    id: "task." + task.id,
    kind: "task",
    title: task.title,
    subtitle: [TaskProvider.label(task.provider), task.dueDate !== null ? DateUtils.shortDay(task.dueDate) : "", task.course?.displayCode ?? ""]
      .filter((part) => part !== "")
      .join(" · "),
    detail: task.title,
    courseCode: task.course?.displayCode ?? null,
    date: task.dueDate,
  });
}

function milestoneDocument(milestone: AcademicMilestone): SearchDocument {
  return new SearchDocument({
    id: "milestone." + milestone.id,
    kind: "milestone",
    title: milestone.title,
    subtitle: [milestoneLabels[milestone.kindRaw] ?? milestone.kindRaw, DateUtils.shortDay(milestone.date), milestone.termLabel]
      .filter((part) => part !== "")
      .join(" · "),
    detail: `${milestone.title} ${milestone.notes} ${milestoneLabels[milestone.kindRaw] ?? milestone.kindRaw}`,
    date: milestone.date,
  });
}

function groupDocument(group: StudyGroup): SearchDocument {
  return new SearchDocument({
    id: "group." + group.id,
    kind: "group",
    title: group.name,
    subtitle: [group.subjectCodes.join(" · "), `${group.members.length} membres`].filter((part) => part !== "").join(" · "),
    detail: `${group.name} ${group.details} ${group.subjectCodes.join(" ")}`,
    courseCode: group.subjectCodes[0] ?? null,
    date: group.lastSyncedAt ?? group.createdAt,
  });
}
