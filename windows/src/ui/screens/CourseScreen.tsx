// Un cours, sa théorie, ses séries, sa progression et ses examens.
// Porte Views/Courses/CourseDetailView.swift (Mac : MacCourseView.swift) en
// quatre volets ; les sous-parties vivent dans `./course/`.

import { useState } from "react";
import type { Course } from "../../models/index.ts";
import { useData } from "../../data/dataContext.tsx";
import { ProgressEngine } from "../../domain/progressEngine.ts";
import { PageHeader } from "../kit.tsx";
import { fmtNumber, openURL } from "./course/common.tsx";
import { TheoryTab } from "./course/TheoryTab.tsx";
import { ExercisesTab } from "./course/ExercisesTab.tsx";
import { ProgressTab } from "./course/ProgressTab.tsx";
import { ExamsTab } from "./course/ExamsTab.tsx";

type CourseTab = "theory" | "exercises" | "progress" | "exams";

export function CourseScreen({ course }: { course: Course }) {
  const { save } = useData();
  const [tab, setTab] = useState<CourseTab>("exercises");
  const [week, setWeek] = useState(0);

  const persistAll = async (objects: object[]) => {
    try {
      for (const object of [...new Set(objects)]) await save(object);
    } catch (error) {
      console.error("Enregistrement impossible", error);
    }
  };

  const progress = ProgressEngine.progress(course);
  const late = ProgressEngine.lateCount(course);
  const ahead = ProgressEngine.aheadCount(course);
  const standing = ProgressEngine.standingLabel(late, ahead);
  const meta = metaLine(course);
  const weeks = [...new Set([
    ...course.theoryItems.map((item) => item.plannedWeek),
    ...course.series.map((entry) => entry.plannedWeek),
  ])].filter((value) => value > 0).sort((a, b) => a - b);

  const tabs: { kind: CourseTab; label: string; count: string | null }[] = [
    { kind: "theory", label: "Théorie", count: `${progress.watchedCount}/${progress.videoCount}` },
    { kind: "exercises", label: "Exercices", count: `${progress.doneCount}/${progress.exerciseCount}` },
    { kind: "progress", label: "Progression", count: null },
    { kind: "exams", label: "Examens", count: course.exams.length + course.pastExams.length > 0
      ? String(course.exams.length + course.pastExams.length) : null },
  ];

  const showWeeks = tab === "theory" || tab === "exercises";

  return (
    <>
      <PageHeader
        title={course.name === "" ? course.displayCode : course.name}
        subtitle={`${course.displayCode} · ${meta}`}
        actions={
          <div style={{ textAlign: "right" }}>
            <div className="mono" style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
              {course.currentWeek > 0 ? `Semaine ${course.currentWeek} / ${course.term?.totalWeeks ?? 14}` : "Semestre"}
            </div>
            <div style={{ fontSize: 13, fontWeight: 600, color: late > 0 ? "var(--wrong)" : "var(--ink-secondary)" }}>
              {standing}
            </div>
          </div>
        }
      />

      <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 10, marginTop: -12, marginBottom: 18,
        color: "var(--ink-secondary)", fontSize: 12 }}>
        {course.lecturer !== "" && <span>{course.lecturer}</span>}
        {course.term && <span>· {course.term.displayName}</span>}
        {course.moodleLink && (
          <button
            type="button"
            onClick={() => openURL(course.moodleLink!.href)}
            style={{ border: "1px solid var(--rule)", background: "var(--sheet-raised)", color: "var(--ink)",
              borderRadius: 999, padding: "3px 10px", fontSize: 11 }}
          >
            Page du cours ↗
          </button>
        )}
      </div>

      <div role="tablist" aria-label="Volets du cours" style={{ display: "flex", gap: 4, borderBottom: "1px solid var(--rule)",
        marginBottom: 16 }}>
        {tabs.map((entry) => {
          const active = tab === entry.kind;
          return (
            <button
              key={entry.kind}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => setTab(entry.kind)}
              style={{
                border: "none", borderBottom: active ? "2px solid var(--ink)" : "2px solid transparent",
                background: "transparent", color: active ? "var(--ink)" : "var(--ink-secondary)",
                padding: "8px 12px 7px", fontSize: 13, fontWeight: active ? 600 : 400,
                display: "inline-flex", alignItems: "baseline", gap: 6,
              }}
            >
              {entry.label}
              {entry.count && <span className="mono" style={{ fontSize: 10, color: "var(--ink-tertiary)" }}>{entry.count}</span>}
            </button>
          );
        })}
      </div>

      {showWeeks && weeks.length > 0 && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 5, marginBottom: 18 }}>
          <WeekChip label="Tout le cours" selected={week === 0} onClick={() => setWeek(0)} />
          {weeks.map((value) => (
            <WeekChip
              key={value}
              label={`S${value}`}
              selected={week === value}
              current={course.isTermRunning && value === course.currentWeek}
              onClick={() => setWeek(value)}
            />
          ))}
        </div>
      )}

      {tab === "theory" && <TheoryTab course={course} week={week} saveAll={persistAll} />}
      {tab === "exercises" && <ExercisesTab course={course} week={week} saveAll={persistAll} />}
      {tab === "progress" && <ProgressTab course={course} saveAll={persistAll} />}
      {tab === "exams" && <ExamsTab course={course} saveAll={persistAll} />}
    </>
  );
}

function WeekChip({ label, selected, current, onClick }:
  { label: string; selected: boolean; current?: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={selected}
      style={{
        border: current && !selected ? "1px solid var(--ink-secondary)" : "1px solid var(--rule)",
        background: selected ? "var(--ink)" : "var(--sheet)",
        color: selected ? "var(--ground)" : "var(--ink)",
        borderRadius: 999,
        padding: label === "Tout le cours" ? "4px 12px" : "4px 9px",
        fontSize: 12,
        fontWeight: selected || current ? 600 : 400,
        minWidth: label === "Tout le cours" ? undefined : 34,
      }}
    >
      {label}
    </button>
  );
}

/** « 6 ECTS · 3 h de cours · 2 h d'exercices » (espaces insécables comme le Swift). */
function metaLine(course: Course): string {
  const parts = [`${fmtNumber(course.credits)}\u00A0ECTS`];
  parts.push(course.hasLectures
    ? `${fmtNumber(course.weeklyLectureHours)}\u00A0h de cours · ${fmtNumber(course.weeklyExerciseHours)}\u00A0h d'exercices`
    : `${fmtNumber(course.weeklyExerciseHours)}\u00A0h d'exercices, sans amphi`);
  return parts.join(" · ");
}
