// Fusionne les doublons qu'iCloud fait apparaître
// (Polymestre/Domain/SyncDeduplicator.swift).
//
// La synchronisation recopie chaque objet tel quel : elle ne sait pas que le
// « CS-250 » importé sur l'iPhone et celui importé sur l'iPad sont le même
// cours. Ici, chaque famille a sa **clé naturelle** ; deux objets de même clé
// sont fusionnés.
//
// Deux règles, parce que deux appareils peuvent fusionner en même temps :
//   • **le gardé est choisi de la même façon partout** (le plus petit
//     identifiant) — sinon chacun garderait le sien et supprimerait l'autre ;
//   • **la fusion ne perd rien** : un exercice fait d'un côté reste fait, une
//     session n'est jamais supprimée (elle change de cours), la correction la
//     plus récente l'emporte.
//
// Le `ModelContext` de SwiftData devient le `ModelStore` en mémoire.

import { AcademicMilestone } from "../models/academicMilestone.ts";
import { AcademicTerm } from "../models/academicTerm.ts";
import { Course } from "../models/course.ts";
import { Exam } from "../models/exam.ts";
import { Exercise, ExerciseSeries, type SubQuestion } from "../models/exercise.ts";
import { LinkedCalendarEvent } from "../models/linkedCalendarEvent.ts";
import { LinkedTask } from "../models/linkedTask.ts";
import { PastExam } from "../models/pastExam.ts";
import { PlannedSession } from "../models/plannedSession.ts";
import type { ModelClass, ModelStore } from "../models/store.ts";
import { StudyGroup } from "../models/studyGroup.ts";
import { StudySession } from "../models/studySession.ts";
import { TheoryItem } from "../models/theoryItem.ts";

export class Report {
  merged: Record<string, number> = {};

  get total(): number { return Object.values(this.merged).reduce((sum, value) => sum + value, 0); }

  count(family: string, n = 1): void {
    if (n <= 0) return;
    this.merged[family] = (this.merged[family] ?? 0) + n;
  }

  get summary(): string {
    return Object.keys(this.merged).sort()
      .map((family) => `${this.merged[family]} ${family}`)
      .join(" · ");
  }
}

// MARK: Outils

/** Les groupes de doublons : par clé (`null` = pas de clé, jamais fusionné). */
export function duplicates<T>(
  items: T[],
  id: (item: T) => string,
  key: (item: T) => string | null,
): { keep: T; drop: T[] }[] {
  const buckets = new Map<string, T[]>();
  for (const item of items) {
    const k = key(item);
    if (k === null || k === "") continue;
    const bucket = buckets.get(k) ?? [];
    bucket.push(item);
    buckets.set(k, bucket);
  }
  const result: { keep: T; drop: T[] }[] = [];
  for (const bucket of buckets.values()) {
    if (bucket.length <= 1) continue;
    const sorted = [...bucket].sort((left, right) => {
      const a = id(left).toUpperCase();
      const b = id(right).toUpperCase();
      return a < b ? -1 : a > b ? 1 : 0;
    });
    result.push({ keep: sorted[0], drop: sorted.slice(1) });
  }
  return result;
}

function fetch<T extends object>(store: ModelStore, model: ModelClass<T>): T[] {
  return store.fetch(model);
}

function earliest(a: Date | null, b: Date | null): Date | null {
  if (a !== null && b !== null) return a < b ? a : b;
  return a ?? b;
}

/** `folding(options: [.caseInsensitive, .diacriticInsensitive])` puis `trimmingCharacters`. */
function normalized(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().normalize("NFC").trim();
}

// MARK: Semestres et cours

function termKey(term: AcademicTerm | null): string {
  return term === null ? "" : `${term.year}-${term.seasonRaw}`;
}

function mergeTerms(store: ModelStore, report: Report): void {
  const all = fetch(store, AcademicTerm);
  for (const { keep, drop } of duplicates(all, (term) => term.id, (term) => termKey(term))) {
    for (const loser of drop) {
      for (const course of [...loser.courses]) course.term = keep;
      store.delete(loser);
      report.count("semestres");
    }
  }
}

function mergeCourses(store: ModelStore, report: Report): void {
  const all = fetch(store, Course);
  for (const { keep, drop } of duplicates(
    all,
    (course) => course.id,
    (course) => `${normalized(course.code)}|${termKey(course.term)}`,
  )) {
    for (const loser of drop) {
      mergeCourse(loser, keep, store);
      store.delete(loser);
      report.count("cours");
    }
  }
}

/** Fusionne `b` dans `a`, sans rien perdre. */
export function mergeCourse(b: Course, a: Course, store: ModelStore): void {
  a.isTracked = a.isTracked || b.isTracked;
  for (const [target, value] of [
    ["moodleURLString", b.moodleURLString],
    ["lecturer", b.lecturer],
    ["notes", b.notes],
    ["documentsRaw", b.documentsRaw],
    ["weekGuideRaw", b.weekGuideRaw],
  ] as const) {
    if (a[target] === "") a[target] = value;
  }
  const sources = [...a.contentSources];
  for (const source of b.contentSources) if (!sources.includes(source)) sources.push(source);
  a.contentSources = sources;
  if (a.term === null) a.term = b.term;

  // Théorie : même nature, même numéro, même titre.
  const theoryKey = (item: TheoryItem): string => `${item.kindRaw}|${item.number}|${normalized(item.title)}`;
  const theory = new Map<string, TheoryItem>();
  for (const item of a.theoryItems) if (!theory.has(theoryKey(item))) theory.set(theoryKey(item), item);
  for (const item of [...b.theoryItems]) {
    const match = theory.get(theoryKey(item));
    if (match) {
      match.watchedAt = earliest(match.watchedAt, item.watchedAt);
      match.summarizedAt = earliest(match.summarizedAt, item.summarizedAt);
      if ((match.summaryText ?? "") === "") match.summaryText = item.summaryText;
      for (const session of [...item.targetedSessions]) session.theoryItem = match;
      for (const task of [...item.targetedTasks]) task.video = match;
      store.delete(item);
    } else {
      item.course = a;
      theory.set(theoryKey(item), item);
    }
  }

  // Séries : par numéro (ou titre, sans numéro).
  const seriesKey = (series: ExerciseSeries): string =>
    series.seriesNumber > 0 ? `n${series.seriesNumber}` : `t${normalized(series.title)}`;
  const series = new Map<string, ExerciseSeries>();
  for (const item of a.series) if (!series.has(seriesKey(item))) series.set(seriesKey(item), item);
  for (const item of [...b.series]) {
    const match = series.get(seriesKey(item));
    if (match) {
      mergeSeries(item, match, store);
      store.delete(item);
    } else {
      item.course = a;
      series.set(seriesKey(item), item);
    }
  }

  // Le temps n'est jamais perdu : chaque session change de cours.
  for (const session of [...b.sessions]) session.course = a;
  for (const task of [...b.linkedTasks]) task.course = a;
  for (const event of [...b.linkedEvents]) event.course = a;

  const examKey = (exam: Exam): string =>
    `${exam.kindRaw}|${normalized(exam.title)}|${new Date(exam.date.getFullYear(), exam.date.getMonth(), exam.date.getDate()).getTime() / 1000}`;
  const examKeys = new Set(a.exams.map(examKey));
  for (const exam of [...b.exams]) {
    if (examKeys.has(examKey(exam))) {
      store.delete(exam);
    } else {
      exam.course = a;
    }
  }
  const past = new Map<string, PastExam>();
  for (const exam of a.pastExams) if (!past.has(`${exam.year}|${normalized(exam.title)}`)) past.set(`${exam.year}|${normalized(exam.title)}`, exam);
  for (const exam of [...b.pastExams]) {
    const key = `${exam.year}|${normalized(exam.title)}`;
    const match = past.get(key);
    if (match) {
      match.workedAt = earliest(match.workedAt, exam.workedAt);
      if (match.confidenceRaw === null) match.confidenceRaw = exam.confidenceRaw;
      store.delete(exam);
    } else {
      exam.course = a;
      past.set(key, exam);
    }
  }
}

/** Fusionne une série dans une autre. */
export function mergeSeries(b: ExerciseSeries, a: ExerciseSeries, store: ModelStore): void {
  if (a.urlString === "") a.urlString = b.urlString;
  if (a.solutionURLString === "") a.solutionURLString = b.solutionURLString;
  if (a.topic === "") a.topic = b.topic;
  if (a.dueDate === null) a.dueDate = b.dueDate;
  if (a.solutionsAt === null) a.solutionsAt = b.solutionsAt;
  if (a.publishedAt === null) a.publishedAt = b.publishedAt;
  const exercises = new Map<string, Exercise>();
  for (const exercise of a.exercises) if (!exercises.has(exercise.exerciseNumber)) exercises.set(exercise.exerciseNumber, exercise);
  for (const exercise of [...b.exercises]) {
    const match = exercises.get(exercise.exerciseNumber);
    if (match) {
      mergeExercise(exercise, match, store);
      store.delete(exercise);
    } else {
      exercise.series = a;
      exercises.set(exercise.exerciseNumber, exercise);
    }
  }
}

/** Fusionne un exercice dans un autre ; la correction la plus récente l'emporte en bloc. */
export function mergeExercise(b: Exercise, a: Exercise, store: ModelStore): void {
  for (const [target, value] of [
    ["title", b.title],
    ["statement", b.statement],
    ["hint", b.hint],
    ["solution", b.solution],
    ["statementURLString", b.statementURLString],
  ] as const) {
    if (a[target] === "") a[target] = value;
  }
  a.doneAt = earliest(a.doneAt, b.doneAt);
  if (a.confidenceRaw === null) a.confidenceRaw = b.confidenceRaw;
  // La correction la plus récente l'emporte, en bloc.
  if (b.correctedAt !== null && b.correctedAt > (a.correctedAt ?? new Date(-62_135_596_800_000))) {
    a.correctedAt = b.correctedAt;
    a.correctnessRaw = b.correctnessRaw;
    a.redoRequired = b.redoRequired;
    a.correctionNote = b.correctionNote ?? a.correctionNote;
    a.score = b.score ?? a.score;
    a.maxScore = b.maxScore ?? a.maxScore;
  }
  mergeQuestions(
    b.subQuestions.filter((question) => question.parent === null),
    a.subQuestions.filter((question) => question.parent === null),
    a,
    null,
    store,
  );
  for (const session of [...b.targetedSessions]) session.exercise = a;
  for (const task of [...b.targetedTasks]) task.exercise = a;
}

function mergeQuestions(
  incoming: SubQuestion[],
  existing: SubQuestion[],
  exercise: Exercise,
  parent: SubQuestion | null,
  store: ModelStore,
): void {
  const byLabel = new Map<string, SubQuestion>();
  for (const question of existing) {
    const key = `${question.label}|${question.sortOrder}`;
    if (!byLabel.has(key)) byLabel.set(key, question);
  }
  for (const question of incoming) {
    const key = `${question.label}|${question.sortOrder}`;
    const match = byLabel.get(key);
    if (match) {
      match.isDone = match.isDone || question.isDone;
      match.doneAt = earliest(match.doneAt, question.doneAt);
      if (match.text === "") match.text = question.text;
      mergeQuestions(question.children, match.children, exercise, match, store);
      store.delete(question);
    } else {
      question.exercise = exercise;
      question.parent = parent;
      for (const child of question.children) child.exercise = exercise;
      byLabel.set(key, question);
    }
  }
}

// MARK: Ce que chaque appareil produit de son côté

function mergeSessions(store: ModelStore, report: Report): void {
  const all = fetch(store, StudySession);
  for (const { drop } of duplicates(all, (session) => session.id, (session) => session.externalKey === "" ? null : session.externalKey)) {
    for (const loser of drop) store.delete(loser);
    report.count("sessions", drop.length);
  }
}

function mergeEvents(store: ModelStore, report: Report): void {
  const all = fetch(store, LinkedCalendarEvent);
  const groups = duplicates(all, (event) => event.id, (event) => {
    const span = `${Math.trunc(event.startsAt.getTime() / 1000)}|${Math.trunc(event.endsAt.getTime() / 1000)}`;
    return `${normalized(event.title)}|${span}`;
  });
  for (const { keep, drop } of groups) {
    for (const loser of drop) {
      keep.isAttended = keep.isAttended || loser.isAttended;
      keep.isSkipped = keep.isSkipped || loser.isSkipped;
      if (loser.kindIsManual && !keep.kindIsManual) {
        keep.kindRaw = loser.kindRaw;
        keep.kindIsManual = true;
      }
      if (keep.course === null) keep.course = loser.course;
      if (keep.notes === "") keep.notes = loser.notes;
      store.delete(loser);
    }
    report.count("séances", drop.length);
  }
}

function mergeTasks(store: ModelStore, report: Report): void {
  const all = fetch(store, LinkedTask);
  for (const { keep, drop } of duplicates(all, (task) => task.id, (task) =>
    task.externalID === null ? null : `${task.providerRaw}|${task.externalID}`)) {
    for (const loser of drop) {
      keep.isDone = keep.isDone || loser.isDone;
      store.delete(loser);
    }
    report.count("tâches", drop.length);
  }
}

function mergePlanned(store: ModelStore, report: Report): void {
  const all = fetch(store, PlannedSession);
  const groups = duplicates(all, (session) => session.id, (session) =>
    `${session.groupRemoteID ?? ""}|${normalized(session.title)}|${Math.trunc(session.startsAt.getTime() / 1000)}`);
  for (const { drop } of groups) {
    for (const loser of drop) store.delete(loser);
    report.count("sessions prévues", drop.length);
  }
}

/** Le calendrier académique, installé sur chaque appareil. */
function mergeMilestones(store: ModelStore, report: Report): void {
  const all = fetch(store, AcademicMilestone);
  for (const { drop } of duplicates(all, (milestone) => milestone.id, (milestone) =>
    milestone.externalID === "" ? null : milestone.externalID)) {
    for (const loser of drop) store.delete(loser);
    report.count("échéances", drop.length);
  }
}

/** Les groupes relus sur le serveur par chaque appareil. */
function mergeGroups(store: ModelStore, report: Report): void {
  const all = fetch(store, StudyGroup);
  for (const { keep, drop } of duplicates(all, (group) => group.id, (group) => group.remoteID)) {
    for (const loser of drop) {
      keep.isAdmin = keep.isAdmin || loser.isAdmin;
      for (const member of [...loser.members]) member.group = keep;
      for (const completion of [...loser.completions]) completion.group = keep;
      for (const completion of [...loser.itemCompletions]) completion.group = keep;
      store.delete(loser);
    }
    report.count("groupes", drop.length);
  }
  // Dans chaque groupe : un membre par personne, une coche par élément.
  for (const group of fetch(store, StudyGroup)) {
    for (const { keep, drop } of duplicates(group.members, (member) => member.id, (member) => member.userID)) {
      for (const loser of drop) {
        keep.isMe = keep.isMe || loser.isMe;
        keep.totalSeconds = Math.max(keep.totalSeconds, loser.totalSeconds);
        keep.weeklySeconds = Math.max(keep.weeklySeconds, loser.weeklySeconds);
        store.delete(loser);
      }
      report.count("membres", drop.length);
    }
    for (const { drop } of duplicates(group.completions, (completion) => completion.id,
      (completion) => `${completion.userID}|${completion.courseCode}|${completion.seriesNumber}`)) {
      for (const loser of drop) store.delete(loser);
      report.count("coches", drop.length);
    }
    for (const { drop } of duplicates(group.itemCompletions, (completion) => completion.id,
      (completion) => `${completion.userID}|${completion.courseCode}|${completion.kindRaw}|${completion.itemNumber}`)) {
      for (const loser of drop) store.delete(loser);
      report.count("coches", drop.length);
    }
  }
}

/** Lance toutes les fusions ; le compte rendu dit ce qui a été fait. */
export function run(store: ModelStore): Report {
  const report = new Report();
  mergeTerms(store, report);
  mergeCourses(store, report);
  mergeSessions(store, report);
  mergeEvents(store, report);
  mergeTasks(store, report);
  mergePlanned(store, report);
  mergeMilestones(store, report);
  mergeGroups(store, report);
  if (report.total > 0) store.save();
  return report;
}

/** La même fusion, hors du fil principal (le magasin est en mémoire, mais l'appel reste asynchrone). */
export async function runInBackground(store: ModelStore): Promise<Report> {
  return run(store);
}

export const SyncDeduplicator = {
  Report,
  duplicates,
  mergeCourse,
  mergeSeries,
  mergeExercise,
  run,
  runInBackground,
};
