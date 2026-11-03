// Une note rapide, rangée dans les notes d'un cours, datée (QuickNoteSheet du Mac) : ce qu'on
// veut retenir arrive n'importe quand — « le midterm couvre jusqu'au chapitre 5 », « demander
// la 3.4 à l'assistant ». Une ligne, un cours, et c'est rangé. S'ouvre de partout par
// l'événement `studytrack:quicknote` (la palette, le mode étude).

import { useEffect, useMemo, useRef, useState } from "react";
import { Course } from "../../models/index.ts";
import { useData } from "../../data/dataContext.tsx";
import { timerController } from "../timerController.ts";

export const QUICK_NOTE_EVENT = "studytrack:quicknote";

export function openQuickNote(): void {
  window.dispatchEvent(new CustomEvent(QUICK_NOTE_EVENT));
}

const stamp = new Intl.DateTimeFormat("fr-CH", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

/** Ajoute une ligne datée aux notes du cours (`QuickNote.append`). */
export function appendQuickNote(course: Course, text: string, at = new Date()): void {
  const line = text.trim();
  if (!line) return;
  const entry = `- **${stamp.format(at)}** — ${line}`;
  const current = course.notes.trim();
  course.notes = current === "" ? entry : current + "\n" + entry;
}

export function QuickNoteHost() {
  const { store, version, save } = useData();
  const [open, setOpen] = useState(false);
  const [courseID, setCourseID] = useState<string>("");
  const [text, setText] = useState("");
  const field = useRef<HTMLTextAreaElement | null>(null);
  const courses = useMemo(() => (store ? store.fetch(Course).filter((c) => c.isTracked).sort((a, b) => a.code.localeCompare(b.code)) : []), [store, version]);

  useEffect(() => {
    const show = () => {
      const preferred = timerController.snapshot().state?.courseID;
      setCourseID(courses.find((c) => c.id === preferred)?.id ?? courses[0]?.id ?? "");
      setText("");
      setOpen(true);
    };
    window.addEventListener(QUICK_NOTE_EVENT, show);
    return () => window.removeEventListener(QUICK_NOTE_EVENT, show);
  }, [courses]);
  useEffect(() => { if (open) field.current?.focus(); }, [open]);

  if (!open) return null;
  const course = courses.find((c) => c.id === courseID) ?? null;
  const commit = () => {
    if (!course || !text.trim()) return;
    appendQuickNote(course, text);
    void save(course);
    setOpen(false);
  };
  return (
    <div role="dialog" aria-label="Note rapide" onKeyDown={(event) => { if (event.key === "Escape") setOpen(false); }}
      style={{ position: "fixed", inset: 0, zIndex: 400, display: "grid", placeItems: "center", background: "rgba(0,0,0,0.35)" }}
      onClick={(event) => { if (event.target === event.currentTarget) setOpen(false); }}>
      <div style={{ width: 480, maxWidth: "calc(100vw - 32px)", padding: 18, borderRadius: 16, background: "var(--sheet)", border: "1px solid var(--rule)", display: "flex", flexDirection: "column", gap: 12, color: "var(--ink)" }}>
        <span className="serif" style={{ fontSize: 20 }}>Note rapide</span>
        <select className="select" value={courseID} onChange={(event) => setCourseID(event.target.value)} aria-label="Cours">
          {courses.map((c) => <option key={c.id} value={c.id}>{c.displayCode} · {c.name}</option>)}
        </select>
        <textarea ref={field} className="field" rows={4} value={text} placeholder="Ce que tu veux retenir"
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); commit(); } }} />
        <div style={{ display: "flex", justifyContent: "flex-end", gap: 8 }}>
          <button type="button" className="btn" onClick={() => setOpen(false)}>Annuler</button>
          <button type="button" className="btn btn-primary" disabled={!course || !text.trim()} onClick={commit}>Ranger (Ctrl+Entrée)</button>
        </div>
      </div>
    </div>
  );
}
