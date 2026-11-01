import { useMemo } from "react";
import { isTauri } from "@tauri-apps/api/core";
import { DataProvider } from "./data/dataContext.tsx";
import { pickSource } from "./data/appSource.ts";
import { Shell } from "./ui/shell.tsx";

// Dans l'app Tauri : la base SQLite locale (tauri-plugin-sql), relue et
// écrite par le Repository de la synchronisation. Dans le navigateur (`npm
// run dev`, l'aperçu Vite) : la source mémoire. Les paramètres d'adresse
// imposent une autre source pour un essai — voir appSource.ts.
// `useMemo` au montage : la source vit aussi longtemps que la fenêtre.
export default function App() {
  const source = useMemo(
    () => pickSource(isTauri(), new URLSearchParams(window.location.search)),
    [],
  );
  return (
    <DataProvider source={source}>
      <Shell />
    </DataProvider>
  );
}
