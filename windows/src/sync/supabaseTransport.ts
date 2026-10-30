// Transport du moteur de synchronisation vers les tables sync_* de Supabase (PostgREST).

import type { SupabaseClient } from "../services/supabase.ts";
import type { Row } from "./store.ts";
import type { PullPage, Transport } from "./engine.ts";

export class SupabaseTransport implements Transport {
  constructor(private readonly client: SupabaseClient) {}

  async push(table: string, rows: Row[]): Promise<Row[]> {
    if (!rows.length) return [];
    // Upsert : la garde du serveur (sync_guard) garde la plus récente, et
    // return=representation renvoie la version gardée, la nôtre ou la sienne.
    return this.client.request<Row[]>(`/rest/v1/${table}?on_conflict=id`, {
      method: "POST",
      body: rows,
      prefer: "resolution=merge-duplicates,return=representation",
    });
  }

  async pull(table: string, since: string | null, afterId: string | null, limit: number): Promise<PullPage> {
    const q = new URLSearchParams({ select: "*", order: "server_updated_at.asc,id.asc", limit: String(limit) });
    if (since && afterId) q.set("or", keysetFilter(since, afterId));
    else if (since) q.set("server_updated_at", `gt.${since}`);
    const rows = await this.client.request<Row[]>(`/rest/v1/${table}?${q}`);
    return { rows };
  }
}

export const keysetFilter = (since: string, afterId: string): string =>
  `(server_updated_at.gt.${since},and(server_updated_at.eq.${since},id.gt.${afterId}))`;
