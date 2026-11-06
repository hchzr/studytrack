// Le temps de travail **réel**, compté partout de la même façon
// (Polymestre/Domain/StudyTime.swift) : les sessions (chrono, saisies, Anki)
// **plus** les cours suivis.
//
// Ce qui compte, l'étudiant·e le choisit (`studyCounting.ts`, Réglages › Chrono) ; une séance
// de l'horaire compte finie, pas manquée, d'un cours suivi, et jamais deux fois avec un chrono.

import { LinkedCalendarEvent } from "../models/linkedCalendarEvent.ts";
import { StudySession } from "../models/studySession.ts";
import type { ModelStore } from "../models/store.ts";
import { DateUtils } from "./dateUtils.ts";
import { countsEvent, countsSession, readCounting, type Counting } from "./studyCounting.ts";

/** Un intervalle de chrono (début, fin). */
export interface Interval {
  start: Date;
  end: Date;
}

/** Une durée comptée, rangée pour l'agrégation (jour, cours, nature). */
export interface Block {
  start: Date;
  seconds: number;
  courseCode: string | null;
  /** `TaskType.rawValue` d'une session, `lecture` pour un cours de l'horaire. */
  taskType: string;
}

/** Au-delà, un « cours » n'en est pas un : le plus long amphi de l'EPFL tient en 4 h. */
export const longestLecture = 4.5 * 3600;

const secondsBetween = (later: Date, earlier: Date) => (later.getTime() - earlier.getTime()) / 1000;

/** La part d'un cours qui compte : sa durée moins ce que recouvrent les chronos. */
export function lectureSeconds(start: Date, end: Date, minus: Interval[]): number {
  if (!(end > start) || secondsBetween(end, start) > longestLecture) return 0;
  // Les recouvrements, fusionnés : deux chronos qui se chevauchent ne retirent
  // pas deux fois la même minute.
  const clipped = minus
    .map((session) => ({
      start: new Date(Math.max(session.start.getTime(), start.getTime())),
      end: new Date(Math.min(session.end.getTime(), end.getTime())),
    }))
    .filter((part) => part.end > part.start)
    .sort((a, b) => a.start.getTime() - b.start.getTime());
  let covered = 0;
  let cursor = start;
  for (const part of clipped) {
    const from = new Date(Math.max(part.start.getTime(), cursor.getTime()));
    if (part.end > from) {
      covered += secondsBetween(part.end, from);
      cursor = part.end;
    }
  }
  return Math.max(0, Math.trunc(secondsBetween(end, start) - covered));
}

/**
 * Les séances de l'horaire qui comptent (amphi, et exercices si choisi), moins ce que recouvrent
 * les chronos comptés — de n'importe quel cours ; la même séance lue deux fois ne compte qu'une fois.
 */
export function lectureBlocks(events: LinkedCalendarEvent[], sessions: StudySession[], counting: Counting = readCounting(), now = new Date()): Block[] {
  const timers = sessions.filter((s) => !s.isFromAnki && countsSession(counting, s)).map((s) => ({
    start: s.startedAt,
    end: new Date(s.startedAt.getTime() + s.durationSeconds * 1000),
  }));
  const seen = new Set<string>();
  const result: Block[] = [];
  for (const event of [...events].sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime())) {
    if (!countsEvent(counting, event, now)) continue;
    const key = `${event.course?.id ?? event.title}|${event.startsAt.getTime()}|${event.endsAt.getTime()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    // Une séance pas encore finie (« J'y suis ») ne compte que jusqu'à maintenant.
    const end = new Date(Math.min(event.endsAt.getTime(), Math.max(event.startsAt.getTime(), now.getTime())));
    const seconds = lectureSeconds(event.startsAt, end, timers);
    if (seconds <= 0) continue;
    result.push({ start: event.startsAt, seconds, courseCode: event.course?.code ?? null, taskType: event.kind === "lecture" ? "lecture" : "exercise" });
  }
  return result;
}

/** Tout ce qui compte : les sessions choisies (chrono, saisies, Anki), puis les séances. */
export function blocks(events: LinkedCalendarEvent[], sessions: StudySession[], counting: Counting = readCounting(), now = new Date()): Block[] {
  return sessions.filter((session) => countsSession(counting, session)).map((session) => ({
    start: session.startedAt,
    seconds: session.durationSeconds,
    courseCode: session.course?.code ?? null,
    taskType: session.taskTypeRaw,
  })).concat(lectureBlocks(events, sessions, counting, now));
}

/** Tout ce qui compte entre deux dates, lu dans le magasin (mêmes prédicats qu'en Swift). */
export function blocksIn(store: ModelStore, from: Date, to: Date): Block[] {
  const sessions = store.fetch(StudySession).filter((session) => session.startedAt >= from && session.startedAt < to);
  const events = store.fetch(LinkedCalendarEvent).filter((event) => event.startsAt >= from && event.startsAt < to);
  return blocks(events, sessions);
}

/** Le temps compté entre deux dates. */
export function secondsIn(store: ModelStore, from: Date, to: Date): number {
  return total(blocksIn(store, from, to));
}

/** Le temps compté aujourd'hui. */
export function today(store: ModelStore, now: Date = new Date()): number {
  const start = DateUtils.startOfDay(now);
  return secondsIn(store, start, DateUtils.addDays(1, start));
}

/** Le temps compté cette semaine (lundi → dimanche). */
export function thisWeek(store: ModelStore, now: Date = new Date()): number {
  const start = DateUtils.startOfWeek(now);
  return secondsIn(store, start, DateUtils.addDays(7, start));
}

/** La somme des secondes de ces blocs. */
export function total(entries: Block[]): number {
  return entries.reduce((sum, block) => sum + block.seconds, 0);
}

/** Les secondes par jour d'une semaine (lundi = 0). */
export function days(of: Block[], weekStart: Date): number[] {
  const result = Array.from({ length: 7 }, () => 0);
  for (const block of of) {
    const index = DateUtils.daysBetween(weekStart, block.start);
    if (index >= 0 && index < 7 && block.start >= weekStart) result[index] += block.seconds;
  }
  return result;
}

export const StudyTime = {
  longestLecture,
  lectureSeconds,
  lectureBlocks,
  blocks,
  blocksIn,
  secondsIn,
  today,
  thisWeek,
  total,
  days,
};
