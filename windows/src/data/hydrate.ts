// Rows SQLite → graphe d'objets du modèle.
//
// La base locale (source de vérité, alimentée par la synchronisation) tient des
// lignes à plat ; le domaine et l'écran attendent des `Course`, `Exercise`… reliés.
// `buildStore` reconstruit ce graphe : une instance par ligne vivante, chaque
// champ posé depuis sa colonne, puis les références « un » assignées — ce qui
// entretient les inverses tout seul (voir relations.ts). Enfin tout entre dans un
// `ModelStore`, d'où `fetch(Course)` rend la même chose que `FetchDescriptor`.
//
// Les instances sont créées sans passer par le constructeur (`Object.create`) :
// on pose exactement l'état stocké, champ pour champ selon schema.ts, sans
// dépendre du nom que tel `Init` donne à tel champ (`taskType` vs `taskTypeRaw`).

import { ModelStore } from "../models/index.ts";
import { tables, fieldColumn, refColumn, type Field } from "../models/schema.ts";
import type { LocalStore, Row } from "../sync/store.ts";
import { registry } from "./registry.ts";

function decode(value: unknown, field: Field): unknown {
  if (value === null || value === undefined) return null;
  switch (field.type) {
    case "bool": return value === 1 || value === true || value === "1";
    case "date": return new Date(String(value));
    case "int": case "double": return Number(value);
    default: return String(value);
  }
}

export async function buildStore(local: LocalStore): Promise<ModelStore> {
  const made = new Map<string, { inst: Record<string, unknown>; row: Row }>();
  const key = (table: string, id: string) => `${table}:${id}`;

  // 1er passage : une instance par ligne, champs simples posés.
  for (const table of tables) {
    const klass = registry[table.model];
    if (!klass) throw new Error(`table ${table.name} sans classe dans registry`);
    for (const row of await local.live(table.name)) {
      const inst = Object.create(klass.prototype) as Record<string, unknown>;
      inst.id = String(row.id);
      for (const f of table.fields) inst[f.swift] = decode(row[fieldColumn(f)], f);
      made.set(key(table.name, inst.id as string), { inst, row });
    }
  }

  // 2e passage : les références « un » (l'inverse se remplit à l'affectation).
  for (const table of tables) {
    for (const entry of instancesOf(made, table.name)) {
      for (const ref of table.refs) {
        const parentId = entry.row[refColumn(ref)];
        if (parentId === null || parentId === undefined) continue;
        const parent = made.get(key(ref.table, String(parentId)));
        if (parent) entry.inst[ref.swift] = parent.inst;
      }
    }
  }

  const store = new ModelStore();
  for (const { inst } of made.values()) store.insert(inst);
  return store;
}

function* instancesOf(made: Map<string, { inst: Record<string, unknown>; row: Row }>, table: string) {
  for (const [k, entry] of made) if (k.startsWith(`${table}:`)) yield entry;
}
