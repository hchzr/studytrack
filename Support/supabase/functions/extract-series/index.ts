// Supabase Edge Function : extraction des séries d'exercices par un LLM.
//
// Pourquoi ici et pas dans l'app : la clé du fournisseur (Groq, OpenRouter,
// Mistral, OpenAI…) reste **côté serveur**. L'étudiant·e n'a rien à saisir —
// l'app appelle cette fonction avec la clé `anon` déjà compilée, et le texte du
// PDF ne transite que vers le fournisseur choisi ici.
//
// Déploiement (une fois, par le mainteneur du projet Supabase) :
//
//   supabase functions deploy extract-series
//   supabase secrets set LLM_API_KEY=gsk_…                       # clé du fournisseur
//   supabase secrets set LLM_BASE_URL=https://api.groq.com/openai/v1   # facultatif
//   supabase secrets set LLM_MODEL=llama-3.1-8b-instant               # facultatif
//
// Groq offre un palier gratuit largement suffisant pour des PDF de séries.
// N'importe quelle API compatible OpenAI convient (OpenRouter : LLM_BASE_URL=
// https://openrouter.ai/api/v1 et un modèle « :free »).

const INSTRUCTIONS = `Tu extrais la structure d'une série d'exercices d'un cours EPFL à partir du texte brut d'un PDF.
Réponds UNIQUEMENT avec un objet JSON de la forme :
{"series":[{"number":3,"title":"Récurrences","exercises":[{"number":"3.1","title":"Tri fusion","isBonus":false}]}]}
Règles : n'invente aucun exercice ni numéro absent du texte ; le numéro d'un exercice s'écrit « série.exercice » (ex. « 3.2 ») ; si le PDF ne numérote que « Exercice 2 » dans la Série 3, écris « 3.2 » ; « title » est l'intitulé court s'il existe, sinon une chaîne vide (jamais l'énoncé) ; « isBonus » vaut true si l'exercice est marqué bonus, facultatif, optionnel ou étoilé ; s'il n'y a aucune série, renvoie {"series":[]}.`;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAX_CHARACTERS = 7000;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }
  if (request.method !== "POST") {
    return json({ error: "POST attendu" }, 405);
  }

  const apiKey = Deno.env.get("LLM_API_KEY");
  if (!apiKey) {
    return json({ error: "LLM_API_KEY manquante : `supabase secrets set LLM_API_KEY=…`" }, 503);
  }
  const baseURL = (Deno.env.get("LLM_BASE_URL") ?? "https://api.groq.com/openai/v1").replace(/\/$/, "");
  const model = Deno.env.get("LLM_MODEL") ?? "llama-3.1-8b-instant";

  let text = "";
  try {
    const body = await request.json();
    text = typeof body?.text === "string" ? body.text : "";
  } catch {
    return json({ error: "corps JSON attendu : {\"text\": …}" }, 400);
  }
  text = text.slice(0, MAX_CHARACTERS).trim();
  if (!text) {
    return json({ series: [] });
  }

  const upstream = await fetch(`${baseURL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: INSTRUCTIONS },
        { role: "user", content: `Texte du PDF :\n\n${text}` },
      ],
    }),
  });

  if (!upstream.ok) {
    const detail = (await upstream.text()).slice(0, 300);
    return json({ error: `fournisseur : HTTP ${upstream.status} ${detail}` }, 502);
  }

  const payload = await upstream.json();
  const content = payload?.choices?.[0]?.message?.content;
  const raw = typeof content === "string" ? content : JSON.stringify(content ?? {});

  // On renvoie l'objet demandé, jamais le texte brut : l'app relit `series`.
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) {
    return json({ series: [], model });
  }
  try {
    const parsed = JSON.parse(raw.slice(start, end + 1));
    return json({ series: Array.isArray(parsed?.series) ? parsed.series : [], model });
  } catch {
    return json({ series: [], model });
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
