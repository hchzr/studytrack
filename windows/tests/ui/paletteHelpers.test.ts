import { describe, expect, it } from "vitest";
import { matches, moveSelection, resolveHit, sortBySection, startsSection, type ResolvableCourse } from "../../src/ui/palette/paletteHelpers.ts";

const course: ResolvableCourse = {
  id: "c1",
  series: [{ id: "s1", sortedExercises: [{ id: "e1" }, { id: "e2" }] }, { id: "s2", sortedExercises: [] }],
  allExercises: [{ id: "e1" }, { id: "e2" }],
  theoryItems: [{ id: "t1" }],
  exams: [{ id: "x1" }],
};
const hit = (kind: string, id: string) => ({ kind, document: { id } }) as never;

describe("palette", () => {
  it("résout un résultat vers le cours et l'élément", () => {
    expect(resolveHit([course], hit("course", "course.c1"))).toMatchObject({ course: "c1", item: null });
    expect(resolveHit([course], hit("series", "series.s1"))).toMatchObject({ course: "c1", item: "e1" });
    expect(resolveHit([course], hit("series", "series.s2"))).toMatchObject({ course: "c1", item: null });
    expect(resolveHit([course], hit("exercise", "exercise.e2"))).toMatchObject({ item: "e2", type: "exercise" });
    expect(resolveHit([course], hit("theory", "theory.t1"))).toMatchObject({ item: "t1", type: "theory" });
    expect(resolveHit([course], hit("exam", "exam.x1"))).toMatchObject({ course: "c1", item: null });
    expect(resolveHit([course], hit("exercise", "exercise.zz"))).toBeNull();
    expect(resolveHit([course], hit("task", "task.a"))).toBeNull();
  });

  it("ignore accents et casse", () => {
    expect(matches("Démarrer le chrono", "demarrer")).toBe(true);
    expect(matches("Agenda", "bilan")).toBe(false);
  });

  it("déplace la sélection en boucle", () => {
    expect(moveSelection(0, -1, 3)).toBe(2);
    expect(moveSelection(2, 1, 3)).toBe(0);
    expect(moveSelection(0, 1, 0)).toBe(0);
  });

  it("range par section sans bouger l'ordre interne", () => {
    const sorted = sortBySection([
      { section: "Séries", id: 1 }, { section: "Cours", id: 2 }, { section: "Séries", id: 3 },
    ]);
    expect(sorted.map((i) => i.id)).toEqual([2, 1, 3]);
    expect(startsSection(sorted, 0)).toBe(true);
    expect(startsSection(sorted, 1)).toBe(true);
    expect(startsSection(sorted, 2)).toBe(false);
  });
});
