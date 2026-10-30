// Les valeurs JSON que les modèles gardent en texte brut (`documentsRaw`,
// `linksRaw`) : mêmes champs que les `Codable` Swift, donc même JSON.

export type ContentLinkKind = "video" | "slides" | "notes" | "pdf" | "page" | "solution";

/** Un lien d'un élément : la vidéo d'un cours, ses transparents, un corrigé. */
export interface ContentLink {
  title: string;
  url: string;
  kind: ContentLinkKind;
}

/** Un document d'un cours, gardé comme lien : ni théorie ni série. */
export interface CourseDocument {
  title: string;
  url: string;
  group: string;
  kind: ContentLinkKind;
}

/** `decodeList` : une liste illisible est une liste vide (`try?` côté Swift). */
export function decodeList<T>(raw: string): T[] {
  if (raw === "") return [];
  try {
    const value = JSON.parse(raw);
    return Array.isArray(value) ? (value as T[]) : [];
  } catch {
    return [];
  }
}

/** `encodeList` : une liste vide s'écrit « ». */
export function encodeList<T>(list: T[]): string {
  return list.length === 0 ? "" : JSON.stringify(list);
}
