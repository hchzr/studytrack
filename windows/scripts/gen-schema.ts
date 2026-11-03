// Génère, à partir de src/models/schema.ts :
//   - supabase/migrations/20261030000000_user_data_sync.sql  (tables, RLS, garde LWW)
//   - supabase/migrations/20261103000000_sync_e2ee.sql        (les mêmes tables, chiffrées : voir docs/sync-e2ee.md)
//   - src/models/ddl.generated.ts                             (base SQLite locale)
//   - src/models/rows.generated.ts                            (types des lignes)
//
//   node scripts/gen-schema.ts           # écrit les fichiers
//   node scripts/gen-schema.ts --check   # échoue s'ils ne sont plus à jour (CI)

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tables, fieldColumn, refColumn, columnsOf, type Field, type FieldType } from "../src/models/schema.ts";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..", "..");
const banner = "Généré par windows/scripts/gen-schema.ts depuis src/models/schema.ts — ne pas modifier à la main.";

const pgType: Record<FieldType, string> = {
  uuid: "uuid", text: "text", int: "bigint", double: "double precision", bool: "boolean", date: "timestamptz",
};
const sqliteType: Record<FieldType, string> = {
  uuid: "TEXT", text: "TEXT", int: "INTEGER", double: "REAL", bool: "INTEGER", date: "TEXT",
};
const tsType: Record<FieldType, string> = {
  uuid: "string", text: "string", int: "number", double: "number", bool: "boolean", date: "string",
};

function pgDefault(f: Field): string {
  if (f.optional) return "";
  switch (f.type) {
    case "text": return ` not null default '${String(f.default ?? "").replace(/'/g, "''")}'`;
    case "int": case "double": return ` not null default ${f.default ?? 0}`;
    case "bool": return ` not null default ${f.default ?? false}`;
    case "date": return " not null default now()";
    case "uuid": return " not null";
  }
}

function sqliteDefault(f: Field): string {
  if (f.optional) return "";
  switch (f.type) {
    case "text": return ` NOT NULL DEFAULT '${String(f.default ?? "").replace(/'/g, "''")}'`;
    case "int": case "double": return ` NOT NULL DEFAULT ${f.default ?? 0}`;
    case "bool": return ` NOT NULL DEFAULT ${f.default ? 1 : 0}`;
    case "date": return " NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))";
    case "uuid": return " NOT NULL";
  }
}

export function migrationSQL(): string {
  const out: string[] = [
    `-- ${banner}`,
    "--",
    "-- Synchronisation des données personnelles entre l'iPhone, le Mac et Windows.",
    "--",
    "-- Une table par `@Model` de SchemaV1 (hors copies locales des groupes). Chaque",
    "-- ligne appartient à `user_id` ; seule sa propriétaire la lit et l'écrit.",
    "--",
    "-- Trois horodatages :",
    "--   updated_at         heure de la modification, posée par l'appareil : c'est",
    "--                      elle qui départage deux écritures (la plus récente gagne) ;",
    "--   deleted_at         pierre tombale : une suppression se propage comme une",
    "--                      écriture, et un appareil hors ligne l'apprend au retour ;",
    "--   server_updated_at  posée ici, à chaque écriture acceptée : le curseur des",
    "--                      lectures incrémentales (l'horloge d'un appareil ne peut",
    "--                      pas en servir). Les clients relisent avec une marge, une",
    "--                      transaction pouvant valider après une autre plus récente.",
    "--",
    "-- Pas de clés étrangères entre ces tables : un appareil resté hors ligne peut",
    "-- envoyer l'enfant d'un parent supprimé ailleurs, et cet envoi ne doit pas",
    "-- échouer. Les règles de suppression (cascade / mise à nul) sont appliquées par",
    "-- les clients, telles que SwiftData les déclare.",
    "",
    "create or replace function public.sync_guard()",
    "returns trigger",
    "language plpgsql",
    "as $$",
    "begin",
    "  if tg_op = 'UPDATE' then",
    "    if new.user_id is distinct from old.user_id then",
    "      raise exception 'une ligne ne change pas de propriétaire' using errcode = '42501';",
    "    end if;",
    "    -- Écriture plus ancienne que la ligne : ignorée, la version récente reste.",
    "    if new.updated_at < old.updated_at then",
    "      return old;",
    "    end if;",
    "  end if;",
    "  new.server_updated_at := clock_timestamp();",
    "  return new;",
    "end;",
    "$$;",
    "",
  ];
  for (const t of tables) {
    columnsOf(t);
    const cols = [
      "  id                uuid primary key",
      "  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade",
      ...t.fields.map((f) => `  ${fieldColumn(f)} ${pgType[f.type]}${pgDefault(f)}`),
      ...t.refs.map((r) => `  ${refColumn(r)} uuid`),
      "  updated_at        timestamptz not null default now()",
      "  deleted_at        timestamptz",
      "  server_updated_at timestamptz not null default now()",
    ];
    out.push(
      `-- ${t.model}`,
      `create table if not exists public.${t.name} (`,
      cols.join(",\n"),
      ");",
      "",
      `create index if not exists ${t.name}_pull_idx on public.${t.name} (user_id, server_updated_at);`,
      ...t.refs.map((r) => `create index if not exists ${t.name}_${refColumn(r)}_idx on public.${t.name} (${refColumn(r)});`),
      "",
      `alter table public.${t.name} enable row level security;`,
      "",
      `drop policy if exists ${t.name}_owner on public.${t.name};`,
      `create policy ${t.name}_owner on public.${t.name}`,
      "  for all using (user_id = auth.uid()) with check (user_id = auth.uid());",
      "",
      `drop trigger if exists ${t.name}_guard on public.${t.name};`,
      `create trigger ${t.name}_guard before insert or update on public.${t.name}`,
      "  for each row execute function public.sync_guard();",
      "",
    );
  }
  out.push(
    "-- Les appareils ouverts apprennent les écritures des autres sans attendre.",
    "do $$",
    "begin",
    ...tables.map((t) =>
      `  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = '${t.name}') then\n` +
      `    alter publication supabase_realtime add table public.${t.name};\n  end if;`),
    "end;",
    "$$;",
    "",
  );
  return out.join("\n");
}

/**
 * La synchronisation chiffrée de bout en bout. Les champs du modèle (schema.ts) ne sont
 * plus des colonnes : ils vivent dans `payload`, scellé sur l'appareil. Le serveur garde ce
 * dont il a besoin pour la plus-récente-gagne et le curseur : `id`, `updated_at`,
 * `deleted_at`, `server_updated_at` — et `key_id`, l'identifiant public de la clé.
 * L'ancienne migration reste telle qu'elle a été appliquée ; celle-ci remplace ses tables
 * (vides : personne n'avait activé la synchronisation).
 */
export function e2eeMigrationSQL(): string {
  const names = tables.map((t) => t.name);
  const list = names.map((n) => `'${n}'`).join(", ");
  const out: string[] = [
    `-- ${banner}`,
    "--",
    "-- Synchronisation chiffrée de bout en bout (docs/sync-e2ee.md).",
    "--",
    "-- Les tables `sync_*` de 20261030000000_user_data_sync.sql portaient les champs en",
    "-- colonnes, lisibles par le serveur. Elles étaient vides (la synchronisation n'avait",
    "-- jamais été activée) : on les recrée avec une seule colonne de contenu, `payload`,",
    "-- chiffrée par l'appareil (AES-256-GCM, la clé du compte ne quitte pas les appareils).",
    "--",
    "--   updated_at         heure de la modification, posée par l'appareil (la plus récente gagne) ;",
    "--   deleted_at         pierre tombale (alors `payload` est nul) ;",
    "--   server_updated_at  posée ici : le curseur des lectures ;",
    "--   payload            nonce ‖ chiffré ‖ étiquette ; les champs du modèle y sont ;",
    "--   key_id             identifiant public de la clé (16 octets en hexadécimal).",
    "--",
    "-- Le serveur voit donc encore QUAND une ligne change et COMBIEN il y en a ; il ne voit",
    "-- ni leur contenu ni les relations entre elles.",
    "",
    "-- `sync_vault` : un coffre par compte. Il dit qu'une clé existe et laquelle (`key_id`),",
    "-- pour qu'un nouvel appareil sache à quoi s'attendre et vérifie la clé reçue. Il ne contient",
    "-- aucun secret. Écrit une fois : pas de mise à jour, on le supprime pour le réinitialiser.",
    "create table if not exists public.sync_vault (",
    "  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,",
    "  key_id     text not null check (key_id ~ '^[0-9a-f]{32}$'),",
    "  created_at timestamptz not null default now()",
    ");",
    "",
    "alter table public.sync_vault enable row level security;",
    "",
    "drop policy if exists sync_vault_select on public.sync_vault;",
    "create policy sync_vault_select on public.sync_vault for select using (user_id = auth.uid());",
    "drop policy if exists sync_vault_insert on public.sync_vault;",
    "create policy sync_vault_insert on public.sync_vault for insert with check (user_id = auth.uid());",
    "drop policy if exists sync_vault_delete on public.sync_vault;",
    "create policy sync_vault_delete on public.sync_vault for delete using (user_id = auth.uid());",
    "",
    "create or replace function public.sync_vault_immutable()",
    "returns trigger",
    "language plpgsql",
    "as $$",
    "begin",
    "  raise exception 'le coffre ne se modifie pas : on le supprime pour le réinitialiser' using errcode = '42501';",
    "end;",
    "$$;",
    "",
    "drop trigger if exists sync_vault_immutable on public.sync_vault;",
    "create trigger sync_vault_immutable before update on public.sync_vault",
    "  for each row execute function public.sync_vault_immutable();",
    "",
    "-- Les anciennes tables (champs en clair) sont supprimées, une seule fois : une table qui a",
    "-- déjà `payload` n'est pas touchée, la migration se rejoue sans rien perdre.",
    "do $$",
    "declare t text;",
    "begin",
    `  foreach t in array array[${list}] loop`,
    "    if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = t)",
    "       and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'payload') then",
    "      execute format('drop table public.%I cascade', t);",
    "    end if;",
    "  end loop;",
    "end;",
    "$$;",
    "",
    "-- La garde : le propriétaire et la clé d'une ligne ne changent pas ; une écriture plus",
    "-- ancienne que la ligne est ignorée ; le serveur pose server_updated_at.",
    "create or replace function public.sync_guard()",
    "returns trigger",
    "language plpgsql",
    "as $$",
    "begin",
    "  -- Seule la clé du coffre actuel est acceptée : un appareil resté sur une clé",
    "  -- d'avant une réinitialisation ne peut plus rien écrire.",
    "  if not exists (select 1 from public.sync_vault v where v.user_id = new.user_id and v.key_id = new.key_id) then",
    "    raise exception 'clé périmée : ajoute de nouveau cet appareil' using errcode = '42501';",
    "  end if;",
    "  if tg_op = 'UPDATE' then",
    "    if new.user_id is distinct from old.user_id then",
    "      raise exception 'une ligne ne change pas de propriétaire' using errcode = '42501';",
    "    end if;",
    "    if new.key_id is distinct from old.key_id then",
    "      raise exception 'une ligne ne change pas de clé : réinitialise le coffre' using errcode = '42501';",
    "    end if;",
    "    -- Écriture plus ancienne que la ligne : ignorée, la version récente reste.",
    "    if new.updated_at < old.updated_at then",
    "      return old;",
    "    end if;",
    "  end if;",
    "  new.server_updated_at := clock_timestamp();",
    "  return new;",
    "end;",
    "$$;",
    "",
  ];
  for (const t of tables) {
    out.push(
      `-- ${t.model}`,
      `create table if not exists public.${t.name} (`,
      [
        "  id                uuid primary key",
        "  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade",
        "  updated_at        timestamptz not null",
        "  deleted_at        timestamptz",
        "  server_updated_at timestamptz not null default now()",
        "  payload           bytea",
        "  key_id            text not null check (key_id ~ '^[0-9a-f]{32}$')",
        "  constraint " + t.name + "_payload_check check (deleted_at is not null or payload is not null)",
      ].join(",\n"),
      ");",
      "",
      `create index if not exists ${t.name}_pull_idx on public.${t.name} (user_id, server_updated_at);`,
      "",
      `alter table public.${t.name} enable row level security;`,
      "",
      `drop policy if exists ${t.name}_owner on public.${t.name};`,
      `create policy ${t.name}_owner on public.${t.name}`,
      "  for all using (user_id = auth.uid()) with check (user_id = auth.uid());",
      "",
      `drop trigger if exists ${t.name}_guard on public.${t.name};`,
      `create trigger ${t.name}_guard before insert or update on public.${t.name}`,
      "  for each row execute function public.sync_guard();",
      "",
    );
  }
  out.push(
    "-- « Réinitialiser le coffre » : toutes les lignes chiffrées du compte et son coffre, en une",
    "-- transaction (security invoker : les politiques RLS ne laissent effacer que les siennes).",
    "create or replace function public.sync_reset_vault()",
    "returns void",
    "language plpgsql",
    "security invoker",
    "as $$",
    "begin",
    ...names.map((n) => `  delete from public.${n} where user_id = auth.uid();`),
    "  delete from public.sync_vault where user_id = auth.uid();",
    "end;",
    "$$;",
    "",
    "revoke all on function public.sync_reset_vault() from public, anon;",
    "grant execute on function public.sync_reset_vault() to authenticated;",
    "",
    "-- Les appareils ouverts apprennent les écritures des autres sans attendre.",
    "do $$",
    "begin",
    ...tables.map((t) =>
      `  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = '${t.name}') then\n` +
      `    alter publication supabase_realtime add table public.${t.name};\n  end if;`),
    "end;",
    "$$;",
    "",
  );
  return out.join("\n");
}

export function sqliteDDL(): string {
  const stmts: string[] = [];
  for (const t of tables) {
    const cols = [
      "id TEXT PRIMARY KEY",
      ...t.fields.map((f) => `${fieldColumn(f)} ${sqliteType[f.type]}${sqliteDefault(f)}`),
      ...t.refs.map((r) => `${refColumn(r)} TEXT`),
      "updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
      "deleted_at TEXT",
      "server_updated_at TEXT",
      // 1 tant que la modification locale n'a pas été acceptée par le serveur.
      "dirty INTEGER NOT NULL DEFAULT 1",
    ];
    stmts.push(`CREATE TABLE IF NOT EXISTS ${t.name} (\n  ${cols.join(",\n  ")}\n)`);
    for (const r of t.refs) stmts.push(`CREATE INDEX IF NOT EXISTS ${t.name}_${refColumn(r)}_idx ON ${t.name} (${refColumn(r)})`);
    stmts.push(`CREATE INDEX IF NOT EXISTS ${t.name}_dirty_idx ON ${t.name} (dirty) WHERE dirty = 1`);
  }
  stmts.push("CREATE TABLE IF NOT EXISTS sync_cursor (\n  table_name TEXT PRIMARY KEY,\n  server_updated_at TEXT NOT NULL\n)");
  return [
    `// ${banner}`,
    "",
    "export const ddl: string[] = [",
    ...stmts.map((s) => `  ${JSON.stringify(s)},`),
    "];",
    "",
  ].join("\n");
}

export function rowTypes(): string {
  const out = [`// ${banner}`, ""];
  for (const t of tables) {
    out.push(`/** ${t.model} (table ${t.name}). */`, `export interface ${t.model}Row {`, "  id: string;");
    for (const f of t.fields) out.push(`  ${fieldColumn(f)}: ${tsType[f.type]}${f.optional ? " | null" : ""};`);
    for (const r of t.refs) out.push(`  ${refColumn(r)}: string | null;`);
    out.push("  updated_at: string;", "  deleted_at: string | null;", "}", "");
  }
  out.push("export interface Rows {");
  for (const t of tables) out.push(`  ${t.name}: ${t.model}Row;`);
  out.push("}", "", `export type TableName = keyof Rows;`, "");
  return out.join("\n");
}

const outputs: [string, () => string][] = [
  [join(repo, "supabase", "migrations", "20261030000000_user_data_sync.sql"), migrationSQL],
  [join(repo, "supabase", "migrations", "20261103000000_sync_e2ee.sql"), e2eeMigrationSQL],
  [join(here, "..", "src", "models", "ddl.generated.ts"), sqliteDDL],
  [join(here, "..", "src", "models", "rows.generated.ts"), rowTypes],
];

if (import.meta.url === `file://${process.argv[1]}`) {
  const checkOnly = process.argv.includes("--check");
  let stale = 0;
  for (const [path, make] of outputs) {
    const content = make();
    const current = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (current === content) continue;
    if (checkOnly) { console.error(`❌ pas à jour : ${path} (lancer node scripts/gen-schema.ts)`); stale++; }
    else { writeFileSync(path, content); console.log(`écrit ${path}`); }
  }
  if (stale) process.exit(1);
  if (checkOnly) console.log("✅ fichiers générés à jour");
}
