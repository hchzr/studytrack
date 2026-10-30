// Exercices d'un cours (ExercisesTabView.swift + ExerciseStatementView.swift).
//
// Tout le suivi se fait dans la liste : cocher un exercice ou ses questions, puis
// le corriger d'un toucher — vert, orange, rouge. La fiche à droite sert à lire
// (énoncé, questions, indication, solution) et à poser la sûreté.

import { useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { Exercise, ExerciseSeries, SubQuestion } from "../../../models/exercise.ts";
import { ConfidenceLevel, Correctness } from "../../../models/enums.ts";
import { ExerciseFlow, ExerciseStage } from "../../../domain/exerciseFlow.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Plural } from "../../../domain/plural.ts";
import {
  ConfidenceDot, ConfidencePicker, CorrectionDots, EmptyState, LinkChip, MathText,
  Pill, ProgressRing, StageMark, exerciseLinks, seriesLinks,
} from "./common.tsx";

interface ExercisesTabProps {
  course: Course;
  week: number;
  saveAll: (objects: object[]) => Promise<void>;
}

export function ExercisesTab({ course, week, saveAll }: ExercisesTabProps) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [toggledSeries, setToggledSeries] = useState<Set<string>>(new Set());
  const [toggledQuestions, setToggledQuestions] = useState<Set<string>>(new Set());

  const series = course.sortedSeries.filter((entry) => week === 0 || entry.plannedWeek === week);
  const selected = selectedId === null
    ? null
    : course.allExercises.find((exercise) => exercise.id === selectedId) ?? null;

  const persistExercise = (exercise: Exercise) => saveAll([exercise, ...exercise.subQuestions]);

  const toggleDone = async (exercise: Exercise) => {
    exercise.setDone(!exercise.isDone);
    await persistExercise(exercise);
  };

  const correct = async (exercise: Exercise, result: Correctness | null) => {
    if (result !== null) exercise.correct(result);
    else exercise.clearCorrection();
    await persistExercise(exercise);
  };

  const toggleQuestion = async (exercise: Exercise, question: SubQuestion) => {
    question.toggle();
    await persistExercise(exercise);
  };

  const setConfidence = async (exercise: Exercise, value: ConfidenceLevel | null) => {
    exercise.confidence = value;
    await saveAll([exercise]);
  };

  const toggleRedo = async (exercise: Exercise) => {
    exercise.redoRequired = !exercise.redoRequired;
    await saveAll([exercise]);
  };

  const flipSeries = (id: string) => {
    setToggledSeries((previous) => {
      const next = new Set(previous);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const flipQuestions = (id: string) => {
    setToggledQuestions((previous) => {
      const next = new Set(previous);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  if (course.series.length === 0) {
    return <EmptyState title="Aucune série" message="Depuis Moodle, ou le PDF d'une série." />;
  }

  return (
    <div style={{ display: "grid", gridTemplateColumns: selected ? "minmax(0, 1fr) 370px" : "minmax(0, 1fr)", gap: 18, alignItems: "start" }}>
      <div>
        <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 10 }}>
          <h2 style={{ fontSize: 13, textTransform: "uppercase", letterSpacing: 0.6,
            color: "var(--ink-tertiary)", margin: 0 }}>
            Séries
          </h2>
          <span className="mono" style={{ color: "var(--ink-secondary)", fontSize: 12 }}>{series.length}</span>
        </div>

        {series.length === 0 ? (
          <EmptyState title="Pas de série" message={`Rien en semaine ${week}.`} />
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            {series.map((entry) => (
              <SeriesCard
                key={entry.id}
                series={entry}
                collapsed={isCollapsed(entry, toggledSeries)}
                onToggleCollapse={() => flipSeries(entry.id)}
                selectedId={selectedId}
                showsQuestions={(exercise) => showsQuestions(exercise, toggledQuestions)}
                onToggleQuestions={(exercise) => flipQuestions(exercise.id)}
                onToggleDone={(exercise) => void toggleDone(exercise)}
                onCorrect={(exercise, result) => void correct(exercise, result)}
                onToggleQuestion={(exercise, question) => void toggleQuestion(exercise, question)}
                onSelect={(exercise) => setSelectedId(exercise.id)}
              />
            ))}
          </div>
        )}

        <Legend />
      </div>

      {selected && (
        <ExerciseDetail
          key={selected.id}
          exercise={selected}
          onClose={() => setSelectedId(null)}
          onToggleDone={() => void toggleDone(selected)}
          onCorrect={(result) => void correct(selected, result)}
          onToggleQuestion={(question) => void toggleQuestion(selected, question)}
          onConfidence={(value) => void setConfidence(selected, value)}
          onToggleRedo={() => void toggleRedo(selected)}
        />
      )}
    </div>
  );
}

/** Une série terminée — sans rien « à refaire » — se replie en une ligne. */
function isCollapsed(series: ExerciseSeries, toggled: Set<string>): boolean {
  const byDefault = series.isComplete && !series.exercises.some((exercise) => exercise.redoRequired);
  return byDefault !== toggled.has(series.id);
}

function showsQuestions(exercise: Exercise, toggled: Set<string>): boolean {
  const byDefault = !ExerciseStage.isDone(ExerciseStage(exercise));
  return byDefault !== toggled.has(exercise.id);
}

// MARK: - Série

function SeriesCard({ series, collapsed, onToggleCollapse, selectedId, showsQuestions: showQuestions, onToggleQuestions, onToggleDone, onCorrect, onToggleQuestion, onSelect }: {
  series: ExerciseSeries;
  collapsed: boolean;
  onToggleCollapse: () => void;
  selectedId: string | null;
  showsQuestions: (exercise: Exercise) => boolean;
  onToggleQuestions: (exercise: Exercise) => void;
  onToggleDone: (exercise: Exercise) => void;
  onCorrect: (exercise: Exercise, result: Correctness | null) => void;
  onToggleQuestion: (exercise: Exercise, question: SubQuestion) => void;
  onSelect: (exercise: Exercise) => void;
}) {
  const links = seriesLinks(series);
  const required = series.requiredExercises;
  const spent = ExerciseFlow.seconds(series);

  return (
    <div className="card" style={{ padding: 0, overflow: "hidden" }}>
      <button
        type="button"
        onClick={onToggleCollapse}
        style={{
          display: "flex", alignItems: "center", gap: 12, width: "100%", textAlign: "left",
          border: "none", background: "transparent", padding: "10px 12px",
        }}
      >
        {series.isComplete ? (
          <span style={{
            width: 28, height: 28, borderRadius: "50%", background: "var(--correct)", color: "var(--sheet)",
            display: "grid", placeItems: "center", fontSize: 14, fontWeight: 700, flexShrink: 0,
          }}>✓</span>
        ) : (
          <ProgressRing value={series.progress} tint="var(--selection)" size={28} lineWidth={4} />
        )}
        <span style={{ flex: 1, minWidth: 0 }}>
          <span style={{ display: "block", fontWeight: 600 }}>{series.title}</span>
          <span style={{ display: "block", fontSize: 12, color: "var(--ink-secondary)",
            overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {seriesSubtitle(series, spent)}
          </span>
        </span>
        <span className="mono" style={{ fontSize: 13, color: "var(--ink-secondary)", fontWeight: 600 }}>
          {series.doneCount}/{required.length}
        </span>
        <span aria-hidden style={{ color: "var(--ink-tertiary)", fontSize: 11 }}>{collapsed ? "▾" : "▴"}</span>
      </button>

      {!collapsed && (
        <div style={{ borderTop: "1px solid var(--rule)", padding: "8px 12px 12px" }}>
          {links.length > 0 && (
            <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 8 }}>
              {links.map((link) => <LinkChip key={link.url} link={link} />)}
            </div>
          )}

          {series.sortedExercises.length === 0 ? (
            <div style={{ color: "var(--ink-secondary)", fontSize: 13, padding: "8px 2px" }}>
              Exercices pas encore lus
            </div>
          ) : (
            <div>
              {series.sortedExercises.map((exercise) => (
                <div key={exercise.id} style={{ borderTop: "1px solid var(--rule)" }}>
                  <ExerciseRow
                    exercise={exercise}
                    selected={selectedId === exercise.id}
                    showsQuestions={showQuestions(exercise)}
                    onToggleDone={() => onToggleDone(exercise)}
                    onCorrect={(result) => onCorrect(exercise, result)}
                    onToggleQuestions={() => onToggleQuestions(exercise)}
                    onToggleQuestion={(question) => onToggleQuestion(exercise, question)}
                    onSelect={() => onSelect(exercise)}
                  />
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function seriesSubtitle(series: ExerciseSeries, spent: number): string {
  const parts: string[] = [series.plannedWeek > 0 ? `Semaine ${series.plannedWeek}` : "Sans semaine"];
  if (series.exercises.length === 0) parts.push("exercices à importer");
  if (series.dueDate) parts.push(`à rendre le ${DateUtils.shortDay(series.dueDate)}`);
  if (series.bonusExercises.length > 0) parts.push(`${series.bonusExercises.length} bonus`);
  if (spent >= 60) parts.push(DateUtils.hoursLabel(spent));
  return parts.join(" · ");
}

// MARK: - Ligne d'exercice

function ExerciseRow({ exercise, selected, showsQuestions: show, onToggleDone, onCorrect, onToggleQuestions, onToggleQuestion, onSelect }: {
  exercise: Exercise;
  selected: boolean;
  showsQuestions: boolean;
  onToggleDone: () => void;
  onCorrect: (result: Correctness | null) => void;
  onToggleQuestions: () => void;
  onToggleQuestion: (question: SubQuestion) => void;
  onSelect: () => void;
}) {
  const stage = ExerciseStage(exercise);
  const seconds = ExerciseFlow.seconds(exercise);
  const summary = exercise.title !== "" ? exercise.title : exercise.statement;
  const correctionShown = exercise.isDone || exercise.isCorrected;

  return (
    <div style={{ background: selected ? "var(--sheet-raised)" : "transparent", borderRadius: 8, padding: "7px 2px" }}>
      <div style={{ display: "flex", alignItems: "flex-start", gap: 9 }}>
        <button
          type="button"
          onClick={(event) => { event.stopPropagation(); onToggleDone(); }}
          aria-label={exercise.isDone ? `Marquer ${exercise.displayNumber} à faire` : `Marquer ${exercise.displayNumber} fait`}
          aria-pressed={exercise.isDone}
          style={{ border: "none", background: "none", padding: 2, flexShrink: 0 }}
        >
          <StageMark stage={stage} size={24} />
        </button>

        <button
          type="button"
          onClick={onSelect}
          style={{ flex: 1, minWidth: 0, textAlign: "left", border: "none", background: "none", padding: 0 }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 7, flexWrap: "wrap" }}>
            <span className="mono" style={{ fontWeight: 600, fontSize: 13 }}>{exercise.exerciseNumber}</span>
            {exercise.isBonus && <Pill color="var(--ink-secondary)" icon="★">bonus</Pill>}
            {exercise.redoRequired && <Pill color="var(--wrong)" icon="↺">à refaire</Pill>}
            {exercise.confidence && <ConfidenceDot level={exercise.confidence} />}
            {exercise.subQuestionLabel && (
              <span className="mono" style={{ fontSize: 11, color: "var(--ink-secondary)" }}>{exercise.subQuestionLabel}</span>
            )}
            {seconds >= 60 && (
              <span className="mono" style={{ fontSize: 11, color: "var(--ink-tertiary)" }}>{DateUtils.durationLabel(seconds)}</span>
            )}
          </div>
          {summary !== "" && (
            <div style={{
              color: "var(--ink-secondary)", fontSize: 13, marginTop: 2,
              overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
            }}>
              <MathText text={summary} />
            </div>
          )}
        </button>

        {correctionShown && <CorrectionDots value={exercise.correctness} onChange={onCorrect} />}
        <span aria-hidden style={{ color: "var(--ink-tertiary)", fontSize: 11, paddingTop: 2 }}>›</span>
      </div>

      {exercise.hasSubQuestions && (
        <div style={{ marginLeft: 34 }}>
          {show && (
            <div>
              {exercise.sortedSubQuestions.map((question) => (
                <div key={question.id}>
                  <SubQuestionRow question={question} onToggle={() => onToggleQuestion(question)} />
                  {question.sortedChildren.map((child) => (
                    <SubQuestionRow key={child.id} question={child} onToggle={() => onToggleQuestion(child)} />
                  ))}
                </div>
              ))}
            </div>
          )}
          <button
            type="button"
            onClick={(event) => { event.stopPropagation(); onToggleQuestions(); }}
            style={{
              border: "none", background: "none", color: "var(--ink-secondary)", fontSize: 11,
              padding: "3px 0", display: "flex", alignItems: "center", gap: 4,
            }}
          >
            {show ? "▴ Replier" : `▾ ${exercise.subQuestionDoneCount}/${exercise.leafSubQuestions.length} questions`}
          </button>
        </div>
      )}
    </div>
  );
}

function SubQuestionRow({ question, onToggle }: { question: SubQuestion; onToggle: () => void }) {
  const label = subQuestionLabel(question);
  return (
    <button
      type="button"
      onClick={(event) => { event.stopPropagation(); onToggle(); }}
      style={{
        display: "flex", alignItems: "flex-start", gap: 7, width: "100%", textAlign: "left",
        border: "none", background: "transparent", padding: question.parent ? "3px 0 3px 24px" : "4px 0",
      }}
    >
      <span aria-hidden style={{
        color: question.isDone ? "var(--correct)" : "var(--ink-tertiary)",
        fontSize: question.parent ? 12 : 14, lineHeight: 1.3,
      }}>
        {question.isDone ? "●" : "○"}
      </span>
      <span style={{ fontSize: 12, fontWeight: 600, color: "var(--ink-secondary)" }}>{label}</span>
      {question.text !== "" && (
        <span style={{ fontSize: 12, color: question.isDone ? "var(--ink-tertiary)" : "var(--ink-secondary)", flex: 1 }}>
          <MathText text={question.text} />
        </span>
      )}
    </button>
  );
}

/** « 1. », « (a) », « Partie » ; « Question 1 » quand le libellé est seul. */
function subQuestionLabel(question: SubQuestion): string {
  if (question.kind === "part") return "Partie";
  const shown = question.displayLabel;
  if (question.text !== "") return shown;
  const bare = shown.replace(/[.) (]/g, "");
  return /^\d+$/.test(bare) ? `Question ${bare}` : shown;
}

// MARK: - Fiche d'un exercice

function ExerciseDetail({ exercise, onClose, onToggleDone, onCorrect, onToggleQuestion, onConfidence, onToggleRedo }: {
  exercise: Exercise;
  onClose: () => void;
  onToggleDone: () => void;
  onCorrect: (result: Correctness | null) => void;
  onToggleQuestion: (question: SubQuestion) => void;
  onConfidence: (value: ConfidenceLevel | null) => void;
  onToggleRedo: () => void;
}) {
  const links = exerciseLinks(exercise.statementURLString, exercise.series);
  const solutionVisible = exercise.series?.solutionsAt
    ? exercise.series.solutionsAt.getTime() <= Date.now()
    : true;

  return (
    <aside className="card" style={{ position: "sticky", top: 0, padding: 16, maxHeight: "calc(100vh - 80px)", overflowY: "auto" }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
        <span style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.7, fontWeight: 700, color: "var(--ink-secondary)" }}>
          {exercise.displayNumber}{exercise.series ? ` · ${exercise.series.title}` : ""}
        </span>
        <span style={{ flex: 1 }} />
        <button type="button" onClick={onClose} aria-label="Fermer" style={{ border: "none", background: "none", color: "var(--ink-secondary)", fontSize: 16 }}>✕</button>
      </div>
      <h3 className="serif" style={{ margin: "6px 0", fontSize: 19 }}>
        {exercise.title === "" ? exercise.displayNumber : exercise.title}
      </h3>

      {exercise.statement !== "" ? (
        <p className="serif" style={{ margin: "8px 0 12px", whiteSpace: "pre-wrap", lineHeight: 1.55, fontSize: 14 }}>
          <MathText text={exercise.statement} />
        </p>
      ) : (
        <p style={{ color: "var(--ink-secondary)", fontSize: 13, margin: "8px 0 12px" }}>
          Pas d'énoncé lisible ici pour cet exercice.
        </p>
      )}

      {links.length > 0 && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 12 }}>
          {links.map((link) => <LinkChip key={link.url} link={link} />)}
        </div>
      )}

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14 }}>
        <button type="button" onClick={onToggleDone} style={buttonStyle}>
          {exercise.isDone ? "↺ Marquer à faire" : "✓ Marquer comme fait"}
        </button>
        <button type="button" onClick={onToggleRedo} style={buttonStyle}>
          {exercise.redoRequired ? "✓ Retirer de « à refaire »" : "↺ À refaire"}
        </button>
      </div>

      {exercise.hasSubQuestions && (
        <div style={{ marginBottom: 14 }}>
          <div style={labelStyle}>Questions · {exercise.subQuestionLabel ?? ""}</div>
          {exercise.sortedSubQuestions.map((question) => (
            <div key={question.id}>
              <SubQuestionRow question={question} onToggle={() => onToggleQuestion(question)} />
              {question.sortedChildren.map((child) => (
                <SubQuestionRow key={child.id} question={child} onToggle={() => onToggleQuestion(child)} />
              ))}
            </div>
          ))}
        </div>
      )}

      <div style={{ marginBottom: 12 }}>
        <div style={labelStyle}>Correction</div>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <CorrectionDots value={exercise.correctness} onChange={onCorrect} size={24} />
          <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
            {exercise.correctness ? Correctness.label(exercise.correctness) : "Pas encore corrigé"}
          </span>
        </div>
      </div>

      <div style={{ marginBottom: 12 }}>
        <div style={labelStyle}>Sûreté</div>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <ConfidencePicker value={exercise.confidence} onChange={onConfidence} size={24} />
          <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
            {exercise.confidence ? ConfidenceLevel.label(exercise.confidence) : "Non renseignée"}
          </span>
        </div>
      </div>

      {exercise.correctionNote !== null && exercise.correctionNote !== "" && (
        <div style={{ marginBottom: 12 }}>
          <div style={labelStyle}>Remarque</div>
          <p style={{ margin: 0, fontSize: 13, color: "var(--ink-secondary)" }}>{exercise.correctionNote}</p>
        </div>
      )}

      {exercise.hint !== "" && (
        <div style={{ marginBottom: 12 }}>
          <div style={labelStyle}>Indication</div>
          <p style={{ margin: 0, fontSize: 13 }}>{exercise.hint}</p>
        </div>
      )}

      {exercise.solution !== "" && solutionVisible && (
        <details style={{ marginBottom: 12 }}>
          <summary style={{ cursor: "pointer", fontSize: 13, color: "var(--ink-secondary)" }}>Afficher la solution</summary>
          <p style={{ margin: "6px 0 0", fontSize: 13, whiteSpace: "pre-wrap" }}>{exercise.solution}</p>
        </details>
      )}

      <div style={{ display: "flex", alignItems: "baseline", gap: 8, borderTop: "1px solid var(--rule)", paddingTop: 10 }}>
        <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>Temps passé</span>
        <span className="mono" style={{ fontSize: 13 }}>{DateUtils.hoursLabel(ExerciseFlow.seconds(exercise))}</span>
      </div>
      {exercise.series && exercise.series.exercises.length > 0 && (
        <div style={{ fontSize: 11, color: "var(--ink-tertiary)", marginTop: 4 }}>
          {Plural.count(exercise.series.requiredExercises.length,
            `${exercise.series.requiredExercises.length} exercice requis`,
            `${exercise.series.requiredExercises.length} exercices requis`)}
          {exercise.series.topic !== "" ? ` · ${exercise.series.topic}` : ""}
        </div>
      )}
    </aside>
  );
}

// MARK: - Légende

function Legend() {
  const items: { label: string; stage: ReturnType<typeof ExerciseStage> }[] = [
    { label: "à faire", stage: { kind: "toDo" } },
    { label: "fait, à corriger", stage: { kind: "toCorrect" } },
    { label: "à refaire", stage: { kind: "redo" } },
    { label: "juste", stage: { kind: "corrected", correctness: "correct" } },
    { label: "moyen", stage: { kind: "corrected", correctness: "partial" } },
    { label: "faux", stage: { kind: "corrected", correctness: "wrong" } },
  ];
  return (
    <div aria-hidden style={{ display: "flex", flexWrap: "wrap", gap: 14, marginTop: 14, padding: "0 2px" }}>
      {items.map((item) => (
        <span key={item.label} style={{ display: "inline-flex", alignItems: "center", gap: 5, fontSize: 11, color: "var(--ink-secondary)" }}>
          <StageMark stage={item.stage} size={14} />
          {item.label}
        </span>
      ))}
    </div>
  );
}

const buttonStyle = {
  border: "1px solid var(--rule)",
  background: "var(--sheet-raised)",
  color: "var(--ink)",
  borderRadius: 999,
  padding: "5px 11px",
  fontSize: 12,
} as const;

const labelStyle = {
  fontSize: 10,
  textTransform: "uppercase",
  letterSpacing: 0.7,
  color: "var(--ink-tertiary)",
  marginBottom: 6,
} as const;
