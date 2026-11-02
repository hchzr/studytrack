// Les secrets de l'app — jetons des fournisseurs de tâches, clé AnkiWeb,
// session Supabase — rangés dans le coffre du système (Credential Manager sous
// Windows, trousseau sur macOS : `src-tauri/src/native/secrets.rs`), comme le
// Mac les range au trousseau (AnkiKeychain, SupabaseSessionStore).
//
// Le reste de l'app lit ses réglages de façon synchrone : le coffre est donc
// lu une fois au démarrage (`loadSecrets`, avant le premier écran) dans une
// table en mémoire ; une écriture met la table à jour tout de suite et part au
// coffre en arrière-plan. Les anciennes valeurs en clair du stockage de la
// webview y sont déplacées au premier lancement, puis effacées.
// Hors de Tauri (aperçu Vite, tests), tout reste dans `localStorage`.

import { callNative, inNative } from "./tauri.ts";

/** Les clés tenues pour secrètes, telles que le reste de l'app les nomme. */
export const SECRET_KEYS: readonly string[] = [
  "settings.todoistToken",
  "settings.googleClientSecret",
  "settings.googleRefreshToken",
  "settings.tickTickToken",
  "settings.notionToken",
  // Une adresse de webhook porte souvent son jeton dans le chemin.
  "settings.webhookURL",
  "ankiweb.hostKey",
  "studytrack.supabase.session",
];

const secretSet = new Set(SECRET_KEYS);
let vault: Map<string, string> | null = null;

export function isSecretKey(key: string): boolean {
  return secretSet.has(key);
}

function local(): Storage | null {
  try {
    return typeof globalThis.localStorage === "undefined" ? null : globalThis.localStorage;
  } catch {
    return null;
  }
}

/**
 * Lit le coffre (une seule fois) et y déplace les secrets restés en clair.
 * Si le coffre ne répond pas, les secrets restent où ils sont : mieux vaut
 * une connexion qui marche qu'un jeton perdu.
 */
export async function loadSecrets(): Promise<void> {
  if (!inNative() || vault) return;
  const found = await callNative<Record<string, string>>("secrets_load", { keys: SECRET_KEYS });
  if (found === null) return;
  const table = new Map(Object.entries(found));
  const storage = local();
  for (const key of SECRET_KEYS) {
    const plain = storage?.getItem(key) ?? null;
    if (plain === null) continue;
    if (!table.has(key) && plain !== "") {
      const moved = await callNative("secret_set", { key, value: plain });
      if (moved === null) continue; // Pas rangé : on garde la copie en clair.
      table.set(key, plain);
    }
    storage?.removeItem(key);
  }
  vault = table;
}

/**
 * Le stockage de l'app : les clés secrètes vont au coffre (une fois chargé),
 * toutes les autres au `localStorage` de la webview.
 */
export const appStorage = {
  getItem(key: string): string | null {
    if (vault && secretSet.has(key)) return vault.get(key) ?? null;
    try { return local()?.getItem(key) ?? null; } catch { return null; }
  },
  setItem(key: string, value: string): void {
    if (vault && secretSet.has(key)) {
      if (value === "") vault.delete(key); else vault.set(key, value);
      void callNative("secret_set", { key, value: value === "" ? null : value });
      return;
    }
    try { local()?.setItem(key, value); } catch { /* stockage refusé */ }
  },
  removeItem(key: string): void {
    if (vault && secretSet.has(key)) {
      vault.delete(key);
      void callNative("secret_set", { key, value: null });
      return;
    }
    try { local()?.removeItem(key); } catch { /* stockage refusé */ }
  },
};

/** Pour les tests : oublier la table chargée. */
export function resetSecretsForTests(table: Map<string, string> | null = null): void {
  vault = table;
}
