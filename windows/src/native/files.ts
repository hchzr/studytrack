// Choisir ou recevoir des fichiers PDF. Dans l'app : boîte de dialogue du système,
// plugin fs et dépôt natif de la fenêtre (Tauri intercepte le glisser-déposer de la
// webview et donne des chemins). Dans le navigateur (aperçu Vite) : `<input type=file>`
// et le dépôt HTML5 ordinaire.

import { inNative } from "./tauri.ts";

export interface PickedFile {
  name: string;
  bytes: Uint8Array;
}

function baseName(path: string): string {
  const parts = path.split(/[\\/]/);
  return parts[parts.length - 1] ?? path;
}

export function isPDFName(name: string): boolean {
  return name.toLowerCase().endsWith(".pdf");
}

async function readPaths(paths: string[]): Promise<PickedFile[]> {
  const { readFile } = await import("@tauri-apps/plugin-fs");
  const files: PickedFile[] = [];
  for (const path of paths) {
    try {
      files.push({ name: baseName(path), bytes: await readFile(path) });
    } catch (error) {
      console.error("Lecture du fichier impossible", path, error);
    }
  }
  return files;
}

/// « Choisir un PDF » : une ou plusieurs fiches. Liste vide si on annule.
export async function pickPDFs(multiple = true): Promise<PickedFile[]> {
  if (inNative()) {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const chosen = await open({ multiple, filters: [{ name: "PDF", extensions: ["pdf"] }] });
    if (chosen === null) return [];
    return readPaths(Array.isArray(chosen) ? chosen : [chosen]);
  }
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "application/pdf,.pdf";
    input.multiple = multiple;
    input.onchange = async () => resolve(await readBrowserFiles([...(input.files ?? [])]));
    input.oncancel = () => resolve([]);
    input.click();
  });
}

export async function readBrowserFiles(files: File[]): Promise<PickedFile[]> {
  return Promise.all(files.filter((file) => isPDFName(file.name))
    .map(async (file) => ({ name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) })));
}

/// Ce qu'un dépôt peut annoncer : le survol (pour l'encadré pointillé) puis les PDF déposés.
export interface DropHandlers {
  onTarget(active: boolean): void;
  onDrop(files: PickedFile[]): void;
}

/// Écoute les dépôts de fichiers PDF sur la fenêtre ; rend de quoi se désabonner.
export async function listenForPDFDrops(handlers: DropHandlers): Promise<() => void> {
  if (inNative()) {
    const { getCurrentWebview } = await import("@tauri-apps/api/webview");
    const off = await getCurrentWebview().onDragDropEvent(async (event) => {
      const payload = event.payload;
      if (payload.type === "enter" || payload.type === "over") handlers.onTarget(true);
      else if (payload.type === "leave") handlers.onTarget(false);
      else if (payload.type === "drop") {
        handlers.onTarget(false);
        const pdfs = payload.paths.filter(isPDFName);
        if (pdfs.length > 0) handlers.onDrop(await readPaths(pdfs));
      }
    });
    return off;
  }
  const over = (event: DragEvent) => {
    if (event.dataTransfer?.types.includes("Files")) { event.preventDefault(); handlers.onTarget(true); }
  };
  const leave = () => handlers.onTarget(false);
  const drop = async (event: DragEvent) => {
    event.preventDefault();
    handlers.onTarget(false);
    const files = await readBrowserFiles([...(event.dataTransfer?.files ?? [])]);
    if (files.length > 0) handlers.onDrop(files);
  };
  window.addEventListener("dragover", over);
  window.addEventListener("dragleave", leave);
  window.addEventListener("drop", drop);
  return () => {
    window.removeEventListener("dragover", over);
    window.removeEventListener("dragleave", leave);
    window.removeEventListener("drop", drop);
  };
}
