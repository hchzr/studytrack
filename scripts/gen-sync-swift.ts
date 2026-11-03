// Génère StudyTrack/Domain/SyncSchema.generated.swift depuis windows/src/models/schema.ts :
// la même description que celle dont la migration Supabase et la base Windows sont
// tirées, donc les mêmes noms de colonnes, au caractère près.
//
//   node scripts/gen-sync-swift.ts           # écrit le fichier
//   node scripts/gen-sync-swift.ts --check   # échoue s'il n'est plus à jour

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tables, fieldColumn, refColumn } from "../windows/src/models/schema.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "StudyTrack", "Domain", "SyncSchema.generated.swift");

const ctor: Record<string, string> = { int: "int", double: "double", bool: "bool", text: "text", date: "date", uuid: "text" };

const lines: string[] = [
  "// Généré par scripts/gen-sync-swift.ts depuis windows/src/models/schema.ts — ne pas modifier à la main.",
  "//",
  "// Le pendant Swift de la migration `user_data_sync` : mêmes tables, mêmes colonnes,",
  "// mêmes règles de suppression.",
  "",
  "import Foundation",
  "import SwiftData",
  "",
  "enum SyncSchema {",
  "    static let tables: [any AnySyncTable] = [",
];
tables.forEach((t, k) => {
  lines.push(`        SyncTable<${t.model}>(name: "${t.name}", fields: [`);
  for (const f of t.fields) {
    const kind = ctor[f.type] + (f.optional ? "Optional" : "");
    lines.push(`            .${kind}("${fieldColumn(f)}", \\.${f.swift}),`);
  }
  lines.push("        ], refs: [");
  for (const r of t.refs) {
    lines.push(`            .one("${refColumn(r)}", \\.${r.swift}, table: "${r.table}", onDelete: .${r.onDelete}),`);
  }
  lines.push(`        ])${k < tables.length - 1 ? "," : ""}`);
});
lines.push("    ]", "}", "");
const text = lines.join("\n");

if (process.argv.includes("--check")) {
  if (!existsSync(out) || readFileSync(out, "utf8") !== text) {
    console.error("SyncSchema.generated.swift n'est plus à jour : node scripts/gen-sync-swift.ts");
    process.exit(1);
  }
  console.log("SyncSchema.generated.swift à jour");
} else {
  writeFileSync(out, text);
  console.log(`écrit ${out}`);
}
