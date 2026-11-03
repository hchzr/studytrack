// La fonction serveur `tutor` (repli quand Claude Code manque) n'accepte aucune consigne du client :
// elle garde une copie des consignes de l'app. Ce test échoue si la copie n'est plus à jour ;
// `UPDATE=1 npx vitest run tests/generators` la réécrit.

import { describe, expect, it } from "vitest";
import { readFileSync, writeFileSync } from "node:fs";
import { ClaudeTutor } from "../../src/domain/claudeTutor.ts";
import { RevisionSheetAI } from "../../src/domain/revisionSheet.ts";

const FILE = new URL("../../../supabase/functions/tutor/prompts.generated.ts", import.meta.url);

function generated(): string {
  const prompts = { tutor: ClaudeTutor.systemPrompt("tutor"), sheet: RevisionSheetAI.instructions, sheetMethods: RevisionSheetAI.methodsInstructions };
  return "// Généré depuis l'app (ClaudeTutor.systemPrompt, RevisionSheetAI) : le serveur n'accepte pas de consigne du client.\n"
    + "// Régénérer : cd windows && UPDATE=1 npx vitest run tests/generators\n\nexport const PROMPTS: Record<string, string> = "
    + JSON.stringify(prompts, null, 2) + ";\n";
}

describe("consignes du serveur", () => {
  it("la fonction tutor a la copie à jour des consignes de l'app", () => {
    if (process.env.UPDATE) writeFileSync(FILE, generated());
    expect(readFileSync(FILE, "utf8")).toBe(generated());
  });
});
