// Exercices d'un cours (ExercisesTabView.swift + ExerciseStatementView.swift ;
// Mac : la liste de MacCourseView et son inspecteur).
//
// Tout le suivi se fait dans la liste : cocher un exercice ou ses questions, puis
// le corriger d'un toucher — vert, orange, rouge. La fiche à droite sert à lire
// (énoncé, questions, indication, solution) et à poser la sûreté.

import { useEffect, useRef, useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { Exercise, ExerciseSeries, SubQuestion } from "../../../models/exercise.ts";
import { ConfidenceLevel, Correctness } from "../../../models/enums.ts";
import { ExerciseFlow, ExerciseStage } from "../../../domain/exerciseFlow.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Plural } from "../../../domain/plural.ts";
import { Button, Card, EmptyState, Icon, IconButton, Section, cx, useContextMenu, type MenuItem } from "../../kit.tsx";
import {
  ConfidenceDot, ConfidencePicker, CorrectionDots, LinkChip, MathText,
  Pill, ProgressRing, StageMark, exerciseLinks, openURL, seriesLinks, useTimedTarget,
  type CourseActions,
} from "./common.tsx";
import { SeriesPDFDialog } from "../../pdf/SeriesPDFDialog.tsx";
import { useSeriesPDF } from "../../pdf/useSeriesPDF.ts";
import "./course.css";

interface ExercisesTabProps {
  course: Course;
  week: number;
  saveAll: (objects: object[]) => Promise<void>;
  actions: CourseActions;
}

export function ExercisesTab({ course, week, saveAll, actions, focusID }: ExercisesTabProps & { focusID?: string | null }) {
  const [selectedId, setSelectedId] = useState<string | null>(focusID ?? null);
  const [toggledSeries, setToggledSeries] = useState<Set<string>>(new Set());
  const [toggledQuestions, setToggledQuestions] = useState<Set<string>>(new Set());
  const menu = useContextMenu();
  const timedId = useTimedTarget();
  const root = useRef<HTMLDivElement>(null);

  const series = course.sortedSeries.filter((entry) => week === 0 || entry.plannedWeek === week);
  const selected = selectedId === null
    ? null
    : course.allExercises.find((exercise) => exercise.id === selectedId) ?? null;

  // On arrive sur la semaine en cours, pas sur la série 1.
  // Ou sur l'exercice demandé (palette, lien d'un autre écran : focusTarget du Mac).
  useEffect(() => {
    if (focusID) {
      root.current?.querySelector(`[data-item="${focusID}"]`)?.scrollIntoView({ block: "center" });
      return;
    }
    if (week !== 0 || course.currentWeek <= 0) return;
    const current = course.sortedSeries.find((entry) => entry.plannedWeek >= course.currentWeek && entry.exercises.length > 0);
    if (!current) return;
    root.current?.querySelector(`[data-series="${current.id}"]`)?.scrollIntoView({ block: "start" });
    // Une seule fois, à l'ouverture du volet.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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

  const setNote = async (exercise: Exercise, note: string) => {
    const next = note.trim() === "" ? null : note;
    if (next === exercise.correctionNote) return;
    exercise.correctionNote = next;
    await saveAll([exercise]);
  };

  const flip = (set: typeof toggledSeries, update: typeof setToggledSeries, id: string) => {
    const next = new Set(set);
    if (next.has(id)) next.delete(id); else next.add(id);
    update(next);
  };

  /** Le `.contextMenu` d'une ligne d'exercice du Mac. */
  const exerciseMenu = (exercise: Exercise): MenuItem[] => {
    const statement = exerciseLinks(exercise.statementURLString, exercise.series)[0];
    return [
      { label: exercise.isDone ? "Marquer à faire" : "Marquer comme fait",
        icon: exercise.isDone ? "arrow.counterclockwise" : "checkmark", action: () => void toggleDone(exercise) },
      ...Correctness.allCases.map((result): MenuItem => ({
        label: `Correction : ${Correctness.label(result)}`,
        icon: exercise.correctness === result ? "checkmark.circle" : "circle",
        action: () => void correct(exercise, result),
      })),
      ...(exercise.correctness !== null
        ? [{ label: "Retirer la correction", icon: "xmark.circle", action: () => void correct(exercise, null) } as MenuItem]
        : []),
      { label: exercise.redoRequired ? "Retirer de « à refaire »" : "À refaire", icon: "repeat",
        action: () => void toggleRedo(exercise) },
      "divider",
      { label: "Chronométrer", icon: "timer", action: () => actions.time(exercise.id, "exercise") },
      ...(exercise.series
        ? [{ label: "Modifier la série…", icon: "pencil", action: () => actions.editSeries(exercise.series) } as MenuItem]
        : []),
      ...(statement
        ? [{ label: "Ouvrir l'énoncé", icon: "arrow.up.right.square", action: () => openURL(statement.url) } as MenuItem]
        : []),
    ];
  };

  const seriesMenu = (entry: ExerciseSeries): MenuItem[] => [
    { label: "Modifier la série…", icon: "pencil", action: () => actions.editSeries(entry) },
    { label: "Réimporter un PDF…", icon: "doc.badge.plus", action: () => actions.importPDF() },
    { label: "Nouvelle série…", icon: "plus", action: () => actions.editSeries(null) },
  ];

  if (course.series.length === 0) {
    return (
      <EmptyState icon="doc.text" title="Aucune série"
        action={<Button icon="plus" onClick={() => actions.editSeries(null)}>Nouvelle série</Button>}>
        Ajoute une série à la main, ou importe-la depuis Moodle.
      </EmptyState>
    );
  }

  return (
    <div className={cx("cs-split", selected && "has-aside")} ref={root}>
      <div>
        <Section title={`Séries · ${series.length}`}>
          {series.length === 0 ? (
            <EmptyState icon="doc.text" title="Pas de série">{`Rien en semaine ${week}.`}</EmptyState>
          ) : (
            series.map((entry) => (
              <SeriesCard
                key={entry.id}
                series={entry}
                collapsed={isCollapsed(entry, toggledSeries)}
                onToggleCollapse={() => flip(toggledSeries, setToggledSeries, entry.id)}
                onMenu={(event) => menu.open(seriesMenu(entry))(event)}
                onMenuAt={(x, y) => menu.openAt(x, y, seriesMenu(entry))}
                selectedId={selectedId}
                timedId={timedId}
                showsQuestions={(exercise) => showsQuestions(exercise, toggledQuestions)}
                onToggleQuestions={(exercise) => flip(toggledQuestions, setToggledQuestions, exercise.id)}
                onToggleDone={(exercise) => void toggleDone(exercise)}
                onCorrect={(exercise, result) => void correct(exercise, result)}
                onToggleQuestion={(exercise, question) => void toggleQuestion(exercise, question)}
                onSelect={(exercise) => setSelectedId(exercise.id)}
                onExerciseMenu={(exercise) => menu.open(exerciseMenu(exercise))}
              />
            ))
          )}
        </Section>
        <Legend />
      </div>

      {selected && (
        <ExerciseDetail
          key={selected.id}
          exercise={selected}
          timed={timedId === selected.id}
          onClose={() => setSelectedId(null)}
          onTime={() => actions.time(selected.id, "exercise")}
          onToggleDone={() => void toggleDone(selected)}
          onCorrect={(result) => void correct(selected, result)}
          onToggleQuestion={(question) => void toggleQuestion(selected, question)}
          onConfidence={(value) => void setConfidence(selected, value)}
          onToggleRedo={() => void toggleRedo(selected)}
          onNote={(note) => void setNote(selected, note)}
        />
      )}
      {menu.element}
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

function SeriesCard({ series, collapsed, onToggleCollapse, onMenu, onMenuAt, selectedId, timedId, showsQuestions: showQuestions, onToggleQuestions, onToggleDone, onCorrect, onToggleQuestion, onSelect, onExerciseMenu }: {
  series: ExerciseSeries;
  collapsed: boolean;
  onToggleCollapse: () => void;
  onMenu: (event: React.MouseEvent) => void;
  onMenuAt: (x: number, y: number) => void;
  selectedId: string | null;
  timedId: string | undefined;
  showsQuestions: (exercise: Exercise) => boolean;
  onToggleQuestions: (exercise: Exercise) => void;
  onToggleDone: (exercise: Exercise) => void;
  onCorrect: (exercise: Exercise, result: Correctness | null) => void;
  onToggleQuestion: (exercise: Exercise, question: SubQuestion) => void;
  onSelect: (exercise: Exercise) => void;
  onExerciseMenu: (exercise: Exercise) => (event: React.MouseEvent) => void;
}) {
  const links = seriesLinks(series);
  // Le PDF importé de la série, s'il est sur l'appareil.
  const pdf = useSeriesPDF(series.id);
  const [viewingPDF, setViewingPDF] = useState(false);
  const required = series.requiredExercises;
  const spent = ExerciseFlow.seconds(series);
  const title = series.title === "" ? `Série ${series.seriesNumber}` : series.title;

  return (
    <Card className="cs-series" flat>
      <div className="cs-series-head" data-series={series.id} onContextMenu={onMenu}>
        <button type="button" className="cs-series-main" onClick={onToggleCollapse}
          aria-expanded={!collapsed} aria-label={`${title}, ${collapsed ? "déplier" : "replier"}`}>
          {series.isComplete ? (
            <span className="cs-seal"><Icon name="checkmark" size={16} strokeWidth={3} /></span>
          ) : (
            <ProgressRing value={series.progress} tint="var(--course)" size={28} lineWidth={4} />
          )}
          <span className="cs-series-text">
            <span className="cs-series-title">{title}</span>
            <SeriesSubtitle series={series} spent={spent} />
          </span>
          <span className={cx("cs-count", series.isComplete && "done")}>{series.doneCount}/{required.length}</span>
          <Icon name={collapsed ? "chevron.down" : "chevron.up"} size={14} className="cs-chev" style={{ marginTop: 0 }} />
        </button>
        <IconButton icon="ellipsis" label="Actions de la série" size="sm"
          onClick={(event) => { const r = event.currentTarget.getBoundingClientRect(); onMenuAt(r.right - 190, r.bottom + 4); }} />
      </div>

      {!collapsed && (
        <div className="cs-series-body">
          {(links.length > 0 || pdf !== null) && (
            <div className="cs-links">
              {pdf !== null && (
                <Button size="sm" icon="doc.text" onClick={() => setViewingPDF(true)} title="Lire le PDF importé de la série">
                  Énoncé PDF
                </Button>
              )}
              {links.map((link) => <LinkChip key={link.url} link={link} />)}
            </div>
          )}

          {series.sortedExercises.length === 0 ? (
            <div className="muted" style={{ fontSize: 13, padding: "8px 2px" }}>
              Exercices pas encore lus
            </div>
          ) : (
            series.sortedExercises.map((exercise) => (
              <div key={exercise.id} className="cs-ex">
                <ExerciseRow
                  exercise={exercise}
                  selected={selectedId === exercise.id}
                  timed={timedId === exercise.id}
                  showsQuestions={showQuestions(exercise)}
                  onContextMenu={onExerciseMenu(exercise)}
                  onToggleDone={() => onToggleDone(exercise)}
                  onCorrect={(result) => onCorrect(exercise, result)}
                  onToggleQuestions={() => onToggleQuestions(exercise)}
                  onToggleQuestion={(question) => onToggleQuestion(exercise, question)}
                  onSelect={() => onSelect(exercise)}
                />
              </div>
            ))
          )}
        </div>
      )}
      {viewingPDF && pdf && <SeriesPDFDialog series={series} bytes={pdf} onClose={() => setViewingPDF(false)} />}
    </Card>
  );
}

function SeriesSubtitle({ series, spent }: { series: ExerciseSeries; spent: number }) {
  const overdue = series.dueDate !== null && series.dueDate.getTime() < Date.now() && !series.isComplete;
  const parts: React.ReactNode[] = [series.plannedWeek > 0 ? `Semaine ${series.plannedWeek}` : "Sans semaine"];
  if (series.exercises.length === 0) parts.push("exercices à importer");
  if (series.dueDate) {
    parts.push(<span key="due" className={overdue ? "late" : undefined}>à rendre le {DateUtils.shortDay(series.dueDate)}</span>);
  }
  if (series.bonusExercises.length > 0) parts.push(`${series.bonusExercises.length} bonus`);
  if (spent >= 60) parts.push(DateUtils.hoursLabel(spent));
  return (
    <span className="cs-series-sub">
      {parts.map((part, index) => <span key={index}>{index > 0 ? " · " : ""}{part}</span>)}
    </span>
  );
}

// MARK: - Ligne d'exercice

function ExerciseRow({ exercise, selected, timed, showsQuestions: show, onContextMenu, onToggleDone, onCorrect, onToggleQuestions, onToggleQuestion, onSelect }: {
  exercise: Exercise;
  selected: boolean;
  timed: boolean;
  showsQuestions: boolean;
  onContextMenu: (event: React.MouseEvent) => void;
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
    <div onContextMenu={onContextMenu} data-item={exercise.id}>
      <div className={cx("cs-ex-row", selected && "selected")}>
        <button
          type="button"
          className="cs-hit"
          onClick={(event) => { event.stopPropagation(); onToggleDone(); }}
          title={exercise.isDone ? "Marquer à faire" : "Marquer comme fait"}
          aria-label={exercise.isDone ? `Marquer ${exercise.displayNumber} à faire` : `Marquer ${exercise.displayNumber} fait`}
          aria-pressed={exercise.isDone}
        >
          <StageMark stage={stage} size={24} />
        </button>

        <button type="button" className="cs-pick" onClick={onSelect} aria-current={selected || undefined}>
          <span className="cs-meta">
            <span className="cs-num">{exercise.exerciseNumber}</span>
            {exercise.isBonus && <Pill icon="star">bonus</Pill>}
            {exercise.redoRequired && <Pill color="var(--wrong)" icon="arrow.counterclockwise">à refaire</Pill>}
            {exercise.confidence && <ConfidenceDot level={exercise.confidence} />}
            {exercise.subQuestionLabel && <span className="cs-small">{exercise.subQuestionLabel}</span>}
            {seconds >= 60 && <span className="cs-small faint">{DateUtils.durationLabel(seconds)}</span>}
            {timed && <Icon name="timer" size={13} className="muted" label="Chrono en cours" />}
          </span>
          {summary !== "" && (
            <span className="cs-ellipsis"><MathText text={summary} /></span>
          )}
        </button>

        {correctionShown && <CorrectionDots value={exercise.correctness} onChange={onCorrect} />}
        <Icon name="chevron.right" size={14} className="cs-chev" />
      </div>

      {exercise.hasSubQuestions && (
        <div className="cs-subs">
          {show && exercise.sortedSubQuestions.map((question) => (
            <div key={question.id}>
              <SubQuestionRow question={question} onToggle={() => onToggleQuestion(question)} />
              {question.sortedChildren.map((child) => (
                <SubQuestionRow key={child.id} question={child} onToggle={() => onToggleQuestion(child)} />
              ))}
            </div>
          ))}
          <button type="button" className="cs-fold" aria-expanded={show}
            onClick={(event) => { event.stopPropagation(); onToggleQuestions(); }}>
            <Icon name={show ? "chevron.up" : "chevron.down"} size={12} />
            {show ? "Replier" : `${exercise.subQuestionDoneCount}/${exercise.leafSubQuestions.length} questions`}
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
      className={cx("cs-sub-row", question.isDone && "done", question.parent && "child")}
      aria-pressed={question.isDone}
      onClick={(event) => { event.stopPropagation(); onToggle(); }}
    >
      <Icon name={question.isDone ? "checkmark.circle" : "circle"} size={question.parent ? 13 : 15} className="mark" />
      <b>{label}</b>
      {question.text !== "" && <span className="text"><MathText text={question.text} /></span>}
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

function ExerciseDetail({ exercise, timed, onClose, onTime, onToggleDone, onCorrect, onToggleQuestion, onConfidence, onToggleRedo, onNote }: {
  exercise: Exercise;
  timed: boolean;
  onClose: () => void;
  onTime: () => void;
  onToggleDone: () => void;
  onCorrect: (result: Correctness | null) => void;
  onToggleQuestion: (question: SubQuestion) => void;
  onConfidence: (value: ConfidenceLevel | null) => void;
  onToggleRedo: () => void;
  onNote: (note: string) => void;
}) {
  const links = exerciseLinks(exercise.statementURLString, exercise.series);
  const solutionVisible = exercise.series?.solutionsAt
    ? exercise.series.solutionsAt.getTime() <= Date.now()
    : true;
  const [note, setNote] = useState(exercise.correctionNote ?? "");

  return (
    <Card className="cs-aside" flat>
      <div className="cs-aside-head">
        <span className="cs-kicker">
          {exercise.displayNumber}{exercise.series ? ` · ${exercise.series.title === "" ? `Série ${exercise.series.seriesNumber}` : exercise.series.title}` : ""}
        </span>
        <span className="spacer" />
        <IconButton icon="xmark" label="Fermer" size="sm" onClick={onClose} />
      </div>
      <h3 className="serif">{exercise.title === "" ? exercise.displayNumber : exercise.title}</h3>

      {exercise.statement !== "" ? (
        <p className="serif cs-statement"><MathText text={exercise.statement} /></p>
      ) : (
        <p className="cs-note">Pas d'énoncé lisible ici pour cet exercice.</p>
      )}

      {links.length > 0 && (
        <div className="cs-links" style={{ margin: 0 }}>
          {links.map((link) => <LinkChip key={link.url} link={link} />)}
        </div>
      )}

      <div className="cs-actions">
        <Button size="sm" variant={exercise.isDone ? "default" : "primary"}
          icon={exercise.isDone ? "arrow.counterclockwise" : "checkmark"} onClick={onToggleDone}>
          {exercise.isDone ? "Marquer à faire" : "Marquer comme fait"}
        </Button>
        <Button size="sm" icon="repeat" aria-pressed={exercise.redoRequired} onClick={onToggleRedo}>
          {exercise.redoRequired ? "Retirer de « à refaire »" : "À refaire"}
        </Button>
        <Button size="sm" icon="timer" onClick={onTime} disabled={timed}>
          {timed ? "Chrono en cours" : "Chronométrer"}
        </Button>
      </div>

      {exercise.hasSubQuestions && (
        <div className="cs-block">
          <div className="cs-label">Questions · {exercise.subQuestionLabel ?? ""}</div>
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

      <div className="cs-block">
        <div className="cs-label">Correction</div>
        <div className="hstack">
          <CorrectionDots value={exercise.correctness} onChange={onCorrect} size={24} />
          <span className="muted small">
            {exercise.correctness ? Correctness.label(exercise.correctness) : "Pas encore corrigé"}
          </span>
        </div>
      </div>

      <div className="cs-block">
        <div className="cs-label">Sûreté</div>
        <div className="hstack">
          <ConfidencePicker value={exercise.confidence} onChange={onConfidence} size={24} />
          <span className="muted small">
            {exercise.confidence ? ConfidenceLevel.label(exercise.confidence) : "Non renseignée"}
          </span>
        </div>
      </div>

      <div className="cs-block">
        <label className="cs-label" htmlFor={`note-${exercise.id}`}>Remarque</label>
        <textarea id={`note-${exercise.id}`} className="field" rows={2} value={note} placeholder="Une erreur à retenir…"
          onChange={(event) => setNote(event.target.value)} onBlur={() => onNote(note)} />
      </div>

      {exercise.hint !== "" && (
        <div className="cs-block">
          <div className="cs-label">Indication</div>
          <p className="cs-note" style={{ color: "var(--ink)" }}>{exercise.hint}</p>
        </div>
      )}

      {exercise.solution !== "" && solutionVisible && (
        <details className="cs-details">
          <summary>Afficher la solution</summary>
          <p>{exercise.solution}</p>
        </details>
      )}

      <div className="cs-foot">
        <span>Temps passé</span>
        <span className="mono" style={{ color: "var(--ink)", fontSize: 13 }}>{DateUtils.hoursLabel(ExerciseFlow.seconds(exercise))}</span>
        {exercise.series && exercise.series.exercises.length > 0 && (
          <>
            <span className="spacer" />
            <span className="faint">
              {Plural.count(exercise.series.requiredExercises.length,
                `${exercise.series.requiredExercises.length} exercice requis`,
                `${exercise.series.requiredExercises.length} exercices requis`)}
              {exercise.series.topic !== "" ? ` · ${exercise.series.topic}` : ""}
            </span>
          </>
        )}
      </div>
    </Card>
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
    <div aria-hidden className="cs-legend">
      {items.map((item) => (
        <span key={item.label}>
          <StageMark stage={item.stage} size={14} />
          {item.label}
        </span>
      ))}
    </div>
  );
}
