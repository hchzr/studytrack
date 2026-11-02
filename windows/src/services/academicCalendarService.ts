// Tient le calendrier académique à jour dans l'app
// (StudyTrack/Services/AcademicCalendarService.swift).
//
// Deux sources, dans cet ordre :
//   1. **L'instantané embarqué** — disponible hors ligne dès l'installation, et le jour
//      de la rentrée, quand on n'a justement pas de réseau ;
//   2. **La page publique de l'EPFL**, relue à la demande. L'EPFL publie deux semestres
//      à la fois et fait glisser la fenêtre chaque année : sans relecture, l'app saurait
//      le semestre en cours mais pas le suivant.

import { AcademicCalendarParser } from "../domain/academicCalendar.ts";
import { AcademicMilestone } from "../models/academicMilestone.ts";
import type { ModelStore } from "../models/store.ts";
import { Plural } from "../domain/plural.ts";
import { nativeFetch } from "../native/http.ts";

export class RefreshError extends Error {
  constructor(readonly kind: "network" | "http" | "empty" | "unreadable", detail: string | number = "") {
    super(kind === "network" ? `Téléchargement impossible : ${detail}`
      : kind === "http" ? `La page de l'EPFL a répondu ${detail}.`
      : kind === "empty" ? "La page ne contient aucune date lisible." : "La page n'a pas pu être lue comme du texte.");
  }
}

export interface RefreshResult {
  added: number;
  updated: number;
  removed: number;
  total: number;
}

export function refreshMessage(result: RefreshResult): string {
  const parts = [Plural.count(result.total, `${result.total} échéance`, `${result.total} échéances`) + " à jour"];
  if (result.added > 0) parts.push(Plural.count(result.added, `${result.added} ajoutée`, `${result.added} ajoutées`));
  if (result.updated > 0) parts.push(Plural.count(result.updated, `${result.updated} corrigée`, `${result.updated} corrigées`));
  if (result.removed > 0) parts.push(Plural.count(result.removed, `${result.removed} retirée`, `${result.removed} retirées`));
  return parts.join(" · ");
}

/** Installe l'instantané si l'app ne connaît encore aucune échéance. Idempotent. */
export function seedIfNeeded(store: ModelStore): number {
  return AcademicMilestone.installSnapshotIfNeeded(store);
}

/** Télécharge la page. Séparé de l'analyse : le réseau se teste à part du parseur, qui est pur. */
export async function fetchPage(urlString: string, fetcher: (url: string, init?: RequestInit) => Promise<Response> = nativeFetch): Promise<string> {
  const raw = urlString.trim();
  let url: URL;
  try { url = new URL(raw); } catch { throw new RefreshError("network", "adresse invalide"); }
  if (raw === "" || !url.protocol.startsWith("http")) throw new RefreshError("network", "adresse invalide");
  let response: Response;
  try {
    // Sans en-tête explicite, certains serveurs renvoient une page allégée.
    response = await fetcher(url.href, { headers: { "Accept-Language": "fr-CH,fr;q=0.9" } });
  } catch (error) {
    throw new RefreshError("network", error instanceof Error ? error.message : String(error));
  }
  if (!(response.status >= 200 && response.status < 300)) throw new RefreshError("http", response.status);
  return response.text();
}

/** Relit la page publique et met le calendrier à jour. */
export async function refresh(store: ModelStore, urlString: string = AcademicCalendarParser.sourceURL,
  fetcher?: (url: string, init?: RequestInit) => Promise<Response>): Promise<RefreshResult> {
  const html = await fetchPage(urlString, fetcher);
  const values = AcademicCalendarParser.parse(html);
  if (values.length === 0) throw new RefreshError("empty");
  const outcome = AcademicMilestone.upsert(values, store);
  return { added: outcome.added, updated: outcome.updated, removed: outcome.removed, total: values.length };
}

export const AcademicCalendarService = { sourceURL: AcademicCalendarParser.sourceURL, seedIfNeeded, refresh, fetch: fetchPage };
