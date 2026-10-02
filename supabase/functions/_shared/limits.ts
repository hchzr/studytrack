// Limites d'appel des fonctions qui consomment des crédits de modèle.
//
// La clé `anon` de l'app est publique : `verify_jwt` écarte les appels sans
// clé, pas les appels d'un inconnu qui l'a extraite de l'app. Sans limite, la
// fonction était un accès gratuit au modèle pour qui le voulait. Ici : un
// plafond par adresse IP et par heure, et un plafond global par jour (coupe-
// circuit), comptés en base (`hit_rate_limit`). Si la base ne répond pas, on
// laisse passer : une panne de comptage ne doit pas casser l'import.

export type Limit = { name: string; perIPPerHour: number; globalPerDay: number };

export async function allowed(request: Request, limit: Limit): Promise<{ ok: boolean; reason?: string }> {
  const ip = (request.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "inconnue";
  const checks: Array<[string, number, number]> = [
    [`${limit.name}:ip:${ip}`, 3600, limit.perIPPerHour],
    [`${limit.name}:global`, 86400, limit.globalPerDay],
  ];
  for (const [bucket, window, max] of checks) {
    const verdict = await hit(bucket, window, max);
    if (verdict === false) {
      return { ok: false, reason: bucket.endsWith(":global") ? "limite quotidienne atteinte" : "trop d'appels, réessaie dans une heure" };
    }
  }
  return { ok: true };
}

async function hit(bucket: string, windowSeconds: number, max: number): Promise<boolean | null> {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return null;
  try {
    const response = await fetch(`${url}/rest/v1/rpc/hit_rate_limit`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: key, Authorization: `Bearer ${key}` },
      body: JSON.stringify({ p_bucket: bucket, p_window_seconds: windowSeconds, p_max: max }),
      signal: AbortSignal.timeout(4000),
    });
    if (!response.ok) return null;
    return (await response.json()) === true;
  } catch {
    return null;
  }
}

/// Le mode évaluation : un jeton secret (`EVAL_TOKEN`) permet de choisir le
/// modèle et ignore les limites — pour comparer des modèles, jamais pour l'app.
export function isEvaluation(request: Request): boolean {
  const token = Deno.env.get("EVAL_TOKEN");
  return !!token && token.length >= 24 && request.headers.get("x-eval-token") === token;
}
