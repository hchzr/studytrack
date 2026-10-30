// Le contexte React qui porte la source de données pour toute l'app.
//
// `useData()` rend : le `ModelStore` courant, les gestes (save/remove) et
// `reload()`. Après un geste, l'écran appelle `reload()` pour relire le graphe
// et se redessiner — simple et sûr ; on affinera si besoin.

import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import type { ModelStore } from "../models/index.ts";
import type { DataSource } from "./source.ts";

interface DataValue {
  store: ModelStore | null;
  /** Augmente à chaque rechargement : sert de clé de rafraîchissement. */
  version: number;
  reload: () => Promise<void>;
  save: (instance: object) => Promise<void>;
  remove: (instance: object) => Promise<void>;
}

const DataContext = createContext<DataValue | null>(null);

export function DataProvider({ source, children }: { source: DataSource; children: ReactNode }) {
  const [store, setStore] = useState<ModelStore | null>(null);
  const [version, setVersion] = useState(0);

  const reload = useCallback(async () => {
    setStore(await source.load());
    setVersion((v) => v + 1);
  }, [source]);

  useEffect(() => { void reload(); }, [reload]);

  const save = useCallback(async (o: object) => { await source.save(o); await reload(); }, [source, reload]);
  const remove = useCallback(async (o: object) => { await source.remove(o); await reload(); }, [source, reload]);

  return <DataContext.Provider value={{ store, version, reload, save, remove }}>{children}</DataContext.Provider>;
}

export function useData(): DataValue {
  const value = useContext(DataContext);
  if (!value) throw new Error("useData doit être sous <DataProvider>");
  return value;
}
