// Corriger une session depuis le journal du bilan : sa durée, sa date, son
// cours, sa catégorie, sa note — ou la supprimer (SessionEditSheet, réduit à
// une feuille de bureau).
//
// Les champs restent locaux jusqu'à « Enregistrer » : « Annuler » ne laisse
// aucune trace dans le magasin, et une nouvelle session n'existe qu'une fois
// enregistrée.

import { useEffect, useState } from "react";
import { useData } from "../../../data/dataContext.tsx";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { type Course, type StudySession, TaskType } from "../../../models/index.ts";
import { Button, Select, Stepper } from "../../kit.tsx";
import "./stats.css";

function localInput(date: Date): string {
  const pad = (value: number): string => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
    + `T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

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
      className="overlay"
      onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}
    >
      <div className="dialog" role="dialog" aria-modal="true"
        aria-label={isNew ? "Nouvelle session" : "Modifier la session"} style={{ width: 460, maxHeight: "86vh", padding: 20, overflowY: "auto" }}>
        <h2 className="serif" style={{ fontSize: 22, margin: "0 0 16px" }}>
          {isNew ? "Nouvelle session" : "Modifier la session"}
        </h2>

        <div className="stats-form">
          <label>Cours</label>
          <Select
            value={courseId}
            ariaLabel="Cours"
            onChange={setCourseId}
            options={[
              { value: "", label: "Aucun cours" },
              ...courses.map((course) => ({ value: course.id, label: `${course.displayCode} — ${course.name}` })),
            ]}
          />

          <label>Catégorie</label>
          <Select
            value={taskType}
            ariaLabel="Catégorie"
            onChange={(value) => setTaskType(value as TaskType)}
            options={choices.map((type) => ({ value: type, label: TaskType.label(type) }))}
          />

          <label htmlFor="stats-start">Début</label>
          <input
            id="stats-start"
            className="field"
            type="datetime-local"
            value={startedAt}
            onChange={(event) => setStartedAt(event.target.value)}
          />

          <label>Durée</label>
          <div className="hstack">
            <Stepper value={minutes} min={1} max={720} step={5} label="durée" onChange={setMinutes}
              format={(value) => DateUtils.durationLabel(value * 60)} />
          </div>

          <label htmlFor="stats-note" style={{ alignSelf: "start", paddingTop: 8 }}>Note</label>
          <textarea
            id="stats-note"
            className="field"
            rows={3}
            value={note}
            placeholder="Note (optionnel)"
            onChange={(event) => setNote(event.target.value)}
          />
        </div>

        <p className="faint" style={{ fontSize: 12, margin: "12px 0 0" }}>
          {validStart
            ? `Total : ${DateUtils.durationLabel(durationSeconds)} — fin à `
              + `${DateUtils.time(new Date(start.getTime() + durationSeconds * 1000))}.`
            : "Date de début invalide."}
        </p>

        <div className="hstack" style={{ marginTop: 20 }}>
          {!isNew && !confirming && (
            <Button variant="danger" size="sm" icon="trash" onClick={() => setConfirming(true)}>
              Supprimer la session
            </Button>
          )}
          {!isNew && confirming && (
            <span className="hstack">
              <span style={{ fontSize: 13, color: "var(--wrong)" }}>Supprimer cette session ?</span>
              <Button variant="danger" size="sm" disabled={busy} onClick={() => void destroy()}>Oui, supprimer</Button>
              <Button variant="ghost" size="sm" onClick={() => setConfirming(false)}>Non</Button>
            </span>
          )}

          <span className="spacer" />

          <Button onClick={onClose}>Annuler</Button>
          <Button variant="primary" disabled={busy || !validStart} onClick={() => void commit()}>
            Enregistrer
          </Button>
        </div>
      </div>
    </div>
  );
}
