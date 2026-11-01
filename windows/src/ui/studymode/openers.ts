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
