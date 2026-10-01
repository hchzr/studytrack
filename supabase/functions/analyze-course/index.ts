// Supabase Edge Function : rangement d'un cours Moodle par un LLM.
//
// L'app lit le plan d'un cours Moodle (sections, noms et types d'activités) et
// le range avec des règles écrites sur quelques cours réels. Pour les formats
// qu'elles ne connaissent pas (« TP 3 – Récursivité », « Séance du 14 », tout
// dans une seule section…), elle demande ici au modèle une étiquette par
// activité : nature (théorie, série, corrigé, échéance, document), semaine,
// numéro de série. Aucune donnée personnelle : uniquement le plan du cours.
//
// Même fournisseur et mêmes secrets que `extract-series` :
//   supabase functions deploy analyze-course --project-ref aaigscutkuefhqftfszv
//   LLM_API_KEY (Groq par défaut), LLM_BASE_URL / LLM_MODEL (facultatifs, ensemble),
//   OPENROUTER_API_KEY / OPENROUTER_MODEL (repli facultatif).

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const INSTRUCTIONS = `Tu ranges les activités d'un cours Moodle de l'EPFL pour une app de suivi d'études.
Réponds UNIQUEMENT par un objet JSON : {"activities":[{"id":"123","kind":"theory","week":3,"series":null}]}
- kind : "theory" (cours, vidéo, enregistrement, transparents, notes, polycopié, chapitre à lire), "series" (énoncé d'une série / feuille / TP d'exercices), "solution" (corrigé), "deadline" (rendu noté, devoir, projet, quiz noté), "document" (organisation, formulaire, ressource générale, ancien examen), "ignore" (forum, annonce, sondage, lien sans contenu).
- week : la semaine du semestre (1 à N) où l'activité se travaille, d'après la section (« Semaine 3 », une plage de dates), un numéro (« Lecture 7 » quand il y a deux cours par semaine → semaine 4), ou une date. null si inconnue.
- series : le numéro de la série d'exercices quand kind vaut "series" ou "solution", sinon null.
- Une entrée par activité reçue, avec son id exact. N'invente aucune activité.`;

/** Un plan de cours dépasse rarement 12 000 caractères ; au-delà, on tronque. */
const MAX_OUTLINE = 14000;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  let body: { outline?: string; weeks?: number; course?: string };
  try {
    body = await request.json();
  } catch {
    return json({ error: "JSON invalide" }, 400);
  }
  const outline = (body.outline ?? "").slice(0, MAX_OUTLINE);
  if (!outline.trim()) return json({ error: "plan vide" }, 400);
  const user = `Cours : ${body.course ?? "?"}\nNombre de semaines : ${body.weeks ?? 14}\n\nPlan :\n${outline}`;
  const messages = [{ role: "system", content: INSTRUCTIONS }, { role: "user", content: user }];

  const candidates: Array<{ baseURL: string; apiKey: string; model: string }> = [];
  const key = Deno.env.get("LLM_API_KEY");
  if (key) {
    candidates.push({
      baseURL: Deno.env.get("LLM_BASE_URL") ?? "https://api.groq.com/openai/v1",
      apiKey: key,
      model: Deno.env.get("LLM_MODEL") ?? "openai/gpt-oss-20b",
    });
  }
  const openRouter = Deno.env.get("OPENROUTER_API_KEY");
  if (openRouter) {
    candidates.push({
      baseURL: "https://openrouter.ai/api/v1",
      apiKey: openRouter,
      model: Deno.env.get("OPENROUTER_MODEL") ?? "deepseek/deepseek-v4.1-flash",
    });
  }
  if (!candidates.length) return json({ error: "aucune clé de modèle configurée" }, 503);

  const errors: string[] = [];
  for (const candidate of candidates) {
    try {
      const content = await ask(candidate, messages);
      const start = content.indexOf("{"), end = content.lastIndexOf("}");
      if (start < 0 || end <= start) throw new Error("réponse sans JSON");
      const parsed = JSON.parse(content.slice(start, end + 1));
      if (!Array.isArray(parsed.activities)) throw new Error("champ « activities » absent");
      return json({ activities: parsed.activities, model: candidate.model });
    } catch (error) {
      errors.push(`${candidate.model} : ${(error as Error).message}`);
    }
  }
  return json({ error: errors.join(" · ") }, 502);
});

async function ask(candidate: { baseURL: string; apiKey: string; model: string },
                   messages: Array<{ role: string; content: string }>): Promise<string> {
  const payload: Record<string, unknown> = {
    model: candidate.model,
    temperature: 0,
    messages,
    response_format: { type: "json_object" },
    max_completion_tokens: 6000,
  };
  if (candidate.model.includes("gpt-oss")) payload.reasoning_effort = "low";
  if (candidate.baseURL.includes("openrouter.ai")) payload.reasoning = { enabled: false };
  const response = await fetch(`${candidate.baseURL}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${candidate.apiKey}` },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(40_000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`HTTP ${response.status} ${text.slice(0, 160)}`);
  const data = JSON.parse(text);
  return data.choices?.[0]?.message?.content ?? "";
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
