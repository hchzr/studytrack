// Extraction des séries et exercices d'un PDF par un modèle de langage
// (StudyKit/SeriesAIExtractor.swift).
//
// Sur Windows il n'y a qu'un moteur : la **fonction Supabase de l'app**
// (`extract-series`), dont la clé du fournisseur est côté serveur — l'app n'a
// besoin que de sa clé `anon`. Le modèle embarqué d'Apple (FoundationModels)
// n'existe pas ici ; `SeriesEngineOrder` reste la définition de l'ordre.
//
// La réponse **complète** l'heuristique et passe par l'écran de relecture : le
// modèle propose, l'étudiant·e dispose. Rien n'est créé sur sa seule parole.

import type { DetectedSeries } from "./seriesPDFParser.ts";
import { SeriesAIParsing } from "../domain/seriesAIParsing.ts";
import { SeriesEngineOrder } from "../domain/seriesEngineOrder.ts";
import { supabaseConfig } from "./syncConfig.ts";
import { nativeFetch } from "../native/http.ts";
import { installID } from "../native/settings.ts";

/// D'où vient la structure proposée à la relecture.
export type SeriesExtractionSource = "heuristic" | "onDevice" | "shared" | "vision";

export const SeriesExtractionSource = {
  label(source: SeriesExtractionSource): string {
    switch (source) {
      case "heuristic": return "détection par motifs";
      case "onDevice": return "IA sur l'appareil";
      case "shared": return "IA Polymestre (sans clé)";
      case "vision": return "IA Polymestre · lecture des pages";
    }
  },
  /// Le moteur a-t-il vu la mise en page ? Sa lecture des sous-questions l'emporte
  /// alors sur celle du texte (`SeriesAIParsing.merge`).
  readsLayout(source: SeriesExtractionSource): boolean { return source === "vision"; },
  icon(source: SeriesExtractionSource): string {
    switch (source) {
      case "heuristic": return "text.magnifyingglass";
      case "onDevice": return "apple.intelligence";
      case "shared": return "sparkles";
      case "vision": return "eye";
    }
  },
};

export type ExtractionErrorKind = "unavailable" | "remote" | "sharedNotDeployed" | "emptyAnswer";

export class ExtractionError extends Error {
  constructor(readonly kind: ExtractionErrorKind, readonly detail: string | number = "") {
    super(ExtractionError.describe(kind, detail));
  }

  static describe(kind: ExtractionErrorKind, detail: string | number): string {
    switch (kind) {
      case "unavailable":
        return "Aucun modèle disponible : l'analyse IA est désactivée, ou aucun moteur n’est joignable (Réglages › IA de lecture).";
      case "remote":
        return `Le service distant a refusé : ${detail}`;
      case "sharedNotDeployed":
        return `La fonction d'analyse n'est pas déployée sur ton projet Supabase (HTTP ${detail}). L'import par motifs a quand même lu le PDF.\n\n`
          + "Pour l'activer, une seule fois, depuis le dossier du projet :\n"
          + "    supabase functions deploy extract-series --project-ref <ta-ref>\n"
          + "    supabase secrets set LLM_API_KEY=<ta-clé>\n"
          + "Le détail est dans docs/configuration.md.";
      case "emptyAnswer":
        return "Le modèle n'a rien trouvé de structuré dans ce texte.";
    }
  }
}

/// La fonction partagée existe dès que la build porte une configuration Supabase.
/// Si elle n'est pas déployée, l'appel échoue proprement.
export function isSharedAvailable(): boolean { return supabaseConfig() !== null; }

/// La fonction partagée a-t-elle répondu au moins une fois dans cette session ?
/// `null` = jamais essayée. `false` = 404 constaté, on n'insiste plus.
let sharedVerdict: boolean | null = null;
export function sharedIsReachable(): boolean { return sharedVerdict !== false; }
/** Remet le constat à zéro (tests). */
export function resetSharedVerdict(): void { sharedVerdict = null; }

/// Les moteurs à essayer, dans l'ordre (le modèle embarqué n'existe pas ici).
export function engineOrder(): ("shared" | "onDevice")[] {
  return SeriesEngineOrder.engines(isSharedAvailable() && sharedIsReachable(), false);
}

/// Le moteur qui servira, selon les réglages.
export function plannedSource(aiExtractionEnabled: boolean): SeriesExtractionSource | null {
  if (!aiExtractionEnabled) return null;
  return engineOrder().length > 0 ? "shared" : null;
}

export interface ExtractOptions {
  pageImages?: Uint8Array[];
  seriesHint?: number | null;
  language?: string | null;
  aiExtractionEnabled: boolean;
  signal?: AbortSignal;
}

/// Extraction d'un texte **déjà préparé** — celui de `prepareLayout`, qui garde
/// titres, retraits et l'indice de série. Le préparer une seconde fois le ramènerait
/// à un texte aplati.
export async function extract(prepared: string, o: ExtractOptions): Promise<{ series: DetectedSeries[]; source: SeriesExtractionSource }> {
  if (!o.aiExtractionEnabled || engineOrder().length === 0) throw new ExtractionError("unavailable");
  let lastError: unknown = new ExtractionError("emptyAnswer");
  const pageImages = o.pageImages ?? [];
  // Les pages d'abord : c'est la seule lecture fiable des sous-questions. Le texte
  // reste le repli, dans le même maillon.
  if (pageImages.length > 0) {
    try {
      const seen = await extractSharedVision(pageImages, prepared, o.seriesHint ?? null, o.language ?? null, o.signal);
      if (seen.length > 0) return { series: seen, source: "vision" };
    } catch (error) {
      if (o.signal?.aborted) throw error;
      if (error instanceof ExtractionError && error.kind === "sharedNotDeployed") throw error;
      console.warn("Lecture des pages impossible", error);
    }
  }
  try {
    const series = await callShared({ text: prepared }, 45, o.signal);
    if (series.length > 0) return { series, source: "shared" };
    lastError = new ExtractionError("emptyAnswer");
  } catch (error) {
    if (o.signal?.aborted) throw error;
    lastError = error;
  }
  throw lastError;
}

/// Les pages en image : plus lent (un paquet de cinq pages par appel côté serveur),
/// d'où un délai plus large. Le texte extrait part avec les images : ses numéros et
/// son vocabulaire sont exacts, ses formules non.
async function extractSharedVision(pages: Uint8Array[], text: string, seriesHint: number | null,
  language: string | null, signal?: AbortSignal): Promise<DetectedSeries[]> {
  const body: Record<string, unknown> = { images: pages.map(toBase64), text };
  if (seriesHint !== null) body.seriesHint = seriesHint;
  // Le texte n'accompagne pas toujours les images : la langue voyage donc à part.
  if (language !== null) body.language = language;
  return callShared(body, 150, signal);
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

async function callShared(body: Record<string, unknown>, timeoutSeconds: number, signal?: AbortSignal): Promise<DetectedSeries[]> {
  const config = supabaseConfig();
  if (!config) throw new ExtractionError("unavailable");
  // Le délai et l'arrêt de l'utilisateur·rice sont deux raisons d'abandonner.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutSeconds * 1000);
  const relay = () => controller.abort();
  signal?.addEventListener("abort", relay);
  try {
    const response = await nativeFetch(`${config.url}/functions/v1/extract-series`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: config.anonKey,
        Authorization: `Bearer ${config.anonKey}`,
        "x-polymestre-install": installID(),
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    if (!(response.status >= 200 && response.status < 300)) {
      // 404 = la fonction n'existe pas. Le dire précisément évite de chercher du
      // côté du réseau, de la clé ou du modèle — trois fausses pistes.
      if (response.status === 404) {
        sharedVerdict = false;
        throw new ExtractionError("sharedNotDeployed", response.status);
      }
      const detail = (await response.text()).slice(0, 200);
      throw new ExtractionError("remote", `fonction Polymestre : HTTP ${response.status} ${detail}`);
    }
    const raw = await response.text();
    sharedVerdict = true;
    return SeriesAIParsing.parse(raw);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", relay);
  }
}

/// Ce que vaut la fonction partagée, en quatre cas **distincts** : « pas déployée »
/// et « déployée mais en échec » demandent deux gestes opposés.
export type SharedVerdict =
  | { kind: "ready" }
  | { kind: "notDeployed"; status: number }
  | { kind: "failing"; detail: string }
  | { kind: "unconfigured" };

/// Vérifie la fonction partagée sans dépendre d'un import, pour l'écran de réglages.
export async function diagnoseShared(): Promise<SharedVerdict> {
  if (!isSharedAvailable()) return { kind: "unconfigured" };
  try {
    await callShared({ text: "Série 1\nExercice 1.1" }, 45);
    return { kind: "ready" };
  } catch (error) {
    if (error instanceof ExtractionError && error.kind === "sharedNotDeployed") {
      return { kind: "notDeployed", status: Number(error.detail) };
    }
    return { kind: "failing", detail: error instanceof Error ? error.message : String(error) };
  }
}

export const SeriesAIExtractor = { plannedSource, extract, diagnoseShared, engineOrder, isSharedAvailable, sharedIsReachable };
