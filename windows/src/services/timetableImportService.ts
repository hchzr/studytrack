// Analyseur iCalendar (RFC 5545), volontairement autonome et sans dépendance
// (Polymestre/Services/TimetableImportService.swift).
//
// L'EPFL publie l'horaire personnel des étudiant·e·s au format `.ics` (« Mon horaire »).
// C'est la seule intégration d'emploi du temps réaliste : aucune API n'est ouverte aux
// étudiant·e·s. Ce parseur couvre ce que produit un emploi du temps universitaire :
// `VEVENT`, `DTSTART`/`DTEND` (UTC, local, `TZID`, journée entière), `RRULE`
// hebdomadaire/quotidienne, `EXDATE`.

import { isLectureCategory } from "../domain/timetableClassifier.ts";
import { addCalendarDays, fromWallTime, startOfDayIn, validTimeZone, wallTime } from "../domain/zonedTime.ts";
import { newId } from "../models/relations.ts";

/** Un événement iCalendar, éventuellement issu d'une récurrence. */
export interface ICSEvent {
  uid: string;
  summary: string;
  start: Date;
  end: Date;
  location: string;
  notes: string;
  isRecurring: boolean;
  /** Valeurs de `CATEGORIES`, concaténées. Porte le **type de séance**. */
  categories: string;
}

export function durationSeconds(event: ICSEvent): number {
  return Math.max(0, Math.trunc((event.end.getTime() - event.start.getTime()) / 1000));
}

interface Field { value: string; params: Record<string, string> }

/** Nombre maximal d'occurrences générées par événement récurrent. */
const occurrenceCap = 400;

export { isLectureCategory };

/** RFC 5545 §3.1 : une ligne repliée commence par un espace ou une tabulation. */
function unfold(text: string): string[] {
  const normalized = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  const result: string[] = [];
  for (const line of normalized.split("\n")) {
    if (line.startsWith(" ") || line.startsWith("\t")) {
      if (result.length > 0) result[result.length - 1] += line.slice(1);
    } else {
      result.push(line);
    }
  }
  return result.filter((line) => line !== "");
}

function firstUnquotedColon(line: string): number {
  let inQuotes = false;
  for (let index = 0; index < line.length; index++) {
    const character = line[index];
    if (character === "\"") inQuotes = !inQuotes;
    if (character === ":" && !inQuotes) return index;
  }
  return -1;
}

function unescape(value: string): string {
  return value
    .split("\\n").join("\n")
    .split("\\N").join("\n")
    .split("\\,").join(",")
    .split("\;").join(";")
    .split("\\\\").join("\\");
}

/** `KEY;PARAM=VALUE:VALUE` → (clé, valeur, paramètres). */
function parseLine(line: string): { key: string; field: Field } | null {
  const colon = firstUnquotedColon(line);
  if (colon < 0) return null;
  const head = line.slice(0, colon);
  const value = line.slice(colon + 1);
  const parts = head.split(";");
  const key = parts[0];
  if (key === undefined) return null;
  const params: Record<string, string> = {};
  for (const part of parts.slice(1)) {
    const equals = part.indexOf("=");
    if (equals <= 0 || equals === part.length - 1) continue;
    params[part.slice(0, equals).toUpperCase()] = part.slice(equals + 1);
  }
  return { key: key.toUpperCase(), field: { value: unescape(value), params } };
}

// MARK: Dates

export function parseDate(raw: string, params: Record<string, string>): Date | null {
  const value = raw.trim();
  const timeZone = validTimeZone(params.TZID);

  const utc = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(value);
  if (value.endsWith("Z")) {
    return utc ? new Date(Date.UTC(+utc[1], +utc[2] - 1, +utc[3], +utc[4], +utc[5], +utc[6])) : null;
  }
  const full = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$/.exec(value);
  if (full) return fromWallTime(+full[1], +full[2], +full[3], +full[4], +full[5], +full[6], timeZone);
  const short = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})$/.exec(value);
  if (short) return fromWallTime(+short[1], +short[2], +short[3], +short[4], +short[5], 0, timeZone);
  const day = /^(\d{4})(\d{2})(\d{2})$/.exec(value);
  if (day) return fromWallTime(+day[1], +day[2], +day[3], 0, 0, 0, timeZone);
  return null;
}

/**
 * Durée ISO 8601 d'un `DURATION` iCalendar : « PT105M », « PT1H30M », « P1D ». Fonction
 * pure : c'est le seul format de durée que produisent les horaires universitaires, et il
 * n'a rien à voir avec une date.
 */
export function parseDuration(value: string): number | null {
  const raw = value.trim().toUpperCase();
  if (!raw.startsWith("P")) return null;
  let seconds = 0;
  let digits = "";
  for (const character of raw.slice(1)) {
    if (/^\d$/.test(character)) { digits += character; continue; }
    const amount = digits === "" ? null : Number(digits);
    if (amount === null) { digits = ""; continue; }
    switch (character) {
      case "W": seconds += amount * 7 * 86_400; break;
      case "D": seconds += amount * 86_400; break;
      case "H": seconds += amount * 3_600; break;
      case "M": seconds += amount * 60; break;
      case "S": seconds += amount; break;
      default: break;
    }
    digits = "";
  }
  return seconds > 0 ? seconds : null;
}

// MARK: Récurrences

interface RecurrenceRule {
  frequency: string;
  interval: number;
  count: number | null;
  until: Date | null;
  /** 1 = dimanche … 7 = samedi (convention iCalendar). */
  byDay: number[];
}

function parseRule(raw: string): RecurrenceRule {
  const rule: RecurrenceRule = { frequency: "WEEKLY", interval: 1, count: null, until: null, byDay: [] };
  const map: Record<string, number> = { SU: 1, MO: 2, TU: 3, WE: 4, TH: 5, FR: 6, SA: 7 };
  for (const component of raw.split(";")) {
    const equals = component.indexOf("=");
    if (equals < 0) continue;
    const key = component.slice(0, equals).toUpperCase();
    const value = component.slice(equals + 1);
    switch (key) {
      case "FREQ": rule.frequency = value.toUpperCase(); break;
      case "INTERVAL": rule.interval = Math.max(1, /^[+-]?\d+$/.test(value) ? Number(value) : 1); break;
      case "COUNT": rule.count = /^[+-]?\d+$/.test(value) ? Number(value) : null; break;
      case "UNTIL": rule.until = parseDate(value, {}); break;
      case "BYDAY":
        rule.byDay = value.split(",").filter((token) => token !== "")
          .map((token) => map[token.slice(-2).toUpperCase()]).filter((day): day is number => day !== undefined);
        break;
      default: break;
    }
  }
  return rule;
}

/**
 * Génère les occurrences. L'expansion se fait **dans le fuseau de l'événement** : sinon
 * un cours de 08:15 à Zurich deviendrait un autre jour pour un appareil réglé ailleurs.
 * L'heure de DTSTART est conservée pour les règles `BYDAY`.
 */
function occurrenceDates(start: Date, rule: RecurrenceRule, horizon: Date, timeZone: string | null): Date[] {
  const dates: Date[] = [];
  const maxCount = rule.count ?? occurrenceCap;
  const stepDays = (from: Date, days: number) => addCalendarDays(from, days, timeZone);

  if (rule.frequency === "DAILY") {
    let cursor = start;
    while (dates.length < maxCount && cursor.getTime() <= horizon.getTime()) {
      dates.push(cursor);
      if (rule.until && cursor.getTime() > rule.until.getTime()) break;
      cursor = stepDays(cursor, rule.interval);
    }
  } else if (rule.frequency === "WEEKLY") {
    if (rule.byDay.length === 0) {
      let cursor = start;
      while (dates.length < maxCount && cursor.getTime() <= horizon.getTime()) {
        dates.push(cursor);
        if (rule.until && cursor.getTime() > rule.until.getTime()) break;
        cursor = stepDays(cursor, 7 * rule.interval);
      }
    } else {
      // La semaine commence le dimanche (numérotation iCalendar), quelle que soit la locale.
      const startDay = startOfDayIn(start, timeZone);
      const weekAnchor = stepDays(startDay, -(wallTime(start, timeZone).weekday - 1));
      // Heure de la journée à conserver (08:15 dans « 08:15–10:00 »).
      const timeOfDay = (start.getTime() - startDay.getTime()) / 1000;
      let weekOffset = 0;
      while (dates.length < maxCount) {
        const base = stepDays(weekAnchor, weekOffset * rule.interval * 7);
        if (base.getTime() > horizon.getTime()) break;
        for (const weekday of [...rule.byDay].sort((a, b) => a - b)) {
          const day = stepDays(base, weekday - 1);
          const candidate = new Date(day.getTime() + timeOfDay * 1000);
          if (candidate.getTime() < start.getTime()) continue;
          if (rule.until && candidate.getTime() > rule.until.getTime()) continue;
          if (candidate.getTime() > horizon.getTime()) continue;
          dates.push(candidate);
          if (dates.length >= maxCount) break;
        }
        weekOffset++;
      }
    }
  } else {
    dates.push(start);
  }
  return dates.sort((a, b) => a.getTime() - b.getTime());
}

function expand(fields: Record<string, Field>, horizon: Date): ICSEvent[] {
  const summaryField = fields.SUMMARY;
  const startField = fields.DTSTART;
  if (!summaryField || !startField) return [];
  const start = parseDate(startField.value, startField.params);
  if (!start) return [];

  // `DTEND` est une date, `DURATION` une durée ISO 8601 (« PT105M »). Le « Mon horaire »
  // de l'EPFL n'émet **que** `DURATION` : sans ce décodage, chaque séance retombait sur
  // le défaut d'une heure — 105 min devenaient 60.
  let end: Date;
  const parsedEnd = fields.DTEND ? parseDate(fields.DTEND.value, fields.DTEND.params) : null;
  const seconds = fields.DURATION ? parseDuration(fields.DURATION.value) : null;
  if (parsedEnd) end = parsedEnd;
  else if (seconds !== null) end = new Date(start.getTime() + seconds * 1000);
  else end = new Date(start.getTime() + 3_600_000);

  const uid = fields.UID?.value ?? newId().toUpperCase();
  const location = fields.LOCATION?.value ?? "";
  const notes = fields.DESCRIPTION?.value ?? "";
  const summary = summaryField.value;
  const categories = fields.CATEGORIES?.value ?? "";

  const rrule = fields.RRULE?.value;
  if (rrule === undefined) {
    return [{ uid, summary, start, end, location, notes, isRecurring: false, categories }];
  }
  const rule = parseRule(rrule);
  const excluded = new Set<number>();
  for (const token of (fields.EXDATE?.value ?? "").split(",").filter((t) => t !== "")) {
    const date = parseDate(token, fields.EXDATE?.params ?? {});
    if (date) excluded.add(date.getTime());
  }
  const duration = end.getTime() - start.getTime();
  const timeZone = validTimeZone(startField.params.TZID);
  const occurrences: ICSEvent[] = [];
  let generated = 0;
  for (const date of occurrenceDates(start, rule, horizon, timeZone)) {
    if (generated >= occurrenceCap) break;
    if (date.getTime() > horizon.getTime()) break;
    generated++;
    if (excluded.has(date.getTime())) continue;
    occurrences.push({
      uid, summary, start: date, end: new Date(date.getTime() + duration),
      location, notes, isRecurring: true, categories,
    });
  }
  return occurrences;
}

/** Les événements d'un flux iCalendar, triés par début. `horizon` : jusqu'où développer les récurrences. */
export function parse(text: string, horizon: Date = new Date(Date.now() + 365 * 86_400_000)): ICSEvent[] {
  const events: ICSEvent[] = [];
  let current: Record<string, Field> | null = null;
  for (const line of unfold(text)) {
    const upper = line.toUpperCase();
    if (upper.startsWith("BEGIN:VEVENT")) { current = {}; continue; }
    if (upper.startsWith("END:VEVENT")) {
      if (current) events.push(...expand(current, horizon));
      current = null;
      continue;
    }
    if (!current) continue;
    const parsed = parseLine(line);
    if (!parsed) continue;
    // Un champ peut apparaître plusieurs fois (EXDATE, CATEGORIES) : on concatène.
    const existing = current[parsed.key];
    current[parsed.key] = existing
      ? { value: existing.value + "," + parsed.field.value, params: parsed.field.params }
      : parsed.field;
  }
  return events.sort((a, b) => a.start.getTime() - b.start.getTime());
}

export const ICSParser = { parse, parseDuration, isLectureCategory, durationSeconds };
