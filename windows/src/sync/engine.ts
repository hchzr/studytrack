// Moteur de synchronisation : envoyer ce qui a changé ici, lire ce qui a changé ailleurs.
//
// Pour chaque table, dans l'ordre du schéma (parents d'abord) :
//   1. envoi des lignes « dirty » par lots ; la réponse du serveur fait foi — si
//      notre écriture était périmée, il renvoie la sienne et on l'adopte ;
//   2. lecture incrémentale par (server_updated_at, id), en repartant un peu
//      **avant** le dernier curseur : une transaction peut valider après une
//      autre plus récente, et ses lignes seraient sinon sautées. Relire une
//      ligne déjà vue est sans effet (la plus récente gagne).
// Puis les orphelins sont rattrapés (voir LocalStore.sweepOrphans).

import { tables } from "../models/schema.ts";
import { LocalStore, fromRemote, toRemote, tableByName, type Row } from "./store.ts";

export interface PullPage { rows: Row[] }

export interface Transport {
  /** Upsert ; renvoie les lignes telles que le serveur les a gardées. */
  push(table: string, rows: Row[]): Promise<Row[]>;
  /** Lignes strictement après (since, afterId), triées par (server_updated_at, id). */
  pull(table: string, since: string | null, afterId: string | null, limit: number): Promise<PullPage>;
}

export interface SyncReport { pushed: number; pulled: number; keptLocal: number; orphans: number }

/** Marge de relecture du curseur. */
export const CURSOR_OVERLAP_MS = 2 * 60 * 1000;

export function rewind(cursor: string | null, ms = CURSOR_OVERLAP_MS): string | null {
  if (!cursor) return null;
  return new Date(new Date(cursor).getTime() - ms).toISOString();
}

export class SyncEngine {
  constructor(readonly store: LocalStore, readonly transport: Transport, readonly batch = 200) {}

  private running: Promise<SyncReport> | null = null;

  /** Une seule synchronisation à la fois ; un appel pendant l'autre l'attend. */
  sync(): Promise<SyncReport> {
    this.running ??= this.run().finally(() => { this.running = null; });
    return this.running;
  }

  private async run(): Promise<SyncReport> {
    const report: SyncReport = { pushed: 0, pulled: 0, keptLocal: 0, orphans: 0 };
    for (const t of tables) await this.pushTable(t.name, report);
    for (const t of tables) await this.pullTable(t.name, report);
    report.orphans = await this.store.sweepOrphans();
    // Les corrections d'orphelins partent tout de suite.
    if (report.orphans) for (const t of tables) await this.pushTable(t.name, report);
    return report;
  }

  private async pushTable(table: string, report: SyncReport): Promise<void> {
    const t = tableByName(table);
    const seen = new Set<string>();
    for (;;) {
      const rows = (await this.store.dirty(table, this.batch)).filter((r) => !seen.has(String(r.id)));
      if (!rows.length) return;
      rows.forEach((r) => seen.add(String(r.id)));
      const kept = await this.transport.push(table, rows.map((r) => toRemote(t, r)));
      const byId = new Map(kept.map((k) => [String(k.id), k]));
      for (const sent of rows) {
        const server = byId.get(String(sent.id));
        if (!server) throw new Error(`${table} : le serveur n'a pas renvoyé ${sent.id}`);
        await this.store.acknowledge(table, sent, fromRemote(t, server));
        report.pushed++;
      }
    }
  }

  private async pullTable(table: string, report: SyncReport): Promise<void> {
    const t = tableByName(table);
    let since = rewind(await this.store.cursor(table));
    let afterId: string | null = null;
    let newest = await this.store.cursor(table);
    for (;;) {
      const { rows } = await this.transport.pull(table, since, afterId, this.batch);
      for (const r of rows) {
        // Une ligne laissée de côté par le chiffrement (autre clé, illisible) : on la saute
        // sans y toucher, le curseur avance quand même.
        if (r._skipped === undefined) {
          const outcome = await this.store.applyRemote(table, fromRemote(t, r));
          if (outcome === "kept-local") report.keptLocal++;
          report.pulled++;
        }
        const stamp = String(r.server_updated_at);
        if (!newest || new Date(stamp) >= new Date(newest)) newest = stamp;
      }
      if (rows.length < this.batch) break;
      const last = rows[rows.length - 1];
      since = String(last.server_updated_at);
      afterId = String(last.id);
    }
    if (newest) await this.store.setCursor(table, newest);
  }
}
