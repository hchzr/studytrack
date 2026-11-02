// La copie locale de la collection AnkiWeb (StudyTrack/Services/AnkiWeb/AnkiCollection.swift).
//
// Le fichier SQLite téléchargé (schéma 11 — paquets, types de notes et réglages en JSON dans
// la table `col`). Windows **lit** seulement : paquets et historique de révision. La
// préparation de notes à envoyer (`addNote`, `sanityCounts`, `pendingChanges`) n'est pas portée.
// Le fichier vit dans le dossier de l'app (`$APPCONFIG/AnkiWeb/collection.anki2`), ouvert par
// tauri-plugin-sql comme la base de l'app.

import type { AnkiReview } from "../domain/ankiReviewImport.ts";
import { inNative } from "../native/tauri.ts";

/** Ce que l'accès à la copie demande à une base SQLite : `?` pour les paramètres. */
export interface ReadableDb {
  select<T = Record<string, unknown>>(sql: string, params?: (string | number | null)[]): Promise<T[]>;
}

export interface AnkiDeck {
  id: number;
  name: string;
  isFiltered: boolean;
}

/** « EPFL::Analyse » → « Analyse ». */
export function leaf(deck: AnkiDeck): string {
  return deck.name.split("::").pop() ?? deck.name;
}

export class AnkiCollection {
  constructor(private readonly db: ReadableDb) {}

  async colJSON(column: "decks" | "models" | "dconf" | "conf"): Promise<Record<string, any>> {
    const rows = await this.db.select<Record<string, string>>(`SELECT ${column} AS value FROM col LIMIT 1`);
    try {
      const parsed = JSON.parse(rows[0]?.value ?? "{}");
      return parsed !== null && typeof parsed === "object" ? parsed : {};
    } catch {
      return {};
    }
  }

  /** Le numéro de schéma (`col.scm`) : change quand la collection est remplacée ailleurs. */
  async schema(): Promise<number> {
    const rows = await this.db.select<{ scm: number }>("SELECT scm FROM col LIMIT 1");
    return Number(rows[0]?.scm ?? 0);
  }

  /** Les paquets, par nom. */
  async decks(): Promise<AnkiDeck[]> {
    const json = await this.colJSON("decks");
    const decks: AnkiDeck[] = [];
    for (const value of Object.values(json)) {
      const deck = value as { id?: number | string; name?: string; dyn?: number };
      if (deck && deck.id !== undefined && typeof deck.name === "string") {
        decks.push({ id: Number(deck.id), name: deck.name, isFiltered: deck.dyn === 1 });
      }
    }
    return decks.sort((a, b) => a.name.localeCompare(b.name, "fr", { numeric: true }));
  }

  /** L'historique de révision depuis `after` (ms), avec le paquet de chaque carte. */
  async reviews(after: number): Promise<AnkiReview[]> {
    const names = new Map((await this.decks()).map((deck) => [deck.id, deck.name]));
    const rows = await this.db.select<{ id: number; time: number; did: number }>(
      "SELECT r.id AS id, r.time AS time, c.did AS did FROM revlog r JOIN cards c ON c.id = r.cid WHERE r.id > ? ORDER BY r.id", [after]);
    return rows.map((row) => ({ id: Number(row.id), durationMs: Number(row.time), deck: names.get(Number(row.did)) ?? "Anki" }));
  }
}

/** Où vit la copie : l'installer, l'ouvrir, la retirer. */
export interface MirrorStore {
  install(bytes: Uint8Array): Promise<void>;
  open(): Promise<AnkiCollection | null>;
  remove(): Promise<void>;
}

const FOLDER = "AnkiWeb";
const FILE = `${FOLDER}/collection.anki2`;

/** La copie sur disque, dans le dossier de l'app (Tauri) ; rien hors de l'app. */
export function diskMirror(): MirrorStore {
  let connection: import("../data/tauriDb.ts").TauriDb | null = null;
  const close = async () => { await connection?.close(); connection = null; };
  return {
    async install(bytes) {
      if (!inNative()) throw new Error("La copie d'AnkiWeb se garde dans l'app Windows.");
      const { BaseDirectory, mkdir, writeFile, remove, exists } = await import("@tauri-apps/plugin-fs");
      await close();
      await mkdir(FOLDER, { baseDir: BaseDirectory.AppConfig, recursive: true });
      // Écrit à côté, puis remplace : une copie à moitié écrite ne doit jamais être lue.
      await writeFile(`${FILE}.download`, bytes, { baseDir: BaseDirectory.AppConfig });
      if (await exists(FILE, { baseDir: BaseDirectory.AppConfig })) await remove(FILE, { baseDir: BaseDirectory.AppConfig });
      const { rename } = await import("@tauri-apps/plugin-fs");
      await rename(`${FILE}.download`, FILE, { oldPathBaseDir: BaseDirectory.AppConfig, newPathBaseDir: BaseDirectory.AppConfig });
    },
    async open() {
      if (!inNative()) return null;
      const { BaseDirectory, exists } = await import("@tauri-apps/plugin-fs");
      if (!(await exists(FILE, { baseDir: BaseDirectory.AppConfig }))) return null;
      if (!connection) {
        const { TauriDb } = await import("../data/tauriDb.ts");
        connection = new TauriDb(`sqlite:${FILE}`);
      }
      return new AnkiCollection(connection);
    },
    async remove() {
      if (!inNative()) return;
      const { BaseDirectory, exists, remove } = await import("@tauri-apps/plugin-fs");
      await close();
      if (await exists(FILE, { baseDir: BaseDirectory.AppConfig })) await remove(FILE, { baseDir: BaseDirectory.AppConfig });
    },
  };
}
