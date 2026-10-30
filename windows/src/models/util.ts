// Petits utilitaires de chaînes et d'URL partagés par les modèles.

/** `trimmingCharacters(in: .whitespaces)` : espaces et tabulations, pas les retours à la ligne. */
export const trimWhitespaces = (s: string): string => s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export const trimAll = (s: string): string => s.trim();

/** `split(separator: "\n")` : les sous-séquences vides sont omises. */
export const splitLines = (s: string): string[] => s.split("\n").filter((x) => x !== "");

/**
 * `URL(string:)` : `null` quand l'adresse n'en est pas une. Plus strict que Swift,
 * qui accepte aussi un chemin relatif (« foo ») : ici, une adresse absolue seulement.
 */
export function makeURL(s: string): URL | null {
  try {
    return new URL(s);
  } catch {
    return null;
  }
}

/** `localizedStandardCompare` : ordre naturel (« 1.2 » avant « 1.10 »), sans casse ni accents. */
const collator = new Intl.Collator("fr", { numeric: true, sensitivity: "base" });
export const localizedStandardCompare = (a: string, b: string): number => collator.compare(a, b);

export const isLetter = (c: string): boolean => /^\p{L}$/u.test(c);
