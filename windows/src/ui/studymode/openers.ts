// Ouvrir une adresse du mode étude : dans le navigateur du système par le
// greffon « opener » de Tauri quand l'app tourne dans Tauri, sinon dans un
// onglet du navigateur courant (l'app de développement dans un navigateur).

import { isTauri } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";

/** Ouvre une adresse http(s) hors de l'app (Moodle, le corrigé, un outil). */
export async function openWebURL(url: string): Promise<void> {
  if (isTauri()) {
    try {
      await openUrl(url);
      return;
    } catch {
      // Le greffon peut refuser : on retombe sur le navigateur.
    }
  }
  window.open(url, "_blank", "noopener,noreferrer");
}

/**
 * Ouvre une adresse **dans l'app** (une fenêtre Polymestre, au-dessus du mode étude) : rien
 * n'oblige à passer par le navigateur. Hors de l'app, un onglet du navigateur.
 */
export async function openInApp(url: string, title = "Polymestre"): Promise<void> {
  if (isTauri()) {
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("web_open", { url, title });
      return;
    } catch {
      // Une adresse que la fenêtre refuse : le navigateur.
    }
  }
  await openWebURL(url);
}
