import { describe, expect, it } from "vitest";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Course, LinkedCalendarEvent, PlannedSession } from "../../../models/index.ts";
import type { Deadline } from "../../../domain/deadline.ts";
import {
  assignLanes,
  buildWeekEntries, deadlineGlyph, entryLayout, entryColor, fallbackWeekNumber, visibleWeekDays, weekDays, weekLabel,
  weekNumberFor, withAlpha,
} from "./weekModel.ts";

const course = new Course({ code: "CS-250", name: "Algorithms I", colorHex: "#4F46E5" });

const event = (overrides: {
  title: string;
  startsAt: Date;
  endsAt: Date;
  kind?: "lecture" | "exerciseSession" | "personal";
  course?: Course | null;
}) => {
  const value = new LinkedCalendarEvent({
    title: overrides.title,
    startsAt: overrides.startsAt,
    endsAt: overrides.endsAt,
    kind: overrides.kind ?? "lecture",
  });
  value.course = overrides.course === undefined ? course : overrides.course;
  return value;
};

// Lundi 15 septembre 2025.
const monday = new Date(2025, 8, 15, 0, 0);

describe("buildWeekEntries", () => {
  it("garde les cours académiques et les sessions de la semaine", () => {
    const lecture = event({
      title: "Cours", startsAt: new Date(2025, 8, 15, 8, 15), endsAt: new Date(2025, 8, 15, 10, 0),
    });
    const personal = event({
      title: "Anniversaire", startsAt: new Date(2025, 8, 16, 12, 0), endsAt: new Date(2025, 8, 16, 13, 0),
      kind: "personal", course: null,
    });
    const session = new PlannedSession({
      course, title: "Révisions", startsAt: new Date(2025, 8, 17, 17, 0), durationMinutes: 90,
    });
    const outside = event({
      title: "Hors semaine", startsAt: new Date(2025, 8, 22, 8, 0), endsAt: new Date(2025, 8, 22, 9, 0),
    });

    const entries = buildWeekEntries(
      [lecture, personal, outside],
      [session],
      monday,
      new Date(2025, 8, 22),
    );

    expect(entries.map((entry) => entry.title)).toEqual(["Cours", "Révisions"]);
    expect(entries[1].kindLabel).toBe("Session d'étude");
  });

  it("écarte une entrée de plus de vingt heures (journée entière)", () => {
    const allDay = event({
      title: "Congé", startsAt: new Date(2025, 8, 15, 0, 0), endsAt: new Date(2025, 8, 16, 0, 0),
      kind: "lecture",
    });
    expect(buildWeekEntries([allDay], [], monday, new Date(2025, 8, 22))).toHaveLength(0);
  });

  it("trie par heure de début puis par titre", () => {
    const late = event({ title: "B", startsAt: new Date(2025, 8, 15, 14, 0), endsAt: new Date(2025, 8, 15, 15, 0) });
    const earlyB = event({ title: "B", startsAt: new Date(2025, 8, 15, 8, 0), endsAt: new Date(2025, 8, 15, 9, 0) });
    const earlyA = event({ title: "A", startsAt: new Date(2025, 8, 15, 8, 0), endsAt: new Date(2025, 8, 15, 9, 0) });

    const entries = buildWeekEntries([late, earlyB, earlyA], [], monday, new Date(2025, 8, 22));
    expect(entries.map((entry) => entry.title)).toEqual(["A", "B", "B"]);
  });
});

describe("entryLayout", () => {
  it("place un cours de 8 h à 9 h en haut de la grille", () => {
    const [entry] = buildWeekEntries(
      [event({ title: "Cours", startsAt: new Date(2025, 8, 15, 8, 0), endsAt: new Date(2025, 8, 15, 9, 0) })],
      [],
      monday,
      new Date(2025, 8, 22),
    );
    expect(entryLayout(entry)).toEqual({ top: 0, height: 50 });
  });

  it(" borne à zéro un cours commencé avant 8 h", () => {
    const [entry] = buildWeekEntries(
      [event({ title: "Tôt", startsAt: new Date(2025, 8, 15, 7, 30), endsAt: new Date(2025, 8, 15, 8, 30) })],
      [],
      monday,
      new Date(2025, 8, 22),
    );
    expect(entryLayout(entry).top).toBe(0);
  });
});

describe("visibleWeekDays", () => {
  it("cache un week-end vide et le montre dès qu'une échéance y tombe", () => {
    const days = weekDays(monday);
    expect(days).toHaveLength(7);
    expect(visibleWeekDays(days, [], [])).toHaveLength(5);

    const deadline: Deadline = {
      id: "due:1", kind: "due", date: new Date(2025, 8, 20, 12, 0), title: "Série 1 à rendre",
      detail: "2 exercices à faire", courseID: course.id, courseCode: "CS-250", colorHex: course.colorHex,
    };
    const visible = visibleWeekDays(days, [], [deadline]);
    expect(visible).toHaveLength(6);
    expect(visible[5].getDay()).toBe(6);
  });
});

describe("weekNumberFor", () => {
  const term = { startDate: monday, endDate: new Date(2025, 11, 21), totalWeeks: 14 };

  it("numérote la semaine 1 au lundi de rentrée", () => {
    expect(weekNumberFor(monday, term)).toBe(1);
  });

  it("rend null hors semestre", () => {
    expect(weekNumberFor(new Date(2025, 7, 25), term)).toBeNull();
    expect(weekNumberFor(new Date(2026, 0, 5), term)).toBeNull();
    expect(weekNumberFor(monday, null)).toBeNull();
  });
});

describe("fallbackWeekNumber", () => {
  it("compte depuis la rentrée EPFL quand le cours n'a pas de semestre", () => {
    const now = new Date(2025, 9, 15);
    const start = DateUtils.startOfWeek(DateUtils.currentAutumnOrSpringStart(now).start);
    expect(fallbackWeekNumber(start, now)).toBe(1);
    expect(fallbackWeekNumber(DateUtils.addWeeks(-1, start), now)).toBeNull();
  });
});

describe("couleurs et libellés", () => {
  it("traduit une couleur de cours en fond translucide", () => {
    expect(withAlpha("#4F46E5", 0.16)).toBe("#4F46E529");
    expect(withAlpha("#abc", 1)).toBe("#aabbccff");
    expect(withAlpha("var(--wrong)", 0.5)).toBe("color-mix(in srgb, var(--wrong) 50%, transparent)");
  });

  it("retombe sur la teinte du type quand le cours manque", () => {
    const [entry] = buildWeekEntries(
      [event({ title: "Cours", startsAt: new Date(2025, 8, 15, 8, 0), endsAt: new Date(2025, 8, 15, 9, 0), course: null })],
      [],
      monday,
      new Date(2025, 8, 22),
    );
    expect(entryColor(entry)).toBe("var(--selection)");
  });

  it("donne le glyphe de chaque échéance", () => {
    expect(deadlineGlyph("exam")).toBe("◆");
    expect(deadlineGlyph("due")).toBe("↥");
    expect(deadlineGlyph("solutions")).toBe("✓");
  });

  it("écrit la plage de la semaine en français", () => {
    expect(weekLabel(monday)).toBe("Du 15 septembre au 21 septembre");
  });
});

describe("assignLanes", () => {
  const base = new Date(2026, 10, 2, 0, 0);
  const at = (hours: number) => new Date(base.getTime() + hours * 3_600_000);
  const span = (from: number, to: number) => ({ start: at(from), end: at(to) });

  it("met côte à côte ce qui se chevauche, le plus long d'abord", () => {
    const lanes = assignLanes([span(8, 10), span(9, 11), span(12, 13), span(8, 20), span(10, 12)]);
    expect(lanes[3]).toEqual({ lane: 0, lanes: 3 });
    expect(lanes[0]).toEqual({ lane: 1, lanes: 3 });
    expect(lanes[1]).toEqual({ lane: 2, lanes: 3 });
    expect(lanes[4].lane).toBe(1);
  });

  it("laisse pleine largeur ce qui se suit bout à bout", () => {
    expect(assignLanes([span(8, 9), span(9, 10)])).toEqual([{ lane: 0, lanes: 1 }, { lane: 0, lanes: 1 }]);
    expect(assignLanes([])).toEqual([]);
  });
});
