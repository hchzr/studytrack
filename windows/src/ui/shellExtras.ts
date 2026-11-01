// Les extras de la coquille côté webview : le raccourci global qui montre ou
// cache la fenêtre (⌃⌥Espace sur le Mac ; Ctrl+Alt+Espace ici — l'icône du
// plateau, elle, est posée côté Rust dans src-tauri/src/lib.rs).
//
// Rien de tout cela n'existe dans le navigateur : la fonction se retire sans
// rien faire hors de Tauri.

import { isTauri } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { register, unregister } from "@tauri-apps/plugin-global-shortcut";

/** Le raccourci de la fenêtre, tel qu'il s'écrit pour le plugin. */
export const WINDOW_SHORTCUT = "Control+Alt+Space";

export async function setupShellExtras(): Promise<void> {
  if (!isTauri()) return;
  const win = getCurrentWindow();
  // Un lancement précédent a pu le laisser : réenregistrer à l'identique.
  try {
    await unregister(WINDOW_SHORTCUT);
  } catch {
    // pas encore enregistré
  }
  try {
    await register(WINDOW_SHORTCUT, async () => {
      try {
        // La fenêtre au premier plan se cache ; cachée ou réduite, elle revient.
        if (await win.isVisible() && await win.isFocused()) {
          await win.hide();
          return;
        }
        await win.show();
        await win.unminimize();
        await win.setFocus();
      } catch {
        // Une fenêtre partie ne doit pas faire tomber le reste.
      }
    });
  } catch {
    // Le raccourci peut être pris par le système (⌃⌥Espace sert à autre chose
    // sur certains Mac) : son absence se remarque à la fenêtre qui ne bascule
    // pas, jamais à un écran d'erreur. Le plateau reste.
  }
}
