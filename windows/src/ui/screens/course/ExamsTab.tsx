// Examens d'un cours (CourseExamsView.swift) : les évaluations qui se
// préparent, puis les annales qui se travaillent. Pas de séances ni de sessions
// ici — elles vivent dans l'Agenda.

import type { Course } from "../../../models/course.ts";
import type { PastExam } from "../../../models/pastExam.ts";
import { PastExamProgress } from "../../../models/pastExam.ts";
import type { Exam } from "../../../models/exam.ts";
import { ExamKind, type ConfidenceLevel } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Button, Card, Icon, IconButton, useContextMenu } from "../../kit.tsx";
import {
  ConfidenceDot, ConfidencePicker, Pill, openURL, tintColor, webURL, type CourseActions,
} from "./common.tsx";
import "./course.css";

interface ExamsTabProps {
  course: Course;
  saveAll: (objects: object[]) => Promise<void>;
  actions: CourseActions;
}

export function ExamsTab({ course, saveAll, actions }: ExamsTabProps) {
  const menu = useContextMenu();
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

  const examMenu = (exam: Exam) => menu.open([
    { label: "Modifier…", icon: "pencil", action: () => actions.editExam(exam) },
  ]);

  return (
    <div className="cs-exams">
      <Card flat>
        <div className="cs-panel-head">
          <h2 className="serif">Évaluations</h2>
          {exams.length > 0 && <span className="mono small muted">{exams.length}</span>}
          <Button size="sm" icon="plus" onClick={() => actions.editExam(null)}>Nouvelle</Button>
        </div>
        {exams.length === 0 ? (
          <p className="muted" style={{ margin: 0, fontSize: 13 }}>Aucune évaluation.</p>
        ) : (
          exams.map((exam) => {
            const color = tintColor(ExamKind.color(exam.kind));
            return (
              <div key={exam.id} className="cs-exam-row" onContextMenu={examMenu(exam)}>
                <div className="grow">
                  <div className="title">
                    {exam.title}
                    <Pill color={color}>{ExamKind.label(exam.kind)}</Pill>
                  </div>
                  <div className="when">
                    {[DateUtils.fullDayLabel(exam.date), exam.location].filter((part) => part !== "").join(" · ")}
                  </div>
                </div>
                <div className="right">
                  <div className="count" style={{ color: exam.isPast ? "var(--ink-secondary)" : color }}>
                    {DateUtils.countdownLabel(exam.date)}
                  </div>
                  {exam.weightLabel && <div className="weight">{exam.weightLabel}</div>}
                </div>
                <IconButton icon="pencil" label={`Modifier ${exam.title}`} size="sm" onClick={() => actions.editExam(exam)} />
              </div>
            );
          })
        )}
        {course.nextSitting && (
          <p className="cs-foot-note">
            Prochaine épreuve : {course.nextSitting.title} · {DateUtils.fullDayLabel(course.nextSitting.date)}
          </p>
        )}
      </Card>

      <Card flat>
        <div className="cs-panel-head">
          <h2 className="serif">Annales</h2>
          {past.length > 0 && <span className="muted small">{summary.label}</span>}
        </div>

        {past.length === 0 ? (
          <p className="muted" style={{ margin: 0, fontSize: 13 }}>Aucun sujet passé.</p>
        ) : (
          <>
            {priority.length > 0 && (
              <div className="cs-priority">
                <Icon name="arrow.up.right" size={13} strokeWidth={2.25} />
                À travailler en priorité : {priority[0]}
              </div>
            )}
            {past.map((exam) => {
              const url = webURL(exam.urlString);
              return (
                <div key={exam.id} className="cs-exam-row"
                  onContextMenu={menu.open([{ label: "Modifier…", icon: "pencil", action: () => actions.editPastExam(exam) }])}>
                  <Icon name="doc.text" size={16} className="cs-past-ico" color={tintColor(ExamKind.color(exam.kind))} />
                  <div className="grow">
                    <div className="title" style={{ fontSize: 13 }}>
                      {exam.title}
                      {exam.confidence && <ConfidenceDot level={exam.confidence} />}
                    </div>
                    <div className="when" style={{ fontSize: 11 }}>{exam.statusLabel}</div>
                    <div className="cs-past-actions">
                      <Button size="sm" icon={exam.isWorked ? "arrow.counterclockwise" : "checkmark"}
                        onClick={() => void toggleWorked(exam)}>
                        {exam.isWorked ? "Pas encore travaillée" : "Travaillée"}
                      </Button>
                      <ConfidencePicker value={exam.confidence} onChange={(value) => void setConfidence(exam, value)} size={18} />
                    </div>
                  </div>
                  {url && <IconButton icon="arrow.up.right.square" label="Ouvrir le sujet" size="sm" onClick={() => openURL(url)} />}
                </div>
              );
            })}
          </>
        )}

        {past.length > 0 && summary.pendingYears.length > 0 && (
          <p className="cs-foot-note">Reste : {summary.pendingYears.join(", ")}.</p>
        )}
      </Card>
      {menu.element}
    </div>
  );
}
