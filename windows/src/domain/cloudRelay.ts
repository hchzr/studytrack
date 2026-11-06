// Ce que les appareils se disent **vite** (Polymestre/Domain/CloudRelay.swift).
//
// La base synchronise les données en quelques secondes à quelques minutes. Le
// chrono, lui, ne peut pas attendre : démarré sur le Mac, il doit tourner sur
// l'iPhone. Les décisions sont ici, pures et testées ; le magasin clé-valeur
// d'iCloud et la voie instantanée sont de l'hôte.
//
// Ce fichier ne garde que l'état partagé minimal (la session que l'autre appareil
// connaît, le dernier instantané publié) ; les `NSUbiquitousKeyValueStore`,
// `UserDefaults` et notifications sont hors du domaine.

import type { FocusTimerState } from "./focusTimerState.ts";
import { isRestorable, isRunning } from "./focusTimerState.ts";

/** Instantané publié par un appareil : l'état du chrono, ou la session terminée. */
export interface TimerSnapshotInit {
  state?: FocusTimerState | null;
  endedSession?: Date | null;
  updatedAt: Date;
  device: string;
  /** Les dernières sessions fermées (les plus récentes) ; `null` : pas envoyées. */
  endedSessions?: Date[] | null;
}

export class TimerSnapshot {
  state: FocusTimerState | null;
  endedSession: Date | null;
  updatedAt: Date;
  device: string;
  endedSessions: Date[] | null;

  constructor(o: TimerSnapshotInit) {
    this.state = o.state ?? null;
    this.endedSession = o.endedSession ?? null;
    this.updatedAt = o.updatedAt;
    this.device = o.device;
    this.endedSessions = o.endedSessions ?? null;
  }

  /** Cette session fait-elle partie de celles que l'appareil a fermées ? */
  ended(session: Date): boolean {
    const list = [...(this.endedSession ? [this.endedSession] : []), ...(this.endedSessions ?? [])];
    return list.some((date) => Math.abs((date.getTime() - session.getTime()) / 1000) < 1);
  }
}

export type TimerDecision =
  | { kind: "ignore" }
  | { kind: "adopt"; state: FocusTimerState }
  /** La session a été terminée (et enregistrée) ailleurs. */
  | { kind: "close" };

export const ignore: TimerDecision = { kind: "ignore" };
export const close: TimerDecision = { kind: "close" };
export const adopt = (state: FocusTimerState): TimerDecision => ({ kind: "adopt", state });

const secondsBetween = (later: Date, earlier: Date) => (later.getTime() - earlier.getTime()) / 1000;

function same(a: Date | null | undefined, b: Date): boolean {
  return a !== null && a !== undefined && Math.abs(secondsBetween(a, b)) < 1;
}

/** Égalité d'état (`FocusTimerState` est `Equatable`) : dates à la milliseconde, champs absents = nil. */
function normalize(value: unknown): unknown {
  if (value === undefined) return null;
  if (value instanceof Date) return value.getTime();
  if (Array.isArray(value)) return value.map(normalize);
  if (value !== null && typeof value === "object") {
    const object = value as Record<string, unknown>;
    const result: Record<string, unknown> = {};
    for (const key of Object.keys(object).sort()) {
      if (object[key] === undefined) continue;
      result[key] = normalize(object[key]);
    }
    return result;
  }
  return value;
}

export function sameState(a: FocusTimerState | null | undefined, b: FocusTimerState | null | undefined): boolean {
  return JSON.stringify(normalize(a ?? null)) === JSON.stringify(normalize(b ?? null));
}

/**
 * Que faire d'un état venu d'un autre appareil ?
 *
 * Une **même** session (même début) suit l'appareil qui a agi en dernier. Deux
 * sessions **différentes** ne s'écrasent jamais. Une **nouvelle** session venue
 * d'ailleurs remplace la mienne quand l'autre appareil l'a fermée — on le sait
 * par `endedSession`, ou parce que ma session était **partagée**.
 */
export function decide(
  local: FocusTimerState | null,
  remote: TimerSnapshot | TimerSnapshotInit,
  lastApplied: Date | null,
  device: string,
  shared: Date | null = null,
  now: Date = new Date(),
): TimerDecision {
  const snapshot = remote instanceof TimerSnapshot ? remote : new TimerSnapshot(remote);
  const mine = local ?? null;
  if (snapshot.device === device) return ignore;
  if (lastApplied !== null && !(snapshot.updatedAt > lastApplied)) return ignore;
  if (mine === null && snapshot.state === null) return ignore;
  if (mine === null && snapshot.state !== null) {
    return isRestorable(snapshot.state, now) || isRunning(snapshot.state) ? adopt(snapshot.state) : ignore;
  }
  if (mine !== null && snapshot.state === null) {
    return snapshot.ended(mine.sessionStartedAt) ? close : ignore;
  }
  if (mine !== null && snapshot.state !== null) {
    const theirs = snapshot.state;
    if (same(mine.sessionStartedAt, theirs.sessionStartedAt)) {
      return sameState(mine, theirs) ? ignore : adopt(theirs);
    }
    const closedThere = snapshot.ended(mine.sessionStartedAt)
      || (same(shared, mine.sessionStartedAt) && theirs.sessionStartedAt > mine.sessionStartedAt);
    if (!closedThere) return ignore;
    if (!(isRestorable(theirs, now) || isRunning(theirs))) return ignore;
    return adopt(theirs);
  }
  return ignore;
}

// MARK: La session partagée (état minimal, à la place de `UserDefaults`)

let sharedSessionValue: Date | null = null;

/** La session que l'autre appareil connaît (dont il a publié un état). */
export function sharedSession(): Date | null { return sharedSessionValue; }
export function setSharedSession(value: Date | null): void { sharedSessionValue = value; }

/** Retient qu'une session est partagée : une session adoptée l'est par définition. */
export function noteAdopted(state: FocusTimerState): void {
  sharedSessionValue = state.sessionStartedAt;
}

export function noteShared(local: FocusTimerState | null, remote: TimerSnapshot | TimerSnapshotInit, device: string): void {
  const snapshot = remote instanceof TimerSnapshot ? remote : new TimerSnapshot(remote);
  if (!local || snapshot.device === device || !snapshot.state) return;
  if (same(snapshot.state.sessionStartedAt, local.sessionStartedAt)) sharedSessionValue = local.sessionStartedAt;
}

// MARK: Le plus récent des autres appareils

/** Le plus récent des autres appareils (pur, testé). */
export function newest(snapshots: TimerSnapshot[], excluding: string): TimerSnapshot | null {
  let result: TimerSnapshot | null = null;
  for (const snapshot of snapshots) {
    if (snapshot.device === excluding) continue;
    if (result === null || snapshot.updatedAt > result.updatedAt) result = snapshot;
  }
  return result;
}

// MARK: Moodle : un seul appareil relit

export interface RefreshClaim {
  at: Date;
  device: string;
}

/** La relecture est-elle à faire **ici** ? */
export function refreshIsDue(
  localLast: Date | null,
  claim: RefreshClaim | null,
  device: string,
  interval: number,
  now: Date = new Date(),
): boolean {
  if (localLast !== null && now.getTime() - localLast.getTime() < interval * 1000) return false;
  if (claim !== null && claim.device !== device && now.getTime() - claim.at.getTime() < interval * 1000) return false;
  return true;
}

// MARK: Moodle : ce qui a déjà été vu

/** L'union des activités vues, cours par cours, triée. */
export function mergeKnown(a: Record<string, string[]>, b: Record<string, string[]>): Record<string, string[]> {
  const merged: Record<string, string[]> = {};
  for (const [course, ids] of Object.entries(a)) merged[course] = [...ids];
  for (const [course, ids] of Object.entries(b)) {
    merged[course] = [...new Set([...(merged[course] ?? []), ...ids])].sort();
  }
  return merged;
}

export const CloudRelay = {
  TimerSnapshot,
  ignore,
  close,
  adopt,
  sameState,
  decide,
  sharedSession,
  setSharedSession,
  noteAdopted,
  noteShared,
  newest,
  refreshIsDue,
  mergeKnown,
};
