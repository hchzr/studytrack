// Lecture et écriture des données, au-dessus de la base locale + synchronisation.
//
// Lecture : `load()` reconstruit le graphe (`buildStore`). L'écran lit le
// `ModelStore` et les objets du modèle, comme le fait le domaine.
//
// Écriture : on modifie l'objet en mémoire puis `save(objet)`. La ligne est
// réécrite dans la base locale, marquée « à envoyer » ; `LocalStore` applique
// déjà les règles de suppression (cascade / mise à nul) et la synchronisation
// pousse le reste. On ne réimplémente donc pas la persistance : on sérialise
// l'objet en colonnes selon schema.ts, rien de plus.

import { ModelStore } from "../models/index.ts";
import { tables, fieldColumn, refColumn, type Table } from "../models/schema.ts";
import { LocalStore, type Value } from "../sync/store.ts";
import { buildStore } from "./hydrate.ts";

const tableByModel = new Map<string, Table>(tables.map((t) => [t.model, t]));

/** La table d'un objet, par son `modelName` Swift. */
export function tableFor(instance: object): Table {
  const name = (instance.constructor as { modelName?: string }).modelName ?? "";
  const table = tableByModel.get(name);
  if (!table) throw new Error(`${name} : modèle non synchronisé, pas de table`);
  return table;
}

/** Objet du modèle → colonnes de sa ligne (hors colonnes de synchronisation). */
export function toColumns(table: Table, instance: Record<string, unknown>): Record<string, Value> & { id: string } {
  const out: Record<string, Value> = { id: String(instance.id) };
  for (const f of table.fields) {
    const v = instance[f.swift];
    if (v === null || v === undefined) { out[fieldColumn(f)] = null; continue; }
    switch (f.type) {
      case "bool": out[fieldColumn(f)] = v ? 1 : 0; break;
      case "date": out[fieldColumn(f)] = (v as Date).toISOString(); break;
      case "int": case "double": out[fieldColumn(f)] = Number(v); break;
      default: out[fieldColumn(f)] = String(v);
    }
  }
  for (const ref of table.refs) {
    const parent = instance[ref.swift] as { id?: string } | null | undefined;
    out[refColumn(ref)] = parent?.id ?? null;
  }
  return out as Record<string, Value> & { id: string };
}

export class Repository {
  store = new ModelStore();

  constructor(private readonly local: LocalStore) {}

  /** Reconstruit le graphe depuis la base locale. À appeler au démarrage et après une synchro. */
  async load(): Promise<ModelStore> {
    this.store = await buildStore(this.local);
    return this.store;
  }

  /** Persiste l'état courant d'un objet (après l'avoir modifié en mémoire). */
  async save(instance: object): Promise<void> {
    const table = tableFor(instance);
    await this.local.write(table.name, toColumns(table, instance as Record<string, unknown>));
  }

  async saveMany(instances: readonly object[]): Promise<void> {
    for (const o of instances) await this.save(o);
  }

  /**
   * Supprime un objet : pierre tombale dans la base (cascade / mise à nul
   * appliquées par LocalStore), et retrait du graphe en mémoire.
   */
  async remove(instance: object): Promise<void> {
    const table = tableFor(instance);
    await this.local.remove(table.name, String((instance as { id: string }).id));
    if (this.store.contains(instance)) this.store.delete(instance);
  }
}
