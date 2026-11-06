// Supabase Edge Function : le tuteur de StudyTrack quand Claude Code n'est pas sur l'appareil.
//
// L'app passe d'abord par Claude (l'abonnement de l'étudiant·e, en local). Sans lui, elle
// appelle ici un modèle **gratuit** d'abord, puis payant en repli :
//   1. Groq (offre gratuite) — LLM_API_KEY, TUTOR_GROQ_MODEL (« openai/gpt-oss-120b » par défaut) ;
//   2. OpenRouter — OPENROUTER_API_KEY, TUTOR_FREE_MODEL (un modèle « :free », facultatif),
//      puis TUTOR_MODEL (« deepseek/deepseek-v4.1-flash » par défaut, peu cher).
//   supabase functions deploy tutor --project-ref aaigscutkuefhqftfszv
//
// Le client choisit un **mode** (tuteur, fiche, méthodes), jamais la consigne : elles sont
// recopiées de l'app (prompts.generated.ts, vérifié par les tests de l'app). Plafonds par
// installation, par adresse et par jour (_shared/limits.ts). Rien n'est gardé côté serveur.

import { allowed } from "../_shared/limits.ts";
import { recordUsage } from "../_shared/usage.ts";
import { PROMPTS } from "./prompts.generated.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-polymestre-install, x-studytrack-install",
};

const MAX_BODY = 260_000;
const MAX_MESSAGES = 60;

type Message = { role: "user" | "assistant"; content: string };
type Candidate = { name: string; baseURL: string; apiKey: string; model: string };

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  let body: { mode?: string; messages?: Message[] };
  try {
    const raw = await request.text();
    if (raw.length > MAX_BODY) return json({ error: "conversation trop longue : recommence-en une" }, 413);
    body = JSON.parse(raw);
  } catch {
    return json({ error: "JSON invalide" }, 400);
  }
  const mode = body.mode ?? "tutor";
  const current = PROMPTS[mode];
  if (!current) return json({ error: "mode inconnu" }, 400);
  // Une app d'avant le changement de nom (sans `x-polymestre-install`) ne lit que ses
  // anciennes balises : elle les reçoit dans la consigne.
  const system = request.headers.has("x-polymestre-install") ? current : current
    .replaceAll("[Polymestre]", "[StudyTrack]").replaceAll("[/Polymestre]", "[/StudyTrack]")
    .replaceAll("```polymestre", "```studytrack");
  const messages = (body.messages ?? [])
    .filter((m) => (m.role === "user" || m.role === "assistant") && typeof m.content === "string" && m.content.trim() !== "")
    .slice(-MAX_MESSAGES);
  if (messages.length === 0 || messages[messages.length - 1].role !== "user") return json({ error: "pas de question" }, 400);

  const gate = await allowed(request, mode === "tutor"
    ? { name: "tutor", perInstallPerHour: 80, globalPerDay: 6000 }
    : { name: "tutor-sheet", perInstallPerHour: 6, globalPerDay: 300 });
  if (!gate.ok) return json({ error: gate.reason }, 429);

  const candidates: Candidate[] = [];
  const groq = Deno.env.get("LLM_API_KEY");
  if (groq) {
    candidates.push({ name: "Groq (gratuit)", baseURL: Deno.env.get("LLM_BASE_URL") ?? "https://api.groq.com/openai/v1", apiKey: groq,
      model: Deno.env.get("TUTOR_GROQ_MODEL") ?? "openai/gpt-oss-120b" });
  }
  const openRouter = Deno.env.get("OPENROUTER_API_KEY");
  if (openRouter) {
    const free = Deno.env.get("TUTOR_FREE_MODEL");
    if (free) candidates.push({ name: "OpenRouter (gratuit)", baseURL: "https://openrouter.ai/api/v1", apiKey: openRouter, model: free });
    candidates.push({ name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", apiKey: openRouter,
      model: Deno.env.get("TUTOR_MODEL") ?? "deepseek/deepseek-v4.1-flash" });
  }
  if (candidates.length === 0) return json({ error: "aucun modèle configuré sur le serveur" }, 503);

  const errors: string[] = [];
  for (const candidate of candidates) {
    const started = Date.now();
    try {
      const { content, usage } = await ask(candidate, [{ role: "system", content: system }, ...messages], mode !== "tutor");
      recordUsage(`tutor:${mode}`, candidate.baseURL, candidate.model, usage, Date.now() - started);
      if (!content.trim()) throw new Error("réponse vide");
      return json({ text: content, model: candidate.model, provider: candidate.name });
    } catch (error) {
      errors.push(`${candidate.model} : ${(error as Error).message}`);
    }
  }
  return json({ error: "les modèles ne répondent pas, réessaie dans un instant", detail: errors }, 502);
});

async function ask(candidate: Candidate, messages: Array<{ role: string; content: string }>, asJSON: boolean):
  Promise<{ content: string; usage: unknown }> {
  const payload: Record<string, unknown> = {
    model: candidate.model,
    temperature: asJSON ? 0 : 0.3,
    messages,
    max_completion_tokens: asJSON ? 16000 : 4000,
  };
  if (asJSON) payload.response_format = { type: "json_object" };
  if (candidate.model.includes("gpt-oss")) payload.reasoning_effort = "low";
  if (candidate.baseURL.includes("openrouter.ai")) {
    payload.usage = { include: true };
    payload.reasoning = candidate.model.includes("gpt-oss") ? { effort: "low" } : { enabled: false };
  }
  const response = await fetch(`${candidate.baseURL}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${candidate.apiKey}` },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(asJSON ? 140_000 : 60_000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`HTTP ${response.status} ${text.slice(0, 160)}`);
  const data = JSON.parse(text);
  return { content: data.choices?.[0]?.message?.content ?? "", usage: data.usage ?? null };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
