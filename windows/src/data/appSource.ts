// Quelle source l'app ouvre ce lancement.
//
// Par défaut ce que le runtime permet : SQLite (tauri-plugin-sql) dans l'app
// Tauri, mémoire pour le développement dans le navigateur (`npm run dev`,
// où le plugin n'existe pas). Quelques paramètres d'adresse l'imposent pour
// un lancement d'essai : `?source=memory` regarde les écrans sur les données
// d'essai sans créer de base, `?source=sqlite&seed=1` amorce la vraie base du
// premier lancement.

import { MemoryDataSource, SqliteSource, type DataSource } from "./source.ts";
import { TauriDb } from "./tauriDb.ts";

export type SourceKind = "sqlite" | "memory";

export function pickSource(inTauri: boolean, params: URLSearchParams): DataSource {
  const kind = chosen(inTauri, params.get("source"));
  if (kind === "sqlite") return new SqliteSource(new TauriDb(), params.get("seed") === "1");
  return new MemoryDataSource();
}

/** La source demandée, bornée à ce que le runtime permet. */
export function chosen(inTauri: boolean, asked: string | null): SourceKind {
  if (asked === "memory" || asked === "sqlite") return inTauri ? asked : "memory";
  return inTauri ? "sqlite" : "memory";
}
