// Le PDF de chaque série, gardé sur l'appareil (StudyKit/SeriesPDFStore.swift).
//
// L'énoncé « exercice par exercice » du chrono ne montrait rien quand l'import
// n'avait pas extrait de texte — c'est-à-dire presque toujours pour un PDF de
// maths, dont les formules ne survivent pas à l'extraction. Le PDF lui-même les a :
// on en montre la bande qui correspond à l'exercice, telle qu'imprimée.
//
// Dans l'app, le fichier est copié dans `AppLocalData/SeriesPDF/<id>.pdf` ; dans le
// navigateur (aperçu) il reste en mémoire le temps de la page. Le téléchargement
// d'un énoncé distant (Moodle authentifié) relève de l'import de contenu.

import { inNative } from "../native/tauri.ts";

const FOLDER = "SeriesPDF";

/** Copies en mémoire : seules vraies hors de l'app, et accélèrent la relecture dans l'app. */
const memory = new Map<string, Uint8Array>();

function fileName(seriesID: string): string {
  return `${seriesID.toUpperCase()}.pdf`;
}

async function fs() {
  const [{ BaseDirectory, exists, mkdir, readFile, remove, writeFile }] = await Promise.all([import("@tauri-apps/plugin-fs")]);
  return { BaseDirectory, exists, mkdir, readFile, remove, writeFile };
}

/// Garde un PDF importé à la main : la série n'a pas d'adresse, mais son énoncé
/// reste affichable dans le chrono.
export async function keep(bytes: Uint8Array, seriesID: string): Promise<void> {
  memory.set(seriesID, bytes);
  if (!inNative()) return;
  try {
    const { BaseDirectory, mkdir, writeFile } = await fs();
    await mkdir(FOLDER, { baseDir: BaseDirectory.AppLocalData, recursive: true });
    await writeFile(`${FOLDER}/${fileName(seriesID)}`, bytes, { baseDir: BaseDirectory.AppLocalData });
  } catch (error) {
    console.error("PDF de la série non gardé", error);
  }
}

/// L'énoncé a changé à la source : la copie gardée et ses découpes partent.
export async function forget(seriesID: string): Promise<void> {
  memory.delete(seriesID);
  if (!inNative()) return;
  try {
    const { BaseDirectory, remove } = await fs();
    await remove(`${FOLDER}/${fileName(seriesID)}`, { baseDir: BaseDirectory.AppLocalData });
  } catch {
    // Rien à oublier : pas de copie.
  }
}

/// Le PDF de cette série, **s'il est déjà sur l'appareil** : rien n'est téléchargé.
export async function localFile(seriesID: string): Promise<Uint8Array | null> {
  const cached = memory.get(seriesID);
  if (cached) return cached;
  if (!inNative()) return null;
  try {
    const { BaseDirectory, exists, readFile } = await fs();
    const path = `${FOLDER}/${fileName(seriesID)}`;
    if (!(await exists(path, { baseDir: BaseDirectory.AppLocalData }))) return null;
    const bytes = await readFile(path, { baseDir: BaseDirectory.AppLocalData });
    memory.set(seriesID, bytes);
    return bytes;
  } catch {
    return null;
  }
}

/// Peut-on espérer un PDF pour cette série ? (Copie locale seulement ici.)
export async function hasDocument(seriesID: string): Promise<boolean> {
  return (await localFile(seriesID)) !== null;
}

export const SeriesPDFStore = { keep, forget, localFile, hasDocument };
