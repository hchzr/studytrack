import { describe, expect, it } from "vitest";
import { pickSource } from "../../src/data/appSource.ts";
import { MemoryDataSource, SqliteSource } from "../../src/data/source.ts";
import { Course, StudySession } from "../../src/models/index.ts";
import { memoryDb } from "./helpers.ts";

describe("SqliteSource — la source de l'app au-dessus de la base", () => {
  it("le premier load crée les tables ; la base jeune est vide", async () => {
    const store = await new SqliteSource(memoryDb()).load();
    expect(store.fetch(Course)).toEqual([]);
  });

  it("si demandé, le premier lancement est amorcé une fois", async () => {
    const db = memoryDb();
    const store = await new SqliteSource(db, true).load();
    expect(store.fetch(Course).length).toBeGreaterThan(0);
    expect(store.fetch(StudySession).length).toBeGreaterThan(0);

    // Un lanceur suivant, réglé pareil, ne ré-amorce pas : mêmes cours, pas
    // de doublon.
    const again = await new SqliteSource(db, true).load();
    expect(again.fetch(Course).length).toBe(store.fetch(Course).length);
  });

  it("enregistrer traverse la base et resurgit au rechargement", async () => {
    const db = memoryDb();
    const source = new SqliteSource(db, true);
    const store = await source.load();
    const course = store.fetch(Course)[0];
    course.name = "Analysé";
    await source.save(course);

    // Une autre instance, comme le prochain lancement de l'app.
    const again = await new SqliteSource(db).load();
    expect(again.fetch(Course).find((c) => c.id === course.id)!.name).toBe("Analysé");
  });

  it("supprimer part de la base ; les enfants en cascade avec le cours", async () => {
    const db = memoryDb();
    const source = new SqliteSource(db, true);
    const store = await source.load();
    const course = store.fetch(Course).find((c) =>
      store.fetch(StudySession).some((s) => s.course === c))!;
    const duCours = store.fetch(StudySession).filter((s) => s.course === course).length;
    const total = store.fetch(StudySession).length;
    expect(duCours).toBeGreaterThan(0);
    await source.remove(course);

    const again = await new SqliteSource(db).load();
    expect(again.fetch(Course).find((c) => c.id === course.id)).toBeUndefined();
    expect(again.fetch(StudySession).length).toBe(total - duCours);
  });
});

describe("appSource — quelle source ce lancement ouvre", () => {
  it("par défaut : SQLite dans Tauri, mémoire dans le navigateur", () => {
    expect(pickSource(true, new URLSearchParams(""))).toBeInstanceOf(SqliteSource);
    expect(pickSource(false, new URLSearchParams(""))).toBeInstanceOf(MemoryDataSource);
  });

  it("?source= impose sa source, quand le runtime le permet", () => {
    expect(pickSource(true, new URLSearchParams("source=memory"))).toBeInstanceOf(MemoryDataSource);
    expect(pickSource(false, new URLSearchParams("source=sqlite"))).toBeInstanceOf(MemoryDataSource);
  });
});
