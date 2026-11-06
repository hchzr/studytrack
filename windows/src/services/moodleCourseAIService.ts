// Demande au modèle comment ranger un cours Moodle (StudyKit/MoodleCourseAIService.swift).
//
// Le service partagé (`analyze-course`, fonction Supabase : la clé du fournisseur est
// côté serveur) ; le modèle de l'appareil n'existe pas sur Windows. La réponse est
// **gardée** pour ce plan de cours : la mise à jour automatique ne redemande que si le
// cours a changé sur Moodle. Une seule réponse gardée par cours (la dernière).

import type { MoodleCourseSnapshot } from "../domain/moodleCourseAnalyzer.ts";
import type { ScrapedCourse } from "../domain/courseContentImport.ts";
import { MoodleCourseAI } from "../domain/moodleAIHint.ts";
import type { MoodleCourseAIAnswer } from "../domain/moodleAIHint.ts";
import { AppLog } from "../domain/appLog.ts";
import { supabaseConfig } from "./syncConfig.ts";
import { nativeFetch } from "../native/http.ts";
import { installID, readAIExtraction } from "../native/settings.ts";
import { ExtractionError } from "./seriesAIExtractor.ts";

/**
 * Change quand le modèle du serveur change : les réponses gardées sont redemandées
 * une fois (passage à GPT-6 Luna après le banc d'essai du 3 octobre 2026).
 */
export const analysisVersion = "gpt-6-luna.2026-10-03";

async function sha1(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function emptyAnswer(): MoodleCourseAIAnswer {
  return MoodleCourseAI.answer("");
}

function readCache(key: string): { print?: string; structure?: string; at?: number; raw?: string } | null {
  try {
    const raw = globalThis.localStorage?.getItem(key);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function writeCache(key: string, value: object): void {
  try { globalThis.localStorage?.setItem(key, JSON.stringify(value)); } catch { /* stockage refusé */ }
}

async function askShared(payload: Record<string, unknown>, signal?: AbortSignal): Promise<string> {
  const config = supabaseConfig();
  if (!config) throw new ExtractionError("unavailable");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 150_000);
  const relay = () => controller.abort();
  signal?.addEventListener("abort", relay);
  try {
    const response = await nativeFetch(`${config.url}/functions/v1/analyze-course`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: config.anonKey,
        Authorization: `Bearer ${config.anonKey}`,
        "x-polymestre-install": installID(),
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const text = await response.text();
    if (!(response.status >= 200 && response.status < 300)) {
      throw new ExtractionError("remote", `analyze-course : HTTP ${response.status} ${text.slice(0, 160)}`);
    }
    return text;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", relay);
  }
}

export interface AnalyzeOptions {
  termStart: Date | null;
  totalWeeks: number;
  plan?: string | null;
  moocs?: ScrapedCourse[];
  sources?: string | null;
  signal?: AbortSignal;
  /** Injectable : l'ordre « maintenant » du cache. */
  now?: Date;
}

/** Le cours rangé par le modèle : ses activités, et — quand le plan et le MOOC sont fournis — les chapitres à regarder. */
export async function analyze(snapshot: MoodleCourseSnapshot, o: AnalyzeOptions): Promise<MoodleCourseAIAnswer> {
  if (!readAIExtraction()) return emptyAnswer();
  const payload = MoodleCourseAI.payload(snapshot, o.termStart, o.totalWeeks, o.plan ?? null, o.moocs ?? []);
  const sources = o.sources ?? null;
  if (sources !== null && sources !== "") payload.sources = sources.slice(0, 16_000);
  let outline = (payload.outline as string | undefined) ?? "";
  if (outline === "" && sources !== null && sources !== "") {
    outline = "(cours vide sur Moodle)";
    payload.outline = outline + "\n" + sources.slice(0, 200);
  }
  if (outline === "") return emptyAnswer();
  // La consigne fait partie de l'empreinte : la changer redemande au modèle.
  const fingerprint = [analysisVersion, MoodleCourseAI.instructions, outline,
    (payload.plan as string | undefined) ?? "", (payload.mooc as string | undefined) ?? "",
    (payload.sources as string | undefined) ?? ""].join("|");
  const key = "moodleAI4." + await sha1(snapshot.url === "" ? snapshot.title : snapshot.url);
  const print = await sha1(fingerprint);
  const structure = await sha1(analysisVersion + "|" + MoodleCourseAI.instructions + "|"
    + MoodleCourseAI.structure(snapshot, o.moocs ?? [], (o.plan ?? "") !== ""));
  const cached = readCache(key);
  if (cached && cached.raw !== undefined
      && MoodleCourseAI.reuses(cached.structure ?? null, cached.print ?? null,
        cached.at !== undefined ? new Date(cached.at * 1000) : null, structure, print, o.now ?? new Date())) {
    return MoodleCourseAI.answer(cached.raw);
  }

  let raw: string;
  try {
    raw = await askShared(payload, o.signal);
  } catch (error) {
    if (o.signal?.aborted) throw error;
    void AppLog.record("info", "import", "Rangement du cours par l'IA : service indisponible",
      error instanceof Error ? error.message : String(error));
    return emptyAnswer();
  }
  const answer = MoodleCourseAI.answer(raw);
  if (Object.keys(answer.hints).length > 0 || Object.keys(answer.guide).length > 0) {
    writeCache(key, { print, structure, at: Date.now() / 1000, raw });
    void AppLog.record("info", "import", "Cours rangé avec l'IA",
      `${snapshot.title} — ${Object.keys(answer.hints).length} activités, ${answer.series.length} séries, ${Object.keys(answer.moocWeeks).length} chapitres de MOOC, ${Object.keys(answer.guide).length} semaines expliquées`);
  }
  return answer;
}

export const MoodleCourseAIService = { analysisVersion, analyze };
