// Import d'un emploi du temps iCalendar (« Mon horaire » EPFL ou tout autre flux)
// (Polymestre/Services/TimetableImport.swift).
//
// Ce chemin fonctionne réellement à l'EPFL : l'étudiant·e exporte/colle son flux
// `.ics` (ou s'y abonne par son adresse), l'app en déduit ses cours, détecte lesquels
// ont des heures de cours (amphi) et crée les événements liés.

import { Course } from "../models/course.ts";
import { AcademicTerm } from "../models/academicTerm.ts";
import { LinkedCalendarEvent } from "../models/linkedCalendarEvent.ts";
import type { ModelStore } from "../models/store.ts";
import { icuRegExp } from "../domain/icuRegExp.ts";
import { TimetableClassifier } from "../domain/timetableClassifier.ts";
import { characters, isLetter, isNumber } from "../domain/textRepair.ts";
import { nativeFetch } from "../native/http.ts";
import { ICSParser } from "./timetableImportService.ts";
import type { ICSEvent } from "./timetableImportService.ts";

/** `Theme.coursePalette` : la palette d'identité des cours. */
export const coursePalette = ["#4F46E5", "#0EA5E9", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6", "#F97316", "#6366F1"];

export interface ImportResult {
  coursesCreated: number;
  coursesMatched: number;
  eventsCreated: number;
  eventsSkipped: number;
  lecturesDetected: number;
  sectionApplied: number;
}

export function emptyResult(): ImportResult {
  return { coursesCreated: 0, coursesMatched: 0, eventsCreated: 0, eventsSkipped: 0, lecturesDetected: 0, sectionApplied: 0 };
}

export function resultMessage(result: ImportResult): string {
  const parts: string[] = [];
  if (result.coursesCreated > 0) parts.push(`${result.coursesCreated} cours créé(s)`);
  if (result.coursesMatched > 0) parts.push(`${result.coursesMatched} cours reconnu(s)`);
  if (result.eventsCreated > 0) parts.push(`${result.eventsCreated} séance(s) importée(s)`);
  if (result.eventsSkipped > 0) parts.push(`${result.eventsSkipped} déjà présente(s)`);
  if (result.lecturesDetected > 0) parts.push(`${result.lecturesDetected} cours avec amphi détecté(s)`);
  return parts.length === 0 ? "Aucun événement trouvé dans le flux." : parts.join(" · ");
}

// MARK: Récupération du flux

export class TimetableError extends Error {
  constructor(readonly kind: "invalidURL" | "network" | "empty", detail = "") {
    super(kind === "invalidURL" ? "URL du flux invalide."
      : kind === "network" ? `Téléchargement impossible : ${detail}` : "Le flux ne contient aucun événement.");
  }
}

/** Télécharge un flux `.ics` (accepte `webcal://`). */
export async function fetchFeed(urlString: string, fetcher: (url: string, init?: RequestInit) => Promise<Response> = nativeFetch): Promise<string> {
  let raw = urlString.trim();
  if (raw === "") throw new TimetableError("invalidURL");
  if (raw.toLowerCase().startsWith("webcal://")) raw = "https://" + raw.slice("webcal://".length);
  let url: URL;
  try { url = new URL(raw); } catch { throw new TimetableError("invalidURL"); }
  let response: Response;
  try {
    response = await fetcher(url.href, { headers: { "User-Agent": "Polymestre/1.0" } });
  } catch (error) {
    throw new TimetableError("network", error instanceof Error ? error.message : String(error));
  }
  if (!(response.status >= 200 && response.status < 300)) throw new TimetableError("network", `HTTP ${response.status}`);
  const text = await response.text();
  if (text === "") throw new TimetableError("empty");
  return text;
}

// MARK: Import

/** Le cours d'un événement : son code (intitulé, puis description — **jamais le lieu**), son nom nettoyé. */
function importEvents(icsEvents: ICSEvent[], store: ModelStore, sectionCode: string): ImportResult {
  const result = emptyResult();
  if (icsEvents.length === 0) return result;

  const courses = [...store.fetch(Course)];
  const storedEvents = [...store.fetch(LinkedCalendarEvent)];
  const existingEventIDs = new Set(storedEvents.map((e) => e.externalEventID).filter((id): id is string => id !== null));
  // Les événements venus du calendrier système, candidats au doublon.
  let calendarEvents = storedEvents.filter((e) => e.sourceCalendarID !== "ics" && e.course !== null);
  // Les créneaux dont le type a été choisi à la main.
  const manualSlots = new Map<string, LinkedCalendarEvent["kind"]>();
  for (const event of storedEvents.filter((e) => e.kindIsManual)) {
    const key = TimetableClassifier.slotKey(TimetableClassifier.slot(
      TimetableClassifier.owner(event.course?.id ?? null, event.title), event.startsAt));
    if (!manualSlots.has(key)) manualSlots.set(key, event.kind);
  }
  // Le semestre auquel rattacher les cours créés ici : sans lui, `Course.currentWeek`
  // retombait sur 1 et un import en semaine 2 affichait « 1 / 14 » partout.
  const term = AcademicTerm.current(store);

  const lectureCourses = new Set<string>();
  const matchedCourses = new Set<string>();
  const createdCourses = new Set<string>();

  for (const event of icsEvents) {
    // Uniquement l'intitulé et la description. **Jamais le lieu** : les salles de l'EPFL
    // s'écrivent « BS-170 », « CE1515 » — le format exact d'un code de cours.
    const code = detectCourseCode(event.summary) ?? detectCourseCode(event.notes);
    const name = cleanedName(event.summary, code);

    // 1. Retrouver ou créer le cours.
    let course: Course | null = null;
    if (code !== null) course = courses.find((c) => c.code.toLowerCase() === code.toLowerCase()) ?? null;
    // Replier sur le nom, comparé sans accents ni ponctuation.
    if (course === null && name !== "") {
      const key = nameKey(name);
      course = courses.find((c) => nameKey(c.name) === key) ?? null;
    }
    // Un code officiel vient d'être retrouvé alors que le cours portait un code fabriqué
    // par un import précédent : on le corrige.
    if (code !== null && course !== null && !isOfficialCode(course.code)) course.code = code;

    if (course === null) {
      const resolvedCode = code ?? derivedCode(name, courses.map((c) => c.code));
      const created = new Course({
        code: resolvedCode,
        name: name === "" ? resolvedCode : name,
        credits: 4,
        colorHex: coursePalette[courses.length % coursePalette.length],
        term,
        weeklyLectureHours: 2,
        weeklyExerciseHours: 1,
        hasLectures: false,
        sectionCode,
      });
      store.insert(created);
      courses.push(created);
      course = created;
      createdCourses.add(created.id);
    } else {
      matchedCourses.add(course.id);
    }

    // Un cours retrouvé mais sans semestre est rattaché au passage.
    if (course.term === null) course.term = term;
    // Renseigner la section du cours existant si elle est vide.
    if (sectionCode !== "" && course.sectionCode === "") {
      course.sectionCode = sectionCode;
      result.sectionApplied++;
    }

    // 2. Créer la séance si elle n'existe pas déjà.
    const identifier = `ics:${event.uid}:${Math.trunc(event.start.getTime() / 1000)}`;
    // `CATEGORIES` tranche quand il se prononce ; sinon l'intitulé, puis le nombre de
    // salles. Un type choisi à la main pour ce créneau l'emporte sur tout.
    const slotKey = TimetableClassifier.slotKey(TimetableClassifier.slot(
      TimetableClassifier.owner(course.id, event.summary), event.start));
    const manualKind = manualSlots.get(slotKey);
    const kind = manualKind ?? TimetableClassifier.kindOfCategories(event.categories, event.summary, event.location, true);
    if (existingEventIDs.has(identifier)) {
      // Déjà là : seul son type peut avoir été mal lu par une version précédente.
      const stored = storedEvents.find((e) => e.externalEventID === identifier);
      if (stored && !stored.kindIsManual) stored.kind = kind;
      result.eventsSkipped++;
      continue;
    }
    const linked = new LinkedCalendarEvent({
      externalEventID: identifier, sourceCalendarID: "ics", title: event.summary,
      startsAt: event.start, endsAt: event.end, location: event.location, kind,
    });
    linked.course = course;
    linked.lastSyncedAt = new Date();
    linked.kindIsManual = manualKind !== undefined;
    store.insert(linked);
    // La même séance, déjà lue dans le calendrier système abonné au même flux : l'horaire
    // importé la remplace — il sait si c'est un cours ou des exercices.
    for (const twin of [...calendarEvents]) {
      if (TimetableClassifier.isSameSession(twin.course?.id ?? null, twin.startsAt, course.id, event.start)) {
        if (twin.isSkipped) linked.isSkipped = true;
        store.delete(twin);
        calendarEvents = calendarEvents.filter((e) => e !== twin);
      }
    }
    existingEventIDs.add(identifier);
    result.eventsCreated++;

    if (kind === "lecture" && !lectureCourses.has(course.id)) {
      lectureCourses.add(course.id);
      if (!course.hasLectures) course.hasLectures = true;
      result.lecturesDetected++;
    }
  }

  result.coursesCreated = createdCourses.size;
  result.coursesMatched = matchedCourses.size;

  // Les heures de la semaine type, lues dans l'horaire, pour les cours créés ici ou restés
  // aux valeurs par défaut (2 h + 1 h) : une saisie faite à la main n'est jamais écrasée.
  const allEvents = store.fetch(LinkedCalendarEvent);
  for (const course of courses) {
    const isNew = createdCourses.has(course.id);
    const isDefault = matchedCourses.has(course.id) && course.weeklyLectureHours === 2 && course.weeklyExerciseHours === 1;
    if (!isNew && !isDefault) continue;
    const sessions = allEvents
      .filter((e) => e.course?.id === course.id && e.sourceCalendarID === "ics")
      .map((e) => ({ start: e.startsAt, seconds: e.durationSeconds, kind: e.kind }));
    if (sessions.length === 0) continue;
    const hours = TimetableClassifier.weeklyHours(sessions);
    course.weeklyLectureHours = hours.lecture;
    course.weeklyExerciseHours = hours.exercise;
    course.hasLectures = hours.lecture > 0;
  }
  return result;
}

/** Importe le texte d'un flux iCalendar dans le graphe (`TimetableImport.import`). */
export function importICS(icsText: string, store: ModelStore, sectionCode = "", horizon?: Date): ImportResult {
  return importEvents(ICSParser.parse(icsText, horizon), store, sectionCode);
}

// MARK: Extraction d'informations

/** Repère un code de cours EPFL dans un intitulé (« CS-250 Algorithms I », « MATH-101 »…). */
export function detectCourseCode(summary: string): string | null {
  const match = icuRegExp(String.raw`\b([A-Z]{2,5})[-\s]?(\d{3})\b`).exec(summary);
  return match === null ? null : `${match[1]}-${match[2]}`;
}

/** Retire le code et les suffixes de type de séance de l'intitulé. */
export function cleanedName(summary: string, code: string | null): string {
  let name = summary;
  if (code !== null) {
    name = name.split(code).join("");
    name = name.split(code.split("-").join(" ")).join("");
  }
  const noise = ["cours", "exercices", "exercise session", "lecture", "amphi", "série", "serie", "tp", "labo",
    "laboratoire", "projet", "test", "contrôle", "controle", "midterm", "examen", "exam"];
  const tokens = name.split("(").join(" ").split(")").join(" ").split("-").join(" ")
    .split(" ").filter((token) => token !== "")
    .filter((token) => !noise.includes(token.toLowerCase()));
  const cleaned = tokens.join(" ").trim();
  return cleaned === "" ? summary : cleaned;
}

/** Un code EPFL officiel : deux à cinq lettres, puis trois chiffres. */
export function isOfficialCode(value: string): boolean {
  return detectCourseCode(value) !== null;
}

/**
 * Clé de comparaison d'un intitulé : sans accents, sans casse, sans ponctuation, espaces
 * normalisés. « Algèbre linéaire » et « Algebre lineaire » désignent le même cours.
 */
export function nameKey(raw: string): string {
  const folded = raw.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
  return characters(folded).map((c) => (isLetter(c) || isNumber(c) ? c : " ")).join("")
    .split(" ").filter((part) => part !== "").join(" ");
}

/** Fabrique un code court et unique quand l'intitulé n'en contient pas. */
export function derivedCode(name: string, existing: string[]): string {
  const letters = characters(name.toUpperCase()).filter((c) => isLetter(c));
  let base = letters.slice(0, 7).join("");
  if (base === "") base = "COURS";
  if (!existing.includes(base)) return base;
  let index = 2;
  while (existing.includes(`${base}-${index}`)) index++;
  return `${base}-${index}`;
}

export const TimetableImport = {
  import: importICS, fetch: fetchFeed, detectCourseCode, cleanedName, isOfficialCode, nameKey, derivedCode,
  resultMessage,
};
