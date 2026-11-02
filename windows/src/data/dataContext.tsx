// Le contexte React qui porte la source de données pour toute l'app.
//
// `useData()` rend : le `ModelStore` courant, les gestes (save/remove) et
// `reload()`. Après un geste, l'écran appelle `reload()` pour relire le graphe
// et se redessiner — simple et sûr ; on affinera si besoin.
//
// Une source qui échoue (base illisible, plugin absent) est montrée à la place
// de l'écran : un « Chargement… » éternel ne dit rien de ce qui a cassé.

import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import type { ModelStore } from "../models/index.ts";
import type { DataSource } from "./source.ts";

interface DataValue {
  store: ModelStore | null;
  /** Augmente à chaque rechargement : sert de clé de rafraîchissement. */
  version: number;
  reload: () => Promise<void>;
  save: (instance: object) => Promise<void>;
  /** Plusieurs objets d'un coup, une seule relecture à la fin (un import en écrit des centaines). */
  saveMany: (instances: readonly object[]) => Promise<void>;
  /** Enregistre et supprime d'un coup (une seule relecture) : un import qui retire des doublons. */
  commit: (changes: { save: readonly object[]; remove: readonly object[] }) => Promise<void>;
  remove: (instance: object) => Promise<void>;
}

const DataContext = createContext<DataValue | null>(null);

export function DataProvider({ source, children }: { source: DataSource; children: ReactNode }) {
  const [store, setStore] = useState<ModelStore | null>(null);
  const [version, setVersion] = useState(0);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try {
      setStore(await source.load());
      setVersion((v) => v + 1);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? `${e.message}` : String(e));
    }
  }, [source]);

  useEffect(() => { void reload(); }, [reload]);

  const save = useCallback(async (o: object) => { await source.save(o); await reload(); }, [source, reload]);
  const saveMany = useCallback(async (list: readonly object[]) => {
    for (const o of new Set(list)) await source.save(o);
    await reload();
  }, [source, reload]);
  const commit = useCallback(async (changes: { save: readonly object[]; remove: readonly object[] }) => {
    for (const o of new Set(changes.remove)) await source.remove(o);
    for (const o of new Set(changes.save)) await source.save(o);
    await reload();
  }, [source, reload]);
  const remove = useCallback(async (o: object) => { await source.remove(o); await reload(); }, [source, reload]);

  if (error && !store) {
    return (
      <div style={{ padding: 40, maxWidth: 640 }}>
        <div className="serif" style={{ fontSize: 20, marginBottom: 8 }}>Les données ne se sont pas ouvertes</div>
        <p style={{ color: "var(--ink-secondary)", whiteSpace: "pre-wrap", fontFamily: "var(--mono)", fontSize: 13 }}>{error}</p>
      </div>
    );
  }

  return <DataContext.Provider value={{ store, version, reload, save, saveMany, commit, remove }}>{children}</DataContext.Provider>;
}

export function useData(): DataValue {
  const value = useContext(DataContext);
  if (!value) throw new Error("useData doit être sous <DataProvider>");
  return value;
}
