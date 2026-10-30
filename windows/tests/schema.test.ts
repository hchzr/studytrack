import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { check } from "../scripts/check-schema.ts";
import { migrationSQL, sqliteDDL, rowTypes } from "../scripts/gen-schema.ts";
import { ddl } from "../src/models/ddl.generated.ts";
import { tables, columnsOf } from "../src/models/schema.ts";

const repo = join(__dirname, "..", "..");

describe("schéma synchronisé", () => {
  it("correspond aux @Model Swift", () => {
    expect(check()).toEqual([]);
  });

  it("les fichiers générés sont à jour", () => {
    expect(readFileSync(join(repo, "supabase/migrations/20261030000000_user_data_sync.sql"), "utf8")).toBe(migrationSQL());
    expect(readFileSync(join(__dirname, "../src/models/ddl.generated.ts"), "utf8")).toBe(sqliteDDL());
    expect(readFileSync(join(__dirname, "../src/models/rows.generated.ts"), "utf8")).toBe(rowTypes());
  });

  it("aucune colonne en double ni réservée", () => {
    for (const t of tables) expect(() => columnsOf(t)).not.toThrow();
  });

  it("la base SQLite locale se crée, deux fois de suite", () => {
    const db = new DatabaseSync(":memory:");
    for (let pass = 0; pass < 2; pass++) for (const stmt of ddl) db.exec(stmt);
    const names = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all()
      .map((r) => (r as { name: string }).name);
    for (const t of tables) expect(names).toContain(t.name);
    expect(names).toContain("sync_cursor");
  });

  it("une ligne insérée sans valeurs prend les défauts Swift", () => {
    const db = new DatabaseSync(":memory:");
    for (const stmt of ddl) db.exec(stmt);
    db.prepare("INSERT INTO sync_mistakes (id) VALUES (?)").run("m1");
    const row = db.prepare("SELECT * FROM sync_mistakes WHERE id = 'm1'").get() as Record<string, unknown>;
    expect(row.kind_raw).toBe("method");
    expect(row.source).toBe("manual");
    expect(row.summary).toBe("");
    expect(row.dirty).toBe(1);
    expect(String(row.updated_at)).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
  });
});
