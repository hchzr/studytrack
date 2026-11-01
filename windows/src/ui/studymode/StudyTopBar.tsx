// La barre du haut du bureau : la session à gauche (l'anneau, ce qui reste,
// la pause), sur quoi on travaille au milieu, et à droite la sortie — qui ne
// se replie jamais (StudyTopBar). Les outils repliables du Mac (musique, état,
// centre de contrôle) n'ont pas d'équivalent Windows.

import { useEffect, useRef, useState, type ReactNode } from "react";
import type { Course } from "../../models/course.ts";
import { TaskType } from "../../models/enums.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { StudyMode } from "../../domain/studyMode.ts";
import { DeskMoment, type DeskMoment as DeskMomentValue } from "../../domain/deskMoment.ts";
import { TimerText } from "../../domain/timerText.ts";
import { displaySecondsOf } from "../screens/focus/timerView.ts";
import { timerController } from "../timerController.ts";
import type { StudyTimerApi } from "./useStudyTimer.ts";
import { CourseTag, Glyph, HoldButton, SmallRing } from "./parts.tsx";

/** La forme du bureau : le chrono continue, le temps déjà compté reste. */
function MomentMenu({ course, moment, onPick }: {
  course: Course | null;
  moment: DeskMomentValue;
  onPick: (taskType: TaskType) => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [open]);

  const items: { taskType: TaskType; label: string }[] = [
    { taskType: "lecture", label: DeskMoment.title("lecture") },
    { taskType: "exercise", label: DeskMoment.title("series") },
    { taskType: "theory", label: course?.nextSitting != null ? DeskMoment.title("revision") : TaskType.label("theory") },
  ];
  return (
    <div ref={ref} style={{ position: "relative" }}>
      <button
        type="button"
        title="La forme du bureau"
        disabled={course === null}
        onClick={() => setOpen(!open)}
        style={{
          display: "inline-flex", alignItems: "center", gap: 4, borderRadius: 999,
          padding: "3px 9px", border: "none", fontSize: 12, fontWeight: 500, cursor: "pointer",
          background: "var(--sheet-raised)", color: "var(--ink-secondary)",
        }}
      >
        <span aria-hidden style={{ color: "var(--ink-tertiary)" }}>·</span>
        <Glyph name={DeskMoment.icon(moment)} />
        {DeskMoment.title(moment)}
        <span aria-hidden style={{ fontSize: 9, fontWeight: 700 }}>▾</span>
      </button>
      {open && (
        <div style={{
          position: "absolute", top: "100%", left: 0, marginTop: 6, zIndex: 30, minWidth: 190,
          background: "var(--sheet)", border: "1px solid var(--rule)", borderRadius: 12,
          padding: 5, display: "flex", flexDirection: "column", gap: 1,
        }}>
          {items.map((item) => (
            <button
              key={item.taskType}
              type="button"
              onClick={() => { setOpen(false); onPick(item.taskType); }}
              style={{
                border: "none", background: "transparent", color: "var(--ink)", fontSize: 13,
                padding: "7px 9px", textAlign: "left", borderRadius: 8, cursor: "pointer",
              }}
            >
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/** Le menu de sortie : prolonger, le rythme, et les sorties de la session. */
function ExitMenu({ timer }: { timer: StudyTimerApi }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [open]);

  const state = timer.state;
  const openEnded = state !== null && StudyMode.isOpenEnded(state);
  const item = (label: ReactNode, action: () => void, destructive = false) => (
    <button
      type="button"
      onClick={() => { setOpen(false); action(); }}
      style={{
        border: "none", background: "transparent", fontSize: 13, padding: "7px 9px",
        textAlign: "left", borderRadius: 8, cursor: "pointer",
        color: destructive ? "var(--wrong)" : "var(--ink)",
      }}
    >
      {label}
    </button>
  );

  return (
    <div ref={ref} style={{ position: "relative" }}>
      <button
        type="button"
        title="Plus"
        aria-label="Plus"
        onClick={() => setOpen(!open)}
        style={{
          border: "none", background: "transparent", color: "var(--ink-secondary)",
          fontSize: 18, padding: "4px 6px", cursor: "pointer", lineHeight: 1,
        }}
      >
        <Glyph name="ellipsis" />
      </button>
      {open && (
        <div style={{
          position: "absolute", top: "100%", right: 0, marginTop: 6, zIndex: 30, minWidth: 230,
          background: "var(--sheet)", border: "1px solid var(--rule)", borderRadius: 12,
          padding: 5, display: "flex", flexDirection: "column", gap: 1,
        }}>
          {!openEnded && item(<span style={{ display: "inline-flex", gap: 7, alignItems: "center" }}>
            <Glyph name="plus" /> Encore 25 min</span>, () => timerController.extendStudy(25))}
          {state?.groupSession == null && item(
            <span style={{ display: "inline-flex", gap: 7, alignItems: "center" }}>
              <Glyph name="timer" />
              {state?.pomodoro === true ? "Couper le Pomodoro" : "Allumer le Pomodoro"}
            </span>,
            () => timerController.setPomodoro(state?.pomodoro !== true),
          )}
          {/* « Réorganiser les outils » et « Mes cours » n'ont pas d'équivalent
              Windows : pas de colonne d'outils épinglables, une seule fenêtre. */}
          {!timer.isLocked && (
            <>
              <div style={{ height: 1, background: "var(--rule)", margin: "4px 2px" }} />
              {item("Sortir, garder la session", () => timerController.leaveStudy())}
              {item("Abandonner", () => timerController.discard(), true)}
            </>
          )}
        </div>
      )}
    </div>
  );
}

export function StudyTopBar({ course, tint, moment, timer, headline, sideOpen, onToggleSide }: {
  course: Course | null;
  tint: string;
  moment: DeskMomentValue;
  timer: StudyTimerApi;
  headline: string;
  sideOpen: boolean;
  onToggleSide: () => void;
}) {
  const state = timer.state;
  if (!state) return null;
  const paused = timer.phase.type === "paused";
  const onBreak = timer.phase.type === "onBreak";
  const openEnded = StudyMode.isOpenEnded(state);

  const caption = paused
    ? "En pause"
    : openEnded
      ? `depuis ${DateUtils.time(state.studySince ?? timer.now)}`
      : `jusqu'à ${DateUtils.time(state.studyUntil ?? timer.now)}`;

  const buttonIcon = timer.phase.type === "working" ? "pause" : onBreak ? "forward" : "play";
  const buttonTitle = timer.phase.type === "working"
    ? "Mettre la session en pause"
    : onBreak ? "Écourter la pause" : "Reprendre la session";

  return (
    <header style={{
      display: "flex", alignItems: "center", gap: 16, padding: "9px 18px",
      borderBottom: "1px solid var(--rule)", background: "var(--ground)", flexShrink: 0,
    }}>
      {/* La session : l'anneau, ce qui reste (ou depuis quand), et la pause. */}
      <div style={{
        display: "flex", alignItems: "center", gap: 12, padding: "5px 6px 5px 12px",
        borderRadius: 999, background: "var(--sheet-raised)",
        border: `1px solid ${paused ? `color-mix(in srgb, ${tint} 60%, transparent)` : "var(--rule)"}`,
      }}>
        <SmallRing progress={StudyMode.progress(state, timer.now)} tint={tint} />
        <div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
          <span className="mono" style={{
            fontSize: 20, lineHeight: 1.15, fontVariantNumeric: "tabular-nums",
            color: paused ? "var(--ink-secondary)" : "var(--ink)",
          }}>
            {TimerText.clock(StudyMode.clock(state, timer.now))}
          </span>
          <span style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 11, color: paused ? "var(--review)" : "var(--ink-tertiary)" }}>
            {caption}
            {state.pomodoro && (
              <>
                <span aria-hidden>·</span>
                <Glyph name={onBreak ? "cup.and.saucer" : "timer"} />
                <span className="mono">{TimerText.clock(displaySecondsOf(state, timer.cycle, timer.now))}</span>
              </>
            )}
          </span>
        </div>
        <button
          type="button"
          title={buttonTitle}
          aria-label={buttonTitle}
          onClick={() => {
            if (onBreak) timerController.skipBreak();
            else timerController.toggle();
          }}
          style={{
            width: 30, height: 30, borderRadius: "50%", border: "none", padding: 0,
            display: "grid", placeItems: "center", fontSize: 12, cursor: "pointer",
            background: paused ? tint : "var(--ink)", color: "var(--ground)",
          }}
        >
          <Glyph name={buttonIcon} />
        </button>
      </div>

      {/* Le cours et la forme du bureau sur une ligne, la cible dessous. */}
      <div style={{ display: "flex", flexDirection: "column", gap: 2, minWidth: 0, maxWidth: 400, flex: 1 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          {course && <CourseTag code={course.displayCode} tint={tint} />}
          <MomentMenu
            course={course}
            moment={moment}
            onPick={(taskType) => timerController.retarget(timer.courseID, taskType, undefined)}
          />
        </div>
        <span className="serif" style={{
          fontSize: 22, color: "var(--ink)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
        }}>
          {headline}
        </span>
      </div>

      <div style={{ flex: 1 }} />

      {/* La sortie de la session : toujours visible. */}
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <div style={{ width: 1, height: 26, background: "var(--rule)" }} />
        <button
          type="button"
          title={sideOpen ? "Fermer le volet d'à côté" : "Le volet d'à côté : l'énoncé, la fiche, tes liens"}
          aria-label="Le volet d'à côté"
          aria-pressed={sideOpen}
          onClick={onToggleSide}
          style={{
            border: "none", background: sideOpen ? "var(--sheet-raised)" : "transparent",
            color: sideOpen ? tint : "var(--ink-secondary)", fontSize: 15, padding: "5px 8px",
            borderRadius: 9, cursor: "pointer",
          }}
        >
          <Glyph name="sidebar.right" />
        </button>
        {timer.isLocked ? (
          // Sous verrou : une seule sortie, qu'on ne prend pas par réflexe.
          <>
            <span title="Session verrouillée" style={{ color: "var(--ink-tertiary)" }}>
              <Glyph name="lock.fill" />
            </span>
            <HoldButton
              title="Sortie d'urgence"
              glyph="exclamationmark.triangle"
              hold={StudyMode.emergencyHold}
              tint="var(--wrong)"
              onAct={() => { void timerController.finish({ emergency: true }); }}
            />
          </>
        ) : (
          // Sans verrou, un clic suffit (« tenir pour terminer » n'est pas réglé ici).
          <HoldButton
            title="Terminer"
            glyph="checkmark"
            hold={0}
            onAct={() => { void timerController.finish(); }}
          />
        )}
        <ExitMenu timer={timer} />
      </div>
    </header>
  );
}
