// La série, au centre : l'exercice visé en entier — l'énoncé, les questions à
// cocher, la correction d'un toucher, et le suivant (ExercisePane, sans le PDF
// ni Botafogo natifs : le texte importé, et les liens ouverts au-dehors).

import { useEffect, useMemo, useRef, useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { Exercise, ExerciseSeries } from "../../../models/exercise.ts";
import { ConfidenceLevel } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Checkbox, CONFIDENCE_COLOR, IconButton, Select } from "../../kit.tsx";
import { ExerciseFlow, ExerciseStage } from "../../../domain/exerciseFlow.ts";
import { CORRECTNESS_COLOR, MathText } from "../../screens/course/common.tsx";
import { timerController } from "../../timerController.ts";
import type { StudyTimerApi } from "../useStudyTimer.ts";
import { seriesName, solutionAddress } from "../helpers.ts";
import { openWebURL } from "../openers.ts";
import { ExerciseQuickMark, Glyph, InkButton, Kicker, PaperButton, SubQuestionChecklist } from "../parts.tsx";

/** La série du moment : celle de l'exercice suivi, sinon celle de la semaine. */
function currentSeriesOf(course: Course, targetID: string | undefined): ExerciseSeries | null {
  const current = course.allExercises.find((item) => item.id === targetID)?.series;
  if (current) return current;
  const all = course.sortedSeries.filter((series) => series.exercises.length > 0);
  return all.find((series) => series.plannedWeek >= course.currentWeek && !series.isComplete) ?? all[all.length - 1] ?? null;
}

/** Un exercice en pastille : son numéro, et sa couleur dit où il en est. */
function ExerciseChip({ exercise, isCurrent, tint, onClick }: {
  exercise: Exercise;
  isCurrent: boolean;
  tint: string;
  onClick: () => void;
}) {
  const stage = ExerciseStage(exercise);
  const parts = exercise.exerciseNumber.split(".");
  const number = parts[parts.length - 1] ?? exercise.exerciseNumber;
  const color = stage.kind === "corrected" ? CORRECTNESS_COLOR[stage.correctness]
    : stage.kind === "redo" ? "var(--wrong)"
    : stage.kind === "toCorrect" ? tint
    : "var(--ink-tertiary)";
  return (
    <button
      type="button"
      onClick={onClick}
      title={`${exercise.displayNumber}${exercise.title === "" ? "" : ` — ${exercise.title}`} · ${ExerciseStage.label(stage)}`}
      style={{
        display: "inline-flex", alignItems: "center", gap: 4, height: 28, minWidth: 34, padding: "0 8px",
        borderRadius: 8, fontSize: 14, fontWeight: isCurrent ? 600 : 500, fontVariantNumeric: "tabular-nums",
        border: `1.5px solid ${isCurrent ? tint : "var(--rule)"}`, cursor: "pointer", flexShrink: 0,
        background: isCurrent ? `color-mix(in srgb, ${tint} 22%, transparent)` : "var(--sheet)",
        color: isCurrent ? "var(--ink)" : "var(--ink-secondary)",
      }}
    >
      {number}
      {stage.kind === "inProgress" && <ThinRing fraction={stage.done / Math.max(stage.total, 1)} tint={tint} />}
      {stage.kind === "toCorrect" && <span aria-hidden style={{ color: tint, display: "grid" }}><Glyph name="checkmark" size={11} /></span>}
      {stage.kind === "corrected" && <span aria-hidden style={{ width: 7, height: 7, borderRadius: 4, background: color }} />}
      {stage.kind === "redo" && <span aria-hidden style={{ color: "var(--wrong)", display: "grid" }}><Glyph name="arrow.counterclockwise" size={11} /></span>}
    </button>
  );
}

function ThinRing({ fraction, tint }: { fraction: number; tint: string }) {
  const deg = Math.round(Math.min(1, Math.max(0, fraction)) * 360);
  return (
    <span aria-hidden style={{
      width: 9, height: 9, borderRadius: "50%", display: "inline-block",
      background: `conic-gradient(${tint} ${deg}deg, var(--rule) 0deg)`,
    }} />
  );
}

/** « J'ai fini » : les questions faites, puis la sûreté (demandée, jamais
 *  supposée) — choisir marque l'exercice fait et passe au suivant. Fait, le
 *  bouton le dit, et un clic rouvre le choix (DoneControl). */
function DoneControl({ exercise, tint, next, onSelect, onPersist }: {
  exercise: Exercise;
  tint: string;
  next: Exercise | null;
  onSelect: (exercise: Exercise) => void;
  onPersist: (objects: object[]) => void;
}) {
  const [asking, setAsking] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!asking) return;
    const close = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setAsking(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [asking]);

  // Ctrl+Maj+Entrée : « J'ai fini » (⇧⌘↩ sur le Mac).
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Enter" && event.shiftKey && (event.ctrlKey || event.metaKey)) {
        event.preventDefault();
        setAsking((value) => !value);
      } else if (event.key === "Escape") {
        setAsking(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const finish = (level: ConfidenceLevel | null) => {
    const wasDone = exercise.isDone;
    if (level !== null) exercise.confidence = level;
    if (!wasDone) exercise.setDone(true);
    onPersist([exercise, ...exercise.subQuestions]);
    setAsking(false);
    // Fini : on passe au suivant (pas quand on corrige seulement la sûreté).
    if (!wasDone && next) setTimeout(() => onSelect(next), 250);
  };

  return (
    <div ref={ref} style={{ position: "relative" }}>
      <button
        type="button"
        className="btn btn-sm"
        title={exercise.isDone ? "Fait — modifier" : "J'ai fini cet exercice (Ctrl+Maj+Entrée)"}
        aria-expanded={asking}
        onClick={() => setAsking(!asking)}
        style={exercise.isDone ? {
          background: "color-mix(in srgb, var(--correct) 14%, transparent)", borderColor: "transparent",
          color: "var(--correct)", fontWeight: 600,
        } : { background: "var(--ink)", borderColor: "var(--ink)", color: "var(--ground)", fontWeight: 600 }}
      >
        <Glyph name="checkmark.circle" size={14} />
        {exercise.isDone ? "Fait" : "J'ai fini"}
      </button>
      {asking && (
        <div className="study-popover" role="dialog" aria-label="J'ai fini" style={{
          top: "100%", right: 0, marginTop: 8, width: 420, padding: 18, gap: 14, borderRadius: 16,
          background: "var(--sheet)",
        }}>
          <h3 className="serif" style={{ margin: 0, fontSize: 22, color: "var(--ink)" }}>{exercise.displayNumber}</h3>
          {exercise.hasSubQuestions && (
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              <Kicker>Les questions faites</Kicker>
              <SubQuestionChecklist
                exercise={exercise}
                tint={tint}
                onToggle={(question) => {
                  question.toggle();
                  onPersist([exercise, ...exercise.subQuestions]);
                }}
              />
            </div>
          )}
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <Kicker>Tu es sûr·e de toi ?</Kicker>
            <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
              {ConfidenceLevel.allCases.map((level) => {
                const color = CONFIDENCE_COLOR[level];
                const selected = exercise.confidence === level;
                return (
                  <button
                    key={level}
                    type="button"
                    className="btn"
                    onClick={() => finish(level)}
                    style={{
                      borderColor: "transparent",
                      background: selected ? color : `color-mix(in srgb, ${color} 12%, transparent)`,
                      color: selected ? "var(--ground)" : color,
                    }}
                  >
                    {ConfidenceLevel.label(level)}
                  </button>
                );
              })}
            </div>
          </div>
          <div style={{ display: "flex", alignItems: "center" }}>
            {exercise.isDone ? (
              <PaperButton onClick={() => {
                exercise.setDone(false);
                onPersist([exercise, ...exercise.subQuestions]);
                setAsking(false);
              }}>Marquer à faire</PaperButton>
            ) : (
              <PaperButton onClick={() => finish(null)}>Fait, sans le dire</PaperButton>
            )}
            <div style={{ flex: 1 }} />
            {next && <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>{`ensuite ${next.displayNumber}`}</span>}
          </div>
        </div>
      )}
    </div>
  );
}

export function ExercisePane({ course, timer, save }: {
  course: Course | null;
  timer: StudyTimerApi;
  save: (instance: object) => Promise<void>;
}) {
  const [seriesID, setSeriesID] = useState<string | null>(null);

  const tint = course?.colorHex ?? "var(--ink)";
  const allSeries = useMemo(
    () => course?.sortedSeries.filter((series) => series.exercises.length > 0) ?? [],
    [course],
  );
  const series = (seriesID !== null ? allSeries.find((item) => item.id === seriesID) : undefined)
    ?? (course ? currentSeriesOf(course, timer.targetID) : null)
    ?? null;
  const exercise = series?.exercises.find((item) => item.id === timer.targetID) ?? null;
  const next = exercise && series ? ExerciseFlow.next(exercise, series.sortedExercises) : null;
  const solution = series ? solutionAddress(series, timer.now) : null;

  const persist = (objects: object[]) => {
    void (async () => {
      for (const object of [...new Set(objects)]) await save(object);
    })();
  };

  const select = (target: Exercise) => {
    if (target.series) setSeriesID(target.series.id);
    if (course) timerController.retarget(course.id, "exercise", target.id);
  };

  // Le précédent et le suivant ; sans exercice ouvert, la reprise (ExercisePane.neighbours).
  const ordered = series?.sortedExercises ?? [];
  const index = exercise ? ordered.findIndex((item) => item.id === exercise.id) : -1;
  const neighbours: { previous: Exercise | null; next: Exercise | null } = index < 0
    ? { previous: null, next: ExerciseFlow.resumePoint(ordered) ?? ordered[0] ?? null }
    : { previous: ordered[index - 1] ?? null, next: ordered[index + 1] ?? null };

  // Ctrl+Alt+← / → : l'exercice d'à côté (⌥⌘← / ⌥⌘→ sur le Mac).
  const latest = useRef({ neighbours, select });
  latest.current = { neighbours, select };
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!(event.ctrlKey || event.metaKey) || !event.altKey) return;
      const target = event.key === "ArrowLeft" ? latest.current.neighbours.previous
        : event.key === "ArrowRight" ? latest.current.neighbours.next : null;
      if (target) {
        event.preventDefault();
        latest.current.select(target);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (!course) {
    return (
      <Empty icon="doc.text" title="Pas de série">
        Choisis un cours pour la session.
      </Empty>
    );
  }
  if (!series) {
    return (
      <Empty icon="doc.text" title="Pas de série">
        Rien d'importé pour ce cours.
      </Empty>
    );
  }

  return (
    <div style={{ height: "100%", display: "flex", flexDirection: "column" }}>
      {/* La barre de la série : son nom, ses exercices en pastilles (SeriesBar). */}
      <div style={{
        display: "flex", alignItems: "center", gap: 10, padding: "8px 16px",
        borderBottom: "1px solid var(--rule)", background: "var(--sheet)", flexShrink: 0,
      }}>
        <Select
          ariaLabel="Changer de série"
          value={series.id}
          onChange={(value) => setSeriesID(value)}
          style={{ maxWidth: 260, fontWeight: 500 }}
          options={allSeries.map((item) => ({
            value: item.id,
            label: `${seriesName(item)} · ${item.doneCount}/${item.requiredExercises.length} faits`,
          }))}
        />
        <IconButton
          icon="square.stack.3d.up"
          label="Vue d'ensemble de la série"
          onClick={() => timerController.retarget(course.id, "exercise", undefined)}
          style={exercise === null ? { color: tint } : undefined}
        />
        <div style={{ display: "flex", gap: 4, overflowX: "auto", paddingBottom: 2, flex: 1 }}>
          {series.sortedExercises.map((item) => (
            <ExerciseChip
              key={item.id}
              exercise={item}
              isCurrent={item.id === exercise?.id}
              tint={tint}
              onClick={() => select(item)}
            />
          ))}
        </div>
        <div style={{ display: "flex", gap: 2 }}>
          <IconButton icon="chevron.left" label="Exercice précédent (Ctrl+Alt+←)" disabled={neighbours.previous === null}
            onClick={() => neighbours.previous && select(neighbours.previous)} />
          <IconButton icon="chevron.right" label="Exercice suivant (Ctrl+Alt+→)" disabled={neighbours.next === null}
            onClick={() => neighbours.next && select(neighbours.next)} />
        </div>
        {exercise && <DoneControl key={exercise.id} exercise={exercise} tint={tint} next={neighbours.next}
          onSelect={select} onPersist={persist} />}
        {series.dueDate && (
          <span style={{ fontSize: 12, whiteSpace: "nowrap", color: series.dueDate < timer.now ? "var(--wrong)" : "var(--ink-secondary)" }}>
            {`à rendre ${DateUtils.countdownLabel(series.dueDate)}`}
          </span>
        )}
      </div>

      <div style={{ flex: 1, overflowY: "auto" }}>
        {exercise ? (
          <div style={{ maxWidth: 760, padding: "24px 28px 40px", display: "flex", flexDirection: "column", gap: 18 }}>
            <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
              <Kicker color={tint}>{seriesName(series)}</Kicker>
              <h1 className="serif" style={{ fontSize: 30, margin: 0, color: "var(--ink)" }}>
                {exercise.displayNumber}
              </h1>
              {exercise.title !== "" && exercise.title !== exercise.displayNumber && (
                <div style={{ fontSize: 14, color: "var(--ink-secondary)" }}><MathText text={exercise.title} /></div>
              )}
            </div>

            {exercise.statement !== "" ? (
              <p className="serif" style={{
                margin: 0, fontSize: 16, lineHeight: 1.55, color: "var(--ink)", whiteSpace: "pre-wrap",
              }}>
                <MathText text={exercise.statement} />
              </p>
            ) : (
              <p style={{ margin: 0, fontSize: 14, color: "var(--ink-secondary)" }}>
                Pas d'énoncé lisible ici pour cet exercice.
              </p>
            )}

            {exercise.hint !== "" && (
              <details
                onToggle={(event) => {
                  const open = (event.target as HTMLDetailsElement).open;
                  // Lu avant d'avoir fini : noté comme l'indice du cours.
                  if (open && !exercise.isDone) {
                    exercise.recordHint(1, "Indication du cours lue");
                    persist([exercise]);
                  }
                }}
                style={{ color: "var(--ink-secondary)", fontSize: 14 }}
              >
                <summary style={{ cursor: "pointer" }}>Indication</summary>
                <p style={{ margin: "8px 0 0", color: "var(--ink)", whiteSpace: "pre-wrap" }}>
                  <MathText text={exercise.hint} />
                </p>
              </details>
            )}

            {exercise.hasSubQuestions && (
              <div style={{ padding: 14, borderRadius: 12, background: "var(--sheet-raised)" }}>
                <SubQuestionChecklist
                  exercise={exercise}
                  tint={tint}
                  onToggle={(question) => {
                    // `toggle()` met à jour l'exercice et les questions parentes.
                    question.toggle();
                    persist([exercise, ...exercise.subQuestions]);
                  }}
                />
              </div>
            )}

            <div style={{ display: "flex", flexDirection: "column", gap: 10, paddingTop: 4 }}>
              <Kicker>Où j'en suis</Kicker>
              <ExerciseQuickMark
                exercise={exercise}
                onToggleDone={(target) => {
                  target.setDone(!target.isDone);
                  persist([target, ...target.subQuestions]);
                }}
                onCorrect={(target, result) => {
                  if (result === null) target.clearCorrection();
                  else target.correct(result);
                  persist([target, ...target.subQuestions]);
                }}
              />
              <Checkbox
                checked={exercise.redoRequired}
                label="À refaire"
                onChange={(checked) => {
                  exercise.redoRequired = checked;
                  persist([exercise]);
                }}
              />
            </div>

            <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
              {next && (
                <InkButton onClick={() => select(next)}>
                  <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
                    <Glyph name="arrow.right" /> {next.displayNumber}
                  </span>
                </InkButton>
              )}
              {solution && (
                <PaperButton onClick={() => { void openWebURL(solution); }}>Corrigé</PaperButton>
              )}
            </div>
          </div>
        ) : (
          // Aucun exercice ouvert : la série, et où la reprendre (SeriesOverview).
          <div style={{ maxWidth: 820, padding: "28px 36px 40px", display: "flex", flexDirection: "column", gap: 20 }}>
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              <Kicker color={tint}>{course.displayCode}</Kicker>
              <h1 className="serif" style={{ fontSize: 34, margin: 0, color: "var(--ink)" }}>{seriesName(series)}</h1>
              <span style={{ fontSize: 14, color: "var(--ink-secondary)" }}>
                {`${series.doneCount} sur ${series.requiredExercises.length} faits`}
              </span>
            </div>
            {(() => {
              const resume = ExerciseFlow.resumePoint(series.sortedExercises);
              if (!resume) {
                return (
                  <span className="serif" style={{ display: "inline-flex", gap: 8, alignItems: "center", color: "var(--correct)", fontSize: 22 }}>
                    <Glyph name="checkmark.seal" /> Toute la série est corrigée.
                  </span>
                );
              }
              return (
                <button
                  type="button"
                  onClick={() => select(resume)}
                  style={{
                    display: "flex", alignItems: "center", gap: 12, textAlign: "left",
                    padding: "14px 18px", borderRadius: 14, border: "none", cursor: "pointer",
                    background: tint, color: "var(--ground)",
                  }}
                >
                  <span>
                    <span style={{ display: "block", fontSize: 11, fontWeight: 600, textTransform: "uppercase", letterSpacing: 1, opacity: 0.8 }}>
                      {ExerciseStage(resume).kind === "toDo" && series.doneCount === 0 ? "Commencer" : "Reprendre"}
                    </span>
                    <span className="serif" style={{ fontSize: 22 }}>
                      {resume.displayNumber}{resume.title === "" ? "" : ` — ${resume.title}`}
                    </span>
                  </span>
                  <div style={{ flex: 1 }} />
                  <Glyph name="arrow.right" />
                </button>
              );
            })()}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(190px, 1fr))", gap: 10 }}>
              {series.sortedExercises.map((item) => {
                const stage = ExerciseStage(item);
                const stageColor = stage.kind === "corrected" ? CORRECTNESS_COLOR[stage.correctness]
                  : stage.kind === "redo" ? "var(--wrong)"
                  : stage.kind === "toCorrect" || stage.kind === "inProgress" ? tint
                  : "var(--ink-tertiary)";
                return (
                  <button
                    key={item.id}
                    type="button"
                    onClick={() => select(item)}
                    style={{
                      display: "flex", flexDirection: "column", gap: 8, alignItems: "flex-start",
                      padding: 14, borderRadius: 12, cursor: "pointer",
                      background: "var(--sheet)", border: "1px solid var(--rule)",
                    }}
                  >
                    <span style={{ display: "flex", gap: 8, alignItems: "center", width: "100%" }}>
                      <span className="serif" style={{ fontSize: 18, color: "var(--ink)" }}>{item.displayNumber}</span>
                      {item.isBonus && <span style={{ fontSize: 11, color: "var(--ink-tertiary)" }}>bonus</span>}
                      <div style={{ flex: 1 }} />
                      <span style={{ fontSize: 11, fontWeight: 500, color: stageColor }}>{ExerciseStage.label(stage)}</span>
                    </span>
                    {(item.title !== "" ? item.title : item.statement) !== "" && (
                      <span style={{ fontSize: 12.5, color: "var(--ink-secondary)", overflow: "hidden",
                        display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", textAlign: "left" }}>
                        <MathText text={item.title !== "" ? item.title : item.statement} />
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function Empty({ icon, title, children }: { icon: string; title: string; children: string }) {
  return (
    <div style={{ height: "100%", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 10, textAlign: "center" }}>
      <Glyph name={icon} />
      <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>{title}</span>
      <span style={{ color: "var(--ink-secondary)", fontSize: 14 }}>{children}</span>
    </div>
  );
}
