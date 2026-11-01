import { beforeEach, describe, expect, it } from "vitest";
import { LocalStore } from "../../src/sync/store.ts";
import { Repository, toColumns, tableFor } from "../../src/data/repository.ts";
import { buildStore } from "../../src/data/hydrate.ts";
import { Course, Exercise, ExerciseSeries, StudySession, SubQuestion } from "../../src/models/index.ts";
import { memoryDb } from "./helpers.ts";

async function seeded() {
  const local = new LocalStore(memoryDb());
  await local.migrate();
  await local.write("sync_courses", { id: "c1", name: "Analyse I", code: "MATH-101", credits: 8, is_active: 1 });
  await local.write("sync_exercise_series", { id: "s1", course_id: "c1", series_number: 3, title: "Série 3" });
  await local.write("sync_exercises", { id: "e1", series_id: "s1", exercise_number: "1.1", is_bonus: 0 });
  await local.write("sync_sub_questions", { id: "q1", exercise_id: "e1", label: "a)" });
  await local.write("sync_study_sessions", { id: "ss1", course_id: "c1", exercise_id: "e1", duration_seconds: 600 });
  return local;
}

describe("pont base ↔ modèle", () => {
  let local: LocalStore;
  beforeEach(async () => { local = await seeded(); });

  it("reconstruit le graphe : relations et inverses", async () => {
    const store = await buildStore(local);
    const course = store.fetch(Course)[0];
    expect(course.name).toBe("Analyse I");
    expect(course.credits).toBe(8);
    expect(course.isActive).toBe(true);

    const series = store.fetch(ExerciseSeries)[0];
    expect(series.seriesNumber).toBe(3);
    expect(series.course).toBe(course); // référence « un »
    expect(course.series).toContain(series); // inverse entretenu

    const ex = store.fetch(Exercise)[0];
    expect(ex.exerciseNumber).toBe("1.1");
    expect(ex.isBonus).toBe(false);
    expect(ex.series).toBe(series);
    expect(series.exercises).toContain(ex);

    const sub = store.fetch(SubQuestion)[0];
    expect(sub.exercise).toBe(ex);
    expect(ex.subQuestions).toContain(sub);

    const ss = store.fetch(StudySession)[0];
    expect(ss.durationSeconds).toBe(600);
    expect(ss.course).toBe(course);
    expect(ss.exercise).toBe(ex);
    expect(course.sessions).toContain(ss);
    expect(ex.targetedSessions).toContain(ss);
  });

  it("les dates et les optionnels sont décodés", async () => {
    await local.write("sync_exercises", { id: "e1", series_id: "s1", exercise_number: "1.1", done_at: "2026-10-30T09:00:00.000Z" });
    const ex = (await buildStore(local)).fetch(Exercise)[0];
    expect(ex.doneAt).toBeInstanceOf(Date);
    expect((ex.doneAt as Date).toISOString()).toBe("2026-10-30T09:00:00.000Z");
    expect(ex.correctedAt).toBeNull();
  });

  it("toColumns resérialise un objet en colonnes", () => {
    const course = new Course({ code: "PHYS-101", name: "Physique", credits: 5 });
    const cols = toColumns(tableFor(course), course as unknown as Record<string, unknown>);
    expect(cols.id).toBe(course.id);
    expect(cols.code).toBe("PHYS-101");
    expect(cols.credits).toBe(5);
    expect(cols.is_active).toBe(0); // bool → 0/1
    expect(cols.term_id).toBeNull();
  });

  it("save écrit la modification et la marque à envoyer ; reload la relit", async () => {
    const repo = new Repository(local);
    const store = await repo.load();
    const course = store.fetch(Course)[0];
    course.name = "Analyse I — modifié";
    await repo.save(course);

    const rows = await local.db.select<{ name: string; dirty: number }>("SELECT name, dirty FROM sync_courses WHERE id = 'c1'");
    expect(rows[0].name).toBe("Analyse I — modifié");
    expect(rows[0].dirty).toBe(1);

    const reloaded = (await repo.load()).fetch(Course)[0];
    expect(reloaded.name).toBe("Analyse I — modifié");
  });

  it("créer un objet : l'ajouter à la base le fait apparaître après reload", async () => {
    const repo = new Repository(local);
    const store = await repo.load();
    const course = store.fetch(Course)[0];
    const ex = new Exercise({ series: store.fetch(ExerciseSeries)[0], exerciseNumber: "2.1" });
    await repo.save(ex);
    void course;

    const reloaded = await repo.load();
    const numbers = reloaded.fetch(Exercise).map((e) => e.exerciseNumber).sort();
    expect(numbers).toEqual(["1.1", "2.1"]);
    expect(reloaded.fetch(Exercise).find((e) => e.exerciseNumber === "2.1")!.series).toBe(reloaded.fetch(ExerciseSeries)[0]);
  });

  it("remove : cascade sur les enfants, mise à nul ailleurs, graphe et base cohérents", async () => {
    const repo = new Repository(local);
    const store = await repo.load();
    const series = store.fetch(ExerciseSeries)[0];
    await repo.remove(series);

    // En mémoire : série et exercice partis, session gardée sans exercice.
    expect(store.fetch(ExerciseSeries)).toEqual([]);
    expect(store.fetch(Exercise)).toEqual([]);
    expect(store.fetch(StudySession)[0].exercise).toBeNull();

    // Après reload (relu depuis la base) : même résultat.
    const reloaded = await repo.load();
    expect(reloaded.fetch(ExerciseSeries)).toEqual([]);
    expect(reloaded.fetch(Exercise)).toEqual([]);
    expect(reloaded.fetch(SubQuestion)).toEqual([]);
    const ss = reloaded.fetch(StudySession)[0];
    expect(ss).toBeTruthy();
    expect(ss.exercise).toBeNull();
    expect(ss.course).toBe(reloaded.fetch(Course)[0]);
  });
});
