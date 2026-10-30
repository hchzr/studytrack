import { useMemo } from "react";
import { DataProvider } from "./data/dataContext.tsx";
import { MemoryDataSource } from "./data/source.ts";
import { Shell } from "./ui/shell.tsx";

// Pour l'instant la source est en mémoire, amorcée par SeedData : l'app se lance
// et se regarde sans base SQLite. La source SQLite + synchronisation (Repository)
// prend sa place quand tauri-plugin-sql est branché.
export default function App() {
  const source = useMemo(() => new MemoryDataSource(), []);
  return (
    <DataProvider source={source}>
      <Shell />
    </DataProvider>
  );
}
