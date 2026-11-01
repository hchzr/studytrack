// Les morceaux purs de l'écran du mode étude : les formats de l'écran de
// lancement (durées, heure de fin), la ligne d'horloge d'un cours (la pause
// de l'EPFL comprise) et l'adresse d'un corrigé.

import { describe, expect, it } from "vitest";
import { ExerciseSeries } from "../../src/models/exercise.ts";
import type { FocusContextSlot } from "../../src/domain/deskMoment.ts";
import { durationChipLabel, endLabel, lecturePhaseLabel, seriesName, solutionAddress } from "../../src/ui/studymode/helpers.ts";

/** Un créneau de l'horaire, pour l'horloge du cours. */
function slot(start: string, end: string, kind: "lecture" | "exerciseSession" = "lecture"): FocusContextSlot {
  return {
    courseID: "c1",
    courseCode: "MATH-101",
    kind,
    start: new Date(start),
    end: new Date(end),
  };
}

/** Une série, avec les adresses qu'on veut tester. */
function series(with_: Partial<Pick<ExerciseSeries, "solutionURLString" | "urlString" | "solutionsAt">>): ExerciseSeries {
  const entry = new ExerciseSeries({ seriesNumber: 3 });
  Object.assign(entry, with_);
  return entry;
}

describe("durationChipLabel — la pastille d'une durée proposée", () => {
  it("« 25 min », « 50 min » en dessous de l'heure", () => {
    expect(durationChipLabel(25)).toBe("25 min");
    expect(durationChipLabel(50)).toBe("50 min");
  });

  it("« 1 h 30 », « 2 h » au-dessus", () => {
    expect(durationChipLabel(60)).toBe("1 h");
    expect(durationChipLabel(90)).toBe("1 h 30");
    expect(durationChipLabel(120)).toBe("2 h");
  });
});

describe("endLabel — ce que l'écran dit de la fin", () => {
  it("l'heure de fin qui en résulte", () => {
    const now = new Date("2026-11-01T16:10:00");
    expect(endLabel(50, false, now)).toBe("jusqu'à 17:00");
  });

  it("sans heure de fin, dit sans heure de fin", () => {
    expect(endLabel(50, true, new Date())).toBe("sans heure de fin");
  });
});

describe("lecturePhaseLabel — l'horloge du cours", () => {
  it("pas encore commencé : dans combien de minutes", () => {
    expect(lecturePhaseLabel(slot("2026-11-01T10:00:00", "2026-11-01T12:00:00"), new Date("2026-11-01T09:45:00")))
      .toBe("Commence dans 15 min");
  });

  it("en cours : ce qui reste, la pause annoncée à l'heure de l'EPFL", () => {
    const klass = slot("2026-11-01T08:00:00", "2026-11-01T10:00:00");
    expect(lecturePhaseLabel(klass, new Date("2026-11-01T08:10:00")))
      .toBe("Encore 110 min · pause à 08:45");
    expect(lecturePhaseLabel(klass, new Date("2026-11-01T09:10:00")))
      .toBe("Encore 50 min");
  });

  it("la pause des 45 minutes : la reprise dans quelques minutes", () => {
    expect(lecturePhaseLabel(slot("2026-11-01T08:00:00", "2026-11-01T10:00:00"), new Date("2026-11-01T08:50:00")))
      .toBe("Pause · reprise dans 10 min");
  });

  it("fini", () => {
    expect(lecturePhaseLabel(slot("2026-11-01T08:00:00", "2026-11-01T10:00:00"), new Date("2026-11-01T10:01:00")))
      .toBe("Le cours est fini");
  });
});

describe("solutionAddress — le corrigé, une fois publié", () => {
  it("vide : rien", () => {
    expect(solutionAddress(series({ solutionURLString: "" }), new Date())).toBeNull();
  });

  it("une page du site (lue en natif), pas un PDF : rien", () => {
    expect(solutionAddress(series({
      solutionURLString: "https://botafogo.epfl.ch/?cours=series/AN_serie_03",
      urlString: "https://moodle.epfl.ch/s3",
    }), new Date())).toBeNull();
  });

  it("l'adresse de l'énoncé : ce n'est pas un corrigé", () => {
    expect(solutionAddress(series({
      solutionURLString: "https://moodle.epfl.ch/s3.pdf",
      urlString: "https://moodle.epfl.ch/s3.pdf",
    }), new Date())).toBeNull();
  });

  it("pas encore publié : rien ; publié : l'adresse", () => {
    const entry = series({
      solutionURLString: "https://moodle.epfl.ch/s3_corrige.pdf",
      urlString: "https://moodle.epfl.ch/s3.pdf",
      solutionsAt: new Date("2026-11-02T08:00:00"),
    });
    expect(solutionAddress(entry, new Date("2026-11-01T20:00:00"))).toBeNull();
    expect(solutionAddress(entry, new Date("2026-11-02T09:00:00"))).toBe("https://moodle.epfl.ch/s3_corrige.pdf");
  });

  it("sans date de publication : l'adresse", () => {
    expect(solutionAddress(series({
      solutionURLString: "https://moodle.epfl.ch/s3_corrige.pdf",
      urlString: "https://moodle.epfl.ch/s3.pdf",
      solutionsAt: null,
    }), new Date())).toBe("https://moodle.epfl.ch/s3_corrige.pdf");
  });
});

describe("seriesName — le nom d'une série", () => {
  it("son titre, sinon « Série N »", () => {
    expect(seriesName(new ExerciseSeries({ seriesNumber: 3, title: "" }))).toBe("Série 3");
    expect(seriesName(new ExerciseSeries({ seriesNumber: 3, title: "Intégration" }))).toBe("Intégration");
  });
});
