// Port de StudyTrack/Domain/NotebookExport.swift : les sources à donner à
// NotebookLM — la fiche, ses liens, ses schémas et ses questions, en Markdown.
// NotebookLM n'a pas d'interface pour une app tierce : on **prépare** les
// sources, l'étudiant·e les dépose, puis rapporte le podcast ici.

import { RevisionEntryKind, type RevisionSheet } from "./revisionSheet.ts";
import { StudyRelation, type StudyMap } from "./studyMap.ts";
import { DiagramKind, StudyLinks } from "./studyMapGraph.ts";

export interface NotebookFile {
  name: string;
  text: string;
}

export const NotebookExport = {
  /** Les fichiers à déposer dans NotebookLM (avec `chapter` : seulement ce chapitre). */
  files(courseName: string, code: string, sheet: RevisionSheet, map: StudyMap, chapter: string | null = null): NotebookFile[] {
    const scoped = sheet.chapter(chapter);
    const name = scoped !== null ? `${courseName} — ${scoped.title}` : courseName;
    const tag = scoped !== null ? `${code} · ${Array.from(scoped.title).slice(0, 24).join("")}` : code;
    return [
      { name: `01 Fiche · ${tag}.md`, text: NotebookExport.sheetText(name, sheet, map, chapter) },
      { name: `02 Liens entre les notions · ${tag}.md`, text: NotebookExport.linksText(name, sheet, map, chapter) },
      { name: `03 Schémas · ${tag}.md`, text: NotebookExport.schemasText(name, map, sheet, chapter) },
      { name: `04 Questions pour se tester · ${tag}.md`, text: NotebookExport.questionsText(name, sheet, map, chapter) },
      { name: `00 Lis-moi · ${tag}.md`, text: NotebookExport.readme(name) },
    ].filter((file) => file.text !== "");
  },

  sheetText(courseName: string, sheet: RevisionSheet, map: StudyMap, only: string | null = null): string {
    const lines = ["# Fiche de révision — " + courseName, ""];
    for (const chapter of sheet.chapters) {
      if (chapter.entries.length === 0 || (only !== null && chapter.id !== only)) continue;
      lines.push("## " + chapter.title);
      lines.push("");
      for (const item of sheet.keyed) {
        if (item.chapterID !== chapter.id) continue;
        lines.push(`### ${item.entry.title} (${RevisionEntryKind.label(item.entry.kind)})`);
        const enrichment = map.enrichment[item.key];
        if (enrichment?.gist !== undefined) lines.push("En clair : " + enrichment.gist);
        if (enrichment?.why !== undefined) lines.push("À quoi ça sert : " + enrichment.why);
        lines.push("");
        lines.push(item.entry.body);
        if (enrichment?.example !== undefined) {
          lines.push("");
          lines.push("Exemple : " + enrichment.example);
        }
        const near = StudyLinks.neighbourhood(item.key, map, new Set(sheet.keyed.map((entry) => entry.key)));
        if (near.before.length !== 0) {
          lines.push("");
          lines.push("À comprendre avant : " + near.before.map((it) => titleOf(it.key, sheet)).join(" ; "));
        }
        if (near.after.length !== 0) lines.push("En découle : " + near.after.map((it) => titleOf(it.key, sheet)).join(" ; "));
        if (near.aside.length !== 0) lines.push("À ne pas confondre avec : " + near.aside.map((it) => titleOf(it.key, sheet)).join(" ; "));
        lines.push("");
      }
    }
    return lines.join("\n");
  },

  linksText(courseName: string, sheet: RevisionSheet, map: StudyMap, chapter: string | null = null): string {
    const mine = new Set(sheet.keyedIn(chapter).map((item) => item.key));
    const links = map.links.filter((link) => chapter === null || (mine.has(link.from) && mine.has(link.to)));
    if (links.length === 0) return "";
    const lines = ["# Comment les notions de " + courseName + " s'enchaînent", "",
      "Chaque ligne dit une dépendance réelle du cours : ce qu'il faut comprendre pour comprendre autre chose.", ""];
    for (const link of links) {
      let line = `- **${titleOf(link.from, sheet)}** ${StudyRelation.label(link.relation)} **${titleOf(link.to, sheet)}**`;
      if (link.note !== null) line += " — " + link.note;
      lines.push(line);
    }
    return lines.join("\n");
  },

  schemasText(courseName: string, map: StudyMap, _sheet: RevisionSheet, chapter: string | null = null): string {
    const diagrams = map.diagrams.filter((diagram) => chapter === null || diagram.chapter === chapter);
    if (diagrams.length === 0) return "";
    const lines = ["# Schémas de " + courseName, ""];
    for (const schema of diagrams) {
      lines.push(`## ${schema.title} (${DiagramKind.label(schema.kind)})`);
      if (schema.summary !== null) lines.push(schema.summary);
      lines.push("");
      if (schema.kind === "comparison" && schema.columns !== null && schema.rows !== null) {
        lines.push("| |" + schema.columns.join(" | ") + " |");
        lines.push("|" + " --- |".repeat(schema.columns.length + 1));
        for (const row of schema.rows) lines.push("| " + row.join(" | ") + " |");
      } else {
        const labels = new Map<string, string>();
        for (const node of schema.nodes) if (!labels.has(node.id)) labels.set(node.id, node.label);
        for (const edge of schema.edges) {
          const name = edge.label !== undefined ? ` (${edge.label})` : "";
          lines.push(`- ${labels.get(edge.from) ?? edge.from} →${name} ${labels.get(edge.to) ?? edge.to}`);
        }
        for (const node of schema.nodes) {
          if (!schema.edges.some((edge) => edge.from === node.id || edge.to === node.id)) lines.push("- " + node.label);
        }
      }
      lines.push("");
    }
    return lines.join("\n");
  },

  questionsText(courseName: string, sheet: RevisionSheet, map: StudyMap, chapter: string | null = null): string {
    const items: { title: string; question: string; answer: string }[] = [];
    for (const item of sheet.keyedIn(chapter)) {
      const check = map.enrichment[item.key]?.check;
      if (check !== undefined) items.push({ title: item.entry.title, question: check.question, answer: check.answer });
    }
    if (items.length === 0) return "";
    const lines = ["# Pour se tester — " + courseName, ""];
    for (const item of items) {
      lines.push(`**${item.title}** — ${item.question}`);
      lines.push("Réponse : " + item.answer);
      lines.push("");
    }
    return lines.join("\n");
  },

  readme(courseName: string): string {
    return `# ${courseName} — sources pour NotebookLM

Dépose ces fichiers dans un nouveau carnet NotebookLM (« Ajouter des sources »). Ajoute aussi, si tu les as, les PDF du cours et tes notes.

Pour le podcast (Résumé audio → « Personnaliser ») :
- « Concentre-toi sur les liens entre les notions et sur ce qu'il faut comprendre avant chaque résultat. »
- « Explique d'abord l'intuition, puis l'énoncé ; signale les pièges. »

Puis reviens dans StudyTrack : colle l'adresse du carnet, et glisse le podcast téléchargé pour l'écouter pendant que tu révises.
`;
  },
};

function titleOf(key: string, sheet: RevisionSheet): string {
  return sheet.entryForKey(key)?.entry.title ?? key;
}
