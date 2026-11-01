import { useEffect, useMemo } from "react";
import { isTauri } from "@tauri-apps/api/core";
import { DataProvider, useData } from "./data/dataContext.tsx";
import { SqliteSource, type DataSource } from "./data/source.ts";
import { pickSource } from "./data/appSource.ts";
import { syncService } from "./services/syncService.ts";
import { setupShellExtras } from "./ui/shellExtras.ts";
import { Shell } from "./ui/shell.tsx";

// Dans l'app Tauri : la base SQLite locale (tauri-plugin-sql), relue et
// écrite par le Repository de la synchronisation. Dans le navigateur (`npm
// run dev`, l'aperçu Vite) : la source mémoire. Les paramètres d'adresse
// imposent une autre source pour un essai — voir appSource.ts.
// `useMemo` au montage : la source vit aussi longtemps que la fenêtre.
export default function App() {
  const source = useMemo(
    () => notifySyncOfWrites(pickSource(isTauri(), new URLSearchParams(window.location.search))),
    [],
  );

  // Le raccourci global (Ctrl+Alt+Espace) : rien hors de Tauri.
  useEffect(() => { void setupShellExtras(); }, []);

  return (
    <DataProvider source={source}>
      <SyncWiring source={source} />
      <Shell />
    </DataProvider>
  );
}

/**
 * La synchronisation suit les écritures : après chaque save/remove, une passe
 * part seule trois secondes plus tard (elle groupe les saisies rapprochées).
 * Sans base réelle (source mémoire) ou sans configuration, rien ne change.
 */
function notifySyncOfWrites(base: DataSource): DataSource {
  if (!(base instanceof SqliteSource)) return base;
  return {
    async load() { return base.load(); },
    async save(instance) { await base.save(instance); syncService.noteLocalWrite(); },
    async remove(instance) { await base.remove(instance); syncService.noteLocalWrite(); },
  };
}

/**
 * Branche la synchronisation une fois les données ouvertes : la base locale,
 * et la relue du graphe après chaque lecture. L'auto-synchronisation (une passe
 * au départ, puis toutes les cinq minutes) se garde elle-même : no-op tant que
 * l'étudiant·e ne l'a pas activée dans les réglages.
 */
function SyncWiring({ source }: { source: DataSource }) {
  const { store, reload } = useData();
  useEffect(() => {
    if (!(source instanceof SqliteSource) || !store) return;
    syncService.attach({ local: source.localStore, reload });
    syncService.startAutoSync();
  }, [source, store, reload]);
  return null;
}
