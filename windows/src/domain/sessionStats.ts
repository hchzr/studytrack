// Agrégats de sessions pour l'historique et les graphiques
// (Polymestre/Domain/SessionStats.swift) : fonctions pures.

import type { StudySession } from "../models/studySession.ts";

/** Total par jour ; chaque jour est présent, même à zéro. */
export class DayTotal {
  day: Date;
  seconds: number;

  constructor(dayOrInit: Date | { day: Date; seconds: number }, seconds = 0) {
    if (dayOrInit instanceof Date) {
      this.day = dayOrInit;
      this.seconds = seconds;
    } else {
      this.day = dayOrInit.day;
      this.seconds = dayOrInit.seconds;
    }
  }

  get id(): Date { return this.day; }
  get isEmpty(): boolean { return this.seconds === 0; }
}

/** Sessions regroupées par jour, le plus récent d'abord. */
export class DayGroup {
  day: Date;
  sessions: StudySession[];

  constructor(dayOrInit: Date | { day: Date; sessions: StudySession[] }, sessions: StudySession[] = []) {
    if (dayOrInit instanceof Date) {
      this.day = dayOrInit;
      this.sessions = sessions;
    } else {
      this.day = dayOrInit.day;
      this.sessions = dayOrInit.sessions;
    }
  }

  get id(): Date { return this.day; }
  get totalSeconds(): number { return this.sessions.reduce((sum, session) => sum + session.durationSeconds, 0); }
}

const startOfDay = (date: Date): Date => new Date(date.getFullYear(), date.getMonth(), date.getDate());

/** Total par jour sur les `days` derniers jours, le plus ancien en premier. */
export function dailyTotals(sessions: StudySession[], days: number, endingAt: Date = new Date()): DayTotal[] {
  const today = startOfDay(endingAt);
  const buckets = new Map<number, number>();
  for (const session of sessions) {
    const day = startOfDay(session.startedAt);
    buckets.set(day.getTime(), (buckets.get(day.getTime()) ?? 0) + session.durationSeconds);
  }
  const result: DayTotal[] = [];
  const count = Math.max(days, 1);
  // `(0..<count).reversed()` : du plus ancien au plus récent.
  for (let offset = count - 1; offset >= 0; offset--) {
    const day = new Date(today.getFullYear(), today.getMonth(), today.getDate() - offset);
    result.push(new DayTotal(day, buckets.get(day.getTime()) ?? 0));
  }
  return result;
}

/** Sessions regroupées par jour, le plus récent d'abord, chaque jour trié du plus récent au plus ancien. */
export function groupedByDay(sessions: StudySession[]): DayGroup[] {
  const grouped = new Map<number, { day: Date; sessions: StudySession[] }>();
  for (const session of sessions) {
    const day = startOfDay(session.startedAt);
    const entry = grouped.get(day.getTime()) ?? { day, sessions: [] };
    entry.sessions.push(session);
    grouped.set(day.getTime(), entry);
  }
  return [...grouped.values()]
    .sort((a, b) => b.day.getTime() - a.day.getTime())
    .map((entry) => new DayGroup(entry.day, [...entry.sessions].sort((a, b) => b.startedAt.getTime() - a.startedAt.getTime())));
}

export const SessionStats = { DayTotal, DayGroup, dailyTotals, groupedByDay };
