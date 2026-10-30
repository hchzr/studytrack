// Les préférences qui n'ont pas encore de modèle côté Windows (`SettingsStore`
// du Mac, `UserDefaults`/iCloud). On les garde dans `localStorage`, avec un
// try/catch partout : un stockage refusé (navigation privée, quota) ne doit pas
// empêcher l'écran de fonctionner.

/** Le thème choisi. `system` laisse les media queries de tokens.css décider. */
export type Appearance = "system" | "light" | "dark";

/** Les clés reprennent celles de `StudyKit/SettingsStore.swift` quand elles existent. */
export const PREFERENCE_KEYS = {
  appearance: "settings.appearance",
  sectionCode: "settings.sectionCode",
} as const;

function storage(): Storage | null {
  try {
    if (typeof window === "undefined") return null;
    return window.localStorage;
  } catch {
    return null;
  }
}

/** Lit une préférence texte ; `null` si absente ou si le stockage refuse. */
export function readPreference(key: string): string | null {
  try {
    return storage()?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

/** Écrit (ou efface avec `null`) une préférence texte. */
export function writePreference(key: string, value: string | null): void {
  try {
    const store = storage();
    if (!store) return;
    if (value === null) store.removeItem(key);
    else store.setItem(key, value);
  } catch {
    // Le réglage reste valable pour la session ; seule sa persistance échoue.
  }
}

export function readAppearance(): Appearance {
  const raw = readPreference(PREFERENCE_KEYS.appearance);
  return raw === "light" || raw === "dark" ? raw : "system";
}

/**
 * Applique le thème sur `<html data-theme>`. `system` retire l'attribut : la
 * règle `prefers-color-scheme` de tokens.css reprend la main.
 */
export function applyAppearance(appearance: Appearance): void {
  try {
    if (typeof document === "undefined") return;
    const root = document.documentElement;
    if (appearance === "system") {
      delete root.dataset.theme;
      root.style.colorScheme = "light dark";
    } else {
      root.dataset.theme = appearance;
      root.style.colorScheme = appearance;
    }
  } catch {
    // Un DOM sans documentElement ne doit pas casser le rendu de l'écran.
  }
}

/** Le code de section EPFL, vide tant qu'il n'est pas choisi. */
export function readSectionCode(): string {
  return readPreference(PREFERENCE_KEYS.sectionCode) ?? "";
}

export function writeSectionCode(code: string): void {
  writePreference(PREFERENCE_KEYS.sectionCode, code);
}

// La coquille importe cet écran au démarrage : le thème enregistré s'applique
// donc dès le lancement, sans attendre que l'on ouvre les réglages.
applyAppearance(readAppearance());
