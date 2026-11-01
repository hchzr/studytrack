// Source de données vue par l'interface : un graphe d'objets qu'on lit, et
// trois gestes (enregistrer, supprimer, recharger). Deux implémentations :
//
//   - `MemoryDataSource` : tout en mémoire, amorcé par `SeedData`. Sert au
//     développement et aux aperçus (`npm run tauri dev`) sans base SQLite.
//   - `Repository` (src/data/repository.ts) : la vraie, au-dessus de la base
//     locale et de la synchronisation. Même interface.
//
// Les écrans ne dépendent que de `DataSource`, jamais de l'une ou l'autre.

import { ModelStore, SeedData, Course } from "../models/index.ts";
import "../domain/registerCodecs.ts";
import { LocalStore, type Db } from "../sync/store.ts";
import { registry } from "./registry.ts";
import { Repository } from "./repository.ts";

export interface DataSource {
  /** Construit (ou reconstruit) le graphe. */
  load(): Promise<ModelStore>;
  /** Persiste l'état courant d'un objet déjà modifié en mémoire. */
  save(instance: object): Promise<void>;
  /** Supprime un objet (cascade / mise à nul selon le modèle). */
  remove(instance: object): Promise<void>;
}

/** Source en mémoire, amorcée une fois ; les écritures restent dans le graphe. */
export class MemoryDataSource implements DataSource {
  private store = new ModelStore();
  private seeded = false;

  async load(): Promise<ModelStore> {
    if (!this.seeded) { SeedData.seed(this.store); this.seeded = true; }
    return this.store;
  }

  async save(instance: object): Promise<void> {
    if (!this.store.contains(instance)) this.store.insert(instance);
  }

  async remove(instance: object): Promise<void> {
    if (this.store.contains(instance)) this.store.delete(instance);
  }
}

/**
 * La vraie source : la base SQLite locale (tauri-plugin-sql), au-dessus de
 * laquelle `Repository` reconstruit le graphe et applique la synchronisation.
 *
 * Le premier `load()` fait le travail coûteux — créer les tables puis, si
 * c'est le premier lancement et qu'on le demande, amorcer des données de
 * démonstration — et une seule fois : deux `load()` lancés en même temps
 * (React 19 rejoue ses effets en mode strict) partagent la même promesse.
 */
export class SqliteSource implements DataSource {
  private readonly local: LocalStore;
  private setup: Promise<Repository> | null = null;

  constructor(db: Db, private readonly seedIfNeeded = false) {
    this.local = new LocalStore(db);
  }

  async load(): Promise<ModelStore> {
    return (await this.repository()).load();
  }

  async save(instance: object): Promise<void> {
    await (await this.repository()).save(instance);
  }

  async remove(instance: object): Promise<void> {
    await (await this.repository()).remove(instance);
  }

  /** Le repository, et derrière lui la base : migration + amorce une fois. */
  private repository(): Promise<Repository> {
    this.setup ??= this.setupRepository();
    return this.setup;
  }

  private async setupRepository(): Promise<Repository> {
    await this.local.migrate();
    const repo = new Repository(this.local);
    if (this.seedIfNeeded && (await repo.load()).fetch(Course).length === 0) {
      await seedRepository(repo);
    }
    return repo;
  }
}

/**
 * Du contenu de démonstration dans la vraie base, une fois : mêmes données
 * que ce que la source mémoire amorce. Écritures objet par objet, champ pour
 * champ ; une base `Course` vide est le seul témoin du premier lancement,
 * jamais ré-amorcée (une deuxième apparence ignore cette passe).
 */
async function seedRepository(repo: Repository): Promise<void> {
  const seeded = new ModelStore();
  SeedData.seed(seeded);
  const seen = new Set<object>();
  const all: object[] = [];
  for (const klass of Object.values(registry)) {
    for (const instance of seeded.fetch(klass)) {
      if (!seen.has(instance)) { seen.add(instance); all.push(instance); }
    }
  }
  await repo.saveMany(all);
}
