// Lit un PDF en **conservant sa mise en page** (StudyTrack/Services/PDFLayoutExtractor.swift).
//
// `PDFPage.string` aplatit tout : les titres et les énoncés deviennent un seul
// flux, et plus rien ne les distingue. C'est la cause directe des faux intitulés
// (« solution générale. » sous l'exercice 1). Ici on garde les lignes, la police,
// sa taille, la graisse et le retrait.
//
// PDFKit n'existe pas hors d'Apple : l'extraction est faite par `pdfjs-dist`
// (build « legacy », qui tourne dans Node). Ce qui est reproduit de PDFKit :
//   • une ligne par ligne de texte (regroupement par ligne de base) ;
//   • la taille **dominante** de la ligne (celle qui couvre le plus de caractères) ;
//   • le gras majoritaire, et « la ligne commence en gras » pour les titres LaTeX ;
//   • le retrait depuis le bord gauche et la position verticale 0 (haut) → 1 (bas).
// Ce qui ne peut pas l'être exactement : les bornes de glyphes de PDFKit (on part
// de l'origine du texte) et sa reconnaissance des polices Type 1 par traits. Le
// nom de la police embarquée (`AAAAAC+Times-Bold`) donne le gras, comme le fait
// déjà `isBold` côté Swift.

import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs";
import { PDFLayoutLine } from "../domain/seriesLayout.ts";
import { composeAccents, precomposed } from "../domain/textRepair.ts";

/// Les noms de police qui disent « gras » — la liste de `PDFLayoutExtractor.isBold`.
const boldNames = ["bold", "cmbx", "cmb10", "black", "heavy", "semibold", "demi", "-bd", "sfbx", "bx10", "bx12"];

/// `PDFLayoutExtractor.isBold(font)` : traits **ou** nom de la police.
export function isBold(fontName: string): boolean {
  const name = fontName.toLowerCase();
  return boldNames.some((needle) => name.includes(needle));
}

interface TextItem {
  str: string;
  transform: number[];
  width: number;
  height: number;
  fontName: string;
}

interface FontFace {
  name?: string;
  bold?: boolean;
  black?: boolean;
  fallbackName?: string;
}

interface TextStyle {
  ascent?: number;
  descent?: number;
}

interface PdfPage {
  view: number[];
  getViewport(o: { scale: number }): { width: number; height: number };
  getOperatorList(): Promise<unknown>;
  getTextContent(): Promise<{ items: TextItem[]; styles: Record<string, TextStyle> }>;
  commonObjs: { get(name: string): FontFace };
}

interface PdfDocument {
  numPages: number;
  getPage(index: number): Promise<PdfPage>;
}

/// Les lignes d'un PDF, page après page. `data` est le fichier PDF entier.
export async function linesFromData(data: Uint8Array): Promise<PDFLayoutLine[]> {
  // Une copie : pdf.js peut détacher le buffer qu'on lui donne.
  const document = await (pdfjs as unknown as {
    getDocument(o: Record<string, unknown>): { promise: Promise<PdfDocument> };
  }).getDocument({
    data: data.slice(),
    fontExtraProperties: true,
    useSystemFonts: true,
    isEvalSupported: false,
    verbosity: 0,
  }).promise;
  const result: PDFLayoutLine[] = [];
  for (let pageIndex = 0; pageIndex < document.numPages; pageIndex++) {
    const page = await document.getPage(pageIndex + 1);
    result.push(...await linesFromPage(page, pageIndex));
  }
  return result;
}

/// Les lignes d'une page, dans l'ordre du document.
async function linesFromPage(page: PdfPage, pageIndex: number): Promise<PDFLayoutLine[]> {
  const [minX, minY, , maxY] = page.view;
  const height = maxY - minY;
  // Les polices ne sont résolues qu'après la lecture de la liste d'opérations :
  // c'est elle qui transporte le nom de la police embarquée.
  try {
    await page.getOperatorList();
  } catch {
    // Un PDF exotique peut refuser la liste d'opérations ; le texte reste lisible.
  }
  const content = await page.getTextContent();
  const items = content.items.filter((item) => typeof item.str === "string" && item.str !== "");
  if (items.length === 0) return [];

  // Regroupement par ligne de base : PDFKit groupe ainsi les fragments d'une
  // même ligne, y compris une seconde colonne à la même hauteur.
  const groups: { y: number; items: TextItem[] }[] = [];
  for (const item of items) {
    const y = item.transform[5];
    const group = groups.find((candidate) => Math.abs(candidate.y - y) < 0.5);
    if (group) group.items.push(item);
    else groups.push({ y, items: [item] });
  }

  // `selectionsByLine()` coupe aussi aux grands trous horizontaux : une liste
  // en deux colonnes donne deux lignes distinctes, et PDFKit les rend colonne
  // par colonne (gauche de haut en bas, puis droite). Sans cette coupe, le
  // « 3) » d'une colonne se retrouvait collé au « 1) » de la gauche.
  const segments: { y: number; items: TextItem[]; minX: number; order: number }[] = [];
  for (const group of groups) {
    const runs = [...group.items].sort((a, b) => a.transform[4] - b.transform[4]);
    let current: TextItem[] = [];
    let previousEnd = Number.NEGATIVE_INFINITY;
    for (const run of runs) {
      const x = run.transform[4];
      const gap = x - previousEnd;
      if (current.length > 0 && gap > Math.max(30, fontSizeOf(run) * 3)) {
        segments.push({
          y: group.y,
          items: current,
          minX: Math.min(...current.map((item) => item.transform[4])),
          order: Math.min(...current.map((item) => items.indexOf(item))),
        });
        current = [];
      }
      current.push(run);
      previousEnd = x + run.width;
    }
    if (current.length > 0) {
      segments.push({
        y: group.y,
        items: current,
        minX: Math.min(...current.map((item) => item.transform[4])),
        order: Math.min(...current.map((item) => items.indexOf(item))),
      });
    }
  }
  // PDFKit rend les lignes dans l'ordre du document. Une seconde colonne peut
  // donc arriver après le texte qui la suit : `questionTree` remet les numéros
  // dans l'ordre, et une consigne « Ensuite… » reste une partie.
  segments.sort((a, b) => a.order - b.order);

  return segments.map((segment) => {
    const runs = segment.items;
    const text = precomposed(composeAccents(runs.map((run) => run.str).join("")));
    const metrics = fontMetrics(runs, content.styles, page);
    const indent = Math.max(0, segment.minX - minX);
    const baseline = segment.y;
    const descent = metrics.descent;
    const midY = baseline + ((metrics.ascent + descent) / 2) * metrics.size;
    const vertical: number | undefined = height > 0 ? (maxY - midY) / height : undefined;
    return PDFLayoutLine.make(text, {
      fontSize: metrics.size,
      isBold: metrics.isBold,
      pageIndex,
      indent,
      startsBold: startsBold(runs, text, page),
      verticalPosition: vertical,
    });
  });
}

/// Taille dominante de la ligne et graisse.
///
/// La taille retenue est celle qui couvre le plus de caractères : une ligne de
/// titre qui se termine par un mot en indice ne doit pas être jugée sur
/// l'indice. La ligne est **grasse** si la majorité de ses caractères le sont —
/// un seul mot en gras dans une phrase ne fait pas d'elle un titre.
function fontMetrics(runs: TextItem[], styles: Record<string, TextStyle>, page: PdfPage):
{ size: number; isBold: boolean; ascent: number; descent: number } {
  const weightBySize = new Map<number, number>();
  let boldCharacters = 0;
  let counted = 0;
  let ascent = 0.75;
  let descent = -0.25;
  for (const run of runs) {
    const size = fontSizeOf(run);
    const visible = [...run.str].filter((character) => !/[\s\u{00A0}]/u.test(character)).length;
    weightBySize.set(size, (weightBySize.get(size) ?? 0) + visible);
    counted += visible;
    if (fontIsBold(run, page)) boldCharacters += visible;
    if (visible > 0) {
      const style = styles[run.fontName];
      if (style?.ascent !== undefined) ascent = style.ascent;
      if (style?.descent !== undefined) descent = style.descent;
    }
  }
  let best = { size: 0, weight: 0 };
  for (const [size, weight] of weightBySize) {
    if (weight > best.weight || (weight === best.weight && size > best.size)) best = { size, weight };
  }
  return {
    size: best.weight === 0 ? 0 : best.size,
    isBold: counted > 0 && boldCharacters * 2 > counted,
    ascent,
    descent: counted > 0 ? descent : -0.25,
  };
}

function fontSizeOf(item: TextItem): number {
  const [a, b, c, d] = item.transform;
  return Math.hypot(b, d) || Math.hypot(a, c) || item.height || 0;
}

function fontIsBold(item: TextItem, page: PdfPage): boolean {
  try {
    const face = page.commonObjs.get(item.fontName);
    if (face?.bold === true) return true;
    const name = face?.name ?? "";
    if (name !== "") return isBold(name);
  } catch {
    // Police non résolue : le nom interne ne dit rien.
  }
  return isBold(item.fontName);
}

/// La ligne s'ouvre-t-elle sur un passage en gras d'au moins trois caractères ?
///
/// C'est la forme d'un titre « en ligne » (« **Exercice 2.** Soit… ») : la
/// police dominante est celle du corps, mais le début dit « titre ».
function startsBold(runs: TextItem[], text: string, page: PdfPage): boolean {
  let boldPrefix = 0;
  for (const run of runs) {
    if (boldPrefix === 0 && run.str.trim() === "") continue;
    if (!fontIsBold(run, page)) break;
    boldPrefix += [...run.str.trim()].length;
  }
  return boldPrefix >= 3 && boldPrefix < text.length;
}

/// Texte brut, pour l'analyse par motifs et pour l'IA.
export function plainText(lines: PDFLayoutLine[]): string {
  // On sépare les pages par une ligne vide : deux séries qui se suivent sur
  // des pages différentes ne doivent pas se coller.
  let result = "";
  let currentPage = lines[0]?.pageIndex;
  for (const line of lines) {
    if (line.pageIndex !== currentPage) {
      result += "\n";
      currentPage = line.pageIndex;
    }
    result += line.text + "\n";
  }
  return result;
}

export const PDFLayoutExtractor = {
  linesFromData,
  plainText,
  isBold,
};
