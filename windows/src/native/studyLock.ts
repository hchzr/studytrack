// Le blocage d'étude, au mieux (StudyLock du Mac) : sous Windows, les apps de la
// liste sont fermées par un scrutateur de processus et les sites coupés par le
// fichier hosts — ce dernier seulement si l'app a les droits administrateur.
// Tout se défait à la fin de la session (et au prochain lancement, côté Rust).

import { isAllowedHost, defaultSites } from "../domain/studyMode.ts";
import { callNative, inNative } from "./tauri.ts";

export interface LockCapabilities { supported: boolean; canBlockSites: boolean }
export interface LockReport { supported: boolean; watching: boolean; sitesBlocked: boolean; note: string | null }

export const NEEDS_ADMIN_NOTE = "sites non bloqués (droits administrateur requis)";

let capabilities: LockCapabilities | null = null;
let lastReport: LockReport | null = null;
const listeners = new Set<() => void>();

export const studyLockStatus = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  /** Le dernier rapport de Rust (`null` : aucun blocage en cours). */
  snapshot: (): LockReport | null => lastReport,
};

function publish(report: LockReport | null): void {
  lastReport = report;
  for (const listener of listeners) listener();
}

/** Les sites à couper : la liste moins ce que l'étude permet d'office (jamais Moodle, Claude…). */
export function sitesToBlock(blocked: string[], allowed: string[] = defaultSites()): string[] {
  return blocked.filter((site) => !isAllowedHost(site, allowed));
}

/** Les mots du réglage « Bloquer le reste », honnêtes sur ce qui est vraiment tenu. */
export function lockNote(known: LockCapabilities | null, native: boolean): string {
  if (!native) return "Le blocage des apps et des sites ne marche que dans l'app Windows.";
  if (known === null) return "Au mieux : les apps de la liste sont fermées, les sites coupés si StudyTrack en a les droits.";
  if (!known.supported) return "Le blocage n'est pas disponible sur ce système.";
  return known.canBlockSites
    ? "Au mieux : les apps de la liste sont fermées et les sites coupés pendant la session — rien n'est garanti."
    : `Au mieux : les apps de la liste sont fermées ; ${NEEDS_ADMIN_NOTE}.`;
}

/** La phrase de l'écran de préparation du mode étude. */
export function studyLockNote(): string {
  return lockNote(capabilities, inNative());
}

export async function loadLockCapabilities(): Promise<void> {
  capabilities = await callNative<LockCapabilities>("study_lock_capabilities");
}

/** Ce que `startStudyLock` lit du chrono. */
export interface StudyLockTimer {
  subscribe(listener: () => void): () => void;
  /** Le mode étude bloque-t-il le reste, là, maintenant ? */
  blocks(): boolean;
  /** Fin prévue (pour réévaluer à l'heure) ; `null` : sans fin. */
  until(): Date | null;
}

export function startStudyLock(
  timer: StudyLockTimer,
  lists: () => { apps: string[]; sites: string[] },
  now: () => Date = () => new Date(),
): () => void {
  let active = false;
  let wake: ReturnType<typeof setTimeout> | null = null;

  const stop = async () => {
    if (!active) return;
    active = false;
    await callNative("study_lock_stop");
    publish(null);
  };

  const evaluate = async () => {
    if (wake) clearTimeout(wake);
    wake = null;
    if (timer.blocks()) {
      if (!active) {
        active = true;
        const { apps, sites } = lists();
        publish(await callNative<LockReport>("study_lock_start", { apps, sites: sitesToBlock(sites) }));
      }
      // Le mode étude finit sans que le chrono change : un réveil à l'heure.
      const until = timer.until();
      const delay = until ? until.getTime() - now().getTime() + 500 : Infinity;
      if (delay > 0 && delay < 2 ** 31 - 1) wake = setTimeout(() => void evaluate(), delay);
    } else {
      await stop();
    }
  };

  const unsubscribe = timer.subscribe(() => void evaluate());
  void evaluate();
  return () => {
    unsubscribe();
    if (wake) clearTimeout(wake);
    void stop();
  };
}
