// Les cartes de « Mes cours » (StudyTrack/Views/Courses/CoursesView.swift) :
// progression d'un cours, son état (à jour / en retard), et le geste de suivi.
// La carte d'ajout reprend le formulaire minimal du cours.

import { useState, type CSSProperties, type FormEvent } from "react";
import { AcademicTerm } from "../../../models/academicTerm.ts";
import { Course } from "../../../models/course.ts";
import { ExamKind } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { ProgressEngine } from "../../../domain/progressEngine.ts";
import { CourseTag } from "./weekCard.tsx";

/** `Course.colorHex` par défaut (`Course.swift`) : une couleur de données, pas un token d'UI. */
const DEFAULT_COURSE_COLOR = "#4F46E5";

const actionButton: CSSProperties = {
  border: "1px solid var(--rule)", background: "var(--sheet-raised)",
  borderRadius: 10, padding: "7px 12px", fontSize: 13, color: "var(--ink)",
};

const fieldStyle: CSSProperties = {
  display: "flex", flexDirection: "column", gap: 4,
  fontSize: 12, color: "var(--ink-secondary)",
};

const inputStyle: CSSProperties = {
  font: "inherit", fontSize: 13, color: "var(--ink)", background: "var(--ground)",
  border: "1px solid var(--rule)", borderRadius: 8, padding: "6px 8px", minWidth: 0,
};

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
  const examSoon = nextExam !== null && DateUtils.daysBetween(new Date(), nextExam.date) <= 21;
  const source = sourceLabel(course);
  return (
    <div className="card" style={{
      padding: 0, overflow: "hidden", display: "flex", flexDirection: "column", minWidth: 0,
    }}>
      <div style={{ height: 5, background: course.colorHex, flexShrink: 0 }} />
      <button onClick={() => onOpen(course.id)} style={{
        flex: 1, textAlign: "left", border: "none", background: "none",
        padding: 14, display: "flex", flexDirection: "column", gap: 6, color: "inherit",
      }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8 }}>
          <CourseTag code={course.displayCode} tint={course.colorHex} />
          <span className="mono" style={{ fontSize: 11, color: "var(--ink-tertiary)", whiteSpace: "nowrap" }}>
            {course.credits > 0 ? `${course.credits} ECTS` : ""}
          </span>
        </div>
        <div className="serif" style={{
          fontSize: 18, lineHeight: 1.25, minHeight: 44,
          display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden",
        }}>{course.name === "" ? course.displayCode : course.name}</div>
        <div style={{ display: "flex", alignItems: "baseline", gap: 2 }}>
          <span className="serif" style={{ fontSize: 30 }}>{percent}</span>
          <span className="serif" style={{ fontSize: 14 }}>%</span>
        </div>
        <div style={{ height: 5, borderRadius: 5, background: "var(--rule)", overflow: "hidden" }}>
          <div style={{
            width: `${Math.min(1, progress.completion) * 100}%`, height: "100%",
            borderRadius: 5, background: course.colorHex,
          }} />
        </div>
        <div style={{
          fontSize: 12, fontWeight: late > 0 ? 600 : 400,
          color: late > 0 ? "var(--wrong)" : "var(--ink-secondary)",
        }}>{ProgressEngine.standingLabel(late, ahead)}</div>
        {examSoon && nextExam && (
          <div style={{
            fontSize: 11,
            color: DateUtils.daysBetween(new Date(), nextExam.date) <= 3 ? "var(--wrong)" : "var(--ink-secondary)",
          }}>{ExamKind.label(nextExam.kind)} {DateUtils.countdownLabel(nextExam.date).toLowerCase()}</div>
        )}
        {source && (
          <div style={{
            fontSize: 11, color: "var(--ink-tertiary)", overflow: "hidden",
            textOverflow: "ellipsis", whiteSpace: "nowrap",
          }}>{source}</div>
        )}
      </button>
      <div style={{
        borderTop: "1px solid var(--rule)", padding: "8px 14px",
        display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8,
      }}>
        <label style={{
          display: "inline-flex", alignItems: "center", gap: 6, fontSize: 12,
          color: "var(--ink-secondary)", cursor: "pointer",
        }}>
          <input
            type="checkbox"
            checked={course.isTracked}
            onChange={(event) => onToggle(course, event.target.checked)}
            style={{ accentColor: "var(--ink)" }}
          />
          Suivi
        </label>
        <button onClick={() => onOpen(course.id)} style={{
          border: "none", background: "none", padding: 0, fontSize: 12, color: "var(--ink)",
        }}>Ouvrir →</button>
      </div>
    </div>
  );
}

/** Une ligne de cours archivé : « Réactiver » le remet dans la grille. */
export function ArchivedCourseRow({ course, onOpen, onToggle }:
  { course: Course; onOpen: (id: string) => void; onToggle: (course: Course, next: boolean) => void }) {
  const progress = ProgressEngine.progress(course);
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "9px 4px" }}>
      <CourseTag code={course.displayCode} tint={course.colorHex} />
      <span style={{
        flex: 1, minWidth: 0, fontSize: 13, overflow: "hidden",
        textOverflow: "ellipsis", whiteSpace: "nowrap",
      }}>{course.name === "" ? course.displayCode : course.name}</span>
      <span className="mono" style={{ fontSize: 11, color: "var(--ink-tertiary)", whiteSpace: "nowrap" }}>
        {Math.round(progress.completion * 100)}%
      </span>
      <button onClick={() => onOpen(course.id)} style={{
        border: "none", background: "none", padding: "2px 4px", fontSize: 12,
        color: "var(--ink-secondary)",
      }}>Ouvrir</button>
      <button onClick={() => onToggle(course, true)} style={{
        border: "1px solid var(--rule)", background: "var(--sheet-raised)", borderRadius: 8,
        padding: "3px 8px", fontSize: 12, color: "var(--ink)",
      }}>Réactiver</button>
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

  return (
    <form className="card" onSubmit={submit} style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div className="serif" style={{ fontSize: 18 }}>Ajouter un cours</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 10 }}>
        <label style={fieldStyle}>
          Code
          <input style={inputStyle} value={code} onChange={(event) => setCode(event.target.value)}
            placeholder="Ex. CS-250" autoFocus />
        </label>
        <label style={fieldStyle}>
          Nom
          <input style={inputStyle} value={name} onChange={(event) => setName(event.target.value)}
            placeholder="Ex. Algorithmes I" />
        </label>
        <label style={fieldStyle}>
          Crédits ECTS
          <input style={inputStyle} type="number" min={0} step={1} value={credits}
            onChange={(event) => setCredits(event.target.value)} />
        </label>
        <label style={fieldStyle}>
          Couleur
          <input style={{ ...inputStyle, padding: 2, height: 33 }} type="color" value={color}
            onChange={(event) => setColor(event.target.value)} />
        </label>
        {terms.length > 0 && (
          <label style={fieldStyle}>
            Semestre
            <select style={inputStyle} value={termID} onChange={(event) => setTermID(event.target.value)}>
              <option value="">Sans semestre</option>
              {terms.map((term) => (
                <option key={term.id} value={term.id}>{term.displayName}</option>
              ))}
            </select>
          </label>
        )}
      </div>
      {error && <div style={{ color: "var(--wrong)", fontSize: 12 }}>{error}</div>}
      <div style={{ display: "flex", gap: 8 }}>
        <button type="submit" disabled={busy || code.trim() === "" || name.trim() === ""}
          style={{ ...actionButton, opacity: busy || code.trim() === "" || name.trim() === "" ? 0.5 : 1 }}>
          Ajouter
        </button>
        <button type="button" onClick={onCancel} style={actionButton}>Annuler</button>
      </div>
    </form>
  );
}
