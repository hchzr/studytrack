import { durationLabel } from "./dateUtils.ts";
import {
  start,
  elapsed,
  type FocusTimerState,
} from "./focusTimerState.ts";

/** `date.addingTimeInterval(seconds)`, à la milliseconde (un `Date` JS n'a pas mieux). */
const adding = (date: Date, seconds: number) => new Date(Math.round(date.getTime() + seconds * 1000));

/** Où en est la session dans sa structure Pomodoro.
 *
 * Le chrono compte le **travail** : une pause n'est pas du temps compté. La
 * structure se déduit donc du temps écoulé, elle ne le découpe pas. C'est ce qui
 * permet d'afficher « bloc 3, encore 12 min » sans tenir un second compteur qui
 * divergerait du premier.
 */
export interface PomodoroStatus {
  /** Bloc en cours, à partir de 1. */
  blockNumber: number;
  /** Temps écoulé dans le bloc en cours. */
  elapsedInBlock: number;
  /** Temps restant avant la pause conseillée. */
  remaining: number;
  /** Blocs entièrement terminés. */
  completedBlocks: number;
}

export function statusProgress(status: PomodoroStatus): number {
  const total = status.elapsedInBlock + status.remaining;
  if (!(total > 0)) return 0;
  return Math.min(1, Math.max(0, status.elapsedInBlock / total));
}

/** Le bloc est fini : c'est le moment de proposer la pause. */
export function statusIsBlockComplete(status: PomodoroStatus): boolean {
  return status.remaining <= 0;
}

/** « Bloc 3 ». */
export function statusLabel(status: PomodoroStatus): string {
  return `Bloc ${status.blockNumber}`;
}

export function statusRemainingLabel(status: PomodoroStatus): string {
  return statusIsBlockComplete(status)
    ? "bloc terminé"
    : `reste ${durationLabel(Math.ceil(status.remaining))}`;
}

/** Découpe une durée de travail en blocs Pomodoro. */
export const PomodoroEngine = {
  /** Durée d'un bloc, bornée à des valeurs utilisables.
   *
   * Un bloc de 0 minute rendrait `remaining` constamment nul et la boucle
   * d'alerte se déclencherait sans fin ; une durée négative n'a pas de sens.
   */
  blockDuration(minutes: number): number {
    return Math.max(1, minutes) * 60;
  },

  /** Où en est-on après `elapsed` secondes de travail compté ? `origin` : le travail déjà
   * compté quand le cycle a commencé (Pomodoro allumé en cours de séance). */
  status(elapsedSeconds: number, focusMinutes: number, origin = 0): PomodoroStatus {
    const block = PomodoroEngine.blockDuration(focusMinutes);
    const safeElapsed = Math.max(0, elapsedSeconds - origin);
    const completed = Math.trunc(safeElapsed / block);
    const inBlock = safeElapsed - completed * block;

    // Un bloc exactement terminé (60 min pour un bloc de 60) compte comme fini,
    // pas comme le début du suivant : sinon la pause conseillée n'apparaîtrait
    // jamais à l'instant précis où elle est due.
    if (inBlock === 0 && completed > 0) {
      return { blockNumber: completed, elapsedInBlock: block, remaining: 0, completedBlocks: completed };
    }
    return {
      blockNumber: completed + 1,
      elapsedInBlock: inBlock,
      remaining: Math.max(0, block - inBlock),
      completedBlocks: completed,
    };
  },
};

// MARK: - Le cycle : travail, pause, travail

export type PomodoroBreak = "short" | "long";

export function breakLabel(kind: PomodoroBreak): string {
  return kind === "long" ? "Pause longue" : "Pause";
}

/** Ce que dure chaque temps du cycle, lu dans les réglages. */
export interface PomodoroSettings {
  focusMinutes: number;
  shortBreakMinutes: number;
  longBreakMinutes: number;
  /** Une pause longue tous les `longBreakEvery` blocs. */
  longBreakEvery: number;
  /** À la fin d'une pause, le bloc suivant démarre-t-il seul ?
   *
   * Non par défaut : revenir à sa table est un geste, et un chrono qui
   * repartirait pendant qu'on est encore à la machine à café compterait du
   * travail qui n'a pas eu lieu.
   */
  autoStartFocus: boolean;
}

export function makePomodoroSettings(partial: Partial<PomodoroSettings> = {}): PomodoroSettings {
  return {
    focusMinutes: 25,
    shortBreakMinutes: 5,
    longBreakMinutes: 15,
    longBreakEvery: 4,
    autoStartFocus: false,
    ...partial,
  };
}

export function settingsBlockDuration(settings: PomodoroSettings): number {
  return PomodoroEngine.blockDuration(settings.focusMinutes);
}

export function breakDuration(settings: PomodoroSettings, kind: PomodoroBreak): number {
  return Math.max(1, kind === "long" ? settings.longBreakMinutes : settings.shortBreakMinutes) * 60;
}

/** La pause qui suit le bloc numéro `completedBlocks`. */
export function breakKindAfterBlock(settings: PomodoroSettings, completedBlocks: number): PomodoroBreak {
  const every = Math.max(2, settings.longBreakEvery);
  return completedBlocks > 0 && completedBlocks % every === 0 ? "long" : "short";
}

/** Ce qui vient de se passer dans le cycle — pour l'haptique et le journal. */
export type PomodoroEvent =
  /** Un bloc de travail vient de finir ; la pause démarre. */
  | { type: "blockEnded"; block: number; kind: PomodoroBreak }
  /** La pause est finie ; le bloc suivant attend (ou démarre, si réglé ainsi). */
  | { type: "breakEnded"; nextBlock: number };

/** Où en est une session, du point de vue de ce qu'il faut afficher.
 *
 * Déduit de l'état persisté, jamais stocké : il ne peut pas diverger.
 */
export type FocusPhase =
  /** Rien n'a encore été compté. */
  | { type: "idle" }
  /** Le travail est compté. */
  | { type: "working" }
  /** Le travail est suspendu, en dehors de toute pause Pomodoro. */
  | { type: "paused" }
  /** Une pause Pomodoro décompte jusqu'à `endsAt`. */
  | { type: "onBreak"; kind: PomodoroBreak; startedAt: Date; endsAt: Date }
  /** La pause est finie : le bloc suivant attend un geste. */
  | { type: "readyForBlock"; block: number };

export function phaseIsBreak(phase: FocusPhase): boolean {
  return phase.type === "onBreak";
}

// MARK: - Extension de FocusTimerState

/** La pause en cours, s'il y en a une. */
export function currentBreak(
  state: FocusTimerState,
): { kind: PomodoroBreak; startedAt: Date; endsAt: Date } | null {
  const raw = state.breakKindRaw;
  if ((raw !== "short" && raw !== "long") || !state.breakStartedAt || !state.breakEndsAt) return null;
  return { kind: raw, startedAt: state.breakStartedAt, endsAt: state.breakEndsAt };
}

/** La phase à afficher à l'instant `now`, **après** `advance`. */
export function phase(state: FocusTimerState, settings: PomodoroSettings, now: Date = new Date()): FocusPhase {
  const current = currentBreak(state);
  if (current) {
    return { type: "onBreak", kind: current.kind, startedAt: current.startedAt, endsAt: current.endsAt };
  }
  if (state.runningSince) return { type: "working" };
  const total = elapsed(state, now);
  if (!(total >= 1)) return { type: "idle" };
  if (state.pomodoro) {
    const block = settingsBlockDuration(settings);
    const relative = Math.max(0, total - cycleOriginSeconds(state));
    const completed = Math.floor(relative / block);
    // Pile sur une frontière de bloc, à l'arrêt : c'est la fin d'une pause.
    if (completed > 0 && Math.abs(relative - completed * block) < 0.5) {
      return { type: "readyForBlock", block: completed + 1 };
    }
  }
  return { type: "paused" };
}

/** Fait avancer le cycle jusqu'à `now` (en place), et dit ce qui s'est passé.
 *
 * **Tout se déduit des dates.** Une app fermée pendant la fin d'un bloc ne
 * rate rien : au retour, on retrouve l'instant exact où le bloc a fini, le
 * travail est coupé **à cet instant** — les minutes passées en pause ne sont
 * pas comptées comme du travail — et la pause a commencé là.
 *
 * Hors Pomodoro, la fonction ne fait rien.
 */
export function advance(state: FocusTimerState, settings: PomodoroSettings, now: Date = new Date()): PomodoroEvent[] {
  if (!state.pomodoro) {
    clearBreak(state);
    return [];
  }
  const events: PomodoroEvent[] = [];
  const block = settingsBlockDuration(settings);
  // Borne de sécurité : une session ne compte jamais des centaines de
  // cycles, mais une date corrompue ne doit pas faire boucler l'app.
  for (let i = 0; i < 64; i++) {
    const current = currentBreak(state);
    if (current) {
      if (!(now.getTime() >= current.endsAt.getTime())) break;
      clearBreak(state);
      const next = Math.floor(cycleAccumulated(state) / block) + 1;
      events.push({ type: "breakEnded", nextBlock: next });
      if (settings.autoStartFocus) {
        state.runningSince = current.endsAt;
        continue;
      }
      break;
    }
    const since = state.runningSince;
    if (!since) break;
    const relative = cycleAccumulated(state);
    const nextBoundary = (Math.floor(relative / block) + 1) * block;
    const boundaryDate = adding(since, nextBoundary - relative);
    if (!(now.getTime() >= boundaryDate.getTime())) break;
    state.accumulated = cycleOriginSeconds(state) + nextBoundary;
    state.runningSince = undefined;
    const completed = Math.round(nextBoundary / block);
    const kind = breakKindAfterBlock(settings, completed);
    state.breakKindRaw = kind;
    state.breakStartedAt = boundaryDate;
    state.breakEndsAt = adding(boundaryDate, breakDuration(settings, kind));
    events.push({ type: "blockEnded", block: completed, kind });
  }
  return events;
}

/** Termine la pause maintenant et relance le travail. */
export function skipBreak(state: FocusTimerState, now: Date = new Date()): void {
  if (currentBreak(state) === null) return;
  clearBreak(state);
  start(state, now);
}

/** Allonge la pause en cours. */
export function extendBreak(state: FocusTimerState, seconds: number): void {
  if (!state.breakEndsAt) return;
  state.breakEndsAt = adding(state.breakEndsAt, seconds);
}

export function clearBreak(state: FocusTimerState): void {
  state.breakKindRaw = undefined;
  state.breakStartedAt = undefined;
  state.breakEndsAt = undefined;
}

/** Quand le bloc en cours finira, si le travail est compté. */
export function blockEndDate(state: FocusTimerState, settings: PomodoroSettings): Date | null {
  const since = state.runningSince;
  if (!state.pomodoro || !since) return null;
  const block = settingsBlockDuration(settings);
  const relative = cycleAccumulated(state);
  const nextBoundary = (Math.floor(relative / block) + 1) * block;
  return adding(since, nextBoundary - relative);
}

// MARK: Le cycle compté depuis son début

/** Le travail compté à l'entrée du cycle (voir `cycleOrigin`). */
export function cycleOriginSeconds(state: FocusTimerState): number {
  return state.cycleOrigin ?? 0;
}

/** Le travail arrêté **dans le cycle** : ce que `accumulated` valait depuis son début. */
export function cycleAccumulated(state: FocusTimerState): number {
  return Math.max(0, state.accumulated - cycleOriginSeconds(state));
}

/** Le travail compté dans le cycle à l'instant `now`. */
export function cycleElapsed(state: FocusTimerState, now: Date = new Date()): number {
  return Math.max(0, elapsed(state, now) - cycleOriginSeconds(state));
}

/** Allume ou coupe le Pomodoro **en cours de séance**. Allumé, le premier bloc part
 * de maintenant (le temps déjà travaillé n'est pas perdu : il reste compté, hors cycle) ;
 * coupé, la pause en cours s'arrête et le travail reprend. */
export function setPomodoro(state: FocusTimerState, enabled: boolean, now: Date = new Date()): void {
  if (enabled === state.pomodoro) return;
  if (enabled) {
    // Le temps qui court est mis dans le compte, pour que l'origine soit exacte.
    if (state.runningSince) {
      state.accumulated += Math.max(0, (now.getTime() - state.runningSince.getTime()) / 1000);
      state.runningSince = now;
    }
    state.cycleOrigin = state.accumulated;
  } else {
    const wasOnBreak = currentBreak(state) !== null;
    clearBreak(state);
    state.cycleOrigin = undefined;
    if (wasOnBreak) start(state, now);
  }
  state.pomodoro = enabled;
}
