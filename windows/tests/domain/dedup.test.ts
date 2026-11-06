// Port des sections de Validation/main.swift qui portent sur la fusion iCloud,
// les décisions entre appareils, le journal local et la distribution.
// Un `it` par `check` Swift, même libellé.

import { describe, expect, it } from "vitest";
import {
  AcademicMilestone, AcademicTerm, Course, Exercise, ExerciseSeries, ModelStore, StudySession,
} from "../../src/models/index.ts";
import { SyncDeduplicator } from "../../src/domain/syncDeduplicator.ts";
import {
  CloudRelay, type TimerDecision,
} from "../../src/domain/cloudRelay.ts";
import {
  newFocusTimerState, pause, start, type FocusTimerState,
} from "../../src/domain/focusTimerState.ts";
import { LogBuffer, LogEntry, AppLog, memoryLogStore } from "../../src/domain/appLog.ts";
import { FeedbackMail, MacUpdateFeed, AppDistribution } from "../../src/domain/appDistribution.ts";

function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

const add = (date: Date, seconds: number): Date => new Date(date.getTime() + seconds * 1000);
const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);

// MARK: iCloud : fusion des doublons

describe("iCloud : fusion des doublons", () => {
  const store = new ModelStore();
  // Deux appareils ont importé le même semestre et le même cours, chacun de son côté.
  const idA = "00000000-0000-0000-0000-00000000000A";
  const idB = "00000000-0000-0000-0000-00000000000B";
  const termA = new AcademicTerm({ year: 2026, season: "autumn", startDate: new Date(0), endDate: new Date(1000) });
  const termB = new AcademicTerm({ year: 2026, season: "autumn", startDate: new Date(0), endDate: new Date(1000) });
  const a = new Course({ id: idB, code: "CS-250", name: "Algorithms I", credits: 6 });
  const b = new Course({ id: idA, code: "cs-250", name: "Algorithms I", credits: 6 });
  a.term = termA;
  b.term = termB;
  a.isTracked = true;
  a.contentSources = ["https://moodle.epfl.ch/course/view.php?id=1"];
  for (const term of [termA, termB]) store.insert(term);
  for (const course of [a, b]) store.insert(course);
  const sa = new ExerciseSeries({ course: a, seriesNumber: 1 });
  const sb = new ExerciseSeries({ course: b, seriesNumber: 1 });
  const sb2 = new ExerciseSeries({ course: b, seriesNumber: 2 });
  const a11 = new Exercise({ series: sa, exerciseNumber: "1.1" });
  const a12 = new Exercise({ series: sa, exerciseNumber: "1.2" });
  const b11 = new Exercise({ series: sb, exerciseNumber: "1.1" });
  const b12 = new Exercise({ series: sb, exerciseNumber: "1.2" });
  const b21 = new Exercise({ series: sb2, exerciseNumber: "2.1" });
  const early = new Date(1_000_000 * 1000);
  const late = new Date(2_000_000 * 1000);
  a11.doneAt = late;
  a11.correctedAt = early;
  a11.correctnessRaw = "wrong";
  a11.redoRequired = true;
  b11.doneAt = early;
  b11.correctedAt = late;
  b11.correctnessRaw = "correct";
  b12.doneAt = late;
  for (const series of [sa, sb, sb2]) store.insert(series);
  for (const exercise of [a11, a12, b11, b12, b21]) store.insert(exercise);
  const sessA = new StudySession({ course: a, taskType: "exercise", startedAt: early, durationSeconds: 600 });
  const sessB = new StudySession({ course: b, taskType: "exercise", startedAt: late, durationSeconds: 900 });
  sessB.exercise = b12;
  const ankiA = new StudySession({ course: a, taskType: "flashcards", startedAt: early, durationSeconds: 300 });
  const ankiB = new StudySession({ course: b, taskType: "flashcards", startedAt: early, durationSeconds: 300 });
  ankiA.externalKey = "anki:42";
  ankiB.externalKey = "anki:42";
  for (const session of [sessA, sessB, ankiA, ankiB]) store.insert(session);
  const m1 = new AcademicMilestone({ externalID: "epfl-rentree", title: "Rentrée", date: early, kind: "teachingStart" });
  const m2 = new AcademicMilestone({ externalID: "epfl-rentree", title: "Rentrée", date: early, kind: "teachingStart" });
  for (const milestone of [m1, m2]) store.insert(milestone);
  store.save();

  const report = SyncDeduplicator.run(store);
  const keptCourses = store.fetch(Course);
  check(keptCourses.length === 1 && keptCourses[0].id === idA,
    "un seul CS-250, le même gardé sur chaque appareil (plus petit identifiant)");
  const kept = keptCourses[0];
  check(store.fetch(AcademicTerm).length === 1 && kept.term !== null, "un seul semestre, le cours y reste rattaché");
  check(kept.isTracked && kept.contentSources.length === 1, "suivi et sources repris de l'autre copie");
  check(kept.series.length === 2, `séries fusionnées par numéro, la série 2 rapatriée (${kept.series.length})`);
  const s1 = kept.series.find((series) => series.seriesNumber === 1)!;
  check(s1.exercises.length === 2, `exercices fusionnés par numéro (${s1.exercises.length})`);
  const e11 = s1.exercises.find((exercise) => exercise.exerciseNumber === "1.1")!;
  const e12 = s1.exercises.find((exercise) => exercise.exerciseNumber === "1.2")!;
  check(e11.doneAt?.getTime() === early.getTime(), "fait : la date la plus ancienne");
  check(e11.correctness === "correct" && !e11.redoRequired && e11.correctedAt?.getTime() === late.getTime(),
    "la correction la plus récente l'emporte, en bloc");
  check(e12.isDone, "un exercice fait d'un seul côté reste fait");
  const keptSessions = store.fetch(StudySession);
  check(keptSessions.length === 3,
    `aucune session perdue ; la révision Anki relevée deux fois n'est comptée qu'une fois (${keptSessions.length})`);
  check(keptSessions.every((session) => session.course?.id === idA), "chaque session suit le cours gardé");
  check(sessB.exercise?.exerciseNumber === "1.2" && sessB.exercise?.series?.course?.id === idA,
    "une session garde sa cible, fusionnée elle aussi");
  check(store.fetch(AcademicMilestone).length === 1, "le calendrier de l'EPFL installé deux fois : une seule échéance");
  check(report.merged["cours"] === 1 && report.merged["sessions"] === 1, `compte rendu : ${report.summary}`);
  check(SyncDeduplicator.run(store).total === 0, "deuxième passage : plus rien à fusionner");
});

// MARK: Entre appareils : chrono partagé, Moodle relu une fois

describe("Entre appareils : chrono partagé, Moodle relu une fois", () => {
  const t0 = new Date(2_000_000_000 * 1000);
  const session = newFocusTimerState({ sessionStartedAt: t0, taskTypeRaw: "exercise" });
  start(session, t0);
  const snap = (
    state: FocusTimerState | null,
    at: number,
    device = "mac",
    ended: Date | null = null,
  ): CloudRelay.TimerSnapshot => new CloudRelay.TimerSnapshot({
    state, endedSession: ended, updatedAt: add(t0, at), device,
  });
  const now = add(t0, 120);
  const isAdopt = (decision: TimerDecision, state: FocusTimerState): boolean =>
    decision.kind === "adopt" && CloudRelay.sameState(decision.state, state);

  check(isAdopt(CloudRelay.decide(null, snap(session, 1), null, "iphone", null, now), session),
    "chrono démarré sur le Mac : l'iPhone le reprend");
  check(CloudRelay.decide(null, snap(session, 1, "iphone"), null, "iphone", null, now).kind === "ignore",
    "son propre écho est ignoré");
  check(CloudRelay.decide(null, snap(session, 1), add(t0, 5), "iphone", null, now).kind === "ignore",
    "un état plus ancien que le dernier appliqué est ignoré");
  const paused = newFocusTimerState({ ...session });
  pause(paused, add(t0, 60));
  check(isAdopt(CloudRelay.decide(session, snap(paused, 60), t0, "iphone", null, now), paused),
    "pause sur le Mac : même session, l'iPhone suit");
  check(CloudRelay.decide(session, snap(null, 90, "mac", t0), t0, "iphone", null, now).kind === "close",
    "terminée sur le Mac : l'iPhone ferme sans enregistrer une seconde fois");
  const other = newFocusTimerState({ sessionStartedAt: add(t0, 30) });
  start(other, add(t0, 30));
  check(CloudRelay.decide(other, snap(session, 60), t0, "iphone", null, now).kind === "ignore",
    "deux sessions différentes ne s'écrasent jamais");
  check(CloudRelay.decide(other, snap(null, 90, "mac", t0), t0, "iphone", null, now).kind === "ignore",
    "la fin d'une autre session ne ferme pas la mienne");
  // Terminer puis relancer aussitôt sur l'iPhone : seule la nouvelle session arrive.
  const next = newFocusTimerState({ sessionStartedAt: add(t0, 100) });
  start(next, add(t0, 100));
  check(isAdopt(CloudRelay.decide(session, snap(next, 101, "mac", t0), t0, "iphone", null, now), next),
    "nouvelle session après avoir terminé la mienne ailleurs : elle remplace la mienne");
  check(isAdopt(CloudRelay.decide(session, snap(next, 101), t0, "iphone", t0, now), next),
    "ma session était partagée et l'autre appareil en a lancé une plus récente : il l'a fermée");
  check(CloudRelay.decide(session, snap(next, 101), t0, "iphone", null, now).kind === "ignore",
    "session jamais partagée : une autre session ne l'écrase pas");
  // L'iPhone a dormi pendant trois sessions du Mac : la sienne est dans la liste des fermées.
  const several = new CloudRelay.TimerSnapshot({
    state: next, endedSession: add(t0, 50), updatedAt: add(t0, 101), device: "mac",
    endedSessions: [add(t0, 50), add(t0, 20), t0],
  });
  check(isAdopt(CloudRelay.decide(session, several, t0, "iphone", null, now), next),
    "plusieurs sessions fermées pendant que l'iPhone dormait : il reconnaît la sienne et suit");
  const closedOld = new CloudRelay.TimerSnapshot({
    state: null, endedSession: add(t0, 50), updatedAt: add(t0, 101), device: "mac",
    endedSessions: [add(t0, 50), t0],
  });
  check(CloudRelay.decide(session, closedOld, t0, "iphone", null, now).kind === "close",
    "sa session figure parmi les fermées : il la ferme");
  check(CloudRelay.decide(next, snap(session, 101), t0, "iphone", add(t0, 100), now).kind === "ignore",
    "une session plus ancienne ne remplace jamais une plus récente");

  const viaKVS = snap(null, 10, "mac", t0);
  const viaBase = snap(session, 20, "iphone");
  const mine = snap(session, 30, "mac-self");
  check(CloudRelay.newest([viaKVS, viaBase, mine], "mac-self") === viaBase,
    "deux voies (clé-valeur, base) : le plus récent des autres appareils fait foi");
  const hour = 3600;
  check(CloudRelay.refreshIsDue(null, null, "a", 12 * hour, t0), "jamais relu : à faire");
  check(!CloudRelay.refreshIsDue(null, { at: add(t0, -hour), device: "b" }, "a", 12 * hour, t0),
    "relu par l'iPad il y a une heure : l'iPhone ne relit pas");
  check(CloudRelay.refreshIsDue(null, { at: add(t0, -13 * hour), device: "b" }, "a", 12 * hour, t0),
    "relu ailleurs il y a 13 h : à refaire");
  check(!CloudRelay.refreshIsDue(add(t0, -hour), null, "a", 12 * hour, t0), "relu ici il y a une heure : pas encore");
  const merged = CloudRelay.mergeKnown({ "1": ["a", "b"] }, { "1": ["b", "c"], "2": ["x"] });
  check(same(merged, { "1": ["a", "b", "c"], "2": ["x"] }), "activités vues : union de tous les appareils");
});

// MARK: Journal local

describe("Journal local", () => {
  let logEntries: LogEntry[] = [];
  for (let index = 0; index < 10; index++) {
    logEntries = LogBuffer.append(new LogEntry({ level: "info", category: "test", message: `ligne ${index}` }), logEntries);
  }
  check(logEntries.length === 10, `dix lignes ajoutées (${logEntries.length})`);
  check(logEntries[0].message === "ligne 9", "la plus récente est en tête");

  // Le tampon est borné.
  let bounded: LogEntry[] = [];
  for (let index = 0; index < LogBuffer.limit + 50; index++) {
    bounded = LogBuffer.append(new LogEntry({ level: "info", category: "test", message: `${index}` }), bounded);
  }
  check(bounded.length === LogBuffer.limit, `le journal est borné à ${LogBuffer.limit} lignes (${bounded.length})`);

  // Quand la place manque, on garde ce qui explique un problème.
  let mixed: LogEntry[] = [];
  mixed = LogBuffer.append(new LogEntry({ level: "error", category: "test", message: "erreur ancienne" }), mixed);
  for (let index = 0; index < LogBuffer.limit; index++) {
    mixed = LogBuffer.append(new LogEntry({ level: "info", category: "test", message: `${index}` }), mixed);
  }
  check(mixed.some((entry) => entry.message === "erreur ancienne"), "une erreur survit à l'éviction des informations");
  check(mixed.length <= LogBuffer.limit, `et le tampon reste borné (${mixed.length})`);
  check(LogBuffer.filtered(mixed, null).length === mixed.length, "sans filtre, tout passe");
  check(LogBuffer.filtered(mixed, "error").length === 1, "le filtre par niveau isole les erreurs");
  check(LogBuffer.count(mixed, "info") === mixed.length - 1, "le comptage par niveau est juste");
  check(LogBuffer.text([]) === "Journal vide.", "un journal vide se dit vide");
  check(LogBuffer.text([
    new LogEntry({ level: "warning", category: "sync", message: "échec", detail: "détail" }),
  ]).includes("AVERTISSEMENT"), "le texte porte le niveau en clair");
  check(LogBuffer.text([
    new LogEntry({ level: "info", category: "import", message: "ok", detail: "deuxième ligne" }),
  ]).includes("deuxième ligne"), "le détail est repris dans l'export");

  // Persistance : ce que le journal écrit se relit.
  const defaults = memoryLogStore();
  AppLog.record("info", "test", "conservé", null, defaults);
  check(AppLog.load(defaults).length === 1 && AppLog.load(defaults)[0].message === "conservé", "le journal se relit");
  AppLog.clear(defaults);
  check(AppLog.load(defaults).length === 0, "le journal s'efface");
});

// MARK: Distribution

describe("Distribution : retour et mises à jour du Mac", () => {
  const entry = new LogEntry({
    date: new Date(2_000_000_000 * 1000), level: "error",
    category: "Sync", message: "a & b = c ?", detail: "ligne 1\nligne 2",
  });
  const mail = FeedbackMail.url("polymestre@example.ch", "2.1 (3)", "iPhone · iOS 27.0", [entry]);
  const text = mail?.toString() ?? "";
  check(text.startsWith("mailto:polymestre@example.ch?subject="), "retour : un lien mailto vers l'adresse configurée");
  const body = text.split("&body=").pop() ?? "";
  check(!body.includes("&") && !body.includes("="), "retour : « & » et « = » du journal encodés (le corps n'est pas coupé)");
  check(decodeURIComponent(body).includes("a & b = c ?") && decodeURIComponent(body).includes("2.1 (3)"),
    "retour : le journal et la version sont dans le corps");
  check(decodeURIComponent(body).includes("\r\n"), "retour : fins de ligne CRLF (RFC 6068)");
  const many = Array.from({ length: 500 }, () => new LogEntry({
    level: "info", category: "x", message: "é".repeat(80),
  }));
  const long = FeedbackMail.url("a@b.ch", "1", "Mac", many);
  check(Array.from(decodeURIComponent(long?.toString().split("&body=").pop() ?? "")).length <= FeedbackMail.maxBody + 200,
    "retour : un long journal est tronqué");

  const json = `{"version":"2.2","build":7,"url":"https://studytrack.hczr.ch/mac/Polymestre.dmg","notes":"Mise à jour"}`;
  const feed = MacUpdateFeed.decode(json);
  check(feed?.build === 7 && feed?.version === "2.2", "mise à jour : le flux se lit");
  check(feed?.isNewer("3") === true, "mise à jour : build 7 > 3 → proposée");
  check(feed?.isNewer("7") === false && feed?.isNewer("9") === false, "mise à jour : même build ou plus récente → rien");
  check(feed?.isNewer(null) === false, "mise à jour : build inconnue → rien");
  check(MacUpdateFeed.decode("<html>") === null, "mise à jour : une page d'erreur n'est pas un flux");
  const t = new Date(2_000_000_000 * 1000);
  check(MacUpdateFeed.isDue(null, t), "mise à jour : jamais lue → à lire");
  check(!MacUpdateFeed.isDue(add(t, -3600), t), "mise à jour : lue il y a une heure → pas encore");
  check(MacUpdateFeed.isDue(add(t, -90_000), t), "mise à jour : lue hier → à relire");
  check(MacUpdateFeed.isDue(add(t, 3600), t), "mise à jour : horloge reculée → à relire");

  AppDistribution.configure({ feedbackEmail: "a@b.ch", siteHost: "polymestre.example", version: "2.1", build: "14" });
  check(AppDistribution.versionLabel() === "2.1 (14)", "version : « 2.1 (14) »");
});
