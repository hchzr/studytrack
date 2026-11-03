// Les petites vues d'« Aujourd'hui » : le prochain geste, une ligne du planning,
// une session, une échéance, une tâche et l'anneau de l'objectif du jour.

import { countsEvent, isCheckable, readCounting } from "../../../domain/studyCounting.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import type { StudySession } from "../../../models/studySession.ts";
import type { LinkedTask } from "../../../models/linkedTask.ts";
import { TaskProvider, type TaskType } from "../../../models/enums.ts";
import type { Deadline } from "../../../domain/deadline.ts";
import { Badge, Button, Card, Icon, cx, type IconName } from "../../kit.tsx";
import type { NextAction, TodayItem } from "./todayModel.ts";
import "./today.css";

/** L'icône d'un type de travail (`TaskType.icon` du Swift, en noms lucide). */
export function taskTypeIcon(type: TaskType): IconName {
  switch (type) {
    case "lecture": return "graduationcap";
    case "exercise": return "list.bullet";
    case "theory": return "book";
    case "flashcards": return "square.stack.3d.up";
    case "correction": return "checkmark.circle";
    case "video": return "book";
    default: return "ellipsis";
  }
}

/** L'anneau du jour : le septième de l'objectif hebdomadaire (MacTodayView, `TimerRing`). */
export function GoalRing({ seconds, goal }: { seconds: number; goal: number }) {
  const ratio = goal > 0 ? Math.min(1, Math.max(0, seconds / goal)) : 0;
  const done = goal > 0 && seconds >= goal;
  const tint = done ? "var(--correct)" : "var(--review)";
  return (
    <div className="t-ring" role="img"
      aria-label={`Objectif du jour : ${DateUtils.hoursLabel(seconds)} sur ${DateUtils.hoursLabel(goal)}`}
      title="Objectif du jour"
      style={{ background: `conic-gradient(${tint} ${ratio * 360}deg, var(--rule) 0deg)` }}>
      <div className="t-ring-hole">{done && <Icon name="checkmark" size={18} strokeWidth={2.5} />}</div>
    </div>
  );
}

/**
 * « Prochain geste » : le cours ou la session qui commence, sinon l'échéance la
 * plus proche, sinon le cours qui a du retard. Un seul bouton, l'action utile.
 */
export function NextActionCard({ action, onOpen }:
  { action: NextAction | null; onOpen: (id: string) => void }) {
  if (!action) {
    return (
      <Card accent="var(--correct)" className="t-next">
        <span className="t-kicker">Prochain geste</span>
        <div className="serif t-next-title small">Tout est à jour</div>
        <div className="t-sub" style={{ fontSize: 13 }}>
          Rien d'urgent aujourd'hui — la semaine est sur les rails.
        </div>
      </Card>
    );
  }
  return (
    <Card accent={action.color} className="t-next">
      <div className="t-next-head">
        <span className="t-kicker">Prochain geste</span>
        {action.badge && <Badge>{action.badge}</Badge>}
      </div>
      <div className="serif t-next-title">{action.title}</div>
      {action.subtitle !== "" && <div className="t-sub" style={{ fontSize: 13 }}>{action.subtitle}</div>}
      {action.courseId && (
        <div className="t-next-actions">
          <Button size="sm" trailingIcon="arrow.right" onClick={() => onOpen(action.courseId!)}>Ouvrir le cours</Button>
        </div>
      )}
    </Card>
  );
}

/** Une ligne du planning : l'heure, la couleur, le titre et l'état « en cours »/passé. */
export function PlanRow({ item, now, onOpen, onToggle }:
  { item: TodayItem; now: Date; onOpen: (id: string) => void; onToggle?: (event: NonNullable<TodayItem["event"]>) => void }) {
  const counting = readCounting();
  const checkable = item.event !== undefined && onToggle !== undefined && isCheckable(counting, item.event, now);
  const checked = checkable && countsEvent(counting, item.event!, now);
  const end = item.end ?? item.start;
  const isPast = end.getTime() < now.getTime();
  const isOngoing = item.start.getTime() <= now.getTime() && !isPast;
  const body = (
    <>
      <span className="t-plan-time">
        <span className="mono" style={{
          fontWeight: isOngoing ? 600 : 400, color: isPast ? "var(--ink-tertiary)" : "var(--ink)",
        }}>{DateUtils.time(item.start)}</span>
        {item.end && <span className="mono end">{DateUtils.time(item.end)}</span>}
      </span>
      <span className="t-plan-bar" style={{ background: item.color, opacity: isPast ? 0.35 : 1 }} />
      <span className="t-row-body">
        <span className="hstack" style={{ gap: 6, minWidth: 0 }}>
          <span className={cx("t-plan-title t-ellipsis", isOngoing && "ongoing", isPast && "past")}>{item.title}</span>
          {isOngoing && <span className="t-plan-live">en cours</span>}
        </span>
        {item.subtitle !== "" && <span className="t-sub t-ellipsis">{item.subtitle}</span>}
      </span>
      {checkable && (
        <span role="checkbox" aria-checked={checked} tabIndex={0} title={checked ? "Compté — marquer manqué" : "J'y étais"}
          onClick={(e) => { e.stopPropagation(); onToggle!(item.event!); }}
          onKeyDown={(e) => { if (e.key === " " || e.key === "Enter") { e.preventDefault(); e.stopPropagation(); onToggle!(item.event!); } }}
          style={{ display: "grid", placeItems: "center", width: 22, height: 22, borderRadius: 11, cursor: "pointer", flex: "none",
            border: checked ? "none" : "1.5px solid var(--ink-tertiary)", background: checked ? item.color : "transparent", color: "var(--ground)" }}>
          {checked && <Icon name="checkmark" size={12} />}
        </span>
      )}
      {item.courseId && <Icon name="chevron.right" size={14} className="t-chev" />}
    </>
  );
  return item.courseId
    ? <button type="button" className="t-row" onClick={() => onOpen(item.courseId!)}>{body}</button>
    : <div className="t-row">{body}</div>;
}

/** Une session enregistrée : icône du travail, code du cours, cible, heure et durée. */
export function SessionRow({ session }: { session: StudySession }) {
  const tint = session.course?.colorHex ?? "var(--ink-tertiary)";
  const short = session.durationSeconds < 60;
  return (
    <div className="t-row">
      <span className="t-session-icon" style={{ color: tint }}>
        <Icon name={taskTypeIcon(session.taskType)} size={15} />
      </span>
      <span className="t-session-code">{session.course?.displayCode ?? "Sans cours"}</span>
      {session.targetLabel && <span className="t-sub t-ellipsis">{session.targetLabel}</span>}
      <span style={{ flex: 1 }} />
      <span className="mono t-session-time">{DateUtils.time(session.startedAt)}</span>
      <span className="mono t-session-dur" style={{ color: short ? "var(--ink-secondary)" : "var(--ink)" }}>
        {short ? "< 1 min" : DateUtils.durationLabel(session.durationSeconds)}
      </span>
    </div>
  );
}

/** Une échéance : titre, cours et détail, compte à rebours. */
export function DeadlineRow({ item, onOpen }: { item: Deadline; onOpen: (id: string) => void }) {
  const days = DateUtils.daysBetween(new Date(), item.date);
  const tint = item.kind === "exam" ? "var(--wrong)" : item.colorHex;
  return (
    <button type="button" className="t-row" onClick={() => onOpen(item.courseID)}>
      <span className="t-dot" style={{ background: tint }} />
      <span className="t-row-body">
        <span className="t-ellipsis" style={{ fontSize: 13 }}>{item.title}</span>
        <span className="t-sub-xs t-ellipsis">{item.courseCode} · {item.detail}</span>
      </span>
      <span className={cx("t-count", item.kind === "exam" && days <= 3 && "urgent")}>
        {DateUtils.countdownLabel(item.date)}
      </span>
    </button>
  );
}

/** Une tâche ouverte d'un fournisseur relié (Rappels, Todoist) : elle se coche là-bas. */
export function TaskRow({ task }: { task: LinkedTask }) {
  const parts = [
    task.course?.displayCode ?? null,
    task.dueDate ? DateUtils.countdownLabel(task.dueDate) : null,
    TaskProvider.label(task.provider),
  ].filter((part): part is string => part !== null);
  return (
    <div className="t-row">
      <Icon name="circle" size={16} className="t-chev" />
      <span className="t-row-body">
        <span className="t-ellipsis" style={{ fontSize: 13 }}>{task.title}</span>
        <span className={cx("t-sub-xs t-ellipsis", task.isOverdue && "urgent")}>{parts.join(" · ")}</span>
      </span>
    </div>
  );
}
