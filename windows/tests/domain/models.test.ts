// Port des sections de Validation/main.swift qui ne portent que sur les modèles
// (StudyTrack/Models), DateUtils et Plural. Chaque `check` Swift devient un `it` du
// même libellé ; la condition est évaluée à la collecte, dans l'ordre du fichier Swift,
// parce que les sections se suivent sur le même contexte (comme dans main.swift).
//
// Non portés (moteur d'un autre domaine, SwiftData réel, PDFKit…) : voir le rapport de
// l'agent ; chaque omission est signalée par un commentaire « NON PORTÉ ».

import { describe, expect, it } from "vitest";
import {
  AcademicTerm, Course, Exam, ExamKind, Exercise, ExerciseSeries, GroupMember, GroupRole,
  GroupSeriesCompletion, LinkedCalendarEvent, LinkedTask, ModelStore, PastExam, PastExamProgress,
  PlannedSession, SeedData, StudyGroup, StudySession, SubQuestion, TaskProvider, TheoryItem,
  TheoryKind, relations, type DetectedSubQuestionData,
} from "../../src/models/index.ts";
import { tables } from "../../src/models/schema.ts";
import { DateUtils } from "../../src/domain/dateUtils.ts";
import { Plural } from "../../src/domain/plural.ts";

/** `check(condition, label)` : la condition est évaluée tout de suite, l'assertion rejouée par vitest. */
function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

/** `DetectedSubQuestion(label:text:kind:children:)` avec ses valeurs par défaut. */
const dq = (label: string, o: Partial<Omit<DetectedSubQuestionData, "label">> = {}): DetectedSubQuestionData =>
  ({ label, text: "", kind: "question", children: [], ...o });

const eq = <T>(a: T, b: T): boolean => JSON.stringify(a) === JSON.stringify(b);
const byCode = (a: Course, b: Course): number => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0);

const store = new ModelStore();

const term = SeedData.seed(store);
const courses = store.fetch(Course);
const cs = courses.find((c) => c.code === "CS-250")!;

describe("Données d'exemple", () => {
  const videos = store.fetch(TheoryItem);
  const series = store.fetch(ExerciseSeries);
  const exercises = store.fetch(Exercise);
  const sessions = store.fetch(StudySession);
  const exams = store.fetch(Exam);

  check(courses.length === 4, `4 cours (${courses.length})`);
  check(term.displayName !== "", `semestre « ${term.displayName} »`);
  check(videos.length === 17, `vidéos (${videos.length})`);
  check(series.length === 10, `séries (${series.length})`);
  check(exercises.length === 23, `exercices (${exercises.length})`);
  check(sessions.length === 17, `sessions (${sessions.length})`);
  check(exams.length === 5, `évaluations (${exams.length})`);
});

describe("Relations inverses SwiftData", () => {
  for (const course of [...courses].sort(byCode)) {
    check(course.theoryItems.length !== 0, `${course.code} : videos peuplé (${course.theoryItems.length})`);
    check(course.theoryItems.every((t) => t.course?.code === course.code),
      `${course.code} : inverse vidéo→cours cohérent`);
    check(course.series.length !== 0, `${course.code} : series peuplé (${course.series.length})`);
    check(course.series.every((s) => s.exercises.length !== 0),
      `${course.code} : chaque série a des exercices`);
    check(course.series.every((s) => s.exercises.every((e) => e.series?.id === s.id)),
      `${course.code} : inverse exercice→série cohérent`);
  }
});

describe("Théorie typée (cours sans vidéo)", () => {
  const projectCourse = courses.find((c) => c.code === "PROJ-101");
  check(projectCourse !== undefined, "le cours sans vidéo existe dans les données d'exemple");
  if (projectCourse) {
    check(projectCourse.theoryItems.length !== 0, "il a bien de la théorie");
    check(projectCourse.theoryItems.every((t) => t.kind !== "video"), "aucun de ses éléments n'est une vidéo");
    check(projectCourse.theoryItems.every((t) => !t.hasDuration), "ses chapitres n'ont pas de durée inventée");
    const chapter = projectCourse.theoryItems[0];
    if (chapter) {
      check(chapter.displayNumber.startsWith("Théorie"),
        `le libellé est celui de la catégorie, pas du support : « ${chapter.displayNumber} »`);
      check(TheoryKind.icon(chapter.kind) !== TheoryKind.icon("video"), "l'icône suit le support");
      // NON PORTÉ : « un chapitre compte comme théorie restante »
      // (ProgressEngine.remainingVideos — moteur d'un autre agent).
    }
  }
  check(courses.some((c) => c.theoryItems.some((t) => t.kind === "video")),
    "les autres cours ont bien des vidéos");
  check(new Set(TheoryKind.allCases.map(TheoryKind.label)).size === 4,
    `quatre supports distincts : ${TheoryKind.allCases.map(TheoryKind.label).join(", ")}`);
});

describe("Entités sociales", () => {
  const group = new StudyGroup({ name: "Groupe test", courseCode: "CS-250" });
  store.insert(group);
  store.insert(new GroupMember({ group, userID: "u1", displayName: "Alice Moreau", weeklySeconds: 12 * 3600, totalSeconds: 96 * 3600, completedSeriesCount: 4 }));
  store.insert(new GroupSeriesCompletion({ group, userID: "u1", displayName: "Alice Moreau", courseCode: "CS-250", seriesNumber: 1 }));
  store.save();
  const groups = store.fetch(StudyGroup);
  check(groups.length === 1, "groupe persisté");
  check(groups[0]?.members.length === 1, `membre lié au groupe (${groups[0]?.members.length ?? 0})`);
  check(groups[0]?.completions.length === 1, "complétion liée au groupe");
  check(groups[0]?.inviteCode.startsWith("EPFL-") === true, `code d'invitation : ${groups[0]?.inviteCode ?? "-"}`);
  check(new GroupMember({ group: groups[0], userID: "u9", displayName: "Bob Favre" }).initials === "BF", "initiales calculées");
});

describe("Matières multiples d'un groupe", () => {
  const subjectGroup = new StudyGroup({ name: "Promo", courseCodes: ["cs-250", " MATH-101 ", "CS-250", ""] });
  check(eq(subjectGroup.subjectCodes, ["CS-250", "MATH-101"]),
    `normalisation : majuscules, espaces retirés, sans doublon — ${JSON.stringify(subjectGroup.subjectCodes)}`);
  check(eq(StudyGroup.normalize(["a", "A", " b "]), ["A", "B"]), "liste de codes normalisée");
  check(StudyGroup.normalize([]).length === 0, "liste vide reste vide");

  const legacyGroup = new StudyGroup({ name: "Ancien", courseCode: "PHYS-101" });
  check(eq(legacyGroup.subjectCodes, ["PHYS-101"]), "repli sur l'ancien champ mono-matière");
  check(legacyGroup.tracks("phys-101"), "tracks() ignore la casse");
  check(!legacyGroup.tracks("BIO-101"), "tracks() rejette une matière absente");

  const bothGroup = new StudyGroup({ name: "Mixte", courseCode: "CS-250", courseCodes: ["CS-250", "MATH-101"] });
  check(eq(bothGroup.subjectCodes, ["CS-250", "MATH-101"]),
    `ancien et nouveau champ fusionnés sans doublon — ${JSON.stringify(bothGroup.subjectCodes)}`);
  check(eq(bothGroup.mySubjectCodes(new Set(["MATH-101"])), ["MATH-101"]),
    "mes matières : seulement celles que je suis");
  check(bothGroup.mySubjectCodes(new Set()).length === 0, "sans cours suivi, aucune matière commune");

  bothGroup.addSubject("bio-101");
  check(bothGroup.subjectCodes.length === 3, "ajout d'une matière");
  bothGroup.removeSubject("CS-250");
  check(eq(bothGroup.subjectCodes, ["MATH-101", "BIO-101"]),
    `retrait d'une matière, ancien champ compris — ${JSON.stringify(bothGroup.subjectCodes)}`);
  check(bothGroup.courseCode === "", "le champ historique est vidé au retrait");

  const absorbed = new StudyGroup({ name: "Absorbé", courseCode: "CS-250" });
  absorbed.subjectCodes = ["MATH-101"];
  check(eq(absorbed.subjectCodes, ["MATH-101"]),
    `définir la liste absorbe le champ historique — ${JSON.stringify(absorbed.subjectCodes)}`);
  check(absorbed.courseCode === "", "le champ historique ne peut plus ressusciter une matière retirée");
  absorbed.subjectCodes = ["CS-250", "cs-250", " PHYS-101 "];
  check(eq(absorbed.subjectCodes, ["CS-250", "PHYS-101"]),
    `affectation normalisée et dédupliquée — ${JSON.stringify(absorbed.subjectCodes)}`);

  const invitationGroup = new StudyGroup({ name: "Buddies", courseCodes: ["CS-250"], inviteCode: "EPFL-4F2A" });
  check(invitationGroup.inviteLink === "studytrack://join?code=EPFL-4F2A",
    `lien d'invitation — ${invitationGroup.inviteLink}`);
  check(StudyGroup.normalizeInviteCode(" epfl-4f2a ") === "EPFL-4F2A", "code d'invitation reçu par lien, normalisé");
  check(StudyGroup.normalizeInviteCode("EPFL 4F2A") === "EPFL4F2A", "espaces internes retirés");
  check(invitationGroup.inviteMessage.includes("EPFL-4F2A")
    && invitationGroup.inviteMessage.includes("CS-250")
    && invitationGroup.inviteMessage.includes("studytrack://"),
  "message d'invitation : nom, matières, code et lien");
});

describe("Rôles dans un groupe", () => {
  check(new GroupMember({ userID: "u2", displayName: "Bob" }).role === "member", "rôle par défaut = membre");
  const adminMember = new GroupMember({ userID: "u1", displayName: "Alice", role: "admin" });
  check(adminMember.isAdmin, "rôle admin reconnu");
  adminMember.role = "member";
  check(!adminMember.isAdmin, "rétrogradation effective");
  adminMember.roleRaw = "valeur inconnue";
  check(adminMember.role === "member", "rôle illisible retombe sur membre");
  check(GroupRole.label("admin") === "Admin" && GroupRole.label("member") === "Membre", "libellés de rôle");

  const scopedMember = new GroupMember({ userID: "u3", displayName: "Chloé", courseCodes: ["MATH-101"] });
  check(scopedMember.follows("math-101"), "un membre suit sa matière, quelle que soit la casse");
  check(!scopedMember.follows("CS-250"), "un membre ne suit pas les autres");
  check(new GroupMember({ userID: "u4", displayName: "Dan" }).follows("CS-250"),
    "sans liste explicite, un membre suit tout le groupe");
});

describe("Sous-questions", () => {
  // Un polycopié numérote ses exercices 1, 2, 3 dans chaque section, et regroupe souvent
  // plusieurs questions sous un seul numéro. Les compter comme des exercices séparés
  // gonfle la liste et fausse la progression.
  const subSeries = new ExerciseSeries({ course: courses.find((c) => c.code === "CS-250"), seriesNumber: 9 });
  const subExercise = new Exercise({ series: subSeries, exerciseNumber: "9.3", title: "Suites d'ensembles" });
  check(!subExercise.hasSubQuestions, "un exercice neuf n'a pas de question");
  check(subExercise.subQuestionLabel === null, "…et n'affiche pas de compteur");
  check(subExercise.isDone === false, "…et n'est pas fait");

  const q1 = new SubQuestion({ exercise: subExercise, label: "1", text: "L'intersection est bornée ?", sortOrder: 0 });
  const q2 = new SubQuestion({ exercise: subExercise, label: "2", text: "L'union est bornée ?", sortOrder: 1 });
  subExercise.subQuestions = [q1, q2];
  check(subExercise.hasSubQuestions, "l'exercice a maintenant des questions");
  check(subExercise.subQuestionLabel === "0/2", `compteur — ${subExercise.subQuestionLabel ?? "-"}`);

  q1.toggle();
  check(subExercise.subQuestionDoneCount === 1, "une question cochée");
  check(!subExercise.isDone, "l'exercice n'est pas fait tant qu'elles ne le sont pas toutes");
  check(subExercise.subQuestionLabel === "1/2", "compteur intermédiaire");

  q2.toggle();
  check(subExercise.isDone, "toutes cochées : l'exercice devient fait");
  check(subExercise.subQuestionLabel === "2/2", "compteur complet");

  q1.toggle();
  check(!subExercise.isDone, "décocher une question défait l'exercice");
  check(subExercise.doneAt === null, "…et la date de réalisation est retirée");

  // Cocher l'exercice entier coche ses questions : c'est le geste courant.
  subExercise.setSubQuestions(true);
  check(subExercise.isDone, "cocher l'exercice le marque fait");
  check(subExercise.subQuestions.every((q) => q.isDone), "…et coche toutes ses questions");
  subExercise.setSubQuestions(false);
  check(!subExercise.isDone, "décocher l'exercice le défait");
  check(subExercise.subQuestions.every((q) => !q.isDone), "…et décoche toutes ses questions");

  // Deux niveaux : « 1) (a) (b) » et « 2) » font trois cases, pas cinq.
  const nestedExercise = new Exercise({ series: subSeries, exerciseNumber: "9.4" });
  nestedExercise.replaceSubQuestions([
    dq("1", { children: [dq("a"), dq("b")] }),
    dq("2"),
    dq("", { text: "Ensuite, représenter", kind: "part" }),
  ], null);
  check(nestedExercise.subQuestions.length === 5, `cinq nœuds enregistrés — ${nestedExercise.subQuestions.length}`);
  check(eq(nestedExercise.sortedSubQuestions.map((q) => q.label), ["1", "2", ""]), "trois au premier niveau");
  check(nestedExercise.subQuestionLabel === "0/4", `quatre cases réelles — ${nestedExercise.subQuestionLabel ?? "-"}`);
  const pointA = nestedExercise.sortedSubQuestions[0].sortedChildren[0];
  check(pointA.path === "1.a", `chemin d'un point — ${pointA.path}`);
  pointA.toggle();
  check(!nestedExercise.sortedSubQuestions[0].isDone, "une question à moitié faite ne l'est pas");
  nestedExercise.sortedSubQuestions[0].sortedChildren[1].toggle();
  check(nestedExercise.sortedSubQuestions[0].isDone, "tous ses points faits : la question l'est");
  check(nestedExercise.subQuestionLabel === "2/4", `compteur par les points — ${nestedExercise.subQuestionLabel ?? "-"}`);
  nestedExercise.sortedSubQuestions[0].toggle();
  check(nestedExercise.subQuestionLabel === "0/4", "décocher la question décoche ses points");
  nestedExercise.sortedSubQuestions[0].toggle();
  nestedExercise.sortedSubQuestions[1].toggle();
  nestedExercise.sortedSubQuestions[2].toggle();
  check(nestedExercise.isDone, "toutes les cases faites : l'exercice l'est");

  // Un réimport remplace l'arbre et garde ce qui était coché, par chemin.
  nestedExercise.sortedSubQuestions[1].toggle();
  nestedExercise.replaceSubQuestions([
    dq("1", { children: [dq("a"), dq("b"), dq("c")] }),
    dq("2"),
  ], null);
  check(nestedExercise.subQuestionLabel === "2/4",
    `1.a et 1.b restent cochés, 1.c est neuf — ${nestedExercise.subQuestionLabel ?? "-"}`);
  check(!nestedExercise.isDone, "…et l'exercice n'est plus fait");
  check(eq(nestedExercise.detectedSubQuestions.map((q) => q.label), ["1", "2"]), "l'arbre se relit pour être modifié");

  // L'étiquette s'écrit comme le polycopié.
  check(new SubQuestion({ exercise: null, label: "1" }).displayLabel === "1.", "étiquette numérique");
  check(new SubQuestion({ exercise: null, label: "a" }).displayLabel === "(a)", "étiquette alphabétique");
  check(new SubQuestion({ exercise: null, label: "(b)" }).displayLabel === "(b)", "déjà ponctuée : inchangée");
  check(new SubQuestion({ exercise: null, label: "1." }).displayLabel === "1.", "idem pour un point");
  check(new SubQuestion({ exercise: null, label: "" }).displayLabel === "", "étiquette vide");

  // Une série dont les exercices ont des questions reste comptée par exercices.
  const subSeries2 = new ExerciseSeries({ course: null, seriesNumber: 10 });
  const e1 = new Exercise({ series: subSeries2, exerciseNumber: "10.1" });
  const e1q = new SubQuestion({ exercise: e1, label: "1" });
  e1.subQuestions = [e1q];
  const e2 = new Exercise({ series: subSeries2, exerciseNumber: "10.2" });
  subSeries2.exercises = [e1, e2];
  e1.setSubQuestions(true);
  e2.doneAt = new Date();
  check(subSeries2.doneCount === 2,
    `la série compte les exercices, pas les questions (${subSeries2.doneCount}/${subSeries2.requiredExercises.length})`);
  check(subSeries2.isComplete, "…et elle est complète");

  // NON PORTÉ (11 vérifications) : « La réponse du modèle porte les questions… » et
  // « La fusion ne mélange jamais deux numérotations » — SeriesAIParsing, DetectedSeries,
  // DetectedExercise (Domain, autre agent), pas les modèles.
});

describe("Tâches, calendrier, sessions planifiées", () => {
  const task = new LinkedTask({ provider: "todoist", externalID: "t1", title: "CS-250 exercice 1.1", dueDate: new Date() });
  task.course = cs;
  store.insert(task);
  const event = new LinkedCalendarEvent({
    title: "CS-250 Cours",
    startsAt: new Date(Date.now() - 3 * 3600_000 - 7 * 86_400_000),
    endsAt: new Date(Date.now() - 2 * 3600_000 - 7 * 86_400_000),
    kind: "lecture",
  });
  event.isAttended = true;
  event.course = cs;
  store.insert(event);
  store.insert(new PlannedSession({ course: cs, title: "Révisions", startsAt: new Date(), durationMinutes: 90 }));
  store.save();

  const tasks = store.fetch(LinkedTask);
  const events = store.fetch(LinkedCalendarEvent);
  const plannedAll = store.fetch(PlannedSession);
  check(tasks.length === 1 && tasks[0].linkLabel === "CS-250", "tâche liée au cours");
  check(events.length === 1 && events[0].isLecture, "événement de cours marqué présent");
  check(plannedAll.length === 3, `sessions planifiées (${plannedAll.length})`);
  // NON PORTÉ : « les heures d'amphi entrent dans le réel » (WorkloadEngine.classSeconds).
  check(event.countsAsAttendedLecture, "(ajout) un cours de l'horaire fini compte comme amphi suivi");
});

describe("Cours sans heures de cours (« a un cours » = non)", () => {
  const project = courses.find((c) => c.code === "PROJ-101");
  if (project) {
    check(!project.hasLectures, "PROJ-101 déclaré sans amphi");
    // NON PORTÉ : les deux vérifications de WorkloadEngine.delta (heures d'amphi attendues
    // nulles ; tout en travail personnel) — moteur d'un autre agent.
  } else {
    check(false, "PROJ-101 présent dans les données d'exemple");
  }
});

describe("Bornage de la semaine dans le semestre", () => {
  const finishedTerm = new AcademicTerm({
    year: 2020,
    season: "spring",
    startDate: DateUtils.addWeeks(-40, new Date()),
    endDate: DateUtils.addWeeks(-26, new Date()),
    totalWeeks: 14,
  });
  const clamped = DateUtils.clampedWeek(new Date(), finishedTerm);
  check(clamped === 14, `semestre terminé → semaine bornée à 14 (obtenu ${clamped})`);
  check(!finishedTerm.isRunning, "semestre terminé détecté");
  const runningTerm = new AcademicTerm({
    year: 2025,
    season: "spring",
    startDate: DateUtils.addWeeks(-2, DateUtils.startOfWeek(new Date())),
    endDate: DateUtils.addWeeks(12, new Date()),
    totalWeeks: 14,
  });
  check(runningTerm.isRunning, "semestre en cours détecté");
  // Une date fixe, sans interruption des cours dans les deux semaines : avec `Date()`, le
  // contrôle échouait chaque fois qu'une pause du calendrier EPFL (19–23 octobre 2026,
  // Pâques…) tombait dans la fenêtre — l'app avait raison.
  const fixedNow = new Date(2026, 8, 30, 12);
  const fixedTerm = new AcademicTerm({
    year: 2026,
    season: "autumn",
    startDate: DateUtils.addWeeks(-2, DateUtils.startOfWeek(fixedNow)),
    endDate: DateUtils.addWeeks(12, fixedNow),
    totalWeeks: 14,
  });
  check(DateUtils.clampedWeek(fixedNow, fixedTerm) === 3, "semestre démarré il y a 2 semaines → semaine 3");
});

describe("Début du semestre d'automne", () => {
  // L'EPFL fait commencer le semestre d'automne le lundi 7 septembre pour tout le monde.
  // Le demander à l'onboarding décalait tout le suivi hebdomadaire.
  const sept2026 = DateUtils.autumnStart(2026);
  check(sept2026.getFullYear() === 2026 && sept2026.getMonth() + 1 === 9 && sept2026.getDate() === 7,
    `2026 : le 7 septembre (${sept2026.getDate()}/${sept2026.getMonth() + 1})`);
  check(sept2026.getDay() === 1, "2026 : c'est bien un lundi");
  // Une année où le 7 septembre n'est pas un lundi doit donner le lundi suivant.
  for (let year = 2026; year <= 2032; year++) {
    const start = DateUtils.autumnStart(year);
    check(start.getDay() === 1, `${year} : le semestre commence un lundi`);
    check(start.getMonth() + 1 === 9 && start.getDate() >= 7 && start.getDate() <= 13,
      `${year} : début entre le 7 et le 13 septembre (${start.getDate()})`);
  }
  // Le suivi hebdomadaire doit alors dire « semaine 1 » la semaine du 7 septembre.
  const term = new AcademicTerm({
    year: 2026, season: "autumn", startDate: sept2026,
    endDate: DateUtils.addWeeks(14, sept2026), totalWeeks: 14,
  });
  const firstMonday = DateUtils.addDays(7, sept2026);
  check(DateUtils.clampedWeek(firstMonday, term) === 2, "la semaine suivant le 7 septembre est la semaine 2");
  check(DateUtils.clampedWeek(sept2026, term) === 1, "la semaine du 7 septembre est la semaine 1");
});

describe("Semestre rattaché aux cours importés", () => {
  // `TimetableImport` créait les cours avec `term: nil`. `Course.currentWeek` n'avait alors
  // rien pour calculer et retombait sur 1 : un import fait en semaine 2 affichait « 1 / 14 ».
  const expectedWeek = DateUtils.weekNumber(DateUtils.currentAutumnOrSpringStart().start);
  // NON PORTÉ (2) : « un cours créé par l'import d'horaire reçoit un semestre » et sa semaine
  // (cours THERMOD créé par TimetableImport/ICSParser, Services).

  const orphanCourse = new Course({ code: "ORPHAN-1", name: "Cours sans semestre" });
  store.insert(orphanCourse);
  // Deux séries importées pendant la panne : elles portent toutes deux « semaine 1 », y
  // compris la Série 2 — parce que l'import PDF prend `course.currentWeek`.
  const orphanSeries1 = new ExerciseSeries({ course: orphanCourse, seriesNumber: 1, plannedWeek: 1 });
  const orphanSeries2 = new ExerciseSeries({ course: orphanCourse, seriesNumber: 2, plannedWeek: 1 });
  const orphanSeries4 = new ExerciseSeries({ course: orphanCourse, seriesNumber: 4, plannedWeek: 7 });
  store.insert(orphanSeries1);
  store.insert(orphanSeries2);
  store.insert(orphanSeries4);
  store.save();
  check(orphanCourse.term === null, "un cours peut exister sans semestre");
  check(orphanCourse.currentWeek === expectedWeek,
    `sans semestre, la semaine reste celle du calendrier (${orphanCourse.currentWeek}) — jamais 1 par défaut`);
  const repaired = AcademicTerm.attachOrphanCourses(store);
  check(repaired >= 1, `les cours orphelins sont rattachés (${repaired})`);
  check(orphanCourse.term !== null, "le cours orphelin a maintenant un semestre");
  check(AcademicTerm.attachOrphanCourses(store) === 0, "le rattachement est idempotent");
  check(orphanCourse.term?.isRunning === true, "le semestre rattaché est celui en cours");

  // La réparation des semaines de série reste bornée.
  check(orphanSeries1.plannedWeek === 1, "une série 1 reste en semaine 1");
  check(orphanSeries2.plannedWeek === 2, `la Série 2 repasse en semaine 2 — ${orphanSeries2.plannedWeek}`);
  check(orphanSeries4.plannedWeek === 7, `une semaine choisie à la main n'est jamais écrasée — ${orphanSeries4.plannedWeek}`);

  // La date de début n'est pas déduite du jour : elle vient du calendrier EPFL.
  const autumn = DateUtils.autumnStart(2026);
  check(DateUtils.weekNumber(autumn, autumn) === 1, "le lundi de rentrée est la semaine 1");
  check(DateUtils.weekNumber(autumn, DateUtils.addDays(7, autumn)) === 2, "sept jours plus tard, semaine 2");
  check(DateUtils.weekNumber(autumn, DateUtils.addDays(9, autumn)) === 2,
    "le mercredi de la deuxième semaine est bien la semaine 2");
  // L'interruption d'automne (16 → 26 octobre 2026) ne compte pas : les sites des cours
  // reprennent à « semaine 7 » le lundi de la reprise.
  check(DateUtils.weekNumber(autumn, DateUtils.addDays(35, autumn)) === 6, "12 octobre : semaine 6");
  check(DateUtils.weekNumber(autumn, DateUtils.addDays(49, autumn)) === 7,
    `26 octobre, reprise après l'interruption : semaine 7 — ${DateUtils.weekNumber(autumn, DateUtils.addDays(49, autumn))}`);
  check(DateUtils.weekNumber(autumn, DateUtils.addDays(98, autumn)) === 14, "14 décembre : semaine 14");
  check(DateUtils.addTeachingWeeks(14, autumn).getTime() === DateUtils.addDays(105, autumn).getTime(),
    "14 semaines d'enseignement finissent une semaine plus tard que 14 semaines de calendrier");
});

describe("Pluriels : la règle de la langue", () => {
  check(Plural.usesSingular(0, "fr") && Plural.usesSingular(1, "fr") && !Plural.usesSingular(2, "fr"),
    "français : 0 et 1 au singulier");
  check(!Plural.usesSingular(0, "en") && Plural.usesSingular(1, "en"), "anglais : seul 1 au singulier");
});

describe("Annales", () => {
  const pastSummary = PastExamProgress.summary([
    { year: 2024, worked: false }, { year: 2023, worked: true }, { year: 2022, worked: true }, { year: 2021, worked: false },
  ]);
  check(pastSummary.total === 4, "quatre annales");
  check(pastSummary.worked === 2, "deux travaillées");
  check(pastSummary.label === "2/4 travaillées", `libellé du bilan — ${pastSummary.label}`);
  check(eq(pastSummary.pendingYears, [2024, 2021]), "les années restantes, de la plus récente à la plus ancienne");
  check(!pastSummary.isComplete, "le jeu n'est pas complet");

  const doneSummary = PastExamProgress.summary([{ year: 2024, worked: true }, { year: 2023, worked: true }]);
  check(doneSummary.isComplete, "tout est travaillé");
  check(doneSummary.label === "2/2 travaillées", "libellé quand tout est fait");
  check(PastExamProgress.summary([]).label === "Aucune annale", "aucune annale : le libellé le dit");
  check(PastExamProgress.summary([]).ratio === 0, "…sans division par zéro");

  check(eq(PastExamProgress.priority([
    { year: 2020, worked: false }, { year: 2024, worked: false }, { year: 2022, worked: true }, { year: 2023, worked: false },
  ]), [2024, 2023, 2020]), "priorité aux années récentes non travaillées");
  check(eq(PastExamProgress.priority([{ year: 2024, worked: false }, { year: 2023, worked: false }], 1), [2024]),
    "la priorité est bornée");
  check(PastExamProgress.priority([{ year: 2024, worked: true }]).length === 0, "rien à prioriser quand tout est fait");

  const pastCourse = courses.find((c) => c.code === "CS-250")!;
  const past = new PastExam({ course: pastCourse, title: "Examen final 2024", year: 2024 });
  check(past.title === "Examen final 2024", "titre conservé");
  check(!past.isWorked, "une annale neuve n'est pas travaillée");
  check(past.statusLabel === "Pas encore travaillé", `…et le dit — ${past.statusLabel}`);
  past.workedAt = new Date();
  past.confidence = "orange";
  check(past.isWorked, "cochée, elle est travaillée");
  check(past.statusLabel.includes("Travaillé le"), `…avec sa date — ${past.statusLabel}`);
  check(past.url === null, "sans lien, aucune URL inventée");
  past.urlString = "https://example.org/sujet.pdf";
  check(past.url !== null, "un lien valide donne une URL");
  past.urlString = "   ";
  check(past.url === null, "un lien blanc n'en donne pas");
  const untitled = new PastExam({ course: pastCourse, year: 2023, kind: "midterm" });
  check(untitled.title === "Midterm 2023", `sans titre, un intitulé par défaut — ${untitled.title}`);
});

describe("Rôle : le créateur reste administrateur après migration", () => {
  // `roleRaw` est arrivé après `StudyGroup.isAdmin`. Pour un groupe créé avant, SwiftData a
  // migré le nouvel attribut à sa valeur par défaut — « member » — y compris pour la
  // personne qui avait créé le groupe. Elle se retrouvait sans droits sur son propre groupe.
  const migratedGroup = new StudyGroup({ name: "Créé avant les rôles", isAdmin: true });
  const migratedOwner = new GroupMember({ group: migratedGroup, userID: "me", displayName: "Moi", isMe: true, role: "member" });
  check(migratedOwner.role === "member", "le rôle a bien migré à « member »");
  check(migratedOwner.isAdmin, "…et le créateur reste administrateur malgré tout");

  const joinedGroup = new StudyGroup({ name: "Rejoint", isAdmin: false });
  const joiner = new GroupMember({ group: joinedGroup, userID: "me", displayName: "Moi", isMe: true, role: "member" });
  check(!joiner.isAdmin, "celui qui a rejoint n'est pas administrateur");
  joiner.role = "admin";
  check(joiner.isAdmin, "une promotion explicite prime sur le drapeau local");
  joiner.role = "member";
  check(!joiner.isAdmin, "une rétrogradation aussi");

  const otherGroup = new StudyGroup({ name: "Autre", isAdmin: true });
  const someoneElse = new GroupMember({ group: otherGroup, userID: "u9", displayName: "Alice", role: "member" });
  check(!someoneElse.isAdmin, "le drapeau « admin » du groupe ne profite qu'à moi");
});

describe("Catégorisation fine du temps", () => {
  const exercise = cs.allExercises[0];
  const item = cs.theoryItems[0];
  if (exercise && item) {
    const precise = new StudySession({ course: cs, taskType: "exercise", startedAt: new Date(), durationSeconds: 1800, exercise });
    check(precise.targetLabel === exercise.displayNumber, `session liée à un exercice : « ${precise.targetLabel ?? "—"} »`);
    const reading = new StudySession({ course: cs, taskType: "theory", startedAt: new Date(), durationSeconds: 900, theoryItem: item });
    check(reading.targetLabel === item.displayNumber, `session liée à la théorie : « ${reading.targetLabel ?? "—"} »`);
    const loose = new StudySession({ course: cs, taskType: "exercise", durationSeconds: 600 });
    check(loose.targetLabel === null, "une session non précisée reste valide et sans cible");
    check(precise.durationSeconds + reading.durationSeconds === 2700, "le temps reste compté pareil, cible ou pas");
  }
});

describe("Notice de chaque intégration de tâches", () => {
  check(TaskProvider.allCases.length === 7, `sept fournisseurs de tâches (${TaskProvider.allCases.length})`);
  for (const provider of ["googleTasks", "tickTick"] as const) {
    check(TaskProvider.supportsReading(provider), `${TaskProvider.label(provider)} : lecture annoncée`);
    check(TaskProvider.credentialLabel(provider) !== null, `${TaskProvider.label(provider)} : identifiant nommé`);
    check(TaskProvider.icon(provider) !== TaskProvider.icon("reminders"), `${TaskProvider.label(provider)} : icône propre`);
  }
  for (const provider of TaskProvider.allCases) {
    const label = TaskProvider.label(provider);
    check(TaskProvider.setupSummary(provider) !== "", `${label} : résumé présent`);
    check(TaskProvider.setupSteps(provider).length >= 3,
      `${label} : ${TaskProvider.setupSteps(provider).length} étapes de configuration`);
    check(TaskProvider.setupSteps(provider).every((s) => s !== "" && Array.from(s).length > 12),
      `${label} : aucune étape vide ni trop courte`);
    check(TaskProvider.capabilityLabel(provider) !== "", `${label} : capacité annoncée`);
    check(TaskProvider.helpText(provider) !== "", `${label} : aide en ligne présente`);
    check(TaskProvider.setupCaveat(provider) !== null, `${label} : limite annoncée`);
  }
  check(TaskProvider.allCases.filter((p) => TaskProvider.setupURLString(p) !== null).length >= 2,
    "au moins deux fournisseurs renvoient vers leur page d'identifiants");
  check(TaskProvider.allCases.some((p) => TaskProvider.setupURLString(p) === null),
    "les fournisseurs sans page d'identifiants n'en inventent pas");
});

describe("Une épreuve n'est pas un devoir", () => {
  check(ExamKind.isSitting("exam") && ExamKind.isSitting("midterm"), "épreuve : un examen et un midterm comptent");
  check(!ExamKind.isSitting("quiz") && !ExamKind.isSitting("assignment") && !ExamKind.isSitting("project") && !ExamKind.isSitting("other"),
    "épreuve : un quiz, un devoir, un projet ou une échéance importée ne font pas passer en révision");
});

// NON PORTÉ — « Conteneur SwiftData (en mémoire) » et « Schéma versionné » : réflexion sur
// `Schema.entities`, `SchemaV1.models`, `declaredModelNames`, `Schema.Version` (SwiftData).
// L'équivalent TypeScript est le test ci-dessous, ainsi que tests/schema.test.ts.

describe("(ajout) ModelStore et règles de suppression", () => {
  it("les règles de suppression de relations.ts recoupent celles de schema.ts", () => {
    const classNameToTable = new Map(tables.map((t) => [t.model, t]));
    for (const table of tables) {
      for (const ref of table.refs) {
        const parent = classNameToTable.get(
          tables.find((p) => p.name === ref.table)!.model,
        )!.model;
        const rel = relations.find((r) => r.child === table.model && r.one === ref.swift);
        expect(rel, `${table.model}.${ref.swift}`).toBeDefined();
        expect(rel!.parent).toBe(parent);
        expect(rel!.rule).toBe(ref.onDelete);
      }
    }
  });

  it("cascade : supprimer un cours supprime ses séries, exercices, sous-questions", () => {
    const s = new ModelStore();
    SeedData.seed(s);
    const course = s.fetch(Course).find((c) => c.code === "CS-250")!;
    const before = s.fetchCount(Exercise);
    const own = course.allExercises.length;
    s.delete(course);
    expect(s.fetchCount(Exercise)).toBe(before - own);
    expect(s.fetchCount(SubQuestion)).toBe(0);
    expect(s.fetch(Course).includes(course)).toBe(false);
    expect(s.fetch(AcademicTerm)[0].courses.includes(course)).toBe(false);
  });

  it("nullify : supprimer un semestre garde les cours, sans semestre", () => {
    const s = new ModelStore();
    const term = SeedData.seed(s);
    s.delete(term);
    expect(s.fetchCount(Course)).toBe(4);
    expect(s.fetch(Course).every((c) => c.term === null)).toBe(true);
  });

  it("nullify : supprimer un exercice laisse ses sessions, sans cible", () => {
    const s = new ModelStore();
    SeedData.seed(s);
    const course = s.fetch(Course)[0];
    const exercise = course.allExercises[0];
    const session = new StudySession({ course, taskType: "exercise", exercise });
    s.insert(session);
    s.delete(exercise);
    expect(s.fetch(StudySession).includes(session)).toBe(true);
    expect(session.exercise).toBeNull();
  });

  it("assigner un parent ailleurs retire l'enfant de l'ancien parent (inverses)", () => {
    const a = new Course({ code: "A", name: "A" });
    const b = new Course({ code: "B", name: "B" });
    const item = new TheoryItem({ course: a, sectionNumber: 1, number: "1.1" });
    expect(a.theoryItems).toEqual([item]);
    item.course = b;
    expect(a.theoryItems).toEqual([]);
    expect(b.theoryItems).toEqual([item]);
    b.theoryItems = [];
    expect(item.course).toBeNull();
  });
});
