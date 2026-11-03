import { useEffect, useMemo, useRef } from "react";
import { isTauri } from "@tauri-apps/api/core";
import { DataProvider, useData } from "./data/dataContext.tsx";
import { SqliteSource, type DataSource } from "./data/source.ts";
import { pickSource } from "./data/appSource.ts";
import { syncService } from "./services/syncService.ts";
import { checkMoodleNews } from "./services/moodleWatcher.ts";
import { startGroupPresence } from "./ui/groups/groupPresence.ts";
import { setupShellExtras } from "./ui/shellExtras.ts";
import { Shell } from "./ui/shell.tsx";
import { QuickNoteHost } from "./ui/quicknote/QuickNote.tsx";
import { startNative } from "./native/index.ts";
import { Course } from "./models/index.ts";

// Dans l'app Tauri : la base SQLite locale (tauri-plugin-sql), relue et
// écrite par le Repository de la synchronisation. Dans le navigateur (`npm
// run dev`, l'aperçu Vite) : la source mémoire. Les paramètres d'adresse
// imposent une autre source pour un essai — voir appSource.ts.
// `useMemo` au montage : la source vit aussi longtemps que la fenêtre.
export default function App() {
  // La base elle-même, et la même enveloppée pour prévenir la synchronisation des écritures.
  // La synchronisation se branche sur **la base** : l'enveloppe n'est pas une SqliteSource, et
  // tester l'enveloppe laissait la synchronisation débranchée (« jamais », sans erreur).
  const base = useMemo(() => pickSource(isTauri(), new URLSearchParams(window.location.search)), []);
  const source = useMemo(() => notifySyncOfWrites(base), [base]);

  // Le raccourci global (Ctrl+Alt+Espace) : rien hors de Tauri.
  useEffect(() => { void setupShellExtras(); }, []);

  return (
    <DataProvider source={source}>
      <SyncWiring source={base} />
      <NativeWiring />
      <MoodleNewsWiring />
      <GroupPresenceWiring />
      <Shell />
      <QuickNoteHost />
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

/** Ma présence dans mes groupes pendant que le chrono tourne. */
function GroupPresenceWiring() {
  const { store } = useData();
  const storeRef = useRef(store);
  storeRef.current = store;
  useEffect(() => startGroupPresence(
    (id) => (id ? storeRef.current?.fetch(Course).find((c) => c.id === id)?.displayCode ?? "" : ""),
    (state) => {
      const course = state.courseID ? storeRef.current?.fetch(Course).find((c) => c.id === state.courseID) : undefined;
      const exercise = course?.allExercises.find((e) => e.id === state.targetID);
      return exercise ? exercise.displayNumber : "";
    },
  ), []);
  return null;
}

/** Les nouveautés Moodle : un relevé au lancement et au retour sur l'app (deux heures au plus souvent). */
function MoodleNewsWiring() {
  const { store } = useData();
  useEffect(() => {
    if (!store) return;
    const check = () => { void checkMoodleNews(store.fetch(Course)); };
    check();
    window.addEventListener("focus", check);
    return () => window.removeEventListener("focus", check);
  }, [store]);
  return null;
}

/**
 * La couche native (veille, blocage d'étude, chrono flottant) suit le chrono de
 * l'app. Le chrono flottant retrouve le cours (code, couleur) dans les données
 * ouvertes. Rien hors de Tauri.
 */
function NativeWiring() {
  const { store } = useData();
  const storeRef = useRef(store);
  storeRef.current = store;
  useEffect(() => {
    let stop: (() => void) | null = null;
    let cancelled = false;
    void startNative((id) => (id ? storeRef.current?.fetch(Course).find((course) => course.id === id) ?? null : null))
      .then((cleanup) => { if (cancelled) cleanup(); else stop = cleanup; });
    return () => { cancelled = true; stop?.(); };
  }, []);
  return null;
}
