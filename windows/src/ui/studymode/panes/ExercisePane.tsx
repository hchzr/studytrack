// La série, au centre : l'exercice visé en entier — l'énoncé, les questions à
// cocher, la correction d'un toucher, et le suivant (ExercisePane, sans le PDF
// ni Botafogo natifs : le texte importé, et les liens ouverts au-dehors).

import { useMemo, useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { Exercise, ExerciseSeries } from "../../../models/exercise.ts";
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
        border: `1.5px solid ${isCurrent ? tint : "var(--rule)"}`, cursor: "pointer",
        background: isCurrent ? `color-mix(in srgb, ${tint} 22%, transparent)` : "var(--sheet)",
        color: isCurrent ? "var(--ink)" : "var(--ink-secondary)",
      }}
    >
      {number}
      {stage.kind === "inProgress" && <ThinRing fraction={stage.done / Math.max(stage.total, 1)} tint={tint} />}
      {stage.kind === "toCorrect" && <span aria-hidden style={{ color: tint, fontSize: 11 }}>✓</span>}
      {stage.kind === "corrected" && <span aria-hidden style={{ width: 7, height: 7, borderRadius: 4, background: color }} />}
      {stage.kind === "redo" && <span aria-hidden style={{ color: "var(--wrong)", fontSize: 11 }}>↺</span>}
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
        <select
          aria-label="Changer de série"
          value={series.id}
          onChange={(event) => setSeriesID(event.target.value)}
          style={{
            appearance: "none", border: "none", background: "transparent", font: "inherit",
            fontSize: 15, fontWeight: 500, color: "var(--ink)", padding: "4px 22px 4px 0", cursor: "pointer",
          }}
        >
          {allSeries.map((item) => (
            <option key={item.id} value={item.id}>
              {`${seriesName(item)} · ${item.doneCount}/${item.requiredExercises.length} faits`}
            </option>
          ))}
        </select>
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
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 14, cursor: "pointer" }}>
                <input
                  type="checkbox"
                  checked={exercise.redoRequired}
                  onChange={(event) => {
                    exercise.redoRequired = event.target.checked;
                    persist([exercise]);
                  }}
                  style={{ width: 15, height: 15, accentColor: "var(--ink)" }}
                />
                À refaire
              </label>
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
                  <span style={{ display: "inline-flex", gap: 8, alignItems: "center", color: "var(--correct)", fontSize: 18 }}>
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
