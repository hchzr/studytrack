// L'état que la fenêtre principale envoie au chrono flottant, et ce que celui-ci
// en déduit seconde après seconde. Fonctions pures : la fenêtre flottante n'a
// ni base de données ni contrôleur, juste ce message et une horloge.

import { elapsed, cycleOr } from "../domain/focusTimerState.ts";
import { currentBreak, cycleElapsed, settingsBlockDuration, type PomodoroSettings } from "../domain/pomodoroEngine.ts";
import { StudyMode } from "../domain/studyMode.ts";
import type { FocusTimerState } from "../domain/focusTimerState.ts";
import type { Course } from "../models/course.ts";
import { TaskType } from "../models/enums.ts";
import {
  displaySecondsOf, headlineOf, phaseOf, statusLabelOf, tintOf,
} from "../ui/screens/focus/timerView.ts";

export interface MiniState {
  /** Une session existe (sinon la fenêtre est cachée). */
  active: boolean;
  phase: "working" | "paused" | "break" | "ready";
  /** Le temps avance (travail ou pause décomptée). */
  running: boolean;
  /** L'horloge décompte (Pomodoro, pause) au lieu de compter. */
  countdown: boolean;
  /** Secondes affichées à `sentAt`. */
  seconds: number;
  sentAt: number;
  /** L'anneau : où l'on en est dans le bloc / la pause, et sa longueur. */
  ringValue: number;
  ringLength: number;
  studying: boolean;
  /** Fin du mode étude (ms) ; `null` : sans fin. */
  studyUntil: number | null;
  status: string | null;
  what: string;
  courseCode: string | null;
  tint: string;
}

export const inactiveMini: MiniState = {
  active: false, phase: "paused", running: false, countdown: false, seconds: 0, sentAt: 0,
  ringValue: 0, ringLength: 1, studying: false, studyUntil: null, status: null, what: "",
  courseCode: null, tint: "var(--ink)",
};

const clamp01 = (value: number) => Math.min(1, Math.max(0, value));

export function buildMiniState(
  state: FocusTimerState | null,
  settings: PomodoroSettings,
  course: Course | null,
  now: Date,
): MiniState {
  if (!state) return { ...inactiveMini, sentAt: now.getTime() };
  const phase = phaseOf(state, settings, now);
  const pause = currentBreak(state);
  const cycle = cycleOr(state, settings);
  let ringValue: number;
  let ringLength: number;
  if (pause) {
    ringLength = Math.max(1, (pause.endsAt.getTime() - pause.startedAt.getTime()) / 1000);
    ringValue = (now.getTime() - pause.startedAt.getTime()) / 1000;
  } else if (phase.type === "readyForBlock") {
    ringLength = 1;
    ringValue = 1;
  } else {
    ringLength = state.pomodoro ? settingsBlockDuration(cycle) : 3600;
    ringValue = (state.pomodoro ? cycleElapsed(state, now) : elapsed(state, now)) % ringLength;
  }
  const studying = StudyMode.isActive(state, now);
  const open = StudyMode.isOpenEnded(state);
  const kind = pause ? "break" : phase.type === "readyForBlock" ? "ready" : state.runningSince ? "working" : "paused";
  return {
    active: true,
    phase: kind,
    running: kind === "working" || kind === "break",
    countdown: pause !== null || state.pomodoro,
    seconds: displaySecondsOf(state, settings, now),
    sentAt: now.getTime(),
    ringValue,
    ringLength,
    studying,
    studyUntil: studying && !open && state.studyUntil ? state.studyUntil.getTime() : null,
    status: statusLabelOf(state, settings, now),
    what: headlineOf(course, state.taskTypeRaw as TaskType, state.targetID),
    courseCode: course ? course.displayCode : null,
    tint: tintOf(course),
  };
}

/** Les secondes à afficher à `nowMs` (décompte arrondi au-dessus, comme le cadran). */
export function miniSeconds(state: MiniState, nowMs: number): number {
  const delta = state.running ? Math.max(0, (nowMs - state.sentAt) / 1000) : 0;
  return state.countdown ? Math.max(0, Math.ceil(state.seconds - delta)) : Math.max(0, Math.trunc(state.seconds + delta));
}

export function miniProgress(state: MiniState, nowMs: number): number {
  const delta = state.running ? Math.max(0, (nowMs - state.sentAt) / 1000) : 0;
  return clamp01((state.ringValue + delta) / state.ringLength);
}

/** La ligne sous l'horloge (MiniTimerView.subtitle). */
export function miniSubtitle(state: MiniState, nowMs: number): string {
  if (state.studying) {
    if (state.studyUntil === null) return "Mode étude";
    const left = Math.ceil((state.studyUntil - nowMs) / 60_000);
    return left > 0 ? `Mode étude · reste ${left} min` : "Mode étude · temps écoulé";
  }
  if (state.status) return `${state.status} · ${state.what}`;
  return state.courseCode ? `${state.courseCode} · ${state.what}` : state.what;
}

/** Message de la fenêtre flottante vers la principale. */
export type MiniCommand = "toggle" | "finish" | "hide" | "open";
