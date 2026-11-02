// Les cartes de « Mes cours » (StudyTrack/Views/Courses/CoursesView.swift) :
// progression d'un cours, son état (à jour / en retard), et le geste de suivi.
// La carte d'ajout reprend le formulaire minimal du cours.

import { useState, type FormEvent } from "react";
import { AcademicTerm } from "../../../models/academicTerm.ts";
import { Course } from "../../../models/course.ts";
import { ExamKind } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { ProgressEngine } from "../../../domain/progressEngine.ts";
import { Button, Card, Checkbox, ProgressBar, Select, cx } from "../../kit.tsx";
import { CourseTag } from "./weekCard.tsx";
import "./today.css";

/** `Course.colorHex` par défaut (`Course.swift`) : une couleur de données, pas un token d'UI. */
const DEFAULT_COURSE_COLOR = "#4F46E5";

/** « Moodle · Botafogo » : d'où vient le contenu du cours. */
function sourceLabel(course: Course): string | null {
  const hosts = course.contentSources
    .map((source) => {
      try { return new URL(source).hostname.toLowerCase(); } catch { return null; }
    })
    .filter((host): host is string => host !== null);
  const names: string[] = [];
  if (hosts.some((host) => host.includes("moodle"))) names.push("Moodle");
  if (hosts.some((host) => host.includes("courseware"))) names.push("Courseware");
  if (hosts.some((host) => host.includes("botafogo"))) names.push("Botafogo");
  return names.length === 0 ? null : names.join(" · ");
}

/**
 * La carte d'un cours sur la grille : sa couleur en tête, son code, son nom, son
 * avancement global et son état. Le suivi se coche ici — c'est le seul geste
 * « archiver / réactiver » de l'écran.
 */
export function CourseCard({ course, onOpen, onToggle }:
  { course: Course; onOpen: (id: string) => void; onToggle: (course: Course, next: boolean) => void }) {
  const progress = ProgressEngine.progress(course);
  const late = ProgressEngine.lateCount(course);
  const ahead = ProgressEngine.aheadCount(course);
  const percent = Math.round(progress.completion * 100);
  const nextExam = course.nextExam;
  const examDays = nextExam ? DateUtils.daysBetween(new Date(), nextExam.date) : null;
  const examSoon = nextExam !== null && examDays !== null && examDays <= 21;
  const source = sourceLabel(course);
  return (
    <div className="card c-card">
      <div className="c-card-band" style={{ background: course.colorHex }} />
      <button type="button" className="c-card-open" onClick={() => onOpen(course.id)}>
        <span className="c-card-top">
          <CourseTag code={course.displayCode} tint={course.colorHex} />
          {course.credits > 0 && <span className="mono faint" style={{ fontSize: 11 }}>{course.credits} ECTS</span>}
        </span>
        <span className="serif c-card-name">{course.name === "" ? course.displayCode : course.name}</span>
        <span className="c-card-percent">
          <span className="serif" style={{ fontSize: 30, lineHeight: 1 }}>{percent}</span>
          <span className="serif" style={{ fontSize: 14 }}>%</span>
        </span>
        <ProgressBar value={progress.completion} color={course.colorHex} />
        <span className={cx("t-sub", late > 0 && "urgent")} style={{ fontWeight: late > 0 ? 600 : 400 }}>
          {ProgressEngine.standingLabel(late, ahead)}
        </span>
        {examSoon && nextExam && (
          <span className={cx("t-sub-xs", examDays !== null && examDays <= 3 && "urgent")}>
            {ExamKind.label(nextExam.kind)} {DateUtils.countdownLabel(nextExam.date).toLowerCase()}
          </span>
        )}
        {source && <span className="c-card-source t-ellipsis">{source}</span>}
      </button>
      <div className="c-card-foot">
        <Checkbox checked={course.isTracked} onChange={(next) => onToggle(course, next)}
          label={<span className="muted" style={{ fontSize: 12 }}>Suivi</span>}
          ariaLabel={`Suivre ${course.displayCode}`} />
        <Button variant="ghost" size="sm" trailingIcon="arrow.right" onClick={() => onOpen(course.id)}>Ouvrir</Button>
      </div>
    </div>
  );
}

/** Une ligne de cours archivé : « Réactiver » le remet dans la grille. */
export function ArchivedCourseRow({ course, onOpen, onToggle }:
  { course: Course; onOpen: (id: string) => void; onToggle: (course: Course, next: boolean) => void }) {
  const progress = ProgressEngine.progress(course);
  return (
    <div className="t-row">
      <CourseTag code={course.displayCode} tint={course.colorHex} />
      <span className="t-ellipsis" style={{ flex: 1, fontSize: 13 }}>
        {course.name === "" ? course.displayCode : course.name}
      </span>
      <span className="mono faint" style={{ fontSize: 11 }}>{Math.round(progress.completion * 100)}%</span>
      <Button variant="ghost" size="sm" onClick={() => onOpen(course.id)}>Ouvrir</Button>
      <Button size="sm" icon="arrow.counterclockwise" onClick={() => onToggle(course, true)}>Réactiver</Button>
    </div>
  );
}

/**
 * « Ajouter un cours à la main » : les champs du formulaire Swift qui suffisent à
 * faire exister le cours (code, nom, crédits, couleur, semestre). Le reste se
 * règle dans la fiche du cours.
 */
export function AddCourseForm({ terms, defaultTerm, onCancel, onCreate }:
  {
    terms: AcademicTerm[];
    defaultTerm: AcademicTerm | null;
    onCancel: () => void;
    onCreate: (course: Course) => Promise<void>;
  }) {
  const [code, setCode] = useState("");
  const [name, setName] = useState("");
  const [credits, setCredits] = useState("4");
  const [color, setColor] = useState(DEFAULT_COURSE_COLOR);
  const [termID, setTermID] = useState(defaultTerm?.id ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (code.trim() === "" || name.trim() === "") return;
    setBusy(true);
    setError(null);
    try {
      const term = terms.find((candidate) => candidate.id === termID) ?? null;
      await onCreate(new Course({
        code: code.trim(),
        name: name.trim(),
        credits: Number.isFinite(Number(credits)) ? Number(credits) : 0,
        colorHex: color,
        term,
      }));
    } catch {
      setError("Impossible d'ajouter ce cours.");
    } finally {
      setBusy(false);
    }
  };

  const invalid = code.trim() === "" || name.trim() === "";
  return (
    <Card>
      <form onSubmit={submit} className="c-form">
        <div className="serif" style={{ fontSize: 18 }}>Ajouter un cours</div>
        <div className="c-form-grid">
          <label className="c-label">
            Code
            <input className="field" value={code} onChange={(event) => setCode(event.target.value)}
              placeholder="Ex. CS-250" autoFocus />
          </label>
          <label className="c-label">
            Nom
            <input className="field" value={name} onChange={(event) => setName(event.target.value)}
              placeholder="Ex. Algorithmes I" />
          </label>
          <label className="c-label">
            Crédits ECTS
            <input className="field" type="number" min={0} step={1} value={credits}
              onChange={(event) => setCredits(event.target.value)} />
          </label>
          <label className="c-label">
            Couleur
            <input className="field c-color" type="color" value={color}
              onChange={(event) => setColor(event.target.value)} />
          </label>
          {terms.length > 0 && (
            <label className="c-label">
              Semestre
              <Select value={termID} onChange={setTermID} ariaLabel="Semestre"
                options={[{ value: "", label: "Sans semestre" },
                  ...terms.map((term) => ({ value: term.id, label: term.displayName }))]} />
            </label>
          )}
        </div>
        {error && <div className="c-error" role="alert">{error}</div>}
        <div className="hstack">
          <Button type="submit" variant="primary" icon="plus" disabled={busy || invalid}>Ajouter</Button>
          <Button onClick={onCancel}>Annuler</Button>
        </div>
      </form>
    </Card>
  );
}
