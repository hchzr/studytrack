// Les réglages dont l'écran Chrono a besoin, lus sur le poste.
//
// Le Mac les tient dans `SettingsStore` (StudyKit), publié par iCloud ; ici il
// n'y a pas encore d'écran de réglages, alors on relit les **mêmes clés** quand
// elles existent et on retombe sur les valeurs par défaut du Mac (25 / 5 / 15,
// une pause longue tous les 4 blocs). Le jour où l'écran Réglages écrira ces
// clés, le chrono les suivra sans rien changer.

import type { KeyValueStore } from "../../../domain/focusTimerState.ts";
import { makePomodoroSettings, type PomodoroSettings } from "../../../domain/pomodoroEngine.ts";

/** Ce que l'écran lit une fois au montage. */
export interface FocusSettings {
  /** Les durées du cycle (celles de la session ouverte l'emportent : `cycleOr`). */
  cycle: PomodoroSettings;
  /** « Pomodoro » coché par défaut pour une nouvelle session. */
  pomodoroDefault: boolean;
  /** L'objectif de la semaine, en minutes (0 : la charge EPFL des cours suivis). */
  weeklyGoalMinutes: number;
  /** Heures attendues par crédit ECTS (30 par défaut, comme `SettingsStore`). */
  hoursPerCredit: number;
}

/** `UserDefaults` du Mac, en `localStorage` ; indisponible → on lit les défauts. */
export const focusStore: KeyValueStore = {
  get(key: string): string | null {
    try {
      return globalThis.localStorage?.getItem(key) ?? null;
    } catch {
      return null;
    }
  },
  set(key: string, value: string): void {
    try {
      globalThis.localStorage?.setItem(key, value);
    } catch {
      // Un stockage plein ou refusé ne doit pas arrêter le chrono.
    }
  },
  remove(key: string): void {
    try {
      globalThis.localStorage?.removeItem(key);
    } catch {
      // idem
    }
  },
};

const readNumber = (key: string, fallback: number): number => {
  const raw = focusStore.get(key);
  if (raw === null || raw.trim() === "") return fallback;
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
};

const readInteger = (key: string, fallback: number): number => Math.trunc(readNumber(key, fallback));

const readBoolean = (key: string, fallback: boolean): boolean => {
  const raw = focusStore.get(key);
  if (raw === "true" || raw === "1") return true;
  if (raw === "false" || raw === "0") return false;
  return fallback;
};

/** Les durées et l'objectif, relus une fois pour toute la vie de l'écran. */
export function readFocusSettings(): FocusSettings {
  const defaults = makePomodoroSettings();
  const cycle = makePomodoroSettings({
    focusMinutes: readInteger("settings.pomodoroFocusMinutes", defaults.focusMinutes),
    shortBreakMinutes: readInteger("settings.pomodoroBreakMinutes", defaults.shortBreakMinutes),
    longBreakMinutes: readInteger("settings.pomodoroLongBreakMinutes", defaults.longBreakMinutes),
    longBreakEvery: readInteger("settings.pomodoroLongBreakEvery", defaults.longBreakEvery),
    autoStartFocus: readBoolean("settings.pomodoroAutoStartFocus", defaults.autoStartFocus),
  });
  return {
    cycle,
    pomodoroDefault: readBoolean("settings.pomodoroDefault", false),
    weeklyGoalMinutes: readInteger("settings.weeklyGoalMinutes", 0),
    hoursPerCredit: readNumber("settings.hoursPerCredit", 30),
  };
}
