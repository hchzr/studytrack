// Le PDF de chaque série, gardé sur l'appareil (StudyKit/SeriesPDFStore.swift).
//
// L'énoncé « exercice par exercice » du chrono ne montrait rien quand l'import
// n'avait pas extrait de texte — c'est-à-dire presque toujours pour un PDF de
// maths, dont les formules ne survivent pas à l'extraction. Le PDF lui-même les a :
// on en montre la bande qui correspond à l'exercice, telle qu'imprimée.
//
// Dans l'app, le fichier est copié dans `AppLocalData/SeriesPDF/<id>.pdf` ; dans le
// navigateur (aperçu) il reste en mémoire le temps de la page.
//
// Un énoncé qui vient de la synchronisation (iPhone) n'a que son adresse : à la
// première ouverture on le télécharge (`ensure`) — jamais en avance, jamais en
// boucle — et la copie reste sur l'appareil, nulle part ailleurs.

import { MoodleLinks, SiteLinks } from "../domain/botafogoProgram.ts";
import { inNative } from "../native/tauri.ts";
import { nativeFetch } from "../native/http.ts";
import { SiteError, siteAvailable, siteDownload } from "./siteSession.ts";

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

// MARK: - Téléchargement d'un énoncé distant (SeriesPDFStore.download)

/** Au-delà, ce n'est plus un énoncé de série : on n'en garde pas la copie. */
export const maxPDFBytes = 50 * 1024 * 1024;

export type DownloadFailure = "noDocument" | "notSignedIn" | "notPDF" | "tooLarge" | "timeout" | "http" | "network";

/** Pourquoi l'énoncé n'a pas pu être téléchargé (`SeriesPDFStore.Failure`). */
export class SeriesPDFError extends Error {
  constructor(readonly kind: DownloadFailure, readonly status?: number) {
    super(SeriesPDFError.describe(kind, status));
    this.name = "SeriesPDFError";
  }

  static describe(kind: DownloadFailure, status?: number): string {
    switch (kind) {
      case "noDocument": return "Cette série n'a pas de PDF à télécharger.";
      case "notSignedIn": return "Connecte-toi à Moodle pour télécharger cet énoncé.";
      case "notPDF": return "Ce lien ne mène pas à un PDF.";
      case "tooLarge": return "Ce PDF dépasse 50 Mo : il n'est pas téléchargé.";
      case "timeout": return "Le site ne répond pas. Vérifie ta connexion.";
      case "http": return `Le site a refusé le téléchargement (erreur ${status ?? "HTTP"}).`;
      case "network": return "Téléchargement impossible. Vérifie ta connexion.";
    }
  }
}

function parse(address: string): URL | null {
  try { return new URL(address.trim()); } catch { return null; }
}

/// L'adresse d'un PDF : un fichier, ou une activité Moodle qui en porte un.
/// Une page web de série (Botafogo, proginsc) n'en est pas un.
export function documentURL(address: string): URL | null {
  const url = parse(address);
  if (url === null || !url.protocol.startsWith("http")) return null;
  if (MoodleLinks.activityModule(url) !== null || MoodleLinks.isDocument(url.toString())) return url;
  if (url.hostname.includes("dropbox.com")) return url;
  return null;
}

/// Un lien Dropbox partagé mène à une page ; `dl=1` en fait le fichier.
export function directURL(url: URL): URL {
  if (!url.hostname.includes("dropbox.com")) return url;
  const result = new URL(url.toString());
  result.searchParams.delete("dl");
  result.searchParams.append("dl", "1");
  return result;
}

/// Un PDF commence par « %PDF » (parfois après quelques octets de bruit).
export function isPDF(bytes: Uint8Array): boolean {
  const head = bytes.subarray(0, 1024);
  for (let i = 0; i + 3 < head.length; i++) {
    if (head[i] === 0x25 && head[i + 1] === 0x50 && head[i + 2] === 0x44 && head[i + 3] === 0x46) return true;
  }
  return false;
}

/// Une erreur de transport, dite en français.
export function mapError(error: unknown): SeriesPDFError {
  if (error instanceof SeriesPDFError) return error;
  if (error instanceof SiteError) {
    if (error.kind === "notSignedIn") return new SeriesPDFError("notSignedIn");
    if (error.kind === "timeout") return new SeriesPDFError("timeout");
    const http = /^HTTP (\d{3})$/.exec(error.message);
    if (http) return statusError(Number(http[1]));
    return new SeriesPDFError("network");
  }
  const message = error instanceof Error ? error.message : String(error);
  if (/timed out|timeout/i.test(message)) return new SeriesPDFError("timeout");
  return new SeriesPDFError("network");
}

function statusError(status: number): SeriesPDFError {
  return status === 401 || status === 403 ? new SeriesPDFError("notSignedIn") : new SeriesPDFError("http", status);
}

/** Ce que le téléchargement demande au réseau (remplaçable dans les tests). */
export interface DownloadDeps {
  /** Un fichier Moodle, avec la session de l'étudiant·e. */
  siteBytes(url: string): Promise<Uint8Array>;
  /** Un lien public. */
  publicBytes(url: string): Promise<Uint8Array>;
}

const defaultDeps: DownloadDeps = {
  siteBytes: (url) => siteDownload(url, { timeout: 60 }),
  async publicBytes(url) {
    const response = await nativeFetch(url, { method: "GET" });
    if (!response.ok) throw statusError(response.status);
    const length = Number(response.headers.get("content-length") ?? "0");
    if (length > maxPDFBytes) throw new SeriesPDFError("tooLarge");
    return new Uint8Array(await response.arrayBuffer());
  },
};

function checked(bytes: Uint8Array): Uint8Array {
  if (bytes.length > maxPDFBytes) throw new SeriesPDFError("tooLarge");
  if (!isPDF(bytes)) throw new SeriesPDFError("notPDF");
  return bytes;
}

/// Télécharge ; une page d'activité Moodle (page, dossier, « cliquez ici ») est
/// suivie jusqu'au PDF qu'elle désigne, deux sauts au plus
/// (`AuthenticatedDownloader.fetch`).
async function fetchMoodle(address: URL, depth: number, deps: DownloadDeps): Promise<Uint8Array> {
  const url = SiteLinks.normalize(address);
  const bytes = await deps.siteBytes(url.toString());
  if (isPDF(bytes)) return checked(bytes);
  // Une page HTML : celle d'une activité Moodle qui porte le lien du PDF, ou une page de connexion.
  const html = new TextDecoder().decode(bytes.length > 2_000_000 ? bytes.subarray(0, 2_000_000) : bytes);
  const next = MoodleLinks.statementLink(html, url).statement;
  const nextURL = next === null ? null : parse(next);
  if (depth < 2 && nextURL !== null && nextURL.toString() !== url.toString()) return fetchMoodle(nextURL, depth + 1, deps);
  if (depth === 0 && MoodleLinks.activityModule(url) !== null && MoodleLinks.workaroundPage(url).toString() !== url.toString()) {
    return fetchMoodle(MoodleLinks.workaroundPage(url), depth + 1, deps);
  }
  if (/\/login\/index\.php|name=["']username["']/i.test(html)) throw new SeriesPDFError("notSignedIn");
  throw new SeriesPDFError("notPDF");
}

/// Les octets du PDF d'une adresse (`SeriesPDFStore.download`) : Moodle avec la
/// session, le reste en https public. Vérifie que c'est bien un PDF.
export async function download(url: URL, deps: DownloadDeps = defaultDeps): Promise<Uint8Array> {
  try {
    if (url.hostname.includes("moodle")) {
      if (deps === defaultDeps && !siteAvailable()) throw new SeriesPDFError("network");
      return await fetchMoodle(url, 0, deps);
    }
    if (url.protocol !== "https:") throw new SeriesPDFError("noDocument");
    return checked(await deps.publicBytes(directURL(url).toString()));
  } catch (error) {
    throw mapError(error);
  }
}

/// Peut-on espérer un PDF pour cette série ? (Copie locale, ou adresse de PDF à télécharger.)
export function hasRemoteDocument(urlString: string): boolean {
  return documentURL(urlString) !== null;
}

const inFlight = new Map<string, Promise<Uint8Array>>();

/// Le PDF de la série : la copie de l'appareil, sinon téléchargé **maintenant**
/// (première ouverture) puis gardé. Un seul téléchargement à la fois par série.
export function ensure(series: { id: string; urlString: string }, deps?: DownloadDeps): Promise<Uint8Array> {
  const running = inFlight.get(series.id);
  if (running) return running;
  const task = (async () => {
    const local = await localFile(series.id);
    if (local) return local;
    const remote = documentURL(series.urlString);
    if (remote === null) throw new SeriesPDFError("noDocument");
    const bytes = await download(remote, deps);
    await keep(bytes, series.id);
    return bytes;
  })();
  inFlight.set(series.id, task);
  const clear = () => { inFlight.delete(series.id); };
  task.then(clear, clear);
  return task;
}

export const SeriesPDFStore = { keep, forget, localFile, hasDocument, documentURL, hasRemoteDocument, download, ensure };
