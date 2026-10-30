// Le temps de travail **réel**, compté partout de la même façon
// (StudyTrack/Domain/StudyTime.swift) : les sessions (chrono, saisies, Anki)
// **plus** les cours suivis.
//
// La règle :
//   • une heure de cours (amphi) compte toute seule, une fois passée — sauf
//     marquée manquée ;
//   • une séance d'exercices ne compte jamais d'elle-même : seul le chrono
//     lancé pendant la séance compte ;
//   • un chrono lancé pendant un cours ne compte pas deux fois : la part du
//     cours qu'il recouvre est retirée du cours.

import { LinkedCalendarEvent } from "../models/linkedCalendarEvent.ts";
import { StudySession } from "../models/studySession.ts";
import type { ModelStore } from "../models/store.ts";
import { DateUtils } from "./dateUtils.ts";

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

/** Les cours qui comptent, à partir de l'horaire et des sessions. */
export function lectureBlocks(events: LinkedCalendarEvent[], sessions: StudySession[]): Block[] {
  const byCourse = new Map<string, StudySession[]>();
  for (const session of sessions) {
    const course = session.course;
    if (!course) continue;
    const list = byCourse.get(course.id) ?? [];
    list.push(session);
    byCourse.set(course.id, list);
  }
  const result: Block[] = [];
  for (const event of events) {
    if (!event.countsAsAttendedLecture) continue;
    const own = (event.course ? byCourse.get(event.course.id) ?? [] : []).map((session) => ({
      start: session.startedAt,
      end: new Date(session.startedAt.getTime() + session.durationSeconds * 1000),
    }));
    const seconds = lectureSeconds(event.startsAt, event.endsAt, own);
    if (seconds <= 0) continue;
    result.push({
      start: event.startsAt,
      seconds,
      courseCode: event.course?.code ?? null,
      taskType: "lecture",
    });
  }
  return result;
}

/** Tout ce qui compte : les sessions (chrono, saisies, Anki), puis les cours. */
export function blocks(events: LinkedCalendarEvent[], sessions: StudySession[]): Block[] {
  return sessions.map((session) => ({
    start: session.startedAt,
    seconds: session.durationSeconds,
    courseCode: session.course?.code ?? null,
    taskType: session.taskTypeRaw,
  })).concat(lectureBlocks(events, sessions));
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
