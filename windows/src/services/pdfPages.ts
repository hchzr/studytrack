// Rend les pages d'un PDF en images (StudyKit/PDFPageRenderer.swift, et le rendu
// des bandes de `SeriesPDFStore`) — pour le modèle qui **voit** les pages, pour
// l'aperçu de la relecture et pour le lecteur de PDF.
//
// Le texte d'un polycopié LaTeX perd ses symboles (« ≤ » devient rien), éclate ses
// fractions et mélange ses colonnes : les sous-questions en sortaient fausses.
// L'image garde la structure telle qu'on la lit. Navigateur seulement (canvas) :
// la lecture du texte, elle, reste dans `pdfLayoutExtractor`.

import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs";
import workerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";

(pdfjs as unknown as { GlobalWorkerOptions: { workerSrc: string } }).GlobalWorkerOptions.workerSrc = workerUrl;

/// Largeur de rendu : assez pour lire un indice, assez peu pour tenir dans une
/// requête (≈ 150 dpi sur une page A4).
export const targetWidth = 1240;
export const jpegQuality = 0.6;
/// Au-delà, le PDF n'est pas une série : un polycopié entier, qu'on ne rend pas.
export const maxPages = 20;

interface PdfViewport { width: number; height: number }
interface PdfPageProxy {
  getViewport(o: { scale: number }): PdfViewport;
  render(o: { canvasContext: CanvasRenderingContext2D; viewport: PdfViewport; canvas?: HTMLCanvasElement; transform?: number[] }): { promise: Promise<void> };
}
interface PdfDocumentProxy {
  numPages: number;
  getPage(n: number): Promise<PdfPageProxy>;
  destroy(): Promise<void>;
}

/// Un PDF ouvert pour le rendu.
export interface OpenPDF {
  pageCount: number;
  page(index: number): Promise<PdfPageProxy>;
  destroy(): void;
}

export async function openPDF(bytes: Uint8Array): Promise<OpenPDF> {
  const doc = await (pdfjs as unknown as {
    getDocument(o: Record<string, unknown>): { promise: Promise<PdfDocumentProxy> };
  }).getDocument({ data: bytes.slice(), isEvalSupported: false, verbosity: 0 }).promise;
  return {
    pageCount: doc.numPages,
    page: (index) => doc.getPage(index + 1),
    destroy: () => { void doc.destroy(); },
  };
}

/// Une page, ou une bande de page (fractions du haut), à la largeur voulue en pixels.
export async function renderBand(pdf: OpenPDF, pageIndex: number, widthPx: number, top = 0, bottom = 1): Promise<HTMLCanvasElement> {
  const page = await pdf.page(pageIndex);
  const base = page.getViewport({ scale: 1 });
  const scale = widthPx / base.width;
  const viewport = page.getViewport({ scale });
  const canvas = document.createElement("canvas");
  const from = Math.round(viewport.height * top);
  const to = Math.round(viewport.height * bottom);
  canvas.width = Math.round(viewport.width);
  canvas.height = Math.max(1, to - from);
  const context = canvas.getContext("2d");
  if (!context) throw new Error("canvas indisponible");
  context.fillStyle = "#fff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  // La bande voulue tombe dans le cadre : on remonte la page de `from`.
  await page.render({ canvasContext: context, viewport, canvas, transform: [1, 0, 0, 1, 0, -from] }).promise;
  return canvas;
}

function toJPEG(canvas: HTMLCanvasElement): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(async (blob) => {
      if (!blob) { reject(new Error("JPEG indisponible")); return; }
      resolve(new Uint8Array(await blob.arrayBuffer()));
    }, "image/jpeg", jpegQuality);
  });
}

/// Les pages en JPEG (au plus `maxPages`), ou seulement ces indices (sans le plafond
/// d'une série : l'appelant borne ce qu'il demande).
export async function jpegPages(pdf: OpenPDF, indices?: number[]): Promise<Uint8Array[]> {
  const wanted = indices ?? Array.from({ length: Math.min(pdf.pageCount, maxPages) }, (_, i) => i);
  const result: Uint8Array[] = [];
  for (const index of wanted) {
    try {
      result.push(await toJPEG(await renderBand(pdf, index, targetWidth)));
    } catch {
      // Une page illisible ne prive pas des autres.
    }
  }
  return result;
}

export const PDFPageRenderer = { targetWidth, jpegQuality, maxPages, jpegPages, renderBand };
