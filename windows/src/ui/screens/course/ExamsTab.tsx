// Examens d'un cours (CourseExamsView.swift) : les évaluations qui se
// préparent, puis les annales qui se travaillent. Pas de séances ni de sessions
// ici — elles vivent dans l'Agenda.

import type { Course } from "../../../models/course.ts";
import type { PastExam } from "../../../models/pastExam.ts";
import { PastExamProgress } from "../../../models/pastExam.ts";
import { ExamKind, type ConfidenceLevel } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import {
  ConfidenceDot, ConfidencePicker, Pill, openURL, tintColor, webURL,
} from "./common.tsx";

interface ExamsTabProps {
  course: Course;
  saveAll: (objects: object[]) => Promise<void>;
}

export function ExamsTab({ course, saveAll }: ExamsTabProps) {
  const exams = course.sortedExams;
  const past = course.sortedPastExams;
  const summary = PastExamProgress.summary(past.map((exam) => ({ year: exam.year, worked: exam.isWorked })));
  const priority = PastExamProgress.priority(past.map((exam) => ({ year: exam.year, worked: exam.isWorked })));

  const setConfidence = async (exam: PastExam, value: ConfidenceLevel | null) => {
    exam.confidence = value;
    await saveAll([exam]);
  };

  const toggleWorked = async (exam: PastExam) => {
    exam.workedAt = exam.isWorked ? null : new Date();
    await saveAll([exam]);
  };

  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(330px, 1fr))", gap: 18, alignItems: "start" }}>
      <section className="card">
        <div style={{ display: "flex", alignItems: "baseline", gap: 8, marginBottom: 10 }}>
          <h2 className="serif" style={{ fontSize: 19, margin: 0, flex: 1 }}>Évaluations</h2>
          {exams.length > 0 && <span className="mono" style={{ color: "var(--ink-secondary)", fontSize: 12 }}>{exams.length}</span>}
        </div>
        {exams.length === 0 ? (
          <p style={{ margin: 0, color: "var(--ink-secondary)", fontSize: 13 }}>Aucune évaluation.</p>
        ) : (
          <div>
            {exams.map((exam, index) => (
              <div key={exam.id} style={{ borderTop: index === 0 ? "none" : "1px solid var(--rule)", padding: "9px 0" }}>
                <div style={{ display: "flex", alignItems: "flex-start", gap: 10 }}>
                  <span style={{ flex: 1, minWidth: 0 }}>
                    <span style={{ display: "flex", alignItems: "center", gap: 7, flexWrap: "wrap" }}>
                      <strong style={{ fontSize: 14 }}>{exam.title}</strong>
                      <Pill color={tintColor(ExamKind.color(exam.kind))}>{ExamKind.label(exam.kind)}</Pill>
                    </span>
                    <span style={{ display: "block", color: "var(--ink-secondary)", fontSize: 12, marginTop: 2 }}>
                      {[DateUtils.fullDayLabel(exam.date), exam.location].filter((part) => part !== "").join(" · ")}
                    </span>
                  </span>
                  <span style={{ textAlign: "right", flexShrink: 0 }}>
                    <span className="mono" style={{ display: "block", fontSize: 12, fontWeight: 600,
                      color: exam.isPast ? "var(--ink-secondary)" : tintColor(ExamKind.color(exam.kind)) }}>
                      {DateUtils.countdownLabel(exam.date)}
                    </span>
                    {exam.weightLabel && (
                      <span style={{ display: "block", color: "var(--ink-secondary)", fontSize: 11 }}>{exam.weightLabel}</span>
                    )}
                  </span>
                </div>
              </div>
            ))}
          </div>
        )}
        {course.nextSitting && (
          <p style={{ margin: "12px 0 0", color: "var(--ink-secondary)", fontSize: 11 }}>
            Prochaine épreuve : {course.nextSitting.title} · {DateUtils.fullDayLabel(course.nextSitting.date)}
          </p>
        )}
      </section>

      <section className="card">
        <div style={{ display: "flex", alignItems: "baseline", gap: 8, marginBottom: 10 }}>
          <h2 className="serif" style={{ fontSize: 19, margin: 0, flex: 1 }}>Annales</h2>
          {past.length > 0 && <span style={{ color: "var(--ink-secondary)", fontSize: 12 }}>{summary.label}</span>}
        </div>

        {past.length === 0 ? (
          <p style={{ margin: 0, color: "var(--ink-secondary)", fontSize: 13 }}>Aucun sujet passé.</p>
        ) : (
          <div>
            {priority.length > 0 && (
              <div style={{ color: "var(--review)", fontSize: 11, marginBottom: 6 }}>
                ↗ À travailler en priorité : {priority[0]}
              </div>
            )}
            {past.map((exam, index) => {
              const url = webURL(exam.urlString);
              return (
                <div key={exam.id} style={{ borderTop: index === 0 ? "none" : "1px solid var(--rule)", padding: "9px 0" }}>
                  <div style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
                    <span style={{ color: tintColor(ExamKind.color(exam.kind)), fontSize: 11, width: 18, paddingTop: 2 }}
                      aria-hidden>▣</span>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                        <span style={{ fontSize: 13, fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis",
                          whiteSpace: "nowrap" }}>{exam.title}</span>
                        {exam.confidence && <ConfidenceDot level={exam.confidence} />}
                      </div>
                      <div style={{ color: "var(--ink-secondary)", fontSize: 11, marginTop: 1 }}>{exam.statusLabel}</div>
                    </div>
                    {url && (
                      <button type="button" onClick={() => openURL(url)} aria-label="Ouvrir le sujet"
                        style={{ border: "none", background: "none", color: "var(--ink-secondary)", padding: 2, fontSize: 12 }}>
                        ↗
                      </button>
                    )}
                  </div>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6, flexWrap: "wrap" }}>
                    <button type="button" onClick={() => void toggleWorked(exam)} style={smallButton}>
                      {exam.isWorked ? "↺ Pas encore travaillée" : "✓ Travaillée"}
                    </button>
                    <ConfidencePicker
                      value={exam.confidence}
                      onChange={(value) => void setConfidence(exam, value)}
                      size={16}
                    />
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {past.length > 0 && summary.pendingYears.length > 0 && (
          <p style={{ margin: "12px 0 0", color: "var(--ink-secondary)", fontSize: 11 }}>
            Reste : {summary.pendingYears.join(", ")}.
          </p>
        )}
      </section>
    </div>
  );
}

const smallButton = {
  border: "1px solid var(--rule)",
  background: "var(--sheet-raised)",
  color: "var(--ink)",
  borderRadius: 999,
  padding: "2px 8px",
  fontSize: 11,
} as const;
