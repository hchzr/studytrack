// Le papier de nuit du mode étude (StudyPalette, StudyKit/ExerciseParts.swift) :
// `Carnet` en apparence sombre, toujours. L'écran du mode étude est sombre
// d'office (« Toujours sombre » par défaut sur le Mac) ; ici on force les
// variables CSS sur la racine de l'écran, pour que tout ce qui est dedans lise
// le sombre même quand l'app est claire. Les valeurs sont celles des tokens
// sombres (tokens.css) — les verdicts compris, pour que juste / à revoir / faux
// gardent leurs couleurs de nuit sur le papier sombre.

import type { CSSProperties } from "react";

/** La palette sombre, en variables CSS posées sur le div racine du mode étude. */
export const studyPalette = {
  "--ground": "#15130F",
  "--sheet": "#211E18",
  "--sheet-raised": "#2B271F",
  "--ink": "#EDE6D6",
  "--ink-secondary": "#A89F8D",
  "--ink-tertiary": "#9E9480",
  "--rule": "#353027",
  "--marker": "#4A4020",
  "--correct": "#8FC58A",
  "--review": "#E0B04E",
  "--wrong": "#E7836F",
  "--selection": "#463E31",
} as CSSProperties;

/** La clé où le choix « Bloquer le reste » est retenu (le blocage natif Windows
 *  n'existe pas encore : le choix est gardé pour quand il arrivera). */
export const locksStorageKey = "studyMode.locks";

/** « Bloquer le reste » tel qu'il a été choisi la dernière fois (faux sans choix). */
export function readStudyLocks(): boolean {
  try {
    return globalThis.localStorage?.getItem(locksStorageKey) === "true";
  } catch {
    return false;
  }
}

/** Retient le choix « Bloquer le reste ». */
export function writeStudyLocks(value: boolean): void {
  try {
    globalThis.localStorage?.setItem(locksStorageKey, value ? "true" : "false");
  } catch {
    // Un stockage refusé ne doit pas arrêter le mode étude.
  }
}

/** Les réglages de lancement du mode étude (studyMinutes & co du Mac), en localStorage. */
function readNumber(key: string, fallback: number): number {
  try {
    const raw = globalThis.localStorage?.getItem(key);
    if (raw === null || raw === undefined || raw.trim() === "") return fallback;
    const value = Number(raw);
    return Number.isFinite(value) ? value : fallback;
  } catch {
    return fallback;
  }
}

function readBoolean(key: string, fallback: boolean): boolean {
  try {
    const raw = globalThis.localStorage?.getItem(key);
    if (raw === "true" || raw === "1") return true;
    if (raw === "false" || raw === "0") return false;
    return fallback;
  } catch {
    return fallback;
  }
}

function write(key: string, value: string): void {
  try {
    globalThis.localStorage?.setItem(key, value);
  } catch {
    // idem
  }
}

/** La durée de la dernière session (50 min par défaut, comme l'écran du Mac). */
export const studyDuration = {
  read: () => readNumber("studyMode.minutes", 50),
  write: (minutes: number) => write("studyMode.minutes", String(minutes)),
};

/** « Sans fin » la dernière fois. */
export const studyOpenEnded = {
  read: () => readBoolean("studyMode.openEnded", false),
  write: (value: boolean) => write("studyMode.openEnded", value ? "true" : "false"),
};

/** Le Pomodoro choisi la dernière fois. */
export const studyPomodoro = {
  read: () => readBoolean("studyMode.pomodoro", false),
  write: (value: boolean) => write("studyMode.pomodoro", value ? "true" : "false"),
};
