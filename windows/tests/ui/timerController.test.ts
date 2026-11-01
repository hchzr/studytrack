import { describe, expect, it } from "vitest";
import { FocusTimerController } from "../../src/ui/timerController.ts";
import { FocusTimerStore, encodeFocusTimerState, type FocusTimerState, type KeyValueStore } from "../../src/domain/focusTimerState.ts";
import { StudyMode } from "../../src/domain/studyMode.ts";
import { Course, Exercise, ExerciseSeries, ModelStore, StudySession } from "../../src/models/index.ts";
import type { TimerRecording } from "../../src/ui/timerController.ts";

/** Un `KeyValueStore` en mémoire : ce que localStorage fait dans l'app. */
function memoryStore(initial: Record<string, string> = {}): KeyValueStore & { values: Map<string, string> } {
  const values = new Map(Object.entries(initial));
  return {
    values,
    get: (key) => values.get(key) ?? null,
    set: (key, value) => { values.set(key, value); },
    remove: (key) => { values.delete(key); },
  };
}

/** Le contrôleur à l'heure d'un faux maintenant, sans battement. */
function controller(at: Date, storage: KeyValueStore = memoryStore()): FocusTimerController {
  return new FocusTimerController({ now: () => at, ticking: false, storage });
}

/** Un faux enregistreur : garde les sessions, ne touche pas à une base. */
function recording(store: ModelStore): TimerRecording & { saved: StudySession[] } {
  const saved: StudySession[] = [];
  return {
    store,
    saved,
    async save(instance) { saved.push(instance as StudySession); },
    async remove() { /* les tests n'annulent pas ici */ },
  };
}

/** Un cours avec deux séries d'un exercice chacune, pour les cibles. */
function seededStore(): ModelStore {
  const store = new ModelStore();
  const course = new Course({ code: "CS-250", name: "Algorithms", credits: 6, colorHex: "#4F46E5" });
  store.insert(course);
  const first = new ExerciseSeries({ course, seriesNumber: 1 });
  const second = new ExerciseSeries({ course, seriesNumber: 2 });
  store.insert(first);
  store.insert(second);
  store.insert(new Exercise({ series: first, exerciseNumber: "1.1" }));
  store.insert(new Exercise({ series: second, exerciseNumber: "2.1" }));
  return store;
}

const hourAfter = (state: FocusTimerState, at: Date) =>
  new Date(state.studyUntil!.getTime() - at.getTime()).getTime() / 60_000;

describe("FocusTimerController — le chrono partagé", () => {
  it("démarrer ouvre une session sur le brouillon, qui survit dans le magasin", () => {
    const storage = memoryStore();
    const at = new Date("2026-11-01T10:00:00Z");
    const timer = controller(at, storage);
    const model = seededStore();
    const [first] = model.fetch(ExerciseSeries);
    const exercise = model.fetch(Exercise).find((e) => e.series === first)!;
    timer.retarget(model.fetch(Course)[0].id, "exercise", exercise.id);
    timer.start();

    expect(timer.snapshot().state?.runningSince).toEqual(at);
    expect(timer.snapshot().state?.targetID).toBe(exercise.id);
    expect(FocusTimerStore.load(storage)?.targetID).toBe(exercise.id);
  });

  it("terminer enregistre une session par cible, dans l'ordre de passage", async () => {
    const model = seededStore();
    const course = model.fetch(Course)[0];
    const [first, second] = model.fetch(ExerciseSeries);
    const one = model.fetch(Exercise).find((e) => e.series === first)!;
    const two = model.fetch(Exercise).find((e) => e.series === second)!;
    const rec = recording(model);

    const start = new Date("2026-11-01T10:00:00Z");
    const timer = controller(start);
    timer.attach(rec);
    timer.retarget(course.id, "exercise", one.id);
    timer.start();
    const mid = new Date("2026-11-01T10:20:00Z");
    (timer as unknown as { now: () => Date }).now = () => mid;
    timer.retarget(course.id, "exercise", two.id);
    const end = new Date("2026-11-01T10:50:00Z");
    (timer as unknown as { now: () => Date }).now = () => end;
    await timer.finish();

    expect(rec.saved.length).toBe(2);
    expect(rec.saved[0].exercise).toBe(one);
    expect(rec.saved[0].durationSeconds).toBe(20 * 60);
    expect(rec.saved[1].exercise).toBe(two);
    expect(rec.saved[1].durationSeconds).toBe(30 * 60);
    expect(timer.snapshot().state).toBeNull();
    expect(timer.snapshot().recap?.totalSeconds).toBe(50 * 60);
  });

  it("une session trop ancienne n'est pas reprise : elle est enregistrée bornée", async () => {
    const model = seededStore();
    const course = model.fetch(Course)[0];
    const exercise = model.fetch(Exercise)[0];
    const stale: FocusTimerState = {
      accumulated: 30 * 3600,
      sessionStartedAt: new Date("2026-10-30T08:00:00Z"),
      courseID: course.id,
      taskTypeRaw: "exercise",
      targetID: exercise.id,
      note: "",
      contextLabel: "",
      pomodoro: false,
    };
    const storage = memoryStore({ [FocusTimerStore.key]: encodeFocusTimerState(stale) });
    const now = new Date("2026-11-01T10:00:00Z");
    const timer = controller(now, storage);
    const rec = recording(model);
    timer.attach(rec);

    expect(timer.snapshot().state).toBeNull(); // pas reprise
    expect(rec.saved.length).toBe(1);
    expect(rec.saved[0].durationSeconds).toBe(18 * 3600); // bornée (maxRestorableAge)
    expect(rec.saved[0].note).toContain("resté ouvert");
    expect(FocusTimerStore.load(storage)).toBeNull(); // le magasin est vidé
  });
});

describe("FocusTimerController — mode étude (TimerEngine.enterStudy)", () => {
  it("entre : démarre la session si besoin, jusqu'à l'heure donnée", () => {
    const at = new Date("2026-11-01T10:00:00Z");
    const timer = controller(at);
    const model = seededStore();
    timer.attach(recording(model));
    timer.enterStudy(50, { courseID: model.fetch(Course)[0].id, taskType: "exercise" });

    const state = timer.snapshot().state!;
    expect(state.runningSince).toEqual(at); // la session tourne
    expect(hourAfter(state, at)).toBe(50);
    expect(StudyMode.isActive(state, at)).toBe(true);
  });

  it("entre sans fin : pas d'heure de fin, l'anneau fait le tour d'une heure", () => {
    const at = new Date("2026-11-01T10:00:00Z");
    const timer = controller(at);
    timer.enterStudy(null, { taskType: "theory" });

    const state = timer.snapshot().state!;
    expect(StudyMode.isOpenEnded(state)).toBe(true);
    expect(StudyMode.locks(state, at)).toBe(false); // sans fin : pas de verrou
  });

  it("une session ouverte reste la sienne ; entrer la verrouille seulement", () => {
    const start = new Date("2026-11-01T10:00:00Z");
    const timer = controller(start);
    const model = seededStore();
    timer.attach(recording(model));
    timer.start();
    const later = new Date("2026-11-01T10:10:00Z");
    (timer as unknown as { now: () => Date }).now = () => later;
    timer.enterStudy(25, { taskType: "exercise" });

    const state = timer.snapshot().state!;
    expect(state.sessionStartedAt).toEqual(start); // la même session
    expect(StudyMode.remaining(state, later)).toBeCloseTo(25 * 60, 0);
    expect(StudyMode.locks(state, later)).toBe(true); // verrouillée
  });

  it("prolonger après l'échéance repart d'un anneau vide", () => {
    const at = new Date("2026-11-01T11:00:00Z"); // l'heure de fin est passée
    const timer = controller(new Date("2026-11-01T10:00:00Z"));
    const model = seededStore();
    timer.attach(recording(model));
    timer.enterStudy(50, { taskType: "exercise" });
    (timer as unknown as { now: () => Date }).now = () => at;
    timer.extendStudy(25);

    const state = timer.snapshot().state!;
    expect(state.studySince).toEqual(at); // l'anneau repart
    expect(StudyMode.remaining(state, at)).toBeCloseTo(25 * 60, 0);
  });

  it("sous verrou : terminer et abandonner sont refusés ; l'urgence passe", async () => {
    const start = new Date("2026-11-01T10:00:00Z");
    const timer = controller(start);
    const model = seededStore();
    const rec = recording(model);
    timer.attach(rec);
    timer.enterStudy(50, { courseID: model.fetch(Course)[0].id, taskType: "exercise", locks: true });
    const later = new Date("2026-11-01T10:30:00Z");
    (timer as unknown as { now: () => Date }).now = () => later;

    await timer.finish();
    timer.discard();
    expect(timer.snapshot().state).not.toBeNull(); // le verrou a tenu

    await timer.finish({ emergency: true });
    expect(timer.snapshot().state).toBeNull();
    expect(rec.saved[0].note).toContain("Sortie d'urgence");
  });

  it("sortir garde la session en marche (leaveStudy), pas l'inverse", () => {
    const at = new Date("2026-11-01T10:00:00Z");
    const timer = controller(at);
    timer.enterStudy(50, { taskType: "exercise", locks: false });
    const state = timer.snapshot().state!;
    expect(state.studyUntil).toBeDefined();

    timer.leaveStudy();
    const after = timer.snapshot().state!;
    expect(after.studyUntil).toBeUndefined(); // le mode étude est levé…
    expect(after.runningSince).toBeDefined(); // …la session continue
  });
});
