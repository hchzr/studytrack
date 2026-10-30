// Données d'exemple (semestre EPFL relatif à aujourd'hui) pour démarrer l'app.

import { DateUtils } from "../domain/dateUtils.ts";
import { AcademicTerm } from "./academicTerm.ts";
import { Course } from "./course.ts";
import type { ExamKind, TaskType, TermSeason, TheoryKind } from "./enums.ts";
import { Exam } from "./exam.ts";
import { Exercise, ExerciseSeries, SubQuestion } from "./exercise.ts";
import { PlannedSession } from "./plannedSession.ts";
import type { ModelStore } from "./store.ts";
import { StudySession } from "./studySession.ts";
import { TheoryItem } from "./theoryItem.ts";

/** Ce que le jeu d'exemple a besoin de savoir des réglages (`SettingsStore`). */
export interface SeedSettings {
  hasSeededSampleData: boolean;
}

/** Heure précise d'un jour (`calendar.date(bySettingHour:minute:second:of:)`). */
const setTime = (date: Date, hour: number, minute: number): Date =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate(), hour, minute, 0);

export const SeedData = {
  seedIfNeeded(store: ModelStore, settings: SeedSettings): void {
    if (store.fetchCount(Course) !== 0) return;
    SeedData.seed(store);
    settings.hasSeededSampleData = true;
  },

  seed(store: ModelStore): AcademicTerm {
    const today = new Date();
    const termStart = DateUtils.currentAutumnOrSpringStart(today).start;
    const termEnd = DateUtils.addWeeks(14, termStart);
    const month = today.getMonth() + 1;
    const season: TermSeason = month >= 2 && month <= 7 ? "spring" : "autumn";

    const term = new AcademicTerm({
      year: today.getFullYear(),
      season,
      startDate: termStart,
      endDate: termEnd,
      totalWeeks: 14,
    });
    store.insert(term);

    // MARK: CS-250
    const cs = new Course({
      code: "CS-250",
      name: "Algorithms I",
      credits: 6,
      colorHex: "#4F46E5",
      iconName: "chevron.left.forwardslash.chevron.right",
      term,
      weeklyLectureHours: 3,
      weeklyExerciseHours: 2,
      lecturer: "Prof. Exemple",
    });
    store.insert(cs);
    addTheory(cs, store, "video", [
      [1, "1.1", "Introduction & complexité", 2700, 1],
      [1, "1.2", "Analyse asymptotique", 3120, 1],
      [1, "1.3", "Diviser pour régner", 2400, 1],
      [2, "2.1", "Récurrences & tri", 2880, 2],
      [2, "2.2", "Tas et files de priorité", 3300, 2],
      [3, "3.1", "Graphes : parcours", 3000, 3],
      [3, "3.2", "Plus courts chemins", 3240, 3],
      [4, "4.1", "Programmation dynamique", 3600, 4],
    ]);
    addSeries(cs, store, 1, 1, [["1.1", false], ["1.2", false], ["1.3", true]]);
    addSeries(cs, store, 2, 2, [["2.1", false], ["2.2", false], ["2.3", true]]);
    addSeries(cs, store, 3, 3, [["3.1", false], ["3.2", false]]);
    addSeries(cs, store, 4, 4, [["4.1", false], ["4.2", false], ["4.3", true]]);
    addExams(cs, store, termStart, [
      ["midterm", "Midterm", 6, 30, "SG1"],
      ["exam", "Examen final", 14, 70, "Polydôme"],
    ]);

    // MARK: MATH-101
    const math = new Course({
      code: "MATH-101",
      name: "Analyse I",
      credits: 7,
      colorHex: "#0EA5E9",
      iconName: "function",
      term,
      weeklyLectureHours: 4,
      weeklyExerciseHours: 2,
      lecturer: "Prof. Exemple",
    });
    store.insert(math);
    addTheory(math, store, "video", [
      [1, "1.1", "Suites et limites", 3000, 1],
      [1, "1.2", "Continuité", 2700, 1],
      [2, "2.1", "Dérivées", 2820, 2],
      [2, "2.2", "Théorèmes de la moyenne", 2400, 2],
      [3, "3.1", "Intégration", 3180, 3],
    ]);
    addSeries(math, store, 1, 1, [["1.1", false], ["1.2", false]]);
    addSeries(math, store, 2, 2, [["2.1", false], ["2.2", false], ["2.3", true]]);
    addSeries(math, store, 3, 3, [["3.1", false], ["3.2", true]]);
    addExams(math, store, termStart, [
      ["midterm", "Midterm", 7, 30, "CM1"],
      ["exam", "Examen final", 14, 70, "Polydôme"],
    ]);

    // MARK: PHYS-101
    const phys = new Course({
      code: "PHYS-101",
      name: "Physique générale I",
      credits: 5,
      colorHex: "#10B981",
      iconName: "atom",
      term,
      weeklyLectureHours: 3,
      weeklyExerciseHours: 1.5,
      lecturer: "Prof. Exemple",
    });
    store.insert(phys);
    addTheory(phys, store, "video", [
      [1, "1.1", "Cinématique", 2400, 1],
      [1, "1.2", "Dynamique", 2640, 1],
      [2, "2.1", "Travail et énergie", 2520, 2],
    ]);
    addSeries(phys, store, 1, 1, [["1.1", false], ["1.2", false]]);
    addSeries(phys, store, 2, 2, [["2.1", false]]);
    addExams(phys, store, termStart, [["exam", "Examen final", 14, 100, "Polydôme"]]);

    // MARK: PROJ-101 — cours sans heures d'amphi
    // Démontre le réglage « ce cours a-t-il un cours ? » : aucune heure d'amphi n'est
    // attendue, tout le travail est du personnel / exercices.
    const project = new Course({
      code: "PROJ-101",
      name: "Projet de semestre",
      credits: 8,
      colorHex: "#8B5CF6",
      iconName: "hammer.fill",
      term,
      weeklyLectureHours: 0,
      weeklyExerciseHours: 0,
      hasLectures: false,
      lecturer: "Encadrant·e",
    });
    store.insert(project);
    // Cours sans aucune vidéo : sa théorie est un chapitre à lire, sans durée.
    addTheory(project, store, "chapter", [[1, "1.1", "Consignes et cadrage", 0, 1]]);
    addSeries(project, store, 1, 2, [["1.1", false], ["1.2", false]]);

    // MARK: Progression d'exemple (théorie + exercices + corrections)
    applySampleProgress([cs, math, phys], store);

    // MARK: Sessions de travail des 10 derniers jours
    applySampleSessions(store, [cs, math, phys]);

    // MARK: Session d'étude planifiée aujourd'hui
    store.insert(new PlannedSession({
      course: cs,
      title: "Révisions séries 1–2",
      startsAt: setTime(new Date(), 17, 0),
      durationMinutes: 90,
      location: "Bibliothèque Rolex",
      createdByUserID: "me",
    }));

    store.insert(new PlannedSession({
      course: math,
      groupRemoteID: null,
      groupName: "Buddies EPFL",
      title: "Analyse I — entraide",
      startsAt: DateUtils.addDays(1, setTime(new Date(), 18, 30)),
      durationMinutes: 120,
      location: "BC 01",
      createdByUserID: "friend-1",
      goingCount: 3,
      maybeCount: 1,
    }));

    store.save();
    return term;
  },
};

// MARK: - Helpers

/**
 * Ajoute des éléments de théorie. Le support est porté par l'élément : un cours sans
 * aucune vidéo reçoit des chapitres, et un support sans durée n'en invente pas une.
 */
function addTheory(
  course: Course,
  store: ModelStore,
  kind: TheoryKind,
  specs: [number, string, string, number, number][],
): void {
  specs.forEach((spec, index) => {
    store.insert(new TheoryItem({
      course,
      sectionNumber: spec[0],
      number: spec[1],
      title: spec[2],
      kind,
      durationSeconds: kind === "video" || kind === "slides" ? spec[3] : 0,
      plannedWeek: spec[4],
      sortOrder: index,
    }));
  });
}

function addSeries(
  course: Course,
  store: ModelStore,
  number: number,
  week: number,
  exercises: [string, boolean][],
): void {
  const series = new ExerciseSeries({ course, seriesNumber: number, title: `Série ${number}`, plannedWeek: week });
  store.insert(series);
  exercises.forEach((spec, index) => {
    store.insert(new Exercise({
      series,
      exerciseNumber: spec[0],
      title: spec[1] ? "Exercice bonus" : "",
      isBonus: spec[1],
      sortOrder: index,
    }));
  });
}

function addExams(
  course: Course,
  store: ModelStore,
  termStart: Date,
  specs: [ExamKind, string, number, number, string][],
): void {
  for (const spec of specs) {
    // À 8 h 15, l'heure des examens EPFL — une date à minuit n'a pas d'heure.
    const day = DateUtils.addWeeks(spec[2], termStart);
    store.insert(new Exam({
      course,
      kind: spec[0],
      title: spec[1],
      date: setTime(day, 8, 15),
      weightPercent: spec[3],
      location: spec[4],
    }));
  }
}

/** Marque une partie du contenu comme fait / corrigé pour que l'UI soit parlante. */
function applySampleProgress(courses: Course[], store: ModelStore): void {
  const cs = courses.find((c) => c.code === "CS-250");
  const math = courses.find((c) => c.code === "MATH-101");
  const phys = courses.find((c) => c.code === "PHYS-101");
  if (!cs || !math || !phys) return;

  const today = new Date();

  // CS-250 : théorie avancée, séries 1–2 traitées.
  for (const video of cs.sortedTheoryItems) {
    if (["1.1", "1.2", "1.3", "2.1"].includes(video.number)) {
      video.watchedAt = DateUtils.addDays(-6, today);
    }
    if (["1.1", "1.2", "1.3"].includes(video.number)) {
      video.summarizedAt = DateUtils.addDays(-5, today);
      video.summaryText = `Résumé de la vidéo ${video.number}.`;
    }
  }
  // Une série dont les exercices portent des questions : c'est le cas des polycopiés qui
  // numérotent « 1., 2. » à l'intérieur d'un même exercice. Sans exemple, l'écran de
  // détail ne montrerait jamais cette partie.
  const s3 = cs.sortedSeries.find((s) => s.seriesNumber === 3);
  if (s3) {
    const labels = [["a", "b"], ["1", "2", "3"], [] as string[], ["1", "2"]];
    // Un énoncé lu, pour que l'écran d'exercice montre ce qu'il fait d'un vrai texte :
    // formules, sous-questions, celle en cours.
    const texts: string[][] = [[
      "Écrire la relation de récurrence vérifiée par son coût $T(n)$.",
      "En déduire que $T(n) = O(n \\log n)$.",
    ], [], [], []];
    const first = s3.sortedExercises[0];
    if (first) {
      first.statement = "On considère le tri fusion d'un tableau de $n$ éléments, avec $n = 2^k$.";
    }
    s3.sortedExercises.forEach((exercise, index) => {
      if (index >= labels.length) return;
      const questions = labels[index];
      if (questions.length === 0) return;
      questions.forEach((label, order) => {
        const question = new SubQuestion({ exercise, label, sortOrder: order });
        if (order < texts[index].length) question.text = texts[index][order];
        store.insert(question);
      });
    });
    // Le premier exercice est entamé : une question sur deux cochée.
    const entamed = s3.sortedExercises.find((e) => e.hasSubQuestions);
    const question = entamed?.sortedSubQuestions[0];
    if (question) {
      question.isDone = true;
      question.doneAt = DateUtils.addDays(-1, today);
    }
  }
  const s1 = cs.sortedSeries.find((s) => s.seriesNumber === 1);
  if (s1) {
    for (const exercise of s1.sortedExercises) {
      exercise.doneAt = DateUtils.addDays(-4, today);
      exercise.confidence = exercise.isBonus ? "orange" : "green";
      exercise.correctedAt = DateUtils.addDays(-3, today);
      exercise.correctness = "correct";
    }
  }
  const s2 = cs.sortedSeries.find((s) => s.seriesNumber === 2);
  if (s2) {
    for (const exercise of s2.sortedExercises) {
      if (exercise.isBonus) continue;
      exercise.doneAt = DateUtils.addDays(-1, today);
      exercise.confidence = "orange";
    }
    const first = s2.sortedExercises[0];
    if (first) {
      first.correctedAt = DateUtils.addDays(-1, today);
      first.correctness = "partial";
      first.redoRequired = true;
      first.correctionNote = "Revoir la récurrence du cas moyen.";
    }
  }

  // MATH-101 : en cours.
  for (const video of math.sortedTheoryItems) {
    if (["1.1", "1.2"].includes(video.number)) video.watchedAt = DateUtils.addDays(-3, today);
  }
  const m1 = math.sortedSeries.find((s) => s.seriesNumber === 1);
  if (m1) {
    m1.sortedExercises.forEach((exercise, index) => {
      exercise.doneAt = DateUtils.addDays(-2, today);
      exercise.confidence = index === 0 ? "green" : "red";
    });
  }

  // PHYS-101 : à peine commencé.
  for (const video of phys.sortedTheoryItems) {
    if (video.number === "1.1") video.watchedAt = DateUtils.addDays(-1, today);
  }
}

function applySampleSessions(store: ModelStore, courses: Course[]): void {
  const cs = courses.find((c) => c.code === "CS-250");
  const math = courses.find((c) => c.code === "MATH-101");
  const phys = courses.find((c) => c.code === "PHYS-101");
  if (!cs || !math || !phys) return;

  // (jours en arrière, cours, type, minutes)
  const plan: [number, Course, TaskType, number][] = [
    [9, cs, "video", 90],
    [9, cs, "summary", 30],
    [8, math, "lecture", 120],
    [8, math, "exercise", 75],
    [7, cs, "exercise", 110],
    [7, cs, "correction", 45],
    [6, phys, "video", 60],
    [5, cs, "flashcards", 40],
    [5, math, "theory", 90],
    [4, cs, "exercise", 120],
    [3, cs, "correction", 50],
    [3, math, "exercise", 80],
    [2, phys, "exercise", 70],
    [1, cs, "video", 105],
    [1, math, "theory", 60],
    [0, cs, "exercise", 95],
    [0, cs, "correction", 35],
  ];

  for (const entry of plan) {
    store.insert(new StudySession({
      course: entry[1],
      taskType: entry[2],
      startedAt: DateUtils.addDays(-entry[0], new Date()),
      durationSeconds: entry[3] * 60,
      isManual: true,
    }));
  }
}
