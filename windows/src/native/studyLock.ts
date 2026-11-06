// Le verrou d'étude (StudyLock du Mac) : pendant une session qui « bloque le reste »,
// Polymestre occupe l'écran — plein écran, toujours au-dessus, il reprend le focus, et
// Rust avale Win, Alt+Tab, Alt+Échap, Ctrl+Échap, Alt+F4 (native/kiosk.rs). Rien n'est
// fermé ni écrit hors de l'app, aucun droit administrateur. On en sort comme le décident
// les règles du mode étude (StudyMode.locks), jamais autrement.

import { callNative, inNative } from "./tauri.ts";

export interface LockReport {
  supported: boolean;
  active: boolean;
  /** Win, Alt+Tab… sont avalés. */
  keysBlocked: boolean;
  note: string | null;
}

export const KIOSK_NOTE =
  "Polymestre occupe l'écran ; les autres apps sont inaccessibles jusqu'à la fin de la session. Ctrl+Alt+Suppr reste disponible.";

let lastReport: LockReport | null = null;
const listeners = new Set<() => void>();

export const studyLockStatus = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  /** Le dernier rapport de Rust (`null` : aucun verrou en cours). */
  snapshot: (): LockReport | null => lastReport,
};

function publish(report: LockReport | null): void {
  lastReport = report;
  for (const listener of listeners) listener();
}

/** Les mots du réglage « Bloquer le reste », honnêtes sur ce qui est tenu. */
export function studyLockNote(): string {
  return inNative() ? KIOSK_NOTE : "Le blocage ne marche que dans l'app Windows.";
}

/**
 * La ligne « Blocage » du mode étude : ce que Rust dit tenir réellement.
 * `null` : rien à dire (hors de l'app Windows).
 */
export function lockStatusLine(report: LockReport | null, wanted: boolean, native: boolean): string | null {
  if (!native) return null;
  if (!wanted) return "Blocage : désactivé pour cette session.";
  if (report === null) return "Blocage : démarrage…";
  if (!report.supported || !report.active) return `Blocage : ${report.note ?? "indisponible sur ce système"}.`;
  if (!report.keysBlocked) return `Blocage : écran tenu, mais ${report.note ?? "les raccourcis du système restent actifs"}.`;
  return "Blocage : Polymestre occupe l'écran, les raccourcis du système sont bloqués. Ctrl+Alt+Suppr reste disponible.";
}

/** Ce que `startStudyLock` lit du chrono. */
export interface StudyLockTimer {
  subscribe(listener: () => void): () => void;
  /** Le mode étude bloque-t-il le reste, là, maintenant ? */
  blocks(): boolean;
  /** Fin prévue (pour réévaluer à l'heure) ; `null` : sans fin. */
  until(): Date | null;
}

/**
 * Sortie d'urgence : rend l'écran tout de suite, sans attendre que le chrono se termine
 * (s'il échoue à s'enregistrer, l'écran est quand même rendu). Sans effet hors de l'app.
 */
export async function releaseStudyLock(): Promise<void> {
  await callNative("study_lock_stop");
  publish(null);
}

export function startStudyLock(timer: StudyLockTimer, now: () => Date = () => new Date()): () => void {
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
        const report = await callNative<LockReport>("study_lock_start");
        // Une commande qui échoue (null) doit se voir, pas se taire.
        publish(report ?? { supported: true, active: false, keysBlocked: false, note: "le verrou n'a pas pu démarrer" });
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
