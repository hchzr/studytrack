// Supabase Edge Function : rangement d'un cours Moodle par un LLM.
//
// L'app lit le plan d'un cours Moodle (sections, noms et types d'activités) et
// le range avec des règles écrites sur quelques cours réels. Pour les formats
// qu'elles ne connaissent pas (« TP 3 – Récursivité », « Séance du 14 », tout
// dans une seule section…), elle demande ici au modèle une étiquette par
// activité : nature (théorie, série, corrigé, échéance, document), semaine,
// numéro de série. Aucune donnée personnelle : uniquement le plan du cours.
//
// Le modèle lit tout ce que le cours montre (sections et consignes, cible et
// début de texte de chaque lien, plan du cours, MOOC) et dit, pour n'importe
// quel cours, où sont les énoncés et ce qu'il faut faire chaque semaine.
// DeepSeek d'abord (contexte long, bon en lecture de plans), Groq en repli :
//   supabase functions deploy analyze-course --project-ref aaigscutkuefhqftfszv
//   OPENROUTER_API_KEY, ANALYZE_MODEL (facultatif, « deepseek/deepseek-v4.1-flash » par défaut),
//   LLM_API_KEY (Groq), LLM_BASE_URL / LLM_MODEL (facultatifs, ensemble).

import { allowed, isEvaluation } from "../_shared/limits.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// La consigne est celle de l'app (`MoodleCourseAI.instructions`), recopiée
// ici : le serveur n'accepte plus celle du client, qui faisait de cette
// fonction un accès libre au modèle pour n'importe quelle consigne.
const INSTRUCTIONS = "Tu lis un cours de l'EPFL comme un·e étudiant·e attentif·ve, pour une app de suivi d'études. Tu reçois les sections Moodle (titre, semaine si connue, texte et consignes, liens cités « Lnn »), chaque activité (id, type Moodle, nom, où mène le lien, ce qu'est la cible et le début de son texte), et parfois le PLAN DU COURS et les MOOC cités (chapitres numérotés). Le cours peut avoir n'importe quelle forme : comprends-le d'après son contenu, pas d'après des habitudes.\nRéponds UNIQUEMENT par un objet JSON :\n{\"activities\":[{\"id\":\"123\",\"kind\":\"theory\",\"week\":3,\"series\":null}],\"series\":[{\"number\":3,\"week\":3,\"statement\":\"a123\",\"solution\":\"a124\"}],\"mooc\":[{\"week\":3,\"lessons\":[\"m1.2.4\",\"m1.2.5\"]}],\"weeks\":[{\"week\":3,\"todo\":\"…\"}]}\n- activities : une entrée par activité reçue, avec son id exact. kind : \"theory\" (cours, enregistrement, transparents, notes, polycopié, chapitre à lire), \"series\" (énoncé d'exercices à faire), \"solution\" (corrigé), \"deadline\" (rendu noté, devoir, projet, quiz noté), \"document\" (organisation, formulaire, ressource générale, ancien examen, matériel facultatif), \"ignore\" (forum, annonce, sondage, lien sans contenu). week : la semaine du semestre (1 à N) où l'activité se travaille — d'après la section, une date, un numéro (« Lecture 7 » avec deux cours par semaine → semaine 4) ou une consigne ; null si inconnue. series : son numéro de série pour \"series\" et \"solution\", sinon null.\n- series : chaque série d'exercices du cours, une entrée par numéro. statement : la référence (« a » + id d'activité, ou « Lnn » pour un lien du texte d'une section) qui mène à l'ÉNONCÉ LUI-MÊME, la page ou le PDF où sont les exercices. Choisis d'après ce que contient la cible (son début de texte), pas seulement d'après le nom : un lien « série 4 » qui mène à un chapitre de MOOC sans ces exercices n'est pas l'énoncé ; une page « énoncé/corrigé » ou « corrigé » qui contient aussi les énoncés peut l'être. solution : le corrigé s'il est à une autre adresse, sinon null. week : la semaine où la série se fait.\n- Les exercices et quiz d'un MOOC ne sont des séries que si le cours (consignes, plan) demande de les faire.\n- mooc : si un MOOC est fourni, ce qu'il faut en regarder chaque semaine — d'après le plan, les consignes des sections ou les liens de chaque semaine. Une entrée par semaine : {\"week\":N,\"lessons\":[\"m1.3.2\",\"m1.3.3\"]} avec les références des LEÇONS (mX.Y.Z) demandées cette semaine-là, et seulement elles (un plan qui dit « vidéos 1.6 à 1.8 » → ces trois leçons ; un chapitre coupé sur deux semaines → ses leçons réparties). Quand le cours demande un chapitre entier (« MOOC 2 : vidéos Module 3 »), donne {\"week\":N,\"id\":\"<id du chapitre>\"} : « Module 3 » est l'entrée « module 3 » du MOOC 2 (préambules hors numérotation). La semaine est celle de la ligne du plan ou de la section : ne la décale jamais. Uniquement des références et des id de la liste ; rien d'optionnel.\n- weeks : pour CHAQUE semaine du semestre où le plan ou Moodle prévoit quelque chose, y compris les semaines à venir, la consigne en une phrase courte (160 caractères au plus), concrète, à l'infinitif : quoi regarder (enregistrement, chapitres du MOOC et leurs numéros), quoi lire, quelle série faire, ce qui est à rendre. Uniquement d'après ce que tu as reçu.\n- Si d'AUTRES SOURCES du cours sont fournies (polycopié en ligne, site du cours), sers-t'en pour les consignes : chapitres à lire ou à regarder, séries à faire, semaine par semaine.\n- N'invente aucun id ni aucune référence.";

/** Un plan de cours dépasse rarement 12 000 caractères ; au-delà, on tronque. */
const MAX_OUTLINE = 60000;

/** Une requête de l'app pèse au plus ~130 000 caractères ; au-delà, refusée. */
const MAX_BODY = 200_000;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const evaluation = isEvaluation(request);
  if (!evaluation) {
    const gate = await allowed(request, { name: "analyze-course", perIPPerHour: 40, globalPerDay: 2000 });
    if (!gate.ok) return json({ error: gate.reason }, 429);
  }
  let body: { outline?: string; weeks?: number; course?: string; plan?: string; mooc?: string; sources?: string; model?: string; provider?: unknown };
  try {
    const raw = await request.text();
    if (raw.length > MAX_BODY) return json({ error: "requête trop lourde" }, 413);
    body = JSON.parse(raw);
  } catch {
    return json({ error: "JSON invalide" }, 400);
  }
  const outline = (body.outline ?? "").slice(0, MAX_OUTLINE);
  if (!outline.trim()) return json({ error: "plan vide" }, 400);
  let user = `Cours : ${body.course ?? "?"}\nNombre de semaines : ${body.weeks ?? 14}\n\nActivités Moodle :\n${outline}`;
  if (body.plan) user += `\n\nPLAN DU COURS (texte) :\n${body.plan.slice(0, 16000)}`;
  if (body.mooc) user += `\n\nMOOC (chapitres et leçons) :\n${body.mooc.slice(0, 30000)}`;
  if (body.sources) user += `\n\nAUTRES SOURCES DU COURS (site du cours, polycopié) :\n${body.sources.slice(0, 16000)}`;
  const messages = [{ role: "system", content: INSTRUCTIONS }, { role: "user", content: user }];

  const candidates: Array<{ baseURL: string; apiKey: string; model: string }> = [];
  const openRouter = Deno.env.get("OPENROUTER_API_KEY");
  if (openRouter) {
    candidates.push({
      baseURL: "https://openrouter.ai/api/v1",
      apiKey: openRouter,
      // En évaluation seulement, le modèle se choisit à l'appel.
      model: (evaluation && body.model) ? body.model : (Deno.env.get("ANALYZE_MODEL") ?? "deepseek/deepseek-v4.1-flash"),
    });
  }
  const key = Deno.env.get("LLM_API_KEY");
  if (key) {
    candidates.push({
      baseURL: Deno.env.get("LLM_BASE_URL") ?? "https://api.groq.com/openai/v1",
      apiKey: key,
      model: Deno.env.get("LLM_MODEL") ?? "openai/gpt-oss-120b",
    });
  }
  if (!candidates.length) return json({ error: "aucune clé de modèle configurée" }, 503);

  const errors: string[] = [];
  for (const candidate of (evaluation && body.model ? candidates.slice(0, 1) : candidates)) {
    try {
      const started = Date.now();
      const { content, usage } = await ask(candidate, messages, evaluation ? body.provider : undefined);
      const start = content.indexOf("{"), end = content.lastIndexOf("}");
      if (start < 0 || end <= start) throw new Error("réponse sans JSON");
      const parsed = JSON.parse(content.slice(start, end + 1));
      if (!Array.isArray(parsed.activities) && !Array.isArray(parsed.weeks)) throw new Error("champs « activities » et « weeks » absents");
      return json({
        activities: Array.isArray(parsed.activities) ? parsed.activities : [],
        mooc: Array.isArray(parsed.mooc) ? parsed.mooc : [],
        series: Array.isArray(parsed.series) ? parsed.series : [],
        weeks: Array.isArray(parsed.weeks) ? parsed.weeks : [],
        model: candidate.model,
        ...(evaluation ? { usage, ms: Date.now() - started } : {}),
      });
    } catch (error) {
      errors.push(`${candidate.model} : ${(error as Error).message}`);
    }
  }
  return json({ error: errors.join(" · ") }, 502);
});

async function ask(candidate: { baseURL: string; apiKey: string; model: string },
                   messages: Array<{ role: string; content: string }>, provider?: unknown): Promise<{ content: string; usage: unknown }> {
  const payload: Record<string, unknown> = {
    model: candidate.model,
    temperature: 0,
    messages,
    response_format: { type: "json_object" },
    max_completion_tokens: 16000,
  };
  if (candidate.model.includes("gpt-oss")) payload.reasoning_effort = "low";
  if (candidate.baseURL.includes("openrouter.ai")) {
    // Certains modèles n'existent qu'avec raisonnement (gpt-oss) : le plus court.
    payload.reasoning = candidate.model.includes("gpt-oss") ? { effort: "low" } : { enabled: false };
    payload.usage = { include: true };
    const routing = provider ?? (Deno.env.get("ANALYZE_PROVIDER_SORT") ? { sort: Deno.env.get("ANALYZE_PROVIDER_SORT") } : undefined);
    if (routing) payload.provider = routing;
  }
  const response = await fetch(`${candidate.baseURL}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${candidate.apiKey}` },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(110_000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`HTTP ${response.status} ${text.slice(0, 160)}`);
  const data = JSON.parse(text);
  return { content: data.choices?.[0]?.message?.content ?? "", usage: data.usage ?? null };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
