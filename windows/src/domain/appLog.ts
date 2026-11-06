// Le journal de l'app (Polymestre/Domain/AppLog.swift).
//
// Le tampon est **pur** : ajouter, borner, filtrer, formater. Séparé du stockage
// pour être testable sans toucher au disque — c'est là que se trouvent les règles
// qui comptent : ne pas grossir sans fin, garder les erreurs plus longtemps que
// les informations.

import { dateToJSON } from "./focusTimerState.ts";
import type { KeyValueStore } from "./focusTimerState.ts";

export type LogLevel = "info" | "warning" | "error";

export const LogLevel = {
  allCases: ["info", "warning", "error"] as readonly LogLevel[],

  label(level: LogLevel): string {
    switch (level) {
      case "info": return "info";
      case "warning": return "avertissement";
      case "error": return "erreur";
    }
  },

  icon(level: LogLevel): string {
    switch (level) {
      case "info": return "info.circle";
      case "warning": return "exclamationmark.triangle";
      case "error": return "exclamationmark.octagon";
    }
  },
};

export interface LogEntryInit {
  id?: string;
  date?: Date;
  level: LogLevel;
  /** D'où vient la ligne : `sync`, `import`, `anki`, `ia`, `stockage`. */
  category: string;
  message: string;
  detail?: string | null;
}

/** Une ligne du journal de l'app. */
export class LogEntry {
  id: string;
  date: Date;
  level: LogLevel;
  category: string;
  message: string;
  detail: string | null;

  constructor(o: LogEntryInit) {
    this.id = o.id ?? crypto.randomUUID();
    this.date = o.date ?? new Date();
    this.level = o.level;
    this.category = o.category;
    this.message = o.message;
    this.detail = o.detail ?? null;
  }
}

/** Nombre maximal de lignes conservées. */
export const limit = 400;

/**
 * Ajoute une ligne en tête et borne la taille.
 *
 * Les plus **anciennes** partent en premier, et parmi elles les informations
 * avant les erreurs : quand la place manque, on garde ce qui explique un
 * problème.
 */
export function append(entry: LogEntry, entries: LogEntry[]): LogEntry[] {
  const updated = [entry, ...entries];
  if (updated.length <= limit) return updated;

  let overflow = updated.length - limit;
  for (const level of ["info", "warning"] as const) {
    if (overflow <= 0) break;
    let index = updated.length - 1;
    while (index >= 0 && overflow > 0) {
      if (updated[index].level === level) {
        updated.splice(index, 1);
        overflow -= 1;
      }
      index -= 1;
    }
  }
  return updated.slice(0, limit);
}

export function filtered(entries: LogEntry[], level: LogLevel | null): LogEntry[] {
  return level === null ? entries : entries.filter((entry) => entry.level === level);
}

export function count(entries: LogEntry[], level: LogLevel): number {
  return entries.filter((entry) => entry.level === level).length;
}

/** Le format ISO 8601 par défaut de `ISO8601DateFormatter` (secondes, sans fraction). */
export function iso8601(date: Date): string {
  return dateToJSON(date);
}

/** Le journal en texte, pour le partager ou le coller dans un message. */
export function text(entries: LogEntry[], formatter: { string(date: Date): string } = { string: iso8601 }): string {
  if (entries.length === 0) return "Journal vide.";
  return entries.map((entry) => {
    let line = `[${formatter.string(entry.date)}] ${LogLevel.label(entry.level).toUpperCase()} ${entry.category} — ${entry.message}`;
    if (entry.detail !== null && entry.detail !== "") {
      line += `\n    ${entry.detail.replace(/\n/g, "\n    ")}`;
    }
    return line;
  }).join("\n");
}

export const LogBuffer = { limit, append, filtered, count, text, iso8601 };

// MARK: - Le journal, persisté

export const logKey = "diagnostics.log";

/** Un `UserDefaults` en mémoire, pour les tests et l'amorçage. */
export function memoryLogStore(initial: Record<string, string> = {}): KeyValueStore {
  const values = new Map(Object.entries(initial));
  return {
    get: (key) => values.get(key) ?? null,
    set: (key, value) => { values.set(key, value); },
    remove: (key) => { values.delete(key); },
  };
}

/** Le magasin par défaut de l'app (remplace `UserDefaults.standard`). */
export const standardLogStore = memoryLogStore();

function encodeEntry(entry: LogEntry): Record<string, unknown> {
  const object: Record<string, unknown> = {
    id: entry.id,
    date: dateToJSON(entry.date),
    level: entry.level,
    category: entry.category,
    message: entry.message,
  };
  if (entry.detail !== null) object.detail = entry.detail;
  return object;
}

export function load(defaults: KeyValueStore = standardLogStore): LogEntry[] {
  const data = defaults.get(logKey);
  if (data === null || data === "") return [];
  let raw: unknown;
  try {
    raw = JSON.parse(data);
  } catch {
    return [];
  }
  if (!Array.isArray(raw)) return [];
  const result: LogEntry[] = [];
  for (const item of raw) {
    if (item === null || typeof item !== "object") return [];
    const o = item as Record<string, unknown>;
    if (typeof o.id !== "string" || typeof o.date !== "string" || typeof o.category !== "string"
      || typeof o.message !== "string" || (o.level !== "info" && o.level !== "warning" && o.level !== "error")) {
      return [];
    }
    if (o.detail !== undefined && o.detail !== null && typeof o.detail !== "string") return [];
    const date = new Date(o.date);
    if (Number.isNaN(date.getTime())) return [];
    result.push(new LogEntry({
      id: o.id,
      date,
      level: o.level,
      category: o.category,
      message: o.message,
      detail: typeof o.detail === "string" ? o.detail : null,
    }));
  }
  return result;
}

export function save(entries: LogEntry[], defaults: KeyValueStore = standardLogStore): void {
  try {
    defaults.set(logKey, JSON.stringify(entries.map(encodeEntry)));
  } catch {
    // Un journal ne doit jamais faire échouer ce qu'il observe.
  }
}

/** La catégorie, en clair, pour filtrer l'écran. */
export const Category = {
  sync: "synchronisation",
  importSeries: "import",
  ai: "analyse IA",
  anki: "anki",
  storage: "stockage",
  calendar: "calendrier",
  claude: "Claude Code",
};

/** Consigne une ligne. Volontairement tolérant. */
export function record(
  level: LogLevel,
  category: string,
  message: string,
  detail: string | null = null,
  defaults: KeyValueStore = standardLogStore,
): void {
  const entry = new LogEntry({ level, category, message, detail });
  save(append(entry, load(defaults)), defaults);
}

export function clear(defaults: KeyValueStore = standardLogStore): void {
  if (defaults.remove) defaults.remove(logKey);
  else defaults.set(logKey, "");
}

export const AppLog = { key: logKey, Category, load, save, record, clear, memoryLogStore, standardLogStore };
