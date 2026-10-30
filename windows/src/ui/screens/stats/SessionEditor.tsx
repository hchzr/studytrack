// Corriger une session depuis le journal du bilan : sa durée, sa date, son
// cours, sa catégorie, sa note — ou la supprimer (SessionEditSheet, réduit à
// une feuille de bureau).
//
// Les champs restent locaux jusqu'à « Enregistrer » : « Annuler » ne laisse
// aucune trace dans le magasin, et une nouvelle session n'existe qu'une fois
// enregistrée.

import { useEffect, useState, type CSSProperties } from "react";
import { useData } from "../../../data/dataContext.tsx";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { type Course, type StudySession, TaskType } from "../../../models/index.ts";

function localInput(date: Date): string {
  const pad = (value: number): string => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
    + `T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

const fieldStyle: CSSProperties = {
  padding: "7px 9px", borderRadius: 8, border: "1px solid var(--rule)",
  background: "var(--ground)", color: "var(--ink)", font: "inherit", minWidth: 0,
};

export function SessionEditor({ session, isNew, courses, onClose }: {
  session: StudySession;
  isNew: boolean;
  courses: Course[];
  onClose: () => void;
}) {
  const { save, remove } = useData();
  const [courseId, setCourseId] = useState(session.course?.id ?? "");
  const [taskType, setTaskType] = useState<TaskType>(TaskType.canonical(session.taskType));
  const [startedAt, setStartedAt] = useState(localInput(session.startedAt));
  const [minutes, setMinutes] = useState(Math.max(1, Math.trunc(session.durationSeconds / 60)));
  const [note, setNote] = useState(session.note);
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Une session Anki garde son étiquette ; on ne la choisit pas d'habitude.
  const choices: TaskType[] = taskType === "flashcards"
    ? [...TaskType.choices, "flashcards"]
    : [...TaskType.choices];
  const start = new Date(startedAt);
  const validStart = !Number.isNaN(start.getTime());
  const durationSeconds = Math.max(1, minutes) * 60;

  const commit = async (): Promise<void> => {
    if (busy) return;
    setBusy(true);
    session.course = courses.find((course) => course.id === courseId) ?? null;
    session.taskType = taskType;
    if (validStart) session.startedAt = start;
    session.durationSeconds = durationSeconds;
    session.note = note;
    await save(session);
    setBusy(false);
    onClose();
  };

  const destroy = async (): Promise<void> => {
    if (busy) return;
    setBusy(true);
    await remove(session);
    setBusy(false);
    onClose();
  };

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={isNew ? "Nouvelle session" : "Modifier la session"}
      onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}
      style={{
        position: "fixed", inset: 0, zIndex: 50, display: "grid", placeItems: "center",
        padding: 20, background: "rgba(0, 0, 0, 0.38)",
      }}
    >
      <div className="card" style={{
        width: 460, maxWidth: "100%", maxHeight: "calc(100vh - 40px)", overflowY: "auto",
        boxShadow: "0 24px 60px rgba(0, 0, 0, 0.28)",
      }}>
        <h2 className="serif" style={{ fontSize: 22, margin: "0 0 16px" }}>
          {isNew ? "Nouvelle session" : "Modifier la session"}
        </h2>

        <div style={{ display: "grid", gridTemplateColumns: "92px minmax(0, 1fr)", gap: 10, alignItems: "center" }}>
          <label htmlFor="stats-course" style={{ fontSize: 13, color: "var(--ink-secondary)" }}>Cours</label>
          <select id="stats-course" value={courseId} onChange={(event) => setCourseId(event.target.value)} style={fieldStyle}>
            <option value="">Aucun cours</option>
            {courses.map((course) => (
              <option key={course.id} value={course.id}>
                {course.displayCode} — {course.name}
              </option>
            ))}
          </select>

          <label htmlFor="stats-task" style={{ fontSize: 13, color: "var(--ink-secondary)" }}>Catégorie</label>
          <select
            id="stats-task"
            value={taskType}
            onChange={(event) => setTaskType(event.target.value as TaskType)}
            style={fieldStyle}
          >
            {choices.map((type) => (
              <option key={type} value={type}>{TaskType.label(type)}</option>
            ))}
          </select>

          <label htmlFor="stats-start" style={{ fontSize: 13, color: "var(--ink-secondary)" }}>Début</label>
          <input
            id="stats-start"
            type="datetime-local"
            value={startedAt}
            onChange={(event) => setStartedAt(event.target.value)}
            style={fieldStyle}
          />

          <label htmlFor="stats-minutes" style={{ fontSize: 13, color: "var(--ink-secondary)" }}>Durée</label>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <input
              id="stats-minutes"
              type="number"
              min={1}
              max={720}
              step={5}
              value={minutes}
              onChange={(event) => setMinutes(Math.max(1, Math.min(720, Number(event.target.value) || 1)))}
              style={{ ...fieldStyle, width: 92 }}
            />
            <span style={{ fontSize: 13, color: "var(--ink-secondary)" }}>min</span>
            <span style={{ fontSize: 13, color: "var(--ink-tertiary)" }}>
              {DateUtils.durationLabel(durationSeconds)}
            </span>
          </div>

          <label htmlFor="stats-note" style={{ fontSize: 13, color: "var(--ink-secondary)", alignSelf: "start", paddingTop: 7 }}>
            Note
          </label>
          <textarea
            id="stats-note"
            rows={3}
            value={note}
            placeholder="Note (optionnel)"
            onChange={(event) => setNote(event.target.value)}
            style={{ ...fieldStyle, resize: "vertical" }}
          />
        </div>

        <p style={{ fontSize: 12, color: "var(--ink-tertiary)", margin: "12px 0 0" }}>
          {validStart
            ? `Total : ${DateUtils.durationLabel(durationSeconds)} — fin à `
              + `${DateUtils.time(new Date(start.getTime() + durationSeconds * 1000))}.`
            : "Date de début invalide."}
        </p>

        <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 20 }}>
          {!isNew && !confirming && (
            <button
              type="button"
              onClick={() => setConfirming(true)}
              style={{
                border: "none", background: "none", padding: "6px 0",
                color: "var(--wrong)", fontSize: 13, cursor: "pointer",
              }}
            >
              Supprimer la session
            </button>
          )}
          {!isNew && confirming && (
            <span style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={{ fontSize: 13, color: "var(--wrong)" }}>Supprimer cette session ?</span>
              <button type="button" onClick={() => void destroy()} disabled={busy}
                style={{ border: "none", background: "none", color: "var(--wrong)", fontWeight: 600, fontSize: 13, cursor: "pointer" }}>
                Oui, supprimer
              </button>
              <button type="button" onClick={() => setConfirming(false)}
                style={{ border: "none", background: "none", color: "var(--ink-secondary)", fontSize: 13, cursor: "pointer" }}>
                Non
              </button>
            </span>
          )}

          <span style={{ flex: 1 }} />

          <button type="button" onClick={onClose}
            style={{
              padding: "7px 14px", borderRadius: 10, border: "1px solid var(--rule)",
              background: "var(--sheet)", color: "var(--ink)", fontSize: 13, cursor: "pointer",
            }}>
            Annuler
          </button>
          <button
            type="button"
            onClick={() => void commit()}
            disabled={busy || !validStart}
            style={{
              padding: "7px 16px", borderRadius: 10, border: "1px solid var(--ink)",
              background: "var(--ink)", color: "var(--sheet)", fontSize: 13, fontWeight: 600,
              cursor: busy || !validStart ? "default" : "pointer",
              opacity: busy || !validStart ? 0.5 : 1,
            }}
          >
            Enregistrer
          </button>
        </div>
      </div>
    </div>
  );
}
