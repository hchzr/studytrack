// La base SQLite de l'app, servie par tauri-plugin-sql.
//
// La webview ne touche jamais à la base elle-même : chaque `execute`/`select`
// est un appel IPC vers Rust, qui tient la vraie base (sqlx + SQLite embarqué)
// dans le dossier de l'app (`BaseDirectory::App` : chez l'utilisateur final,
// `~/Library/Application Support/ch.polymestre.windows/` sur macOS,
// `%APPDATA%\…` sur Windows). Même fichier à chaque lancement — c'est la
// persistance.
//
// Même interface que la source `Db` de la synchronisation (paramètres `?`,
// compris par SQLite) : le reste du code ne sait pas qu'il parle à Rust.
//
// L'ouverture est paresseuse : le constructeur est synchrone (la source se
// choisit au fil, dans App), la connexion part à la première requête. L'appel
// `Database.get` du plugin, lui, n'ouvre rien (« database not loaded » au
// premier execute) — l'ouverture passe toujours par `Database.load` ici.

import Database from "@tauri-apps/plugin-sql";
import type { Db, Value } from "../sync/store.ts";

/** Fichier de la base, relatif au dossier de l'app ; créé au premier lancement. */
export const SQLITE_PATH = "sqlite:polymestre.db";

export class TauriDb implements Db {
  private opened: Promise<Database> | null = null;

  constructor(private readonly path: string = SQLITE_PATH) {}

  private connection(): Promise<Database> {
    this.opened ??= Database.load(this.path);
    // Un échec (dossier refusé…) n'est pas une condamnation : la tentative
    // suivante reconnecte.
    this.opened.catch(() => { this.opened = null; });
    return this.opened;
  }

  /** Ferme la connexion (avant de remplacer le fichier de la base). */
  async close(): Promise<void> {
    const opened = this.opened;
    this.opened = null;
    if (opened) await (await opened).close();
  }

  async execute(sql: string, params: Value[] = []): Promise<void> {
    await (await this.connection()).execute(sql, params);
  }

  async select<T = Record<string, unknown>>(sql: string, params: Value[] = []): Promise<T[]> {
    // Le promis par le plugin : T est le tableau entier, pas une ligne.
    const db = await this.connection();
    return db.select<T[]>(sql, params);
  }
}
