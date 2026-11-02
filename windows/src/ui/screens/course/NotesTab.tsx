// Les notes d'un cours (CourseNotesView.swift) : lues telles quelles, modifiées
// en texte. Le barème, ce que le prof a dit en amphi, l'erreur du corrigé.

import { useState } from "react";
import type { Course } from "../../../models/course.ts";
import { Button } from "../../kit.tsx";
import "./course.css";

export function NotesTab({ course, saveAll }: { course: Course; saveAll: (objects: object[]) => Promise<void> }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(course.notes);
  const empty = course.notes.trim() === "";

  const start = () => { setDraft(course.notes); setEditing(true); };
  const finish = async () => {
    if (draft !== course.notes) {
      course.notes = draft;
      await saveAll([course]);
    }
    setEditing(false);
  };

  return (
    <div className="cs-notes stack">
      <div className="hstack">
        <span className="faint small">
          {editing ? "Texte libre : une ligne par idée, - pour une liste." : ""}
        </span>
        <span className="spacer" />
        {editing && <Button onClick={() => setEditing(false)}>Annuler</Button>}
        <Button variant={editing ? "primary" : "default"} icon={editing ? "checkmark" : "pencil"}
          onClick={() => void (editing ? finish() : start())}>
          {editing ? "Terminé" : empty ? "Écrire" : "Modifier"}
        </Button>
      </div>
      {editing ? (
        <textarea className="field" value={draft} autoFocus aria-label="Notes du cours"
          onChange={(event) => setDraft(event.target.value)} />
      ) : (
        <div className="card">
          {empty ? (
            <div className="cs-notes-body empty" onClick={start}>
              Ce qui ne rentre nulle part ailleurs : le barème, ce que le prof a dit en amphi, l'erreur du corrigé.
            </div>
          ) : (
            <div className="cs-notes-body">{course.notes}</div>
          )}
        </div>
      )}
    </div>
  );
}
