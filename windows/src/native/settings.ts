// Les réglages de la couche native, retenus dans `localStorage` (comme
// `mac.floatingTimer` / `mac.studyKeepAwake` dans les `UserDefaults` du Mac).
// Réglages › Chrono les écrit ; un changement prévient la couche native
// (`NATIVE_SETTINGS_EVENT`) pour qu'il s'applique sans relancer l'app.

import { keepAwakeModes, type KeepAwakeMode } from "../domain/keepAwakePolicy.ts";

const FLOATING = "win.floatingTimer";
const KEEP_AWAKE = "win.studyKeepAwake";
const BLOCKED_APPS = "win.blockedApps";
const BLOCKED_SITES = "win.blockedSites";

function read(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function write(key: string, value: string): void {
  try {
    globalThis.localStorage?.setItem(key, value);
  } catch {
    // Un stockage refusé ne doit rien casser.
  }
}

/** Le chrono flottant : actif par défaut, comme sur le Mac. */
export function readFloatingTimer(): boolean {
  return read(FLOATING) !== "false";
}
export function writeFloatingTimer(value: boolean): void {
  write(FLOATING, value ? "true" : "false");
  notifyNative();
}

/** L'évènement de fenêtre levé quand un réglage natif change. */
export const NATIVE_SETTINGS_EVENT = "studytrack:native-settings";
function notifyNative(): void {
  try { globalThis.dispatchEvent?.(new Event(NATIVE_SETTINGS_EVENT)); } catch { /* hors navigateur */ }
}

/** Garder éveillé pendant le mode étude : « off » par défaut, comme le Mac (mac.studyKeepAwake). */
export function readKeepAwakeMode(): KeepAwakeMode {
  const raw = read(KEEP_AWAKE);
  return (keepAwakeModes as string[]).includes(raw ?? "") ? (raw as KeepAwakeMode) : "off";
}
export function writeKeepAwakeMode(mode: KeepAwakeMode): void {
  write(KEEP_AWAKE, mode);
  notifyNative();
}

/** Les apps fermées pendant un blocage (noms d'exécutables). */
export const defaultBlockedApps = [
  "discord.exe", "steam.exe", "epicgameslauncher.exe", "telegram.exe", "whatsapp.exe", "battle.net.exe",
];

/** Les sites coupés pendant un blocage (fichier hosts). */
export const defaultBlockedSites = [
  "youtube.com", "netflix.com", "twitch.tv", "reddit.com", "instagram.com", "tiktok.com",
  "facebook.com", "x.com", "twitter.com", "primevideo.com", "disneyplus.com",
];

function readList(key: string, fallback: string[]): string[] {
  const raw = read(key);
  if (raw === null) return fallback;
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) && parsed.every((x) => typeof x === "string") ? (parsed as string[]) : fallback;
  } catch {
    return fallback;
  }
}

export const readBlockedApps = () => readList(BLOCKED_APPS, defaultBlockedApps);
export const readBlockedSites = () => readList(BLOCKED_SITES, defaultBlockedSites);
export const writeBlockedApps = (apps: string[]) => write(BLOCKED_APPS, JSON.stringify(apps));
export const writeBlockedSites = (sites: string[]) => write(BLOCKED_SITES, JSON.stringify(sites));

/** Proposer l'analyse par modèle de langage à l'import d'un PDF (`settings.aiExtractionEnabled`) : actif par défaut. */
const AI_EXTRACTION = "win.aiExtraction";
export function readAIExtraction(): boolean {
  return read(AI_EXTRACTION) !== "false";
}
export function writeAIExtraction(value: boolean): void {
  write(AI_EXTRACTION, value ? "true" : "false");
}

/** L'identifiant d'installation anonyme (`SupabaseConfig.installID`) : un par appareil, rien ne le relie à une personne. */
export function installID(): string {
  const key = "supabase.installID";
  const saved = read(key);
  if (saved) return saved;
  const id = globalThis.crypto?.randomUUID?.().toUpperCase() ?? String(Date.now());
  write(key, id);
  return id;
}
