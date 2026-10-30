// Les petites vues d'« Aujourd'hui » : le prochain geste, une ligne du planning,
// une session, une échéance, et l'anneau de l'objectif du jour.

import type { CSSProperties } from "react";
import { DateUtils } from "../../../domain/dateUtils.ts";
import type { StudySession } from "../../../models/studySession.ts";
import type { Deadline } from "../../../domain/deadline.ts";
import type { NextAction, TodayItem } from "./todayModel.ts";

const kicker: CSSProperties = {
  fontSize: 11,
  textTransform: "uppercase",
  letterSpacing: 0.7,
  color: "var(--ink-tertiary)",
};

/** L'anneau du jour : le septième de l'objectif hebdomadaire (MacTodayView, `TimerRing`). */
export function GoalRing({ seconds, goal }: { seconds: number; goal: number }) {
  const ratio = goal > 0 ? Math.min(1, Math.max(0, seconds / goal)) : 0;
  const tint = seconds >= goal ? "var(--correct)" : "var(--review)";
  return (
    <div
      aria-label={`Objectif du jour : ${DateUtils.hoursLabel(seconds)} sur ${DateUtils.hoursLabel(goal)}`}
      style={{
        width: 52, height: 52, borderRadius: "50%", flexShrink: 0,
        background: `conic-gradient(${tint} ${ratio * 360}deg, var(--rule) 0deg)`,
        display: "grid", placeItems: "center",
      }}
    >
      <div style={{
        width: 42, height: 42, borderRadius: "50%", background: "var(--sheet)",
        display: "grid", placeItems: "center", color: "var(--correct)", fontSize: 18,
      }}>{seconds >= goal && goal > 0 ? "✓" : ""}</div>
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
      <div className="card" style={{ borderLeft: "3px solid var(--correct)" }}>
        <div style={kicker}>Prochain geste</div>
        <div className="serif" style={{ fontSize: 21, marginTop: 6 }}>Tout est à jour</div>
        <div style={{ color: "var(--ink-secondary)", fontSize: 13, marginTop: 4 }}>
          Rien d'urgent aujourd'hui — la semaine est sur les rails.
        </div>
      </div>
    );
  }
  return (
    <div className="card" style={{ borderLeft: `3px solid ${action.color}`, display: "flex", flexDirection: "column", gap: 8 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 10 }}>
        <span style={kicker}>Prochain geste</span>
        {action.badge && (
          <span className="mono" style={{
            fontSize: 11, color: "var(--ink-secondary)", border: "1px solid var(--rule)",
            borderRadius: 999, padding: "2px 8px", whiteSpace: "nowrap",
          }}>{action.badge}</span>
        )}
      </div>
      <div className="serif" style={{ fontSize: 22, lineHeight: 1.2 }}>{action.title}</div>
      {action.subtitle !== "" && (
        <div style={{ color: "var(--ink-secondary)", fontSize: 13 }}>{action.subtitle}</div>
      )}
      {action.courseId && (
        <div style={{ marginTop: 4 }}>
          <button onClick={() => onOpen(action.courseId!)} style={{
            border: "1px solid var(--rule)", background: "var(--sheet-raised)", borderRadius: 10,
            padding: "6px 12px", fontSize: 13, color: "var(--ink)",
          }}>Ouvrir le cours →</button>
        </div>
      )}
    </div>
  );
}

/** Une ligne du planning : l'heure, la couleur, le titre et l'état « en cours »/passé. */
export function PlanRow({ item, now, onOpen }:
  { item: TodayItem; now: Date; onOpen: (id: string) => void }) {
  const end = item.end ?? item.start;
  const isPast = end.getTime() < now.getTime();
  const isOngoing = item.start.getTime() <= now.getTime() && !isPast;
  const body = (
    <>
      <span style={{ width: 46, flexShrink: 0, textAlign: "right", display: "flex", flexDirection: "column", gap: 1 }}>
        <span className="mono" style={{
          fontSize: 12, fontWeight: isOngoing ? 600 : 400,
          color: isPast ? "var(--ink-tertiary)" : "var(--ink)",
        }}>{DateUtils.time(item.start)}</span>
        {item.end && (
          <span className="mono" style={{ fontSize: 10, color: "var(--ink-tertiary)" }}>
            {DateUtils.time(item.end)}
          </span>
        )}
      </span>
      <span style={{
        width: 3, height: 32, borderRadius: 2, flexShrink: 0,
        background: item.color, opacity: isPast ? 0.35 : 1,
      }} />
      <span style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 2 }}>
        <span style={{ display: "flex", alignItems: "center", gap: 6, minWidth: 0 }}>
          <span style={{
            fontSize: 14, fontWeight: isOngoing ? 600 : 400, minWidth: 0,
            textDecoration: isPast ? "line-through" : "none",
            color: isPast ? "var(--ink-tertiary)" : "var(--ink)",
            overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
          }}>{item.title}</span>
          {isOngoing && (
            <span style={{
              fontSize: 10, fontWeight: 600, color: "var(--ground)", background: "var(--ink)",
              borderRadius: 999, padding: "1px 6px", flexShrink: 0,
            }}>en cours</span>
          )}
        </span>
        {item.subtitle !== "" && (
          <span style={{
            fontSize: 12, color: "var(--ink-secondary)", overflow: "hidden",
            textOverflow: "ellipsis", whiteSpace: "nowrap",
          }}>{item.subtitle}</span>
        )}
      </span>
    </>
  );
  const style: CSSProperties = {
    display: "flex", alignItems: "center", gap: 10, width: "100%", textAlign: "left",
    padding: "9px 6px", border: "none", background: "none", color: "inherit",
  };
  return item.courseId
    ? <button onClick={() => onOpen(item.courseId!)} style={style}>{body}</button>
    : <div style={style}>{body}</div>;
}

/** Une session enregistrée : code du cours, cible, heure de début et durée. */
export function SessionRow({ session }: { session: StudySession }) {
  const tint = session.course?.colorHex ?? "var(--ink-tertiary)";
  const duration = session.durationSeconds < 60 ? "< 1 min" : DateUtils.durationLabel(session.durationSeconds);
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 6px" }}>
      <span style={{ width: 8, height: 8, borderRadius: 3, background: tint, flexShrink: 0 }} />
      <span style={{ fontSize: 13, fontWeight: 500, whiteSpace: "nowrap" }}>
        {session.course?.displayCode ?? "Sans cours"}
      </span>
      {session.targetLabel && (
        <span style={{
          fontSize: 12, color: "var(--ink-secondary)", overflow: "hidden",
          textOverflow: "ellipsis", whiteSpace: "nowrap", minWidth: 0,
        }}>{session.targetLabel}</span>
      )}
      <span style={{ flex: 1 }} />
      <span className="mono" style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
        {DateUtils.time(session.startedAt)}
      </span>
      <span className="mono" style={{
        fontSize: 12, minWidth: 56, textAlign: "right",
        color: session.durationSeconds < 60 ? "var(--ink-secondary)" : "var(--ink)",
      }}>{duration}</span>
    </div>
  );
}

/** Une échéance : titre, cours et détail, compte à rebours. */
export function DeadlineRow({ item, onOpen }: { item: Deadline; onOpen: (id: string) => void }) {
  const days = DateUtils.daysBetween(new Date(), item.date);
  const tint = item.kind === "exam" ? "var(--wrong)" : item.colorHex;
  return (
    <button onClick={() => onOpen(item.courseID)} style={{
      display: "flex", alignItems: "center", gap: 10, width: "100%", textAlign: "left",
      padding: "9px 6px", border: "none", background: "none", color: "inherit",
    }}>
      <span style={{ width: 8, height: 8, borderRadius: 3, background: tint, flexShrink: 0 }} />
      <span style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 1 }}>
        <span style={{
          fontSize: 13, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
        }}>{item.title}</span>
        <span style={{
          fontSize: 11, color: "var(--ink-secondary)", overflow: "hidden",
          textOverflow: "ellipsis", whiteSpace: "nowrap",
        }}>{item.courseCode} · {item.detail}</span>
      </span>
      <span style={{
        fontSize: 11, fontWeight: 600, whiteSpace: "nowrap",
        color: item.kind === "exam" && days <= 3 ? "var(--wrong)" : "var(--ink-secondary)",
      }}>{DateUtils.countdownLabel(item.date)}</span>
    </button>
  );
}
