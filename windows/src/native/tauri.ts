// Le pont vers la couche Rust, gardé : hors de Tauri (aperçu Vite, tests), tout
// est un no-op et rien ne se plaint.

import { isTauri } from "@tauri-apps/api/core";

/** Sommes-nous dans l'app Tauri ? (Faux dans le navigateur et sous Vitest.) */
export function inNative(): boolean {
  try {
    return isTauri();
  } catch {
    return false;
  }
}

/** Appelle une commande Rust ; `null` hors Tauri ou si elle échoue (jamais d'exception). */
export async function callNative<T>(command: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!inNative()) return null;
  try {
    const { invoke } = await import("@tauri-apps/api/core");
    return await invoke<T>(command, args);
  } catch {
    return null;
  }
}
