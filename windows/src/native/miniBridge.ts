// Côté fenêtre principale : le chrono flottant reflète `timerController`.
//
// Mécanisme (par événements, aucun battement) : à chaque changement du
// contrôleur, la principale émet « mini:state » ; la flottante y répond par des
// commandes « mini:command » (pause/reprise, terminer, masquer, ouvrir). Le
// menu du plateau émet « mini:toggle ». La flottante ne demande l'état qu'une
// fois, à son ouverture (« mini:request »).

import type { Course } from "../models/course.ts";
import { StudyMode } from "../domain/studyMode.ts";
import type { TimerSnapshot } from "../ui/timerController.ts";
import type { FocusTimerState } from "../domain/focusTimerState.ts";
import type { PomodoroSettings } from "../domain/pomodoroEngine.ts";
import { buildMiniState, type MiniCommand, type MiniState } from "./miniState.ts";
import { NATIVE_SETTINGS_EVENT, readFloatingTimer, writeFloatingTimer } from "./settings.ts";
import { callNative, inNative } from "./tauri.ts";

export const MINI_STATE = "mini:state";
export const MINI_COMMAND = "mini:command";
export const MINI_REQUEST = "mini:request";
export const MINI_TOGGLE = "mini:toggle";

/** Ce que le pont lit et commande sur le contrôleur. */
export interface MiniTimer {
  subscribe(listener: () => void): () => void;
  snapshot(): TimerSnapshot;
  toggle(): void;
  finish(): Promise<void>;
}

/**
 * Faut-il montrer la fenêtre flottante ? (MiniTimerPanel.update : réglage + une session.)
 * Elle sert quand on est **ailleurs** : tant que la fenêtre de Polymestre est devant, son
 * chrono est déjà à l'écran (mode étude, récapitulatif), la pilule par-dessus ne ferait que gêner.
 */
export function miniWanted(enabled: boolean, state: FocusTimerState | null, mainFocused = false): boolean {
  // Sous le verrou d'étude, rien ne doit flotter par-dessus l'écran de Polymestre.
  return enabled && state !== null && !mainFocused && !StudyMode.blocks(state);
}

export async function startMiniBridge(options: {
  timer: MiniTimer;
  courseOf: (id: string | undefined) => Course | null;
  openMain: () => void;
  now?: () => Date;
}): Promise<() => void> {
  if (!inNative()) return () => {};
  const { listen, emit } = await import("@tauri-apps/api/event");
  const now = options.now ?? (() => new Date());
  let visible = false;
  let enabled = readFloatingTimer();
  let mainFocused = true;
  /** Les commandes partent une à une : deux `mini_set_visible` simultanés pouvaient
   *  arriver dans le désordre (montrer après masquer), et la pilule restait. */
  let queue: Promise<unknown> = Promise.resolve();
  let last: MiniState | null = null;

  const state = (): { state: FocusTimerState | null; settings: PomodoroSettings } => {
    const snap = options.timer.snapshot();
    return { state: snap.state, settings: snap.settings.cycle };
  };

  const compute = (): MiniState => {
    const { state: current, settings } = state();
    return buildMiniState(current, settings, options.courseOf(current?.courseID), now());
  };

  const apply = async () => {
    const wanted = miniWanted(enabled, state().state, mainFocused);
    // Masquer est sans effet si c'est déjà fait : on le redit toujours (le verrou d'étude
    // masque aussi la pilule de son côté, sans passer par ici).
    if (wanted !== visible || !wanted) {
      visible = wanted;
      await callNative("mini_set_visible", { visible: wanted });
    }
    if (visible) {
      last = compute();
      await emit(MINI_STATE, last);
    }
  };
  const publish = (): Promise<unknown> => (queue = queue.then(apply, apply));

  const unsubscribe = options.timer.subscribe(() => void publish());
  // Réglages › Chrono › Chrono flottant : appliqué tout de suite.
  const onSettings = () => { enabled = readFloatingTimer(); void publish(); };
  globalThis.addEventListener?.(NATIVE_SETTINGS_EVENT, onSettings);

  // La fenêtre principale devant ou non : par événements du système.
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  const main = getCurrentWindow();
  try { mainFocused = await main.isFocused(); } catch { /* garde la valeur prudente */ }

  const offs = await Promise.all([
    main.onFocusChanged(({ payload }) => {
      if (payload === mainFocused) return;
      mainFocused = payload;
      void publish();
    }),
    listen<MiniCommand>(MINI_COMMAND, ({ payload }) => {
      switch (payload) {
        case "toggle": options.timer.toggle(); break;
        // Refusé sous verrou par le contrôleur lui-même.
        case "finish": if (!StudyMode.isActive(state().state, now())) void options.timer.finish(); break;
        case "hide": enabled = false; writeFloatingTimer(false); void publish(); break;
        case "open": options.openMain(); break;
      }
    }),
    listen(MINI_REQUEST, () => { void emit(MINI_STATE, compute()); }),
    listen(MINI_TOGGLE, () => {
      enabled = !enabled;
      writeFloatingTimer(enabled);
      void publish();
    }),
  ]);

  void publish();
  return () => {
    unsubscribe();
    globalThis.removeEventListener?.(NATIVE_SETTINGS_EVENT, onSettings);
    offs.forEach((off) => off());
    if (visible) void callNative("mini_set_visible", { visible: false });
  };
}
