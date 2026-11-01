import { describe, expect, it } from "vitest";
import { DeskSchedule, kindLabelOf } from "../../src/domain/deskSchedule.ts";
import { Course, Exam, LinkedCalendarEvent, ModelStore } from "../../src/models/index.ts";

const now = new Date("2026-11-04T10:30:00"); // un mercredi, heure de Zurich

function day(hours: number, minutes = 0): Date {
  return new Date(2026, 10, 4, hours, minutes, 0, 0);
}

function fixtures(): { events: LinkedCalendarEvent[]; course: Course; autre: Course } {
  const course = new Course({ code: "MATH-101", name: "Analyse I", colorHex: "#B33939" });
  const autre = new Course({ code: "CS-250", name: "Algorithms", colorHex: "#4F46E5" });
  /** Un créneau relié à son cours (la relation se pose après le constructeur). */
  const slot = (init: { title: string; startsAt: Date; endsAt: Date; location: string; kind: string }, of: Course, skipped = false) => {
    const event = new LinkedCalendarEvent(init);
    event.course = of;
    event.isSkipped = skipped;
    return event;
  };
  const events = [
    slot({ title: "Cours d'analyse", startsAt: day(8, 30), endsAt: day(10, 15), location: "CO1", kind: "lecture" }, course),
    slot({ title: "Cours d'algo", startsAt: day(13, 0), endsAt: day(15, 0), location: "BC01", kind: "lecture" }, autre),
    // Un créneau manqué : pas au bureau.
    slot({ title: "Séance ratée", startsAt: day(16, 0), endsAt: day(17, 0), location: "", kind: "exerciseSession" }, course, true),
  ];
  return { events, course, autre };
}

describe("DeskSchedule — l'horaire du jour pour le bureau", () => {
  it("les créneaux du jour, triés, des cours suivis seulement", () => {
    const { events } = fixtures();
    const classes = DeskSchedule.today(events, now);
    expect(classes.length).toBe(2); // le créneau manqué n'y est pas
    expect(classes[0].title).toBe("Analyse I");
    expect(classes[0].location).toBe("CO1");
    expect(classes[0].slot.courseCode).toBe("MATH-101");
    expect(classes[1].slot.start.getTime()).toBe(day(13).getTime());
    expect(kindLabelOf(classes[0].slot)).toBe("Cours");
  });

  it("current : le cours en cours ; next : le prochain du jour", () => {
    const { events } = fixtures();
    const classes = DeskSchedule.today(events, now);
    expect(DeskSchedule.current(classes, day(9))?.title).toBe("Analyse I"); // en cours 8:30→10:15
    expect(DeskSchedule.current(classes, day(10, 30))).toBeNull(); // fini, le suivant est loin
    expect(DeskSchedule.next(classes, now)?.title).toBe("Algorithms");
    expect(DeskSchedule.next(classes, day(20))).toBeNull(); // plus rien
  });

  it("latest : le créneau commencé le plus récemment de ce cours", () => {
    const { events, course } = fixtures();
    const classes = DeskSchedule.today(events, now);
    const at = day(11);
    expect(DeskSchedule.latest(course.id, classes, at)?.slot.courseCode).toBe("MATH-101");
    expect(DeskSchedule.latest("inconnu", classes, at)).toBeNull();
  });

  it("moment : la forme du bureau selon le travail et l'examen qui approche", () => {
    const { course } = fixtures();
    expect(DeskSchedule.moment("exercise", false, course)).toBe("series");
    expect(DeskSchedule.moment("lecture", false, course)).toBe("lecture");
    expect(DeskSchedule.moment("exercise", true, course)).toBe("together");

    // Un examen dans la semaine : la théorie devient de la révision.
    // `nextSitting` lit l'horloge réelle ; le test règle l'examen à demain.
    const exam = new Exam({ course, kind: "exam", title: "Mi-session", date: new Date(Date.now() + 7 * 24 * 3600 * 1000) });
    const store = new ModelStore();
    store.insert(course);
    store.insert(exam);
    expect(course.nextSitting?.id).toBe(exam.id);
    expect(DeskSchedule.moment("theory", false, course)).toBe("revision");
  });
});
