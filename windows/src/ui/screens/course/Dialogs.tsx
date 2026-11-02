// Les formulaires du cours : modifier le cours, une série, un élément de
// théorie, une évaluation (CourseFormView, SeriesEditorSheet, TheoryItemForm et
// ExamFormSheet côté Swift). Une boîte de dialogue du kit, des champs du kit.

import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import type { Course } from "../../../models/course.ts";
import { ExerciseSeries } from "../../../models/exercise.ts";
import { TheoryItem } from "../../../models/theoryItem.ts";
import { Exam } from "../../../models/exam.ts";
import { PastExam } from "../../../models/pastExam.ts";
import { ExamKind, TheoryKind } from "../../../models/enums.ts";
import { Button, IconButton, Select, Switch, cx } from "../../kit.tsx";
import "./course.css";

// MARK: - Squelette

/** Une boîte de dialogue : Échap ferme, Entrée valide, le premier champ prend le focus. */
export function Dialog({ title, onClose, onSubmit, children, danger, submitLabel = "Enregistrer", canSubmit = true }: {
  title: string; onClose: () => void; onSubmit: () => void | Promise<void>; children: ReactNode;
  /** Un bouton « Supprimer » à gauche, pour l'édition d'un objet existant. */
  danger?: { label: string; onClick: () => void | Promise<void> };
  submitLabel?: string; canSubmit?: boolean;
}) {
  const body = useRef<HTMLDivElement>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    body.current?.querySelector<HTMLElement>("input, textarea, select")?.focus();
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!canSubmit || busy) return;
    setBusy(true);
    try { await onSubmit(); } finally { setBusy(false); }
  };

  return (
    <div className="overlay" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <form className="dialog cs-dialog" role="dialog" aria-modal="true" aria-label={title} onSubmit={(e) => void submit(e)}>
        <div className="cs-dialog-head">
          <h2 className="serif">{title}</h2>
          <IconButton icon="xmark" label="Fermer" type="button" onClick={onClose} />
        </div>
        <div className="cs-dialog-body" ref={body}>{children}</div>
        <div className="cs-dialog-foot">
          {danger && <Button variant="danger" icon="trash" onClick={() => void danger.onClick()}>{danger.label}</Button>}
          <span className="spacer" />
          <Button onClick={onClose}>Annuler</Button>
          <Button variant="primary" type="submit" disabled={!canSubmit || busy}>{submitLabel}</Button>
        </div>
      </form>
    </div>
  );
}

export function Field({ label, children, className }: { label: string; children: ReactNode; className?: string }) {
  return <label className={cx("cs-field", className)}><span>{label}</span>{children}</label>;
}

/** « 2026-03-14 » (jour local), pour <input type="date">. */
function pad(value: number): string { return String(value).padStart(2, "0"); }
function toDateInput(date: Date | null): string {
  return date ? `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` : "";
}
function toDateTimeInput(date: Date): string {
  return `${toDateInput(date)}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
function fromInput(value: string): Date | null {
  if (value === "") return null;
  const date = new Date(value.length === 10 ? `${value}T12:00` : value);
  return Number.isNaN(date.getTime()) ? null : date;
}
const toNumber = (value: string, fallback: number): number => {
  const n = Number(value.replace(",", "."));
  return Number.isFinite(n) ? n : fallback;
};

type Saver = (objects: object[]) => Promise<void>;
type Remover = (object: object) => Promise<void>;

// MARK: - Le cours

const SWATCHES = ["#4F46E5", "#0E7490", "#15803D", "#B45309", "#B91C1C", "#9D174D", "#6D28D9", "#475569"];

export function CourseDialog({ course, save, onClose }: { course: Course; save: Saver; onClose: () => void }) {
  const [name, setName] = useState(course.name);
  const [code, setCode] = useState(course.code);
  const [credits, setCredits] = useState(String(course.credits));
  const [lecturer, setLecturer] = useState(course.lecturer);
  const [hasLectures, setHasLectures] = useState(course.hasLectures);
  const [lectureHours, setLectureHours] = useState(String(course.weeklyLectureHours));
  const [exerciseHours, setExerciseHours] = useState(String(course.weeklyExerciseHours));
  const [moodle, setMoodle] = useState(course.moodleURLString);
  const [color, setColor] = useState(course.colorHex);

  return (
    <Dialog title="Modifier le cours" onClose={onClose} canSubmit={name.trim() !== "" || code.trim() !== ""}
      onSubmit={async () => {
        course.name = name.trim();
        course.code = code.trim();
        course.credits = toNumber(credits, course.credits);
        course.lecturer = lecturer.trim();
        course.hasLectures = hasLectures;
        course.weeklyLectureHours = toNumber(lectureHours, course.weeklyLectureHours);
        course.weeklyExerciseHours = toNumber(exerciseHours, course.weeklyExerciseHours);
        course.moodleURLString = moodle.trim();
        course.colorHex = color;
        await save([course]);
        onClose();
      }}>
      <div className="cs-row2">
        <Field label="Code"><input className="field" value={code} onChange={(e) => setCode(e.target.value)} placeholder="CS-250" /></Field>
        <Field label="Crédits ECTS">
          <input className="field mono" inputMode="decimal" value={credits} onChange={(e) => setCredits(e.target.value)} />
        </Field>
      </div>
      <Field label="Nom"><input className="field" value={name} onChange={(e) => setName(e.target.value)} /></Field>
      <Field label="Enseignant"><input className="field" value={lecturer} onChange={(e) => setLecturer(e.target.value)} /></Field>
      <Switch checked={hasLectures} onChange={setHasLectures} label="Ce cours a un amphi" />
      <div className="cs-row2">
        <Field label="Heures de cours par semaine">
          <input className="field mono" inputMode="decimal" value={lectureHours} disabled={!hasLectures}
            onChange={(e) => setLectureHours(e.target.value)} />
        </Field>
        <Field label="Heures d'exercices par semaine">
          <input className="field mono" inputMode="decimal" value={exerciseHours}
            onChange={(e) => setExerciseHours(e.target.value)} />
        </Field>
      </div>
      <Field label="Page du cours (Moodle)">
        <input className="field" type="url" value={moodle} onChange={(e) => setMoodle(e.target.value)} placeholder="https://moodle.epfl.ch/…" />
      </Field>
      <div className="cs-field">
        <span>Couleur</span>
        <div className="cs-swatches">
          {SWATCHES.map((hex) => (
            <button key={hex} type="button" className="cs-swatch" aria-label={`Couleur ${hex}`} title={hex}
              aria-pressed={color.toLowerCase() === hex.toLowerCase()} style={{ ["--sw" as string]: hex }}
              onClick={() => setColor(hex)} />
          ))}
        </div>
      </div>
    </Dialog>
  );
}

// MARK: - Une série

export function SeriesDialog({ course, series, save, remove, onClose }:
  { course: Course; series: ExerciseSeries | null; save: Saver; remove: Remover; onClose: () => void }) {
  const nextNumber = Math.max(0, ...course.series.map((entry) => entry.seriesNumber)) + 1;
  const [number, setNumber] = useState(String(series?.seriesNumber ?? nextNumber));
  const [title, setTitle] = useState(series?.title ?? "");
  const [week, setWeek] = useState(String(series?.plannedWeek ?? Math.max(course.currentWeek, 0)));
  const [due, setDue] = useState(toDateInput(series?.dueDate ?? null));
  const [url, setUrl] = useState(series?.urlString ?? "");
  const [solutionURL, setSolutionURL] = useState(series?.solutionURLString ?? "");
  const [solutionsAt, setSolutionsAt] = useState(toDateInput(series?.solutionsAt ?? null));

  return (
    <Dialog title={series ? "Modifier la série" : "Nouvelle série"} onClose={onClose}
      danger={series ? { label: "Supprimer", onClick: async () => { await remove(series); onClose(); } } : undefined}
      onSubmit={async () => {
        const target = series ?? new ExerciseSeries({ course, seriesNumber: nextNumber });
        target.seriesNumber = Math.max(1, Math.trunc(toNumber(number, nextNumber)));
        target.title = title.trim();
        target.plannedWeek = Math.max(0, Math.trunc(toNumber(week, 0)));
        target.dueDate = fromInput(due);
        target.urlString = url.trim();
        target.solutionURLString = solutionURL.trim();
        target.solutionsAt = fromInput(solutionsAt);
        await save([target]);
        onClose();
      }}>
      <div className="cs-row2">
        <Field label="Numéro"><input className="field mono" inputMode="numeric" value={number} onChange={(e) => setNumber(e.target.value)} /></Field>
        <Field label="Semaine prévue (0 = aucune)">
          <input className="field mono" inputMode="numeric" value={week} onChange={(e) => setWeek(e.target.value)} />
        </Field>
      </div>
      <Field label="Titre"><input className="field" value={title} onChange={(e) => setTitle(e.target.value)} placeholder={`Série ${number}`} /></Field>
      <Field label="À rendre le"><input className="field" type="date" value={due} onChange={(e) => setDue(e.target.value)} /></Field>
      <Field label="Énoncé (adresse)"><input className="field" type="url" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://…" /></Field>
      <Field label="Corrigé (adresse)">
        <input className="field" type="url" value={solutionURL} onChange={(e) => setSolutionURL(e.target.value)} placeholder="https://…" />
      </Field>
      <Field label="Corrigé publié le">
        <input className="field" type="date" value={solutionsAt} onChange={(e) => setSolutionsAt(e.target.value)} />
      </Field>
    </Dialog>
  );
}

// MARK: - Un élément de théorie

export function TheoryDialog({ course, item, save, remove, onClose }:
  { course: Course; item: TheoryItem | null; save: Saver; remove: Remover; onClose: () => void }) {
  const [kind, setKind] = useState<TheoryKind>(item?.kind ?? "video");
  const [number, setNumber] = useState(item?.number ?? "");
  const [title, setTitle] = useState(item?.title ?? "");
  const [section, setSection] = useState(String(item?.sectionNumber ?? 1));
  const [week, setWeek] = useState(String(item?.plannedWeek ?? Math.max(course.currentWeek, 0)));
  const [minutes, setMinutes] = useState(item ? String(Math.round(item.durationSeconds / 60)) : "");
  const [url, setUrl] = useState(item?.urlString ?? "");

  return (
    <Dialog title={item ? "Modifier la théorie" : "Ajouter de la théorie"} onClose={onClose}
      canSubmit={title.trim() !== "" || number.trim() !== ""}
      danger={item ? { label: "Supprimer", onClick: async () => { await remove(item); onClose(); } } : undefined}
      onSubmit={async () => {
        const sectionNumber = Math.max(0, Math.trunc(toNumber(section, 1)));
        const target = item ?? new TheoryItem({
          course, sectionNumber, number: number.trim(),
          sortOrder: Math.max(0, ...course.theoryItems.map((entry) => entry.sortOrder)) + 1,
        });
        target.kind = kind;
        target.sectionNumber = sectionNumber;
        target.number = number.trim();
        target.title = title.trim();
        target.plannedWeek = Math.max(0, Math.trunc(toNumber(week, 0)));
        target.durationSeconds = Math.max(0, Math.round(toNumber(minutes, 0) * 60));
        target.urlString = url.trim();
        await save([target]);
        onClose();
      }}>
      <Field label="Type">
        <Select ariaLabel="Type" value={kind} onChange={setKind}
          options={TheoryKind.allCases.map((value) => ({ value, label: TheoryKind.label(value) }))} />
      </Field>
      <div className="cs-row2">
        <Field label="Numéro"><input className="field mono" value={number} onChange={(e) => setNumber(e.target.value)} placeholder="1.1" /></Field>
        <Field label="Chapitre"><input className="field mono" inputMode="numeric" value={section} onChange={(e) => setSection(e.target.value)} /></Field>
      </div>
      <Field label="Titre"><input className="field" value={title} onChange={(e) => setTitle(e.target.value)} /></Field>
      <div className="cs-row2">
        <Field label="Semaine prévue (0 = aucune)">
          <input className="field mono" inputMode="numeric" value={week} onChange={(e) => setWeek(e.target.value)} />
        </Field>
        <Field label="Durée (minutes)">
          <input className="field mono" inputMode="decimal" value={minutes} onChange={(e) => setMinutes(e.target.value)} />
        </Field>
      </div>
      <Field label="Adresse"><input className="field" type="url" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://…" /></Field>
    </Dialog>
  );
}

// MARK: - Une évaluation

export function ExamDialog({ course, exam, save, remove, onClose }:
  { course: Course; exam: Exam | null; save: Saver; remove: Remover; onClose: () => void }) {
  const [kind, setKind] = useState<ExamKind>(exam?.kind ?? "midterm");
  const [title, setTitle] = useState(exam?.title ?? "");
  const [date, setDate] = useState(toDateTimeInput(exam?.date ?? defaultExamDate()));
  const [weight, setWeight] = useState(exam?.weightPercent != null ? String(exam.weightPercent) : "");
  const [location, setLocation] = useState(exam?.location ?? "");

  return (
    <Dialog title={exam ? "Modifier l'évaluation" : "Nouvelle évaluation"} onClose={onClose}
      canSubmit={fromInput(date) !== null}
      danger={exam ? { label: "Supprimer", onClick: async () => { await remove(exam); onClose(); } } : undefined}
      onSubmit={async () => {
        const when = fromInput(date) ?? new Date();
        const percent = weight.trim() === "" ? null : toNumber(weight, 0);
        const target = exam ?? new Exam({ course, kind, title: title.trim(), date: when });
        target.kind = kind;
        target.title = title.trim() === "" ? ExamKind.label(kind) : title.trim();
        target.date = when;
        target.weightPercent = percent;
        target.location = location.trim();
        await save([target]);
        onClose();
      }}>
      <Field label="Type">
        <Select ariaLabel="Type" value={kind} onChange={setKind}
          options={ExamKind.allCases.map((value) => ({ value, label: ExamKind.label(value) }))} />
      </Field>
      <Field label="Titre"><input className="field" value={title} onChange={(e) => setTitle(e.target.value)} placeholder={ExamKind.label(kind)} /></Field>
      <Field label="Date et heure">
        <input className="field" type="datetime-local" value={date} onChange={(e) => setDate(e.target.value)} />
      </Field>
      <div className="cs-row2">
        <Field label="Poids (%)"><input className="field mono" inputMode="decimal" value={weight} onChange={(e) => setWeight(e.target.value)} /></Field>
        <Field label="Lieu"><input className="field" value={location} onChange={(e) => setLocation(e.target.value)} /></Field>
      </div>
    </Dialog>
  );
}

function defaultExamDate(): Date {
  const date = new Date();
  date.setDate(date.getDate() + 14);
  date.setHours(9, 15, 0, 0);
  return date;
}

// MARK: - Une annale

export function PastExamDialog({ exam, save, remove, onClose }:
  { exam: PastExam; save: Saver; remove: Remover; onClose: () => void }) {
  const [title, setTitle] = useState(exam.title);
  const [url, setUrl] = useState(exam.urlString);
  return (
    <Dialog title="Modifier l'annale" onClose={onClose}
      danger={{ label: "Supprimer", onClick: async () => { await remove(exam); onClose(); } }}
      onSubmit={async () => {
        exam.title = title.trim() === "" ? exam.title : title.trim();
        exam.urlString = url.trim();
        await save([exam]);
        onClose();
      }}>
      <Field label="Titre"><input className="field" value={title} onChange={(e) => setTitle(e.target.value)} /></Field>
      <Field label="Sujet (adresse)"><input className="field" type="url" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://…" /></Field>
    </Dialog>
  );
}
