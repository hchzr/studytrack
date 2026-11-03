// Le chiffrement de bout en bout des lignes, entre le moteur et le transport.
//
// Le moteur parle en lignes « à plat » (`id`, `updated_at`, `deleted_at` et les
// colonnes du modèle). Le serveur, lui, ne reçoit que l'enveloppe :
//
//     { id, updated_at, deleted_at, key_id, payload }      payload = bytea
//
// `payload` est le JSON des champs, scellé par AES-256-GCM (voir
// domain/syncCrypto.ts). Une pierre tombale n'a pas de payload. Un décorateur du
// `Transport` : le moteur ne sait rien du chiffrement, et `SupabaseTransport`
// ne sait rien des champs.

import type { Row } from "./store.ts";
import type { PullPage, Transport } from "./engine.ts";
import { fromBytea, openRow, sealRow, toBytea, SyncCryptoError } from "../domain/syncCrypto.ts";

export interface SyncKeys { dataKey: Uint8Array; keyId: string }

/** Ce qu'une passe a dû laisser de côté, pour l'écran Réglages. */
export class SkipStats {
  /** Lignes chiffrées par une autre clé (« clé différente »). */
  foreignKey = 0;
  /** Lignes de notre clé qu'on n'a pas pu ouvrir (altérées, déplacées). */
  unreadable = 0;
  reset(): void { this.foreignKey = 0; this.unreadable = 0; }
}

/** Le serveur nous a rendu, à l'envoi, une ligne d'une autre clé. */
export class ForeignKeyError extends Error {
  constructor() {
    super("Ce compte est chiffré avec une autre clé que celle de cet appareil.");
    this.name = "ForeignKeyError";
  }
}

const META = new Set(["id", "updated_at", "deleted_at", "server_updated_at", "key_id", "payload"]);

export class EncryptedTransport implements Transport {
  constructor(
    private readonly inner: Transport,
    private readonly keys: SyncKeys,
    readonly stats: SkipStats = new SkipStats(),
  ) {}

  async push(table: string, rows: Row[]): Promise<Row[]> {
    if (!rows.length) return [];
    const envelopes = await Promise.all(rows.map((r) => this.seal(table, r)));
    const kept = await this.inner.push(table, envelopes);
    const out: Row[] = [];
    for (const k of kept) {
      const opened = await this.open(table, k);
      if (opened._skipped === "foreignKey") throw new ForeignKeyError();
      out.push(opened);
    }
    return out;
  }

  async pull(table: string, since: string | null, afterId: string | null, limit: number): Promise<PullPage> {
    const { rows } = await this.inner.pull(table, since, afterId, limit);
    const out: Row[] = [];
    for (const r of rows) {
      const opened = await this.open(table, r);
      if (opened._skipped === "foreignKey") this.stats.foreignKey++;
      else if (opened._skipped === "unreadable") this.stats.unreadable++;
      out.push(opened);
    }
    return { rows: out };
  }

  private async seal(table: string, row: Row): Promise<Row> {
    const id = String(row.id);
    const tombstone = row.deleted_at !== null && row.deleted_at !== undefined;
    const fields: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(row)) if (!META.has(k)) fields[k] = v;
    return {
      id,
      updated_at: row.updated_at,
      deleted_at: row.deleted_at ?? null,
      key_id: this.keys.keyId,
      payload: tombstone ? null : toBytea(await sealRow(this.keys.dataKey, table, id, fields)),
    };
  }

  /** Enveloppe du serveur → ligne à plat. Les lignes à laisser de côté portent `_skipped`. */
  private async open(table: string, env: Row): Promise<Row> {
    const base: Row = {
      id: env.id,
      updated_at: env.updated_at,
      deleted_at: env.deleted_at ?? null,
      server_updated_at: env.server_updated_at,
    };
    if (env.key_id !== this.keys.keyId) return { ...base, _skipped: "foreignKey" };
    if (base.deleted_at !== null) return { ...base, _tombstone: true };
    const box = fromBytea(env.payload);
    if (!box) return { ...base, _skipped: "unreadable" };
    try {
      const fields = await openRow(this.keys.dataKey, table, String(env.id), box);
      return { ...fields, ...base };
    } catch (e) {
      if (e instanceof SyncCryptoError) return { ...base, _skipped: "unreadable" };
      throw e;
    }
  }
}
