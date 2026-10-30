// Source de données vue par l'interface : un graphe d'objets qu'on lit, et
// trois gestes (enregistrer, supprimer, recharger). Deux implémentations :
//
//   - `MemoryDataSource` : tout en mémoire, amorcé par `SeedData`. Sert au
//     développement et aux aperçus (`npm run tauri dev`) sans base SQLite.
//   - `Repository` (src/data/repository.ts) : la vraie, au-dessus de la base
//     locale et de la synchronisation. Même interface.
//
// Les écrans ne dépendent que de `DataSource`, jamais de l'une ou l'autre.

import { ModelStore, SeedData } from "../models/index.ts";
import "../domain/registerCodecs.ts";

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
