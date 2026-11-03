// La musique du système (native/media.rs) : ce qui joue, et la piloter. Hors de Windows, rien.

import { callNative } from "./tauri.ts";

export interface MediaState { available: boolean; playing: boolean; title: string; artist: string; app: string }

export const SystemMedia = {
  state: async (): Promise<MediaState> =>
    (await callNative<MediaState>("media_state")) ?? { available: false, playing: false, title: "", artist: "", app: "" },
  command: async (action: "toggle" | "play" | "pause" | "next" | "previous"): Promise<void> => {
    await callNative("media_command", { action });
  },
};

const PAUSE_KEY = "music.pauseOnBreak";

/** Mettre la musique en pause pendant les pauses du rythme (Pomodoro, pause du cours) ? Oui par défaut. */
export function readPauseOnBreak(): boolean {
  try { return localStorage.getItem(PAUSE_KEY) !== "0"; } catch { return true; }
}

export function writePauseOnBreak(value: boolean): void {
  try { localStorage.setItem(PAUSE_KEY, value ? "1" : "0"); } catch { /* pour la session */ }
}

/** Le nom lisible de l'app qui joue (« Spotify », « Chrome »…). */
export function appName(id: string): string {
  const base = id.split("!")[0].split("\\").pop()?.replace(/\.exe$/i, "") ?? id;
  if (/spotify/i.test(base)) return "Spotify";
  if (/applemusic|itunes/i.test(base)) return "Apple Music";
  if (/chrome/i.test(base)) return "Chrome";
  if (/msedge|edge/i.test(base)) return "Edge";
  if (/firefox/i.test(base)) return "Firefox";
  if (/zune|media/i.test(base)) return "Lecteur multimédia";
  return base.split(".").pop() ?? base;
}
