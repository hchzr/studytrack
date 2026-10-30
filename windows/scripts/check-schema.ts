// Garde-fou : src/models/schema.ts doit décrire exactement les `@Model` Swift.
//
// Lit StudyTrack/Models/*.swift, relève les propriétés **stockées** de chaque
// `@Model` (celles qui ont une valeur par défaut, ou qui sont optionnelles sans
// corps calculé) et les compare au schéma TypeScript : nom, type, optionnalité,
// défaut littéral. Toute différence fait échouer `npm test`, donc la CI.
//
//   node scripts/check-schema.ts

import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tables, excludedModels, excludedFields, type FieldType } from "../src/models/schema.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const modelsDir = join(root, "StudyTrack", "Models");

interface SwiftProp { name: string; type: string; optional: boolean; default?: string }

const swiftTypes: Record<string, FieldType> = {
  String: "text", Int: "int", Double: "double", Bool: "bool", Date: "date", UUID: "uuid",
};

/** Les `@Model` d'un fichier, avec leurs propriétés stockées. */
export function parseModels(source: string): Map<string, SwiftProp[]> {
  const models = new Map<string, SwiftProp[]>();
  const lines = source.split("\n");
  let current: string | null = null;
  let pendingModel = false;
  for (const line of lines) {
    if (/^@Model\b/.test(line)) { pendingModel = true; continue; }
    const cls = line.match(/^(?:final )?class (\w+)/);
    if (cls) {
      current = pendingModel ? cls[1] : null;
      pendingModel = false;
      if (current) models.set(current, []);
      continue;
    }
    if (/^\S/.test(line) && !line.startsWith("//") && current && line.startsWith("}")) { current = null; continue; }
    if (!current) continue;
    // Propriété de premier niveau (4 espaces), éventuellement précédée d'attributs.
    const m = line.match(/^    (?:@\w+(?:\([^)]*\))?\s+)*var (\w+)\s*:\s*([^={]+?)\s*(?:=\s*(.+?))?\s*(\{.*)?$/);
    if (!m) continue;
    const [, name, rawType, def, body] = m;
    if (body !== undefined) continue; // calculée
    const optional = rawType.endsWith("?");
    if (def === undefined && !optional) continue;
    models.get(current)!.push({ name, type: rawType.replace(/\?$/, ""), optional, default: def });
  }
  return models;
}

export function check(): string[] {
  const errors: string[] = [];
  const swift = new Map<string, SwiftProp[]>();
  for (const file of readdirSync(modelsDir).filter((f) => f.endsWith(".swift"))) {
    for (const [k, v] of parseModels(readFileSync(join(modelsDir, file), "utf8"))) swift.set(k, v);
  }
  const schemaSource = readFileSync(join(modelsDir, "StudyTrackSchema.swift"), "utf8");
  const listed = [...schemaSource.matchAll(/^\s+(\w+)\.self,?$/gm)].map((m) => m[1]);

  for (const model of listed) {
    if (!swift.has(model)) errors.push(`${model} : listé dans SchemaV1 mais introuvable dans StudyTrack/Models`);
    const inTables = tables.some((t) => t.model === model);
    if (!inTables && !(model in excludedModels)) errors.push(`${model} : ni synchronisé ni exclu dans schema.ts`);
    if (inTables && model in excludedModels) errors.push(`${model} : à la fois synchronisé et exclu`);
  }
  for (const table of tables) {
    if (!listed.includes(table.model)) { errors.push(`${table.model} : absent de SchemaV1`); continue; }
    const props = swift.get(table.model) ?? [];
    const known = new Set<string>();
    for (const p of props) {
      const key = `${table.model}.${p.name}`;
      known.add(p.name);
      if (p.name === "id") {
        if (p.type !== "UUID") errors.push(`${key} : l'identifiant doit être un UUID`);
        continue;
      }
      if (key in excludedFields) continue;
      const ref = table.refs.find((r) => r.swift === p.name);
      const target = tables.find((t) => t.model === p.type);
      if (target) {
        if (!ref) errors.push(`${key} : relation vers ${p.type} absente de schema.ts`);
        else if (ref.table !== target.name) errors.push(`${key} : relation vers ${ref.table}, attendu ${target.name}`);
        continue;
      }
      if (/^\[/.test(p.type)) continue; // relation « plusieurs » : portée par l'enfant
      const field = table.fields.find((f) => f.swift === p.name);
      if (!field) { errors.push(`${key} (${p.type}) : absent de schema.ts`); continue; }
      const expected = swiftTypes[p.type];
      if (!expected) errors.push(`${key} : type Swift ${p.type} non pris en charge`);
      else if (field.type !== expected) errors.push(`${key} : ${field.type} dans schema.ts, ${expected} en Swift`);
      if (!!field.optional !== p.optional) errors.push(`${key} : optionnalité différente`);
      const def = p.default?.trim();
      if (def && !p.optional) {
        const literal = def.match(/^"(.*)"$/)?.[1];
        const enumDefault = def.match(/\.(\w+)\.rawValue$/)?.[1];
        const wanted = literal !== undefined ? literal : enumDefault;
        if (wanted !== undefined && wanted !== "" && field.default !== wanted)
          errors.push(`${key} : défaut "${wanted}" en Swift, ${JSON.stringify(field.default)} dans schema.ts`);
      }
    }
    for (const f of table.fields) if (!known.has(f.swift)) errors.push(`${table.model}.${f.swift} : n'existe plus en Swift`);
    for (const r of table.refs) if (!known.has(r.swift)) errors.push(`${table.model}.${r.swift} : relation disparue en Swift`);
  }
  // Règles de suppression : `@Relationship(deleteRule: .x, inverse: \Enfant.parent)`.
  for (const file of readdirSync(modelsDir).filter((f) => f.endsWith(".swift"))) {
    const src = readFileSync(join(modelsDir, file), "utf8");
    for (const m of src.matchAll(/deleteRule:\s*\.(\w+)[^)]*inverse:\s*\\(\w+)\.(\w+)/g)) {
      const [, rule, child, prop] = m;
      const ref = tables.find((t) => t.model === child)?.refs.find((r) => r.swift === prop);
      if (!ref) continue; // modèle exclu
      if (ref.onDelete !== rule) errors.push(`${child}.${prop} : onDelete ${ref.onDelete}, deleteRule .${rule} en Swift`);
    }
  }
  for (const table of tables) for (const r of table.refs) {
    const parent = tables.find((t) => t.name === r.table)!;
    const declared = [...readdirSync(modelsDir)].some((f) =>
      new RegExp(`deleteRule:[^)]*inverse:\\s*\\\\${table.model}\\.${r.swift}\\b`).test(readFileSync(join(modelsDir, f), "utf8")));
    // Une relation sans règle déclarée côté parent : SwiftData met à nul.
    if (!declared && r.onDelete !== "nullify" && parent) errors.push(`${table.model}.${r.swift} : cascade sans deleteRule côté Swift`);
  }
  for (const key of Object.keys(excludedFields)) {
    const [model, name] = key.split(".");
    if (!swift.get(model)?.some((p) => p.name === name)) errors.push(`${key} : exclusion d'un champ qui n'existe plus`);
  }
  return errors;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const errors = check();
  if (errors.length) {
    console.error(`❌ schema.ts ne correspond plus aux @Model Swift :\n  - ${errors.join("\n  - ")}`);
    process.exit(1);
  }
  console.log(`✅ schema.ts correspond aux @Model Swift (${tables.length} tables synchronisées)`);
}
