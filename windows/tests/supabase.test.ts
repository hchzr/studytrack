import { describe, expect, it } from "vitest";
import { SupabaseClient, type Session } from "../src/services/supabase.ts";
import { SupabaseTransport } from "../src/sync/supabaseTransport.ts";

const expired: Session = { access_token: "old", refresh_token: "r1", expires_at: 0, user: { id: "u" } };

function setup(session: Session | null) {
  const calls: { url: string; init: RequestInit }[] = [];
  let saved: Session | null = session;
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    if (url.includes("grant_type=refresh_token")) {
      await new Promise((r) => setTimeout(r, 5));
      return new Response(JSON.stringify({ access_token: "new", refresh_token: "r2", expires_in: 3600, user: { id: "u" } }));
    }
    return new Response("[]");
  }) as typeof fetch;
  const client = new SupabaseClient("https://x.supabase.co", "anon", {
    load: async () => saved, save: async (s) => { saved = s; },
  }, fetchImpl);
  return { client, calls, saved: () => saved };
}

describe("client Supabase", () => {
  it("un seul rafraîchissement pour des requêtes simultanées (jeton tournant)", async () => {
    const { client, calls, saved } = setup(expired);
    await Promise.all([1, 2, 3, 4, 5, 6].map(() => client.request("/rest/v1/sync_courses")));
    expect(calls.filter((c) => c.url.includes("refresh_token")).length).toBe(1);
    const rest = calls.filter((c) => c.url.includes("/rest/"));
    expect(rest.every((c) => (c.init.headers as Record<string, string>).Authorization === "Bearer new")).toBe(true);
    expect(saved()!.refresh_token).toBe("r2");
  });

  it("sans session : erreur claire, aucune requête", async () => {
    const { client, calls } = setup(null);
    await expect(client.request("/rest/v1/x")).rejects.toThrow(/Session absente/);
    expect(calls.length).toBe(0);
  });

  it("transport : upsert avec représentation, lecture par clé (date, id)", async () => {
    const { client, calls } = setup({ ...expired, expires_at: 9e9 });
    const t = new SupabaseTransport(client);
    await t.push("sync_courses", [{ id: "c1" }]);
    expect(calls[0].url).toContain("/rest/v1/sync_courses?on_conflict=id");
    expect((calls[0].init.headers as Record<string, string>).Prefer).toBe("resolution=merge-duplicates,return=representation");
    await t.pull("sync_courses", "2026-10-30T10:00:00.123456+00:00", "abc", 200);
    const u = new URL(calls[1].url);
    expect(u.searchParams.get("or")).toBe("(server_updated_at.gt.2026-10-30T10:00:00.123456+00:00,and(server_updated_at.eq.2026-10-30T10:00:00.123456+00:00,id.gt.abc))");
    expect(u.searchParams.get("order")).toBe("server_updated_at.asc,id.asc");
  });
});
