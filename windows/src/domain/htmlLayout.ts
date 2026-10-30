import type { PDFLayoutLine } from "./seriesLayout.ts";
import { MoodleLinks } from "./botafogoProgram.ts";

/// Une page web d'exercices, vue comme une mise en page.
///
/// Les énoncés en PDF sont lus d'après leur mise en page (titres plus grands,
/// « **Exercice 1.** » en gras, questions en retrait). Une page web porte les
/// mêmes signaux, autrement : titres `<h2>`, `<strong>`, listes imbriquées.
/// Les traduire en lignes de mise en page permet de lire **n'importe quelle**
/// page de série — site d'un cours, page Moodle, GitHub — avec la même chaîne
/// que les PDF (règles, puis modèle), sans lecteur écrit pour un site.

/// Taille de police donnée à chaque niveau de titre (`<h1>` … `<h6>`).
const headingSizes = new Map<number, number>([[1, 22], [2, 18], [3, 15], [4, 13], [5, 12], [6, 12]]);

export function lines(html: string): PDFLayoutLine[] {
  let source = html.replace(/<(script|style|nav|header|footer|noscript)[^>]*>.*?<\/\1>/gis, " ");
  source = source.replace(/<!--.*?-->/gis, " ");
  // Les éléments qui ouvrent ou ferment un bloc de texte.
  const tag = /<(\/?)(h[1-6]|p|li|div|tr|pre|blockquote|ul|ol|dt|dd|section|article|br|td|th)\b[^>]*>/gi;
  const result: PDFLayoutLine[] = [];
  let depth = 0;
  let heading: number | null = null;
  let cursor = 0;

  const flush = (raw: string) => {
    const startsBold = /^\s*<(b|strong)\b/i.test(raw);
    const text = MoodleLinks.decodeEntities(raw.replace(/<[^>]+>/g, " "))
      .split(/\p{White_Space}+/u).filter((part: string) => part !== "").join(" ");
    if (text === "") return;
    const size = heading !== null ? (headingSizes.get(heading) ?? 12) : 11;
    // `verticalPosition` reste à `nil` côté Swift : on ne le pose pas.
    result.push({
      text, fontSize: size, isBold: heading !== null, pageIndex: 0,
      indent: 40 + depth * 18, startsBold,
    });
  };

  for (const match of source.matchAll(tag)) {
    const start = match.index!;
    flush(source.slice(cursor, start));
    cursor = start + match[0].length;
    const name = match[2].toLowerCase();
    const closing = match[1] !== "";
    if (name === "ul" || name === "ol" || name === "blockquote" || name === "dd") {
      depth = Math.max(0, depth + (closing ? -1 : 1));
    }
    if (name.startsWith("h")) {
      const level = parseInt(name.slice(1), 10);
      if (!Number.isNaN(level)) heading = closing ? null : level;
    }
  }
  flush(source.slice(cursor));
  return result;
}

export const HTMLLayout = { lines };
