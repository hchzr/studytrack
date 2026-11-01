import { DatabaseSync } from "node:sqlite";
import type { Db, Value } from "../../src/sync/store.ts";

/**
 * Une base SQLite en mémoire pour les tests : ce que tauri-plugin-sql sert
 * dans l'app, sans lancer l'app. SQLite en Node natif, le même dialecte.
 */
export function memoryDb(): Db {
  const db = new DatabaseSync(":memory:");
  return {
    async execute(sql: string, p: Value[] = []) { db.prepare(sql).run(...p); },
    async select<T>(sql: string, p: Value[] = []) { return db.prepare(sql).all(...p) as T[]; },
  };
}
