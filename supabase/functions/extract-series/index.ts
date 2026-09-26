// Supabase Edge Function : extraction des séries d'exercices par un LLM.
//
// Pourquoi ici et pas dans l'app : la clé du fournisseur (Groq, OpenRouter,
// Mistral, OpenAI…) reste **côté serveur**. L'étudiant·e n'a rien à saisir —
// l'app appelle cette fonction avec la clé `anon` déjà compilée, et le texte du
// PDF ne transite que vers le fournisseur choisi ici.
//
// Déploiement (une fois, par le mainteneur du projet Supabase) :
//
//   cd <racine du dépôt>            # la CLI cherche supabase/functions/<nom>/index.ts
//   supabase functions deploy extract-series
//   supabase secrets set LLM_API_KEY=gsk_…                       # clé du fournisseur
//
// Facultatifs — mais **les deux ensemble** : le modèle par défaut n'existe que chez
// Groq, et l'envoyer ailleurs donne un « model_not_found » obscur.
//
//   supabase secrets set LLM_BASE_URL=https://openrouter.ai/api/v1
//   supabase secrets set LLM_MODEL=meta-llama/llama-3.1-8b-instruct:free
//
// Groq offre un palier gratuit largement suffisant pour des PDF de séries.
// N'importe quelle API compatible OpenAI convient (OpenRouter : LLM_BASE_URL=
// https://openrouter.ai/api/v1 et un modèle « :free »).

// Consigne **courte**, et ce n'est pas un détail : le palier gratuit de Groq
// plafonne à 8 000 jetons par minute. Une consigne bavarde consommait à elle seule
// la moitié du quota, et chaque import se soldait par une erreur 429.
//
// Les questions ne portent que leur **étiquette** (« 1 », « 2 », « a »), jamais
// leur énoncé. Recopier des formules mathématiques dans une chaîne JSON produisait
// régulièrement du JSON invalide — guillemets et sauts de ligne non échappés — et
// la réponse entière était perdue. L'étiquette suffit : l'énoncé est dans le PDF.
const INSTRUCTIONS = `Tu extrais la structure d'une série d'exercices depuis le texte brut d'un PDF.
Réponds UNIQUEMENT par un objet JSON :
{"series":[{"number":2,"title":"Sommes","exercises":[{"number":"2.1","title":"Comparer des bornes","isBonus":false,"questions":["1","2"]}]}]}

- Langue : les titres dans la langue du PDF.
- « exercises » = les EXERCICES, jamais les questions. Un exercice = un numéro du polycopié.
- Format du texte : « # » en début de ligne marque un TITRE du PDF (plus gros ou en gras) ; les espaces de tête reproduisent le RETRAIT réel ; « --- page N --- » sépare les pages ; « [Indice : … série N] » donne le numéro de série lu dans l'en-tête ou le nom du fichier — utilise-le. Une ligne d'en-tête répétée à chaque page n'est pas un exercice.
- L'INDENTATION est le signal principal. Des numéros alignés au même niveau sont des EXERCICES, même sous un titre de section commun. Des numéros **décalés vers la droite** sous un numéro d'exercice sont ses QUESTIONS.
- Exemple : un numéro qui se termine par « … telle que : » puis, plus à droite, « 1. … ; 2. … » → cet exercice, avec deux questions. Les numéros voisins, alignés à gauche, restent des exercices.
- Autre cas : « Calculer : » puis « 1. la somme … ; 2. la somme … » au même niveau → UN exercice dont ces numéros sont les questions, parce qu'ils suivent une introduction terminée par deux points et se présentent comme des fragments.
- « questions » ne contient que les étiquettes, en texte court : « 1 », « 2 », « a », « ii ». Jamais l'énoncé, jamais de formule. Omets « questions » s'il n'y en a qu'une.
- « number » de série est un entier (« Série 02a » → 2). Numéro d'exercice : « série.exercice », même si le PDF recommence à 1 dans chaque section. Sans numéro, prends le suivant dans l'ordre. N'invente aucun exercice.
- « title » toujours rempli, et **court** : 2 à 6 mots, jamais une phrase, jamais le nom du cours. Reprends l'intitulé du PDF s'il en donne un. Sinon nomme la tâche toi-même, à partir du titre de section ou de l'objet (« Comparer des bornes supérieures », « Somme des parties entières »). **Ne recopie jamais l'énoncé** : il commence par un verbe à l'infinitif ou à l'impératif et se termine par un point, ce n'est pas un titre.
- « isBonus » : true si bonus, facultatif, optionnel ou étoilé.
- Aucune série : {"series":[]}.`;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAX_CHARACTERS = 6000;

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

  const GROQ = "https://api.groq.com/openai/v1";
  const configured = Deno.env.get("LLM_BASE_URL")?.trim();
  const baseURL = (configured && configured.length > 0 ? configured : GROQ).replace(/\/$/, "");
  const usesGroq = baseURL === GROQ;

  // Le modèle par défaut est un modèle **Groq**. L'envoyer à un autre fournisseur
  // donne « The model … does not exist or you do not have access to it » — un
  // message exact mais qui ne dit pas qu'il vient d'un défaut mal placé.
  const configuredModel = Deno.env.get("LLM_MODEL")?.trim();
  if (!configuredModel && !usesGroq) {
    return json({
      error: "LLM_MODEL manquant : un fournisseur autre que Groq a besoin de son propre nom de modèle. "
        + "`supabase secrets set LLM_MODEL=<modèle>` — la liste est sur la page « Models » du fournisseur. "
        + `Fournisseur actuel : ${baseURL}`,
    }, 503);
  }
  // `llama-3.1-8b-instant` est passé en offre **Enterprise** chez Groq : une clé
  // gratuite n'y a plus accès. Le défaut est donc un modèle ouvert à tous.
  const model = configuredModel || "openai/gpt-oss-20b";

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

  // Le rappel de langue est **répété en fin de message** : un modèle suit
  // nettement mieux une consigne placée juste avant de répondre qu'une consigne
  // noyée dans un long texte système. Sans lui, un PDF français ressortait avec
  // des titres anglais.
  const messages = [
    { role: "system", content: INSTRUCTIONS },
    {
      role: "user",
      content: `Texte du PDF :\n\n${text}\n\n`
        + "Rappel : tous les « title » doivent être écrits dans la langue du document ci-dessus "
        + "(ici, en français), et chaque exercice doit en avoir un.",
    },
  ];

  let usedModel = model;
  let structured = true;
  // Bride **dès le premier essai** : `failed_generation` montrait un JSON tronqué
  // en pleine chaîne, parce que le raisonnement avait consommé le budget de
  // sortie. Lire une liste d'exercices ne demande pas de délibérer longuement.
  let lowReasoning = true;
  let detail = "";
  const attempt = async (): Promise<Response> => {
    const response = await callProvider(baseURL, apiKey, usedModel, messages,
                                        structured, lowReasoning && usesGroq);
    detail = await bodyText(response);
    return response;
  };

  // Le corps d'une `Response` ne se lit **qu'une fois** : le relire lève
  // « Body already used », que rien n'attrape, et la fonction répond alors
  // « Internal Server Error » — masquant le vrai message du fournisseur.
  // `attempt` le lit donc une fois, et le garde dans `detail`.
  let upstream = await attempt();

  // Repli 1 — le nom du modèle. C'est une donnée **extérieure** au projet : les
  // offres changent, et `llama-3.1-8b-instant` est devenu Enterprise sans que rien
  // ne bouge ici. On demande au fournisseur ce qu'il accepte, puis on réessaie.
  if (!upstream.ok && (upstream.status === 404 || detail.includes("model_not_found"))) {
    const available = await listModels(baseURL, apiKey);
    const fallback = pickModel(available, preferredModels);
    if (fallback && fallback !== usedModel) {
      usedModel = fallback;
      upstream = await attempt();
    }
  }

  // Repli 2 — la limite de débit. Le palier gratuit plafonne par minute : un
  // import qui en suit un autre est refusé alors que tout est correct. Le
  // fournisseur dit combien de temps attendre ; on l'écoute, une fois.
  if (!upstream.ok && upstream.status === 429) {
    const wait = retryDelay(detail);
    if (wait > 0) {
      await new Promise((resolve) => setTimeout(resolve, wait));
      upstream = await attempt();
    }
  }

  // Repli 3 — la garantie JSON. Le fournisseur peut refuser de certifier la
  // sortie (`json_validate_failed`) alors que le texte contient un objet valide.
  // On retire alors la garantie : la réponse est de toute façon relue en isolant
  // le premier objet, donc rien ne dépend d'elle.
  if (!upstream.ok && (detail.includes("json_validate_failed") || detail.includes("Failed to validate JSON"))) {
    structured = false;
    upstream = await attempt();
  }

  if (!upstream.ok) {
    // Quand le modèle n'existe pas chez ce fournisseur, on va **chercher** la
    // liste pour la donner : « model_not_found » sans les noms valides oblige à
    // ouvrir un navigateur et à deviner.
    let hint = "";
    if (upstream.status === 404 || detail.includes("model_not_found")) {
      const available = await listModels(baseURL, apiKey);
      if (available.length > 0) {
        hint = ` Modèles disponibles chez ce fournisseur : ${available.slice(0, 8).join(", ")}`
          + (available.length > 8 ? ` (et ${available.length - 8} autres)` : "")
          + ". Corrige avec `supabase secrets set LLM_MODEL=<modèle>`.";
      } else {
        hint = " Vérifie `supabase secrets list`, puis pose `LLM_MODEL` avec un modèle du fournisseur.";
      }
    }

    return json({ error: `fournisseur : HTTP ${upstream.status} ${detail}${hint}` }, 502);
  }

  const payload = await upstream.json();
  const message = payload?.choices?.[0]?.message;
  // Certains modèles qui raisonnent laissent `content` vide et écrivent tout dans
  // `reasoning_content`. On regarde les deux avant de conclure à une réponse vide.
  const content = message?.content;
  const reasoning = message?.reasoning_content ?? message?.reasoning;
  const raw = typeof content === "string" && content.trim().length > 0
    ? content
    : (typeof reasoning === "string" ? reasoning : JSON.stringify(content ?? {}));

  // On renvoie l'objet demandé, jamais le texte brut : l'app relit `series`.
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) {
    // Une réponse illisible n'est **pas** « ce PDF n'a pas de série ». Les
    // confondre laissait l'utilisateur devant une extraction vide sans savoir
    // que le modèle avait répondu autre chose — on dit donc ce qu'il a répondu.
    return json({
      error: `le modèle n'a pas renvoyé de JSON (modèle ${usedModel}, mode strict ${structured}). `
        + `Début de sa réponse : ${raw.slice(0, 200) || "(vide)"}`,
    }, 502);
  }
  try {
    const parsed = JSON.parse(raw.slice(start, end + 1));
    return json({ series: Array.isArray(parsed?.series) ? parsed.series : [],
                  model: usedModel, structured });
  } catch (error) {
    // `finish_reason` dit **pourquoi** la réponse s'arrête : « length » signifie
    // une limite de sortie atteinte, et non un modèle qui écrit mal. Sans lui, on
    // chercherait longtemps.
    const finish = payload?.choices?.[0]?.finish_reason ?? "?";
    const usage = payload?.usage;
    return json({
      error: `JSON illisible de ${usedModel} (strict ${structured}, fin « ${finish} », `
        + `usage ${JSON.stringify(usage ?? {})}) : ${String(error)}. Début : ${raw.slice(0, 200)}`,
    }, 502);
  }
});

/** Les modèles à essayer en premier, du plus léger au plus capable. */
const preferredModels = [
  "openai/gpt-oss-20b",
  "openai/gpt-oss-120b",
  "llama-3.3-70b-versatile",
  "meta-llama/llama-4-scout-17b-16e-instruct",
  "mixtral-8x7b-32768",
];

/**
 * Le meilleur modèle **réellement disponible**, ou `null`.
 *
 * On cherche d'abord dans la liste de préférence ; à défaut, on prend le premier
 * modèle proposé — mieux vaut une réponse d'un modèle inattendu que pas de
 * réponse du tout.
 */
function pickModel(available: string[], preferred: string[]): string | null {
  if (available.length === 0) return null;
  for (const candidate of preferred) {
    if (available.includes(candidate)) return candidate;
  }
  return available[0] ?? null;
}

/** Un appel de complétion, isolé pour pouvoir être rejoué avec un autre modèle. */
function callProvider(
  baseURL: string,
  apiKey: string,
  model: string,
  messages: Array<{ role: string; content: string }>,
  structured = true,
  lowReasoning = false,
): Promise<Response> {
  const payload: Record<string, unknown> = { model, temperature: 0, messages };
  if (structured) payload.response_format = { type: "json_object" };
  // Une limite explicite : le défaut du fournisseur peut être plus court que la
  // liste d'exercices, et un JSON tronqué est un JSON invalide.
  payload.max_completion_tokens = 4096;
  // Les modèles `gpt-oss` **raisonnent** avant de répondre. Sans bride, ils
  // dépensent le quota en raisonnement et rendent parfois un contenu vide : la
  // réponse existe, mais dans `reasoning_content`. « low » suffit largement pour
  // lire une liste d'exercices, et rend le quota au texte utile.
  if (lowReasoning) payload.reasoning_effort = "low";
  return fetch(`${baseURL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(payload),
  });
}

/**
 * Le délai conseillé par le fournisseur, en millisecondes.
 *
 * Groq écrit « Please try again in 9.96s ». On le lit plutôt que d'attendre une
 * durée fixe : trop courte, la reprise échoue ; trop longue, on fait patienter
 * pour rien. Borné à 20 s, au-delà desquels mieux vaut rendre la main.
 */
function retryDelay(detail: string): number {
  const match = detail.match(/try again in ([0-9.]+)\s*s/i);
  if (!match) return detail.includes("429") ? 5_000 : 0;
  const seconds = Number(match[1]);
  if (!Number.isFinite(seconds)) return 5_000;
  return Math.min(20_000, Math.max(1_000, Math.ceil(seconds * 1000) + 500));
}

/** Le corps d'une réponse en texte, borné — sans jamais lever d'exception. */
async function bodyText(response: Response): Promise<string> {
  if (response.ok) return "";
  try {
    return (await response.text()).slice(0, 300);
  } catch {
    return "(corps illisible)";
  }
}

/** Les identifiants de modèles que la clé peut utiliser, ou une liste vide. */
async function listModels(baseURL: string, apiKey: string): Promise<string[]> {
  try {
    const response = await fetch(`${baseURL}/models`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    if (!response.ok) return [];
    const payload = await response.json();
    const items = Array.isArray(payload?.data) ? payload.data : [];
    return items
      .map((item: { id?: unknown }) => (typeof item?.id === "string" ? item.id : ""))
      .filter((id: string) => id.length > 0)
      .sort();
  } catch {
    return [];
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
