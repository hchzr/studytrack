// Enregistre ce qu'a coûté un appel à un modèle (table `ai_usage`), sans
// retarder la réponse : l'écriture part en tâche de fond.

export function recordUsage(fn: string, baseURL: string, model: string, usage: unknown,
                            ms?: number, evaluation = false): void {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  // deno-lint-ignore no-explicit-any
  const u = usage as any;
  if (!url || !key || !u) return;
  let provider = baseURL;
  try { provider = new URL(baseURL).host; } catch { /* tel quel */ }
  const row = {
    function: fn, provider, model,
    prompt_tokens: u.prompt_tokens ?? null,
    completion_tokens: u.completion_tokens ?? null,
    cached_tokens: u.prompt_tokens_details?.cached_tokens ?? null,
    reasoning_tokens: u.completion_tokens_details?.reasoning_tokens ?? null,
    cost: typeof u.cost === "number" ? u.cost : null,
    ms: ms ?? null,
    evaluation,
  };
  const write = fetch(`${url}/rest/v1/ai_usage`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json", Prefer: "return=minimal" },
    body: JSON.stringify(row),
  }).catch(() => {});
  // deno-lint-ignore no-explicit-any
  const runtime = (globalThis as any).EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(write);
}
