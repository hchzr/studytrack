// Le mode étude prend tout l'écran (comme celui du Mac), puis rend la fenêtre
// telle qu'elle était. Par événements : un appel à l'entrée, un à la sortie.

import { inNative } from "./tauri.ts";

/** Ce que le plein écran lit et commande sur la fenêtre. */
export interface FullscreenWindow {
  isFullscreen(): Promise<boolean>;
  setFullscreen(value: boolean): Promise<void>;
}

/**
 * Met la fenêtre en plein écran et rend, à la sortie, l'état d'avant (une fenêtre déjà
 * en plein écran le reste). Les erreurs ne cassent rien : le mode étude marche aussi en fenêtre.
 */
export function enterStudyFullscreen(win: FullscreenWindow | null): () => void {
  if (!win) return () => {};
  let before = false;
  let cancelled = false;
  const ready = (async () => {
    try {
      before = await win.isFullscreen();
      if (!cancelled && !before) await win.setFullscreen(true);
    } catch { /* permission ou fenêtre absente : tant pis */ }
  })();
  return () => {
    cancelled = true;
    void ready.then(async () => {
      try { if (!before) await win.setFullscreen(false); } catch { /* idem */ }
    });
  };
}

/** La fenêtre principale de l'app, ou `null` hors de Tauri. */
export async function currentFullscreenWindow(): Promise<FullscreenWindow | null> {
  if (!inNative()) return null;
  try {
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    return getCurrentWindow();
  } catch {
    return null;
  }
}

/** Plein écran pour la durée de vie de l'appelant (un effet React) ; renvoie l'arrêt. */
export function studyFullscreen(): () => void {
  let stop: (() => void) | null = null;
  let cancelled = false;
  void currentFullscreenWindow().then((win) => {
    if (cancelled) return;
    stop = enterStudyFullscreen(win);
  });
  return () => { cancelled = true; stop?.(); };
}

