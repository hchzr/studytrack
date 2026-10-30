// Ce que le cadran du chrono montre, déduit de l'état et de l'heure — les
// mêmes règles que `MacTimer` (ringProgress, displayTime, statusLabel) et
// `MacFocusView`/`MacTargets` pour les libellés.
//
// Fonctions pures : l'écran peut les appeler à chaque battement sans rien
// stocker, et les tests n'ont pas besoin de React.

import type { Course } from "../../../models/course.ts";
import type { Exercise } from "../../../models/exercise.ts";
import { TaskType, TheoryKind } from "../../../models/enums.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import { FocusTargets } from "../../../domain/focusTargets.ts";
import {
  cycleOr,
  elapsed,
  type FocusTimerState,
} from "../../../domain/focusTimerState.ts";
import {
  PomodoroEngine,
  breakLabel,
  currentBreak,
  cycleElapsed,
  phase,
  settingsBlockDuration,
  type FocusPhase,
  type PomodoroSettings,
  type PomodoroStatus,
} from "../../../domain/pomodoroEngine.ts";
import { TimerText } from "../../../domain/timerText.ts";

const clamp01 = (value: number) => Math.min(1, Math.max(0, value));

// MARK: - Phase et anneau

/** La phase fine : un bloc prêt après une pause se distingue d'une pause simple. */
export function phaseOf(state: FocusTimerState | null, settings: PomodoroSettings, now: Date): FocusPhase {
  if (!state) return { type: "idle" };
  return phase(state, cycleOr(state, settings), now);
}

/** Où en est le cycle (bloc, restant, blocs finis) ; `null` hors Pomodoro. */
export function pomodoroStatusOf(
  state: FocusTimerState | null,
  settings: PomodoroSettings,
  now: Date,
): PomodoroStatus | null {
  if (!state || !state.pomodoro) return null;
  return PomodoroEngine.status(elapsed(state, now), cycleOr(state, settings).focusMinutes, state.cycleOrigin ?? 0);
}

/** Ce que dessine l'anneau : le bloc, la pause, ou l'heure entamée en session libre. */
export function ringProgressOf(
  state: FocusTimerState | null,
  settings: PomodoroSettings,
  now: Date,
): { progress: number; draining: boolean } {
  if (!state) return { progress: 0, draining: false };
  const pause = currentBreak(state);
  if (pause) {
    const total = (pause.endsAt.getTime() - pause.startedAt.getTime()) / 1000;
    const left = (pause.endsAt.getTime() - now.getTime()) / 1000;
    return { progress: total > 0 ? clamp01(1 - left / total) : 0, draining: true };
  }
  if (phaseOf(state, settings, now).type === "readyForBlock") return { progress: 1, draining: false };
  const cycle = cycleOr(state, settings);
  const block = state.pomodoro ? settingsBlockDuration(cycle) : 3600;
  const counted = state.pomodoro ? cycleElapsed(state, now) : elapsed(state, now);
  return { progress: block > 0 ? clamp01((counted % block) / block) : 0, draining: false };
}

// MARK: - Le temps affiché

/** Secondes affichées : le temps compté, ce qui reste du bloc ou de la pause. */
export function displaySecondsOf(
  state: FocusTimerState | null,
  settings: PomodoroSettings,
  now: Date,
): number {
  if (!state) return 0;
  const pause = currentBreak(state);
  // Comptes à rebours arrondis au-dessus, comme sur l'iPhone : « 25:00 » au
  // départ, « 00:01 » à la dernière seconde (sinon une seconde d'écart).
  if (pause) return Math.max(0, Math.ceil((pause.endsAt.getTime() - now.getTime()) / 1000));
  if (state.pomodoro) {
    const block = settingsBlockDuration(cycleOr(state, settings));
    const into = cycleElapsed(state, now) % block;
    return Math.max(0, Math.ceil(block - into));
  }
  return elapsed(state, now);
}

/** « 07:42 », « 1:02:09 ». */
export function displayClockOf(state: FocusTimerState | null, settings: PomodoroSettings, now: Date): string {
  return TimerText.clock(displaySecondsOf(state, settings, now));
}

/** Au repos, le cadran montre la durée du premier bloc ou zéro. */
export function idleClockOf(pomodoro: boolean, settings: PomodoroSettings): string {
  return pomodoro ? TimerText.clock(settingsBlockDuration(settings)) : "00:00";
}

// MARK: - Les mots du cadran

/** « Pause longue », « Bloc 3 prêt », « Bloc 2 », « En pause ». */
export function statusLabelOf(
  state: FocusTimerState | null,
  settings: PomodoroSettings,
  now: Date,
): string | null {
  if (!state) return null;
  const pause = currentBreak(state);
  if (pause) return breakLabel(pause.kind);
  const current = phaseOf(state, settings, now);
  if (current.type === "readyForBlock") return `Bloc ${current.block} prêt`;
  if (!state.runningSince) return "En pause";
  if (state.pomodoro) {
    const block = settingsBlockDuration(cycleOr(state, settings));
    return `Bloc ${Math.trunc(cycleElapsed(state, now) / block) + 1}`;
  }
  return null;
}

/** La ligne au-dessus de l'horloge (MacFocusView.statusLine). */
export function statusLineOf(
  state: FocusTimerState | null,
  settings: PomodoroSettings,
  now: Date,
  courseCode: string | null,
  pomodoro: boolean,
): string {
  if (!state) return pomodoro ? "Pomodoro" : "Prêt";
  if (state.runningSince) return statusLabelOf(state, settings, now) ?? courseCode ?? "En cours";
  return statusLabelOf(state, settings, now) ?? "En pause";
}

// MARK: - Cibles

/** « Série 3 · Ex 2 », « Théorie 4.2 » — le nom court d'une cible. */
export function targetLabel(course: Course | null, targetID: string | undefined): string | null {
  if (!course || !targetID) return null;
  const exercise = course.allExercises.find((candidate) => candidate.id === targetID);
  if (exercise) return exercise.displayNumber;
  const item = course.theoryItems.find((candidate) => candidate.id === targetID);
  if (!item) return null;
  if (item.title !== "") return item.title;
  return item.number !== "" ? `Théorie ${item.number}` : TheoryKind.label(item.kind);
}

/** Ce qu'on travaille, en une ligne : la cible, sinon le travail (MacTargets.headline). */
export function headlineOf(course: Course | null, taskType: TaskType, targetID: string | undefined): string {
  return targetLabel(course, targetID) ?? (course === null ? "Session libre" : TaskType.label(taskType));
}

/** La même, précédée du code du cours (MacFocusView.headline). */
export function courseHeadlineOf(course: Course | null, taskType: TaskType, targetID: string | undefined): string {
  const what = headlineOf(course, taskType, targetID);
  return course ? `${course.displayCode} · ${what}` : what;
}

/** La couleur du cours, ou l'encre pour une session libre. */
export function tintOf(course: Course | null): string {
  return course?.colorHex ?? "var(--ink)";
}

// MARK: - Ce que le menu de cible propose

export interface TargetOption {
  id: string;
  label: string;
}

export interface TargetOptions {
  upNext: TargetOption[];
  done: TargetOption[];
  /** Le sous-menu des cibles déjà faites : « Déjà faits » ou « Déjà vus ». */
  doneLabel: string;
}

/** Les cibles d'un cours pour ce travail (TargetMenu du Mac : 14 puis 24 / 20). */
export function targetOptionsFor(course: Course, taskType: TaskType): TargetOptions {
  const canonical = TaskType.canonical(taskType);
  if (canonical === "theory") {
    const ordered = FocusTargets.theory(course.sortedTheoryItems);
    return {
      upNext: ordered.upNext.slice(0, 14).map((item) => ({ id: item.id, label: targetLabel(course, item.id) ?? TheoryKind.label(item.kind) })),
      done: ordered.done.slice(-20).map((item) => ({ id: item.id, label: targetLabel(course, item.id) ?? TheoryKind.label(item.kind) })),
      doneLabel: "Déjà vus",
    };
  }
  if (canonical === "exercise" || canonical === "correction") {
    const ordered = FocusTargets.exercises(course.series, taskType);
    return {
      upNext: ordered.upNext.slice(0, 14).map((exercise) => ({ id: exercise.id, label: exercise.displayNumber })),
      done: ordered.done.slice(-24).map((exercise) => ({ id: exercise.id, label: exercise.displayNumber })),
      doneLabel: "Déjà faits",
    };
  }
  return { upNext: [], done: [], doneLabel: "Déjà faits" };
}

// MARK: - Ensuite

export interface UpNextItem {
  id: string;
  title: string;
  /** Le type à poser sur le chrono en passant à cette cible (comme UpNextList). */
  taskType: TaskType;
}

/**
 * Les cibles suivantes du cours, dans l'ordre où on les ferait. Pendant une
 * série, la suite vient d'abord (même série, après l'exercice courant).
 */
export function upNextOf(
  course: Course,
  taskType: TaskType,
  targetID: string | undefined,
  limit = 5,
): UpNextItem[] {
  const canonical = TaskType.canonical(taskType);
  if (canonical === "theory") {
    return FocusTargets.theory(course.sortedTheoryItems).upNext
      .filter((item) => item.id !== targetID)
      .slice(0, limit)
      .map((item) => ({ id: item.id, title: itemLabel(course, item), taskType: "theory" as TaskType }));
  }
  let pending: Exercise[] = FocusTargets.exercises(course.series, taskType).upNext
    .filter((exercise) => exercise.id !== targetID);
  const current = course.allExercises.find((exercise) => exercise.id === targetID);
  if (current?.series) {
    const series = current.series;
    const after = pending
      .filter((exercise) => exercise.series?.id === series.id && exercise.sortOrder > current.sortOrder)
      .sort((left, right) => left.sortOrder - right.sortOrder);
    const ids = new Set(after.map((exercise) => exercise.id));
    pending = after.concat(pending.filter((exercise) => !ids.has(exercise.id)));
  }
  const type: TaskType = canonical === "correction" ? "correction" : "exercise";
  return pending.slice(0, limit).map((exercise) => ({
    id: exercise.id,
    title: exercise.displayNumber,
    taskType: type,
  }));
}

function itemLabel(course: Course, item: TheoryItem): string {
  return targetLabel(course, item.id) ?? TheoryKind.label(item.kind);
}
