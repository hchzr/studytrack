// Port des sections de Validation/main.swift sur l'horaire iCalendar : code de cours dans
// un horaire, type de séance depuis CATEGORIES, durée iCalendar, ICSParser, import dans le
// graphe, le lieu ne détermine jamais le code, semestre rattaché, horaire amphi/exercices
// (TimetableClassifier) et réparation. Un `it` par check, le libellé du check pour nom.

import { describe, expect, it } from "vitest";
import { ModelStore } from "../../src/models/store.ts";
import { Course } from "../../src/models/course.ts";
import { LinkedCalendarEvent } from "../../src/models/linkedCalendarEvent.ts";
import { TimetableClassifier } from "../../src/domain/timetableClassifier.ts";
import { ICSParser } from "../../src/services/timetableImportService.ts";
import { TimetableImport, TimetableError } from "../../src/services/timetableImport.ts";
import { CalendarSync } from "../../src/services/calendarService.ts";
import { DateUtils } from "../../src/domain/dateUtils.ts";
import { fromWallTime } from "../../src/domain/zonedTime.ts";
import { AcademicCalendarService } from "../../src/services/academicCalendarService.ts";
import { AcademicTerm } from "../../src/models/academicTerm.ts";

const ZURICH = "Europe/Zurich";

describe("Code de cours dans un horaire iCal", () => {
  it("code lu dans l'intitulé", () => expect(TimetableImport.detectCourseCode("CS-250 Algorithms I")).toBe("CS-250"));
  it("un intitulé sans code n'en invente pas", () => expect(TimetableImport.detectCourseCode("Analyse I")).toBeNull());
  it("code lu dans une description de type « MATH-101 / Analyse I »", () =>
    expect(TimetableImport.detectCourseCode("MATH-101 / Analyse I")).toBe("MATH-101"));
  it("code lu dans le lieu, faute de mieux", () => expect(TimetableImport.detectCourseCode("Salle CS-250")).toBe("CS-250"));
  it("« CS-250 » est un code officiel", () => expect(TimetableImport.isOfficialCode("CS-250")).toBe(true));
  it("« MATH-101 » est un code officiel", () => expect(TimetableImport.isOfficialCode("MATH-101")).toBe(true));
  it("« ANALYSE » est un code fabriqué, pas un code officiel", () => expect(TimetableImport.isOfficialCode("ANALYSE")).toBe(false));
  it("un code fabriqué avec suffixe n'est pas officiel", () => expect(TimetableImport.isOfficialCode("PHYSIQ-2")).toBe(false));
  it("les accents ne séparent pas un cours de lui-même", () =>
    expect(TimetableImport.nameKey("Algèbre linéaire")).toBe(TimetableImport.nameKey("Algebre lineaire")));
  it("casse et espaces multiples ignorés", () => expect(TimetableImport.nameKey("Analyse I")).toBe(TimetableImport.nameKey("analyse  i")));
  it("deux cours différents restent distincts", () => expect(TimetableImport.nameKey("Analyse I")).not.toBe(TimetableImport.nameKey("Analyse II")));
  it("ponctuation ignorée", () => expect(TimetableImport.nameKey("Projet de semestre!")).toBe("projet de semestre"));
});

describe("Type de séance depuis CATEGORIES", () => {
  it("« Cours » reconnu malgré les valeurs vides", () => expect(ICSParser.isLectureCategory("Horaires enseignés FBM,,Cours,")).toBe(true));
  it("« Exercices » n'est pas un cours magistral", () => expect(ICSParser.isLectureCategory(",,Exercices,")).toBe(false));
  it("« Labo » n'est pas un cours magistral", () => expect(ICSParser.isLectureCategory(",,Labo,")).toBe(false));
  it("sans type de séance, on ne tranche pas", () => expect(ICSParser.isLectureCategory("Horaires enseignés FBM,,")).toBeNull());
  it("catégories vides → indécis", () => expect(ICSParser.isLectureCategory("")).toBeNull());
});

describe("Durée iCalendar (DURATION)", () => {
  it("PT105M = 105 min", () => expect(ICSParser.parseDuration("PT105M")).toBe(105 * 60));
  it("PT45M = 45 min", () => expect(ICSParser.parseDuration("PT45M")).toBe(45 * 60));
  it("PT1H30M = 90 min", () => expect(ICSParser.parseDuration("PT1H30M")).toBe(90 * 60));
  it("PT1H = 1 h", () => expect(ICSParser.parseDuration("PT1H")).toBe(3600));
  it("P1D = 1 jour", () => expect(ICSParser.parseDuration("P1D")).toBe(86_400));
  it("PT30S = 30 s", () => expect(ICSParser.parseDuration("PT30S")).toBe(30));
  it("une durée vide n'est pas une durée", () => expect(ICSParser.parseDuration("")).toBeNull());
  it("une durée nulle n'est pas retenue", () => expect(ICSParser.parseDuration("PT0M")).toBeNull());
  it("une date n'est pas une durée — le piège qui faisait tout tomber à 1 h", () =>
    expect(ICSParser.parseDuration("20260915T081500")).toBeNull());
});

const ics = `BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:cs250-cours
SUMMARY:CS-250 Algorithms I (cours)
DTSTART;TZID=Europe/Zurich:20250217T081500
DTEND;TZID=Europe/Zurich:20250217T100000
LOCATION:CM1 100
RRULE:FREQ=WEEKLY;COUNT=5;BYDAY=MO
END:VEVENT
END:VCALENDAR`;

describe("ICSParser (horaire EPFL)", () => {
  const events = ICSParser.parse(ics);
  it("5 occurrences hebdomadaires", () => expect(events).toHaveLength(5));
  it("intitulé conservé", () => expect(events.every((e) => e.summary.includes("CS-250"))).toBe(true));
  it("durée 1 h 45", () => expect(ICSParser.durationSeconds(events[0])).toBe(6300));
  it("occurrences ordonnées", () => expect(events[1].start.getTime()).toBeGreaterThan(events[0].start.getTime()));
  it("occurrences espacées de 7 jours", () => expect(DateUtils.daysBetween(events[0].start, events[1].start)).toBe(7));
  it("lieu conservé", () => expect(events[0].location).toBe("CM1 100"));
  it("l'heure murale de Zurich reste 08:15", () =>
    expect(events[0].start.getTime()).toBe(fromWallTime(2025, 2, 17, 8, 15, 0, ZURICH).getTime()));
  it("code détecté", () => expect(TimetableImport.detectCourseCode("CS-250 Algorithms I (cours)")).toBe("CS-250"));
  it("intitulé nettoyé", () => expect(TimetableImport.cleanedName("CS-250 Algorithms I (cours)", "CS-250")).toBe("Algorithms I"));
  it("code dérivé depuis le nom", () => expect(TimetableImport.derivedCode("Analyse I", ["ANALYSEI"])).toBe("ANALYSE"));
  it("code dérivé rendu unique", () => expect(TimetableImport.derivedCode("Analyse I", ["ANALYSE"])).toBe("ANALYSE-2"));
  it("une exception EXDATE retire l'occurrence", () => {
    const withExdate = ics.replace("END:VEVENT", "EXDATE;TZID=Europe/Zurich:20250224T081500\nEND:VEVENT");
    expect(ICSParser.parse(withExdate)).toHaveLength(4);
  });
  it("lignes repliées et échappées", () => {
    const folded = "BEGIN:VEVENT\nUID:a\nSUMMARY:Analyse\\, partie\n  2\nDTSTART:20250217T081500Z\nEND:VEVENT";
    expect(ICSParser.parse(folded)[0].summary).toBe("Analyse, partie 2");
    expect(ICSParser.parse(folded)[0].start.toISOString()).toBe("2025-02-17T08:15:00.000Z");
  });
});

function storeWithCS250(): { store: ModelStore; course: Course } {
  const store = new ModelStore();
  const course = new Course({ code: "CS-250", name: "Algorithms I" });
  store.insert(course);
  return { store, course };
}

describe("Import iCalendar dans le graphe", () => {
  const { store } = storeWithCS250();
  const first = TimetableImport.import(ics, store, "IN");
  it("CS-250 existant reconnu depuis l'horaire", () => expect(first.coursesMatched).toBe(1));
  it("aucun doublon de cours créé", () => expect(first.coursesCreated).toBe(0));
  it("5 séances créées", () => expect(first.eventsCreated).toBe(5));
  it("section IN appliquée au cours existant", () => expect(first.sectionApplied).toBe(1));
  it("le cours importé a bien des heures de cours", () => {
    const course = store.fetch(Course).find((c) => c.code === "CS-250")!;
    expect(course.hasLectures).toBe(true);
    expect(course.sectionCode).toBe("IN");
  });
  it("réimport idempotent", () => {
    const second = TimetableImport.import(ics, store, "IN");
    expect(second.eventsCreated).toBe(0);
    expect(second.eventsSkipped).toBe(5);
  });
  it("cours inconnu créé automatiquement, avec ses séances", () => {
    const unknown = `BEGIN:VCALENDAR
BEGIN:VEVENT
UID:unknown-1
SUMMARY:Analyse numérique
DTSTART;TZID=Europe/Zurich:20250218T101500
DTEND;TZID=Europe/Zurich:20250218T120000
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT
END:VCALENDAR`;
    const result = TimetableImport.import(unknown, store, "MA");
    expect(result.coursesCreated).toBe(1);
    expect(result.eventsCreated).toBe(3);
  });
  it("le message résume l'import", () => {
    expect(TimetableImport.resultMessage(first)).toBe("1 cours reconnu(s) · 5 séance(s) importée(s) · 1 cours avec amphi détecté(s)");
    expect(TimetableImport.resultMessage({ ...first, coursesMatched: 0, eventsCreated: 0, lecturesDetected: 0 })).toBe("Aucun événement trouvé dans le flux.");
  });
});

describe("Le lieu ne détermine jamais le code de cours", () => {
  const { store } = storeWithCS250();
  const room = `BEGIN:VCALENDAR
BEGIN:VEVENT
UID:room-1
SUMMARY:Thermodynamique appliquée
LOCATION:BS170, CM1221
CATEGORIES:Cours
DTSTART;TZID=Europe/Zurich:20250217T081500
DTEND;TZID=Europe/Zurich:20250217T100000
END:VEVENT
END:VCALENDAR`;
  const result = TimetableImport.import(room, store, "MA");
  const courses = store.fetch(Course);
  const thermo = courses.find((c) => c.code === "THERMOD");
  it("le cours sans code est créé", () => expect(result.coursesCreated).toBe(1));
  it("code dérivé du nom, pas du local", () => expect(thermo).toBeDefined());
  it("aucun cours nommé d'après un local", () => {
    expect(courses.some((c) => c.code.includes("BS170") || c.code.includes("BS-170"))).toBe(false);
    expect(courses.some((c) => c.name.includes("BS170"))).toBe(false);
  });
  it("CATEGORIES:Cours marque bien des heures de cours", () => expect(thermo?.hasLectures).toBe(true));
  const events = store.fetch(LinkedCalendarEvent).filter((e) => e.course?.code === "THERMOD");
  it("une séance enregistrée pour ce cours", () => expect(events).toHaveLength(1));
  it("le local reste enregistré comme lieu", () => expect(events[0].location).toContain("BS170"));
  it("la séance est classée comme cours", () => expect(events[0].isLecture).toBe(true));
  it("l'intitulé du cours n'est pas le local", () => expect(thermo?.name).not.toBe("BS170"));
  it("le cours reçoit un semestre, donc sa semaine vient du calendrier", () => {
    expect(thermo?.term).not.toBeNull();
    expect(thermo?.currentWeek).toBe(DateUtils.weekNumber(DateUtils.currentAutumnOrSpringStart().start));
  });
});

describe("Horaire : amphi ou exercices", () => {
  const monday = fromWallTime(2026, 9, 28, 8, 15, 0, ZURICH);
  const nextMonday = new Date(monday.getTime() + 7 * 86_400_000);
  const wednesday = new Date(monday.getTime() + 2 * 86_400_000);

  it("trois salles comptées", () => expect(TimetableClassifier.roomCount("CE1101, CE1105, CO010")).toBe(3));
  it("une salle avec espaces reste une salle", () => expect(TimetableClassifier.roomCount("RLC E1 240")).toBe(1));
  it("lieu vide : aucune salle", () => expect(TimetableClassifier.roomCount("")).toBe(0));
  it("plusieurs salles : séance d'exercices, même sans mot-clé", () =>
    expect(TimetableClassifier.kindOfTitle("Physique générale : mécanique (anglais)", "CE1101, CE1105, CO010, CO011", true)).toBe("exerciseSession"));
  it("une seule salle, rattachée à un cours : cours", () =>
    expect(TimetableClassifier.kindOfTitle("Analyse I (classe inversée)", "CE16", true)).toBe("lecture"));
  it("sans cours ni mot-clé : agenda personnel", () => expect(TimetableClassifier.kindOfTitle("Dîner", "", false)).toBe("other"));
  it("un midterm dans plusieurs salles reste un midterm", () =>
    expect(TimetableClassifier.kindOfTitle("Midterm Analyse", "CE1, CE2", true)).toBe("midterm"));
  it("CATEGORIES « Exercices » → exercices", () =>
    expect(TimetableClassifier.kindOfCategories("Horaires enseignés FBM,Exercices,", "Analyse I (classe inversée)", "CE1106, CE1515", true)).toBe("exerciseSession"));
  it("CATEGORIES « Cours » → amphi", () =>
    expect(TimetableClassifier.kindOfCategories("Horaires enseignés FBM,Cours,", "Analyse I (classe inversée)", "CE16", true)).toBe("lecture"));

  const a = TimetableClassifier.slot("X", monday, ZURICH);
  it("même créneau d'une semaine à l'autre", () => expect(a).toEqual(TimetableClassifier.slot("X", nextMonday, ZURICH)));
  it("un autre jour, un autre créneau", () => expect(a).not.toEqual(TimetableClassifier.slot("X", wednesday, ZURICH)));
  const b = TimetableClassifier.slot("X", wednesday, ZURICH);
  const learned = TimetableClassifier.learnedKinds([
    { slot: a, kind: "lecture", isManual: false }, { slot: a, kind: "lecture", isManual: false },
    { slot: a, kind: "exerciseSession", isManual: true },
    { slot: b, kind: "lecture", isManual: false }, { slot: b, kind: "exerciseSession", isManual: false },
  ]);
  it("un choix manuel l'emporte sur l'horaire", () => expect(learned.get(TimetableClassifier.slotKey(a))).toBe("exerciseSession"));
  it("sources à égalité : créneau non tranché", () => expect(learned.get(TimetableClassifier.slotKey(b))).toBeUndefined());
  it("même cours, même minute : la même séance lue deux fois", () =>
    expect(TimetableClassifier.isSameSession("c", monday, "c", new Date(monday.getTime() + 30_000))).toBe(true));
  it("deux cours au même moment ne sont pas un doublon", () =>
    expect(TimetableClassifier.isSameSession("c", monday, "d", monday)).toBe(false));
  it("semaine type d'Analyse : 3 h 45 d'amphi, 1 h 45 d'exercices", () => {
    const hours = TimetableClassifier.weeklyHours([
      { start: monday, seconds: 225 * 60, kind: "lecture" },
      { start: wednesday, seconds: 105 * 60, kind: "exerciseSession" },
      { start: nextMonday, seconds: 225 * 60, kind: "lecture" },
      { start: new Date(nextMonday.getTime() + 2 * 86_400_000), seconds: 105 * 60, kind: "exerciseSession" },
    ], ZURICH);
    expect(hours).toEqual({ lecture: 3.75, exercise: 1.75 });
  });
  it("un bloc d'agenda personnel n'est pas un cours", () => {
    expect(TimetableClassifier.kindOfTitle("🧠 MATH-111 — finir la série", "", true)).toBe("study");
    expect(TimetableClassifier.kindOfTitle("✓ [MATH-101] Série 2", "", true)).toBe("study");
  });
  it("une échéance n'est pas une séance", () => {
    expect(TimetableClassifier.kindOfTitle("[CS-107] Rendu mini-projet 2 — 50 %", "", true)).toBe("other");
    expect(TimetableClassifier.kindOfTitle("[CS-107] Défense du projet noté", "", true)).toBe("other");
  });
  it("un cours de l'horaire reste un cours", () =>
    expect(TimetableClassifier.kindOfTitle("Analyse I (classe inversée)", "CE1", true)).toBe("lecture"));

  describe("l'horaire EPFL réel : plusieurs lignes CATEGORIES, DURATION, salles multiples", () => {
    const epfl = `BEGIN:VCALENDAR
BEGIN:VEVENT
UID:horaire_1@is-academia
SUMMARY:Analyse II test (classe inversée)
DTSTART;TZID=Europe/Berlin:20260928T081500
DURATION:PT225M
CATEGORIES:Horaires enseignés FBM
LOCATION:CE16
CATEGORIES:Cours
CATEGORIES:
END:VEVENT
BEGIN:VEVENT
UID:horaire_2@is-academia
SUMMARY:Analyse II test (classe inversée)
DTSTART;TZID=Europe/Berlin:20260930T101500
DURATION:PT105M
CATEGORIES:Horaires enseignés FBM
LOCATION:CE1106, CE1515
CATEGORIES:Exercices
CATEGORIES:
END:VEVENT
END:VCALENDAR`;
    const store = new ModelStore();
    const horizon = new Date(monday.getTime() + 2 * 365 * 86_400_000);
    const parsed = ICSParser.parse(epfl, horizon);
    it("deux séances lues", () => expect(parsed).toHaveLength(2));
    const result = TimetableImport.import(epfl, store, "", horizon);
    const imported = store.fetch(LinkedCalendarEvent).find((e) => e.title === "Analyse II test (classe inversée)")?.course ?? null;
    const ghost = new LinkedCalendarEvent({
      externalEventID: "ek-1", sourceCalendarID: "Horaire EPFL", title: "Analyse II test (classe inversée)",
      startsAt: parsed[1].start, endsAt: parsed[1].end, location: "CE1106, CE1515", kind: "lecture",
    });
    ghost.course = imported;
    ghost.isSkipped = true;
    store.insert(ghost);
    const stray = new LinkedCalendarEvent({
      externalEventID: "ek-2", sourceCalendarID: "Horaire EPFL", title: "Analyse II test (classe inversée)",
      startsAt: new Date(parsed[1].start.getTime() + 86_400_000), endsAt: new Date(parsed[1].end.getTime() + 86_400_000),
      location: "CE1, CE2", kind: "lecture",
    });
    stray.course = imported;
    store.insert(stray);
    const repaired = CalendarSync.repair(store);
    it("réparation : un doublon retiré, une séance reclassée", () => expect(repaired).toBe(2));
    it("plusieurs salles : la séance du calendrier passe en exercices", () => expect(stray.kind).toBe("exerciseSession"));
    store.delete(stray);
    const events = store.fetch(LinkedCalendarEvent).filter((e) => e.title === "Analyse II test (classe inversée)");
    it("deux séances importées", () => expect(result.eventsCreated).toBe(2));
    it("le doublon du calendrier est retiré", () => expect(events).toHaveLength(2));
    it("une seule séance comptée en amphi", () => expect(events.filter((e) => e.isLecture)).toHaveLength(1));
    it("le doublon transmet ce qu'on y avait noté (manqué)", () => expect(events.some((e) => !e.isLecture && e.isSkipped)).toBe(true));
    it("heures du cours lues dans l'horaire", () => {
      expect(events[0].course?.weeklyLectureHours).toBe(3.75);
      expect(events[0].course?.weeklyExerciseHours).toBe(1.75);
    });
    it("« c'est une séance d'exercices » : tout le créneau suit, et le choix tient au réimport", () => {
      const lecture = events.find((e) => e.isLecture)!;
      expect(CalendarSync.setKind("exerciseSession", lecture, store)).toBe(1);
      TimetableImport.import(epfl, store, "", horizon);
      expect(lecture.kind).toBe("exerciseSession");
      expect(lecture.kindIsManual).toBe(true);
    });
  });
});

describe("Flux d'horaire et calendrier académique", () => {
  const ok = (text: string) => async () => new Response(text, { status: 200 });
  it("webcal:// devient https://", async () => {
    let asked = "";
    await TimetableImport.fetch("webcal://exemple.ch/horaire.ics", async (url) => { asked = url; return new Response("x"); });
    expect(asked).toBe("https://exemple.ch/horaire.ics");
  });
  it("une adresse vide ou illisible est refusée", async () => {
    await expect(TimetableImport.fetch("  ", ok("x"))).rejects.toBeInstanceOf(TimetableError);
    await expect(TimetableImport.fetch("pas une adresse", ok("x"))).rejects.toThrow("URL du flux invalide.");
  });
  it("un HTTP en échec est rapporté", async () => {
    await expect(TimetableImport.fetch("https://exemple.ch/a.ics", async () => new Response("", { status: 404 })))
      .rejects.toThrow("Téléchargement impossible : HTTP 404");
  });
  it("une page du calendrier académique sans date lisible : erreur claire", async () => {
    const store = new ModelStore();
    await expect(AcademicCalendarService.refresh(store, "https://exemple.ch/", ok("<html>rien</html>")))
      .rejects.toThrow("La page ne contient aucune date lisible.");
  });
  it("l'instantané embarqué s'installe une fois", () => {
    const store = new ModelStore();
    expect(AcademicCalendarService.seedIfNeeded(store)).toBeGreaterThan(0);
    expect(AcademicCalendarService.seedIfNeeded(store)).toBe(0);
  });
  it("AcademicTerm.current existe pour l'import", () => expect(AcademicTerm.current(new ModelStore())).toBeDefined());
});
