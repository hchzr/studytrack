// Le `ModelContext` de SwiftData, en mémoire : un ensemble d'objets par type, avec
// les règles de suppression déclarées par `@Relationship(deleteRule:)`.
//
// Pas de persistance ici — l'écriture dans SQLite et la synchronisation sont dans
// src/sync. `insert` suit les relations comme SwiftData (insérer un parent insère
// ce qu'il porte), `delete` applique cascade / nullify.

import { relations } from "./relations.ts";

/** Une classe de modèle : `modelName` est son nom Swift (stable après minification). */
export interface ModelClass<T = object> {
  new (...args: any[]): T;
  readonly modelName: string;
}

type Any = Record<string, any>;

const nameOf = (obj: object): string => (obj.constructor as unknown as ModelClass).modelName;

export class ModelStore {
  private readonly byModel = new Map<string, Set<object>>();

  private bucket(name: string): Set<object> {
    let set = this.byModel.get(name);
    if (!set) this.byModel.set(name, (set = new Set()));
    return set;
  }

  contains(obj: object): boolean {
    return this.byModel.get(nameOf(obj))?.has(obj) ?? false;
  }

  /** Insère l'objet et tout ce qui lui est relié (parents, enfants), comme SwiftData. */
  insert(obj: object): void {
    if (this.contains(obj)) return;
    const name = nameOf(obj);
    this.bucket(name).add(obj);
    for (const rel of relations) {
      if (rel.parent === name) for (const child of [...((obj as Any)[rel.list] as object[])]) this.insert(child);
      if (rel.child === name) {
        const parent = (obj as Any)[rel.one] as object | null;
        if (parent) {
          this.insert(parent);
          // Un objet ajouté au tableau sans passer par l'inverse reste cohérent.
          const siblings = (parent as Any)[rel.list] as object[];
          if (!siblings.includes(obj)) siblings.push(obj);
        }
      }
    }
  }

  /**
   * Supprime l'objet. Cascade : les enfants le sont aussi ; nullify : ils restent
   * mais perdent leur référence. L'objet quitte aussi les tableaux de ses parents.
   */
  delete(obj: object): void {
    this.remove(obj, new Set());
  }

  private remove(obj: object, seen: Set<object>): void {
    if (seen.has(obj)) return;
    seen.add(obj);
    const name = nameOf(obj);
    this.byModel.get(name)?.delete(obj);
    for (const rel of relations) {
      if (rel.parent === name) {
        for (const child of [...((obj as Any)[rel.list] as object[])]) {
          if (rel.rule === "cascade") this.remove(child, seen);
          else (child as Any)[rel.one] = null;
        }
        (obj as Any)[rel.list] = [];
      }
      if (rel.child === name) (obj as Any)[rel.one] = null;
    }
  }

  /** Tous les objets d'un type, dans l'ordre d'insertion (`FetchDescriptor<T>()`). */
  fetch<T extends object>(model: ModelClass<T>): T[] {
    return [...(this.byModel.get(model.modelName) ?? [])] as T[];
  }

  fetchCount(model: ModelClass): number {
    return this.byModel.get(model.modelName)?.size ?? 0;
  }

  /** Sans objet : tout est déjà en mémoire (`ModelContext.save()`). */
  save(): void {}
}
