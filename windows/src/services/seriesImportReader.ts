// Lit un ou plusieurs PDF en conservant leur mise en page (la fermeture `read` de
// StudyKit/SeriesImportSheet.swift) : les lignes pour l'analyse, une image JPEG par
// page pour le modèle qui voit et pour l'aperçu de la relecture.

import type { PDFLayoutLine } from "../domain/seriesLayout.ts";
import type { PickedFile } from "../native/files.ts";
import { linesFromData } from "./pdfLayoutExtractor.ts";
import { jpegPages, openPDF } from "./pdfPages.ts";

export interface ReadResult {
  lines: PDFLayoutLine[];
  /** Une image par page — vide quand le rendu a échoué —, alignée sur les numéros de page des lignes. */
  pages: Uint8Array[];
  unreadable: number;
}

export async function readPDFs(files: PickedFile[]): Promise<ReadResult> {
  const lines: PDFLayoutLine[] = [];
  const pages: Uint8Array[] = [];
  let unreadable = 0;
  for (const file of files) {
    try {
      const own = await linesFromData(file.bytes);
      // Les numéros de page repartent de zéro à chaque fichier.
      const offset = pages.length;
      for (const line of own) lines.push({ ...line, pageIndex: line.pageIndex + offset });
      const pdf = await openPDF(file.bytes);
      try {
        const rendered = await jpegPages(pdf);
        pages.push(...rendered);
        // Une image par page, pour garder les index alignés sur les lignes.
        for (let i = rendered.length; i < pdf.pageCount; i++) pages.push(new Uint8Array(0));
      } finally {
        pdf.destroy();
      }
    } catch (error) {
      console.warn("PDF illisible", file.name, error);
      unreadable++;
    }
  }
  return { lines, pages, unreadable };
}
