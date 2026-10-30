// Port de la section « Bureau : la forme du moment » de Validation/main.swift.
// Un `it` par check Swift, le libellé du check pour nom.
import { describe, expect, it } from "vitest";

import {
  DeskMoment, LectureClock, LectureMark, LectureMarks, RevisionFocus,
  type FocusContextSlot,
} from "../../src/domain/deskMoment.ts";

const uuid = () => globalThis.crypto.randomUUID();
const at = (d: Date, seconds: number) => new Date(d.getTime() + seconds * 1000);

describe("Bureau : la forme du moment", () => {
  it("bureau : en cours", () => {
    expect(DeskMoment.resolve("lecture", false, null)).toBe("lecture");
  });
  it("bureau : le groupe d'abord", () => {
    expect(DeskMoment.resolve("lecture", true, 3)).toBe("together");
  });
  it("bureau : examen proche → révision", () => {
    expect(DeskMoment.resolve("theory", false, 5)).toBe("revision");
  });
  it("bureau : une série reste une série", () => {
    expect(DeskMoment.resolve("exercise", false, 5)).toBe("series");
  });
  it("bureau : examen loin → séries", () => {
    expect(DeskMoment.resolve("theory", false, 30)).toBe("series");
  });
  it("bureau : vidéo = théorie", () => {
    expect(DeskMoment.resolve("video", false, 2)).toBe("revision");
  });

  const course = uuid();
  const now = new Date();
  const day = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 8, 15, 0);
  const lecture: FocusContextSlot = { courseID: course, courseCode: "MATH-101", kind: "lecture", start: day, end: at(day, 105 * 60) };
  const later: FocusContextSlot = {
    courseID: uuid(), courseCode: "CS-107", kind: "exerciseSession", start: at(day, 3 * 3600), end: at(day, 5 * 3600),
  };

  it("horloge : dix minutes avant, le cours", () => {
    expect(LectureClock.current(at(day, -5 * 60), [lecture, later])?.courseID).toBe(course);
  });
  it("horloge : trop tôt", () => {
    expect(LectureClock.current(at(day, -20 * 60), [lecture])).toBeNull();
  });
  it("horloge : la suite", () => {
    expect(LectureClock.next(at(day, 60), [lecture, later])?.courseCode).toBe("CS-107");
  });
  it("horloge : la pause à +45", () => {
    expect(LectureClock.phase(lecture, at(day, 50 * 60))).toEqual({ kind: "pause", untilMinutes: 10 });
  });
  it("horloge : en cours", () => {
    expect(LectureClock.phase(lecture, at(day, 20 * 60))).toEqual({ kind: "running" });
  });
  it("horloge : avant", () => {
    expect(LectureClock.phase(lecture, at(day, -3 * 60))).toEqual({ kind: "before", minutes: 3 });
  });
  it("horloge : fini", () => {
    expect(LectureClock.phase(lecture, at(day, 2 * 3600))).toEqual({ kind: "over" });
  });
  it("horloge : 45 min sans pause", () => {
    expect(LectureClock.breakWindow({ courseID: course, courseCode: "X", kind: "lecture", start: day, end: at(day, 45 * 60) })).toBeNull();
  });
  it("horloge : le mode étude tient jusqu'à la fin", () => {
    expect(LectureClock.studyMinutes(lecture, day)).toBe(105);
  });
  it("horloge : à mi-chemin", () => {
    expect(Math.abs(LectureClock.progress(lecture, at(day, 52.5 * 60)) - 0.5)).toBeLessThan(0.001);
  });

  const first = LectureMark.make(course, day, at(day, 754));
  it("repère : 12:34", () => {
    expect(LectureMark.offsetLabel(first)).toBe("12:34");
  });
  it("repère : plus d'une heure", () => {
    expect(LectureMark.offsetLabel(LectureMark.make(course, day, at(day, 3723)))).toBe("1:02:03");
  });
  const single = LectureMarks.adding(LectureMark.make(course, day, at(day, 760)), LectureMarks.adding(first, [], day), day);
  it("repère : deux touchers rapprochés n'en font qu'un", () => {
    expect(single.length).toBe(1);
  });
  const marks = LectureMarks.adding(LectureMark.make(course, day, at(day, 1500)), single, day);
  it("repère : ceux du cours", () => {
    expect(LectureMarks.of(course, day, marks).length).toBe(2);
  });
  it("repère : un créneau", () => {
    expect(LectureMarks.classes(course, marks).length).toBe(1);
  });
  it("repère : un mois au plus", () => {
    const stale = LectureMark.make(course, at(day, -40 * 86_400), at(day, -40 * 86_400));
    expect(LectureMarks.adding(first, [stale], day).length).toBe(1);
  });
  it("repère : aller-retour", () => {
    expect(LectureMarks.decode(LectureMarks.encode(marks))).toEqual(marks);
  });

  const video = new URL("https://mediaspace.epfl.ch/media/1_abc");
  it("repère : MediaSpace à la minute", () => {
    expect(LectureMarks.seekURL(video, 754).href).toBe("https://mediaspace.epfl.ch/media/1_abc?st=754");
  });
  it("repère : YouTube", () => {
    expect(LectureMarks.seekURL(new URL("https://www.youtube.com/watch?v=x"), 60).href.endsWith("t=60")).toBe(true);
  });
  it("repère : relu", () => {
    expect(LectureMarks.startOffset("https://mediaspace.epfl.ch/media/1_abc?st=754")).toBe(754);
  });
  it("repère : fragment relu", () => {
    expect(LectureMarks.startOffset("https://x.ch/v.mp4#t=30")).toBe(30);
  });

  it("révision : jamais faites, puis rouges, les sues en dernier", () => {
    const [a, b, c, d] = [uuid(), uuid(), uuid(), uuid()];
    const order = RevisionFocus.pastExamOrder([
      { id: a, year: 2022, worked: true, confidence: "green" },
      { id: b, year: 2023, worked: false, confidence: null },
      { id: c, year: 2021, worked: true, confidence: "red" },
      { id: d, year: 2024, worked: false, confidence: null },
    ]);
    expect(order).toEqual([d, b, c, a]);
  });
});
