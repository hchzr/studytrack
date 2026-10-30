// Progression d'un cours (ProgressTabView.swift).
//
// L'ordre des questions qu'on se pose : **où j'en suis**, **qu'est-ce qui
// traîne** (et le rattraper d'ici), puis le semestre semaine par semaine, et le
// temps passé cette semaine. Le retard est une liste cochable, pas un nombre.

import { useEffect, useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { Exercise } from "../../../models/exercise.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import { TaskType, Correctness } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Plural } from "../../../domain/plural.ts";
import { ExerciseStage } from "../../../domain/exerciseFlow.ts";
import { ProgressEngine, type WeeklyProgress } from "../../../domain/progressEngine.ts";
import { WorkloadEngine } from "../../../domain/workloadEngine.ts";
import {
  Bar, CheckCircle, EmptyState, HOURS_PER_CREDIT, theoryDetail,
} from "./common.tsx";
import {
  changeSummary, isEmptyChange, markWeeks, undoWeeks,
  type WeekChange, type WeekScope,
} from "./weekCompletion.ts";

interface ProgressTabProps {
  course: Course;
  saveAll: (objects: object[]) => Promise<void>;
}

export function ProgressTab({ course, saveAll }: ProgressTabProps) {
  const current = course.isTermRunning ? course.currentWeek : 0;
  const [expanded, setExpanded] = useState<Set<number>>(() => new Set(current > 0 ? [current] : []));
  const [undo, setUndo] = useState<WeekChange | null>(null);

  useEffect(() => {
    if (current <= 0) return;
    setExpanded((previous) => previous.has(current) ? previous : new Set([...previous, current]));
  }, [current]);

  const progress = ProgressEngine.progress(course);
  const weeks = ProgressEngine.semesterWeeks(course);
  const lateTheory = course.sortedTheoryItems
    .filter((item) => item.plannedWeek > 0 && item.plannedWeek < current && !item.isWatched);
  const lateExercises = course.sortedSeries
    .filter((series) => series.plannedWeek > 0 && series.plannedWeek < current)
    .flatMap((series) => series.sortedExercises)
    .filter((exercise) => !exercise.isBonus && !exercise.isDone);
  const lateRows: LateRow[] = [
    ...lateTheory.map((item): LateRow => ({ kind: "theory", item })),
    ...lateExercises.map((exercise): LateRow => ({ kind: "exercise", exercise })),
  ];
  const unplanned = ProgressEngine.unplannedTheory(course).slice(0, 8);

  const toggleTheory = async (item: TheoryItem) => {
    item.watchedAt = item.isWatched ? null : new Date();
    await saveAll([item]);
  };

  const toggleExercise = async (exercise: Exercise) => {
    exercise.setDone(!exercise.isDone);
    await saveAll([exercise, ...exercise.subQuestions]);
  };

  const completeLate = async (scope: WeekScope) => {
    if (current <= 1) return;
    const result = markWeeks([1, current - 1], course, scope);
    await saveAll(result.touched);
    setUndo(isEmptyChange(result.change) ? null : result.change);
  };

  const undoLate = async () => {
    if (!undo) return;
    const touched = undoWeeks(undo, course);
    await saveAll(touched);
    setUndo(null);
  };

  const late = lateTheory.length + lateExercises.length;
  const ahead = ProgressEngine.aheadCount(course);
  const sentence = late > 0
    ? Plural.count(late, "1 élément à rattraper", `${late} éléments à rattraper`)
    : ahead > 0
      ? `À jour, et ${ahead} d'avance`
      : "À jour";

  const toggleWeek = (week: number) => {
    setExpanded((previous) => {
      const next = new Set(previous);
      if (next.has(week)) next.delete(week); else next.add(week);
      return next;
    });
  };

  const weekStart = DateUtils.startOfWeek(new Date());
  const weekly = WorkloadEngine.weeklyDelta(course, HOURS_PER_CREDIT, weekStart, new Date());
  const byType = new Map<TaskType, number>();
  for (const session of course.sessions) {
    if (session.startedAt < weekStart) continue;
    const type = TaskType.canonical(session.taskType);
    byType.set(type, (byType.get(type) ?? 0) + session.durationSeconds);
  }
  const shownWeeks = weeks.filter((week) => week.hasItems || week.week === current);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 26 }}>
      {/* Où tu en es */}
      <div className="card">
        <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.8, fontWeight: 700,
          color: "var(--ink-secondary)", marginBottom: 6 }}>
          {current > 0 ? `Semaine ${current} sur ${course.term?.totalWeeks ?? 14}` : "Semestre"}
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span aria-hidden style={{ color: late > 0 ? "var(--review)" : "var(--correct)", fontSize: 16 }}>
            {late > 0 ? "!" : "✓"}
          </span>
          <span className="serif" style={{ fontSize: 21 }}>{sentence}</span>
        </div>
        {late > 0 && (
          <p style={{ margin: "5px 0 0", color: "var(--ink-secondary)", fontSize: 13 }}>
            Des semaines passées : {lateDetail(lateTheory.length, lateExercises.length)}.
          </p>
        )}

        <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", gap: 14, marginTop: 14 }}>
          <Axis title="Théorie" done={progress.watchedCount} total={progress.videoCount} tint={course.colorHex} />
          <Axis title="Séries" done={progress.doneCount} total={progress.exerciseCount} tint={course.colorHex} />
          <Axis title="Corrigés" done={progress.correctedCount} total={progress.doneCount} tint={course.colorHex} />
        </div>

        {progress.wrongOrRedoCount > 0 && (
          <div style={{ marginTop: 12, color: "var(--wrong)", fontSize: 12, fontWeight: 600 }}>
            ↺ {Plural.count(progress.wrongOrRedoCount,
              `${progress.wrongOrRedoCount} exercice`, `${progress.wrongOrRedoCount} exercices`)} à refaire
          </div>
        )}
      </div>

      {/* À rattraper */}
      {(lateTheory.length > 0 || lateExercises.length > 0) && (
        <section>
          <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 8 }}>
            <h2 style={sectionTitle}>À rattraper</h2>
            <span style={{ flex: 1 }} />
            <span style={{ display: "flex", gap: 4 }}>
              <SmallButton onClick={() => void completeLate("all")}>Tout faire</SmallButton>
              <SmallButton onClick={() => void completeLate("allCorrected")}>Fait + corrigé</SmallButton>
              <SmallButton onClick={() => void completeLate("theoryOnly")}>Théorie</SmallButton>
            </span>
          </div>
          <div className="card" style={{ padding: "4px 14px" }}>
            {lateRows.slice(0, 12).map((row, index) => (
              <div key={row.kind === "theory" ? row.item.id : row.exercise.id}
                style={{ borderTop: index === 0 ? "none" : "1px solid var(--rule)" }}>
                {row.kind === "theory" ? (
                  <LateLine
                    done={row.item.isWatched}
                    week={row.item.plannedWeek}
                    title={row.item.title === "" ? row.item.number : row.item.title}
                    detail={theoryDetail(row.item)}
                    onToggle={() => void toggleTheory(row.item)}
                  />
                ) : (
                  <LateLine
                    done={row.exercise.isDone}
                    week={row.exercise.series?.plannedWeek ?? 0}
                    title={row.exercise.displayNumber + (row.exercise.title === "" ? "" : ` · ${row.exercise.title}`)}
                    detail={row.exercise.series ? `Série ${row.exercise.series.seriesNumber}` : ""}
                    onToggle={() => void toggleExercise(row.exercise)}
                  />
                )}
              </div>
            ))}
            {lateRows.length > 12 && (
              <div style={{ color: "var(--ink-secondary)", fontSize: 12, padding: "10px 0" }}>
                + {lateRows.length - 12} autres
              </div>
            )}
          </div>
          {undo && (
            <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 8, padding: "0 4px" }}>
              <span style={{ color: "var(--ink-secondary)", fontSize: 12 }}>Coché : {changeSummary(undo)}.</span>
              <span style={{ flex: 1 }} />
              <button type="button" onClick={() => void undoLate()} style={{ border: "none", background: "none",
                color: "var(--ink)", fontSize: 12, fontWeight: 600 }}>
                Annuler
              </button>
            </div>
          )}
        </section>
      )}

      {/* Semaine par semaine */}
      <section>
        <h2 style={{ ...sectionTitle, marginBottom: 10 }}>Semaine par semaine</h2>
        {weeks.every((week) => !week.hasItems) ? (
          <EmptyState title="Rien de planifié" message="Importe la théorie et les séries du cours." />
        ) : (
          <div className="card" style={{ padding: "2px 14px" }}>
            {shownWeeks.map((week, index) => (
              <div key={week.week} style={{ borderTop: index === 0 ? "none" : "1px solid var(--rule)" }}>
                <WeekRow
                  week={week}
                  current={current}
                  tint={course.colorHex}
                  isOpen={expanded.has(week.week)}
                  onToggle={() => toggleWeek(week.week)}
                  theory={course.sortedTheoryItems.filter((item) => item.plannedWeek === week.week)}
                  exercises={course.sortedSeries
                    .filter((series) => series.plannedWeek === week.week)
                    .flatMap((series) => series.sortedExercises)}
                  onToggleTheory={(item) => void toggleTheory(item)}
                  onToggleExercise={(exercise) => void toggleExercise(exercise)}
                />
              </div>
            ))}
          </div>
        )}
      </section>

      {/* Sans semaine */}
      {unplanned.length > 0 && (
        <section>
          <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 8 }}>
            <h2 style={sectionTitle}>Sans semaine</h2>
            <span className="mono" style={{ color: "var(--ink-secondary)", fontSize: 12 }}>{ProgressEngine.unplannedTheory(course).length}</span>
          </div>
          <div className="card" style={{ padding: "2px 14px" }}>
            {unplanned.map((item, index) => (
              <div key={item.id} style={{ borderTop: index === 0 ? "none" : "1px solid var(--rule)" }}>
                <LateLine
                  done={item.isWatched}
                  week={0}
                  title={item.title === "" ? item.number : item.title}
                  detail="Ouvre-le pour lui donner une semaine"
                  onToggle={() => void toggleTheory(item)}
                />
              </div>
            ))}
          </div>
        </section>
      )}

      {/* Ton temps cette semaine */}
      <section>
        <h2 style={{ ...sectionTitle, marginBottom: 10 }}>Ton temps cette semaine</h2>
        <div className="card">
          <div style={{ display: "flex", alignItems: "baseline", gap: 8, flexWrap: "wrap" }}>
            <span className="serif" style={{ fontSize: 21 }}>{weekly.actualLabel}</span>
            <span style={{ color: "var(--ink-secondary)", fontSize: 13 }}>sur {weekly.expectedLabel} attendues</span>
          </div>
          <div style={{ marginTop: 10 }}>
            <Bar value={weekly.completion} tint={weekly.isBehind ? "var(--review)" : course.colorHex} height={5} />
          </div>
          {byType.size > 0 && (
            <div style={{ display: "flex", flexWrap: "wrap", gap: 18, marginTop: 12 }}>
              {TaskType.reportCategories.filter((type) => byType.has(type)).map((type) => (
                <div key={type}>
                  <div style={{ color: "var(--ink-secondary)", fontSize: 11 }}>{TaskType.shortLabel(type)}</div>
                  <div className="mono" style={{ fontSize: 13, fontWeight: 600 }}>{DateUtils.durationLabel(byType.get(type) ?? 0)}</div>
                </div>
              ))}
            </div>
          )}
          <p style={{ color: "var(--ink-secondary)", fontSize: 11, margin: "12px 0 0" }}>
            Attendu : {Math.trunc(HOURS_PER_CREDIT)} h par crédit ECTS, amphi compris.
          </p>
        </div>
      </section>
    </div>
  );
}

type LateRow =
  | { kind: "theory"; item: TheoryItem }
  | { kind: "exercise"; exercise: Exercise };

function lateDetail(theory: number, exercises: number): string {
  const parts: string[] = [];
  if (theory > 0) parts.push(`${theory} de théorie`);
  if (exercises > 0) parts.push(Plural.count(exercises, `${exercises} exercice`, `${exercises} exercices`));
  return parts.join(" et ");
}

function Axis({ title, done, total, tint }: { title: string; done: number; total: number; tint: string }) {
  return (
    <div>
      <div style={{ color: "var(--ink-secondary)", fontSize: 11 }}>{title}</div>
      <div style={{ display: "flex", alignItems: "baseline", gap: 2 }}>
        <span className="serif" style={{ fontSize: 19, color: total > 0 && done === total ? "var(--correct)" : "var(--ink)" }}>
          {total === 0 ? "—" : done}
        </span>
        {total > 0 && <span style={{ color: "var(--ink-secondary)", fontSize: 12 }}>/{total}</span>}
      </div>
      <div style={{ marginTop: 4, opacity: total === 0 ? 0.3 : 1 }}>
        <Bar value={total === 0 ? 0 : done / total} tint={tint} />
      </div>
    </div>
  );
}

function LateLine({ done, week, title, detail, onToggle }:
  { done: boolean; week: number; title: string; detail: string; onToggle: () => void }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "7px 0" }}>
      <CheckCircle isOn={done} tint="var(--selection)" label={`Marquer ${title} fait`} onToggle={onToggle} size={20} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, color: done ? "var(--ink-secondary)" : "var(--ink)",
          overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{title}</div>
        <div style={{ fontSize: 11, color: "var(--ink-secondary)", overflow: "hidden",
          textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {week > 0 ? `S${week} · ${detail}` : detail}
        </div>
      </div>
    </div>
  );
}

function WeekRow({ week, current, tint, isOpen, onToggle, theory, exercises, onToggleTheory, onToggleExercise }: {
  week: WeeklyProgress;
  current: number;
  tint: string;
  isOpen: boolean;
  onToggle: () => void;
  theory: TheoryItem[];
  exercises: Exercise[];
  onToggleTheory: (item: TheoryItem) => void;
  onToggleExercise: (exercise: Exercise) => void;
}) {
  const isCurrent = week.week === current;
  const isLate = current > 0 && week.week < current && week.remainingCount > 0;
  const total = week.videoCount + week.exerciseCount;
  const done = week.watchedCount + week.doneCount;

  return (
    <div>
      <button
        type="button"
        onClick={() => { if (week.hasItems) onToggle(); }}
        style={{ display: "flex", alignItems: "center", gap: 12, width: "100%", textAlign: "left",
          border: "none", background: "transparent", padding: "9px 0" }}
      >
        <span className="mono" style={{
          width: 36, height: 36, borderRadius: "50%", display: "grid", placeItems: "center",
          background: isCurrent ? tint : "var(--sheet-raised)",
          color: isCurrent ? "var(--sheet)" : "var(--ink)", fontSize: 12, fontWeight: 700, flexShrink: 0,
        }}>S{week.week}</span>
        <span style={{ flex: 1, minWidth: 0 }}>
          <span style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
            <span style={{ fontSize: 13, flex: 1 }}>{weekSummary(week)}</span>
            {week.isComplete ? (
              <span style={{ color: "var(--correct)", fontSize: 11, fontWeight: 700 }}>✓</span>
            ) : isLate ? (
              <span style={{ color: "var(--review)", fontSize: 11, fontWeight: 600 }}>
                {Plural.count(week.remainingCount, `${week.remainingCount} restant`, `${week.remainingCount} restants`)}
              </span>
            ) : isCurrent ? (
              <span style={{ color: "var(--ink-secondary)", fontSize: 11, fontWeight: 600 }}>en cours</span>
            ) : null}
          </span>
          <span style={{ display: "block", marginTop: 5, opacity: total === 0 ? 0.3 : 1 }}>
            <Bar value={total === 0 ? 0 : done / total} tint={week.isComplete ? "var(--correct)" : tint} />
          </span>
        </span>
        <span aria-hidden style={{ color: "var(--ink-tertiary)", fontSize: 10, transform: isOpen ? "rotate(90deg)" : "none" }}>
          ▸
        </span>
      </button>

      {isOpen && (
        <div style={{ padding: "0 0 8px 48px" }}>
          {theory.map((item) => (
            <LateLine
              key={item.id}
              done={item.isWatched}
              week={0}
              title={item.title === "" ? item.number : item.title}
              detail={theoryDetail(item)}
              onToggle={() => onToggleTheory(item)}
            />
          ))}
          {exercises.map((exercise) => (
            <LateLine
              key={exercise.id}
              done={exercise.isDone}
              week={0}
              title={exercise.displayNumber + (exercise.isBonus ? " (bonus)" : "")}
              detail={exercise.isCorrected
                ? (exercise.correctness ? Correctness.shortLabel(exercise.correctness) : "corrigé")
                : ExerciseStage.label(ExerciseStage(exercise))}
              onToggle={() => onToggleExercise(exercise)}
            />
          ))}
        </div>
      )}
    </div>
  );
}

/** « Théorie 1/1 · Série 4 : 3/5 ». */
function weekSummary(week: WeeklyProgress): string {
  if (!week.hasItems) return "Rien de prévu";
  const parts: string[] = [];
  if (week.videoCount > 0) parts.push(`Théorie ${week.watchedCount}/${week.videoCount}`);
  if (week.exerciseCount > 0) {
    const name = week.seriesNumbers.length === 0 ? "Séries" : `Série ${week.seriesNumbers.join(", ")}`;
    parts.push(`${name} : ${week.doneCount}/${week.exerciseCount}`);
  }
  return parts.join(" · ");
}

const sectionTitle = {
  fontSize: 13,
  textTransform: "uppercase",
  letterSpacing: 0.6,
  color: "var(--ink-tertiary)",
  margin: 0,
} as const;

function SmallButton({ children, onClick }: { children: string; onClick: () => void }) {
  return (
    <button type="button" onClick={onClick} style={{
      border: "1px solid var(--rule)", background: "var(--sheet-raised)", color: "var(--ink)",
      borderRadius: 999, padding: "3px 9px", fontSize: 11,
    }}>
      {children}
    </button>
  );
}
