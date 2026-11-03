// « Écouter » (NotebookLMPanel.swift, sans compte) : la fiche, ses liens, ses schémas et des
// questions, prêts pour NotebookLM, qui en fait un podcast. Trois étapes, sans quitter l'app.

import { useState } from "react";
import type { RevisionSheet } from "../../domain/revisionSheet.ts";
import type { StudyMap } from "../../domain/studyMap.ts";
import { NotebookExport } from "../../domain/notebookExport.ts";
import { openInApp } from "../studymode/openers.ts";

export function ListenView({ courseName, code, sheet, map, chapter }: {
  courseName: string; code: string; sheet: RevisionSheet; map: StudyMap; chapter: string | null;
}) {
  const [saved, setSaved] = useState(false);
  const files = NotebookExport.files(courseName, code, sheet, map, chapter);
  const save = () => {
    for (const file of files) {
      const url = URL.createObjectURL(new Blob([file.text], { type: "text/markdown;charset=utf-8" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = file.name.replace(/[\\/:*?"<>|]/g, "-");
      document.body.appendChild(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 2000);
    }
    setSaved(true);
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14, maxWidth: 620 }}>
      <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>Un podcast de ta fiche</span>
      <ol className="timetable-steps">
        <li>
          Enregistre les {files.length} fichiers (fiche, liens, schémas, questions).
          <div style={{ marginTop: 6 }}><button type="button" className="btn btn-primary" onClick={save}>{saved ? "Enregistrés ✓" : "Enregistrer les fichiers"}</button></div>
        </li>
        <li>
          Ouvre NotebookLM, crée un carnet et dépose-les.
          <div style={{ marginTop: 6 }}><button type="button" className="btn" onClick={() => { void openInApp("https://notebooklm.google.com/", "NotebookLM"); }}>Ouvrir NotebookLM</button></div>
        </li>
        <li>Dans le carnet, « Résumé audio » : le podcast se génère en quelques minutes.</li>
      </ol>
      <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>{chapter ? "Seulement ce chapitre." : "Tout le cours."} Les fichiers vont dans tes Téléchargements.</span>
    </div>
  );
}
