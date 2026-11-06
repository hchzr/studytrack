// Retour OAuth des fournisseurs de tâches qui exigent un secret client.
//
// Le fournisseur redirige ici avec `?code=…&state=<fournisseur>.<aléa>`. La
// fonction échange le code contre un jeton (le secret ne quitte jamais le
// serveur), puis rouvre l'app : `polymestre://oauth?state=…&access_token=…`. L'app dit
// son nom dans `state` (`<fournisseur>.<aléa>.polymestre`) ; sans lui, c'est une app
// d'avant le changement de nom, rouverte sur `studytrack://oauth`.
// Rien n'est stocké : le jeton ne transite que dans la redirection.
//
// Secrets à définir (supabase secrets set …) :
//   TODOIST_CLIENT_ID, TODOIST_CLIENT_SECRET
//   TICKTICK_CLIENT_ID, TICKTICK_CLIENT_SECRET
//   NOTION_CLIENT_ID, NOTION_CLIENT_SECRET

function back(params: Record<string, string>): Response {
  const url = new URL((params.state ?? "").endsWith(".polymestre") ? "polymestre://oauth" : "studytrack://oauth");
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  return new Response(null, { status: 302, headers: { Location: url.toString() } });
}

function env(name: string): string {
  return Deno.env.get(name) ?? "";
}

async function exchange(provider: string, code: string, redirect: string): Promise<Record<string, unknown>> {
  switch (provider) {
    case "todoist": {
      const body = new URLSearchParams({
        client_id: env("TODOIST_CLIENT_ID"),
        client_secret: env("TODOIST_CLIENT_SECRET"),
        code,
        redirect_uri: redirect,
      });
      const res = await fetch("https://todoist.com/oauth/access_token", { method: "POST", body });
      return await res.json();
    }
    case "ticktick": {
      const basic = btoa(`${env("TICKTICK_CLIENT_ID")}:${env("TICKTICK_CLIENT_SECRET")}`);
      const body = new URLSearchParams({
        code,
        grant_type: "authorization_code",
        scope: "tasks:read tasks:write",
        redirect_uri: redirect,
      });
      const res = await fetch("https://ticktick.com/oauth/token", {
        method: "POST",
        headers: { Authorization: `Basic ${basic}`, "Content-Type": "application/x-www-form-urlencoded" },
        body,
      });
      return await res.json();
    }
    case "notion": {
      const basic = btoa(`${env("NOTION_CLIENT_ID")}:${env("NOTION_CLIENT_SECRET")}`);
      const res = await fetch("https://api.notion.com/v1/oauth/token", {
        method: "POST",
        headers: { Authorization: `Basic ${basic}`, "Content-Type": "application/json", "Notion-Version": "2022-06-28" },
        body: JSON.stringify({ grant_type: "authorization_code", code, redirect_uri: redirect }),
      });
      return await res.json();
    }
    default:
      return { error: "unknown_provider" };
  }
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const state = url.searchParams.get("state") ?? "";
  const provider = state.split(".")[0];
  const error = url.searchParams.get("error");
  if (error) return back({ state, error });
  const code = url.searchParams.get("code");
  if (!code) return back({ state, error: "missing_code" });
  // L'adresse de retour doit être exactement celle envoyée à l'autorisation.
  // `req.url` est l'adresse **interne** de la fonction (http, sans
  // `/functions/v1`) : l'adresse publique vient de `SUPABASE_URL`, toujours
  // définie dans les fonctions Supabase.
  const base = (Deno.env.get("SUPABASE_URL") ?? url.origin).replace(/\/$/, "");
  const redirect = `${base}/functions/v1/oauth`;
  try {
    const payload = await exchange(provider, code, redirect);
    const token = typeof payload.access_token === "string" ? payload.access_token : "";
    if (!token) {
      const detail = (payload.error_description ?? payload.error ?? "no_token") as string;
      return back({ state, error: String(detail) });
    }
    const params: Record<string, string> = { state, access_token: token };
    if (typeof payload.refresh_token === "string") params.refresh_token = payload.refresh_token;
    return back(params);
  } catch (e) {
    return back({ state, error: `exchange_failed: ${(e as Error).message}` });
  }
});
