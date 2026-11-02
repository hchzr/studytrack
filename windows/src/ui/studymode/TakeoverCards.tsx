// Ce qui prend l'écran un instant : la pause, la pause du cours, et le bilan
// des cinq dernières minutes (StudyWorkspace.takeoverCard). Écarté, un voile
// ne revient pas avant le prochain changement.

import type { Exercise } from "../../models/exercise.ts";
import { ConfidenceLevel } from "../../models/enums.ts";
import { StudyMode } from "../../domain/studyMode.ts";
import { PomodoroEngine, type PomodoroSettings } from "../../domain/pomodoroEngine.ts";
import { elapsed, type FocusTimerState } from "../../domain/focusTimerState.ts";
import { TimerText } from "../../domain/timerText.ts";
import type { DeskTakeover } from "../../domain/deskArrangement.ts";
import { CONFIDENCE_COLOR } from "../kit.tsx";
import { displaySecondsOf } from "../screens/focus/timerView.ts";
import { useEffect } from "react";
import { Glyph, InkButton, PaperButton } from "./parts.tsx";

/** La pause en cours, ce qui reste (TimerClockText sur la pause qui s'écoule). */
function BreakClock({ state, cycle, now }: { state: FocusTimerState; cycle: PomodoroSettings; now: Date }) {
  return (
    <div className="mono" style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 22, color: "var(--ink)" }}>
      <Glyph name="cup.and.saucer" size={20} />
      {TimerText.clock(displaySecondsOf(state, cycle, now))}
    </div>
  );
}

/** Le bilan : la sûreté de l'exercice en cours, un geste avant que ça finisse. */
function ConfidenceRow({ exercise, onConfidence }: {
  exercise: Exercise;
  onConfidence: (level: ConfidenceLevel) => void;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6, alignItems: "center" }}>
      <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>{`${exercise.displayNumber} : sûr·e ?`}</span>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", justifyContent: "center" }}>
        {ConfidenceLevel.allCases.map((level) => {
          const selected = exercise.confidence === level;
          const color = CONFIDENCE_COLOR[level];
          return (
            <button
              key={level}
              type="button"
              className="btn"
              title={ConfidenceLevel.label(level)}
              aria-pressed={selected}
              onClick={() => onConfidence(level)}
              style={{
                borderColor: "transparent", fontWeight: 500,
                background: selected ? color : `color-mix(in srgb, ${color} 14%, transparent)`,
                color: selected ? "var(--ground)" : color,
              }}
            >
              {ConfidenceLevel.label(level)}
            </button>
          );
        })}
      </div>
    </div>
  );
}

/** Le voile : ce qui prend l'écran un moment, et comment on l'écarte. */
export function TakeoverOverlay({ kind, state, cycle, now, exercise, onDismiss, onSkipBreak, onResume, onExtend, onConfidence }: {
  kind: DeskTakeover;
  state: FocusTimerState;
  cycle: PomodoroSettings;
  now: Date;
  /** L'exercice visé par la session (le bilan demande sa sûreté). */
  exercise: Exercise | null;
  onDismiss: () => void;
  onSkipBreak: () => void;
  onResume: () => void;
  onExtend: (minutes: number) => void;
  /** La sûreté posée sur l'exercice visé (enregistrée par l'appelant). */
  onConfidence: (level: ConfidenceLevel) => void;
}) {
  // Échap écarte le voile (le Mac : toucher le fond).
  useEffect(() => {
    if (kind === "none") return;
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") onDismiss(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [kind, onDismiss]);

  if (kind === "none") return null;
  const openEnded = StudyMode.isOpenEnded(state);
  const minutes = Math.max(0, Math.trunc(StudyMode.remaining(state, now) / 60));

  let title = "";
  let detail = "";
  let icon = "";
  switch (kind) {
    case "onBreak":
      title = "Pause";
      detail = "Lève les yeux. Le bloc suivant t'attend.";
      icon = "cup.and.saucer";
      break;
    case "paused":
      title = "En pause";
      detail = "Le temps ne compte plus.";
      icon = "pause.circle";
      break;
    case "classBreak":
      title = "Pause du cours";
      detail = "Le cours reprend dans quelques minutes.";
      icon = "person.wave.2";
      break;
    case "wrapUp":
      title = `Plus que ${minutes} min`;
      detail = "Note où tu t'arrêtes, ou prolonge.";
      icon = "hourglass";
      break;
  }

  const status = state.pomodoro
    ? PomodoroEngine.status(elapsed(state, now), cycle.focusMinutes, state.cycleOrigin ?? 0)
    : null;

  return (
    <div style={{
      position: "absolute", inset: 0, display: "flex", flexDirection: "column",
      justifyContent: kind === "wrapUp" ? "flex-end" : "center", alignItems: "center",
      padding: kind === "wrapUp" ? 24 : 0, zIndex: 40,
    }}>
      {kind !== "wrapUp" && (
        // Le voile se ferme d'un toucher ; le bilan, en bas, ne couvre rien.
        <div aria-hidden onClick={onDismiss} className="takeover-scrim" />
      )}
      <div role="dialog" aria-label={title} className="desk-glass takeover-card" style={{
        position: "relative", display: "flex", flexDirection: "column", gap: 14, alignItems: "center",
        textAlign: "center", padding: 28, borderRadius: 26, maxWidth: 380, width: "100%",
      }}>
        <span aria-hidden style={{ color: "var(--ink-secondary)", display: "grid" }}>
          <Glyph name={icon} size={34} />
        </span>
        <h2 className="serif" style={{ fontSize: 26, margin: 0, color: "var(--ink)" }}>{title}</h2>
        <p style={{ margin: 0, fontSize: 15, color: "var(--ink-secondary)" }}>{detail}</p>
        {kind === "onBreak" && (
          <>
            <BreakClock state={state} cycle={cycle} now={now} />
            {status && (
              <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>
                {`Ensuite : bloc ${status.completedBlocks + 1}`}
              </span>
            )}
          </>
        )}
        {kind === "wrapUp" && exercise && <ConfidenceRow exercise={exercise} onConfidence={onConfidence} />}
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap", justifyContent: "center", marginTop: 4 }}>
          {kind === "onBreak" && (
            <>
              <InkButton onClick={onSkipBreak}>Écourter la pause</InkButton>
              <PaperButton onClick={onDismiss}>Rester ici</PaperButton>
            </>
          )}
          {kind === "paused" && (
            <>
              <InkButton onClick={onResume}>Reprendre</InkButton>
              <PaperButton onClick={onDismiss}>Plus tard</PaperButton>
            </>
          )}
          {kind === "wrapUp" && (
            <>
              {!openEnded && <PaperButton onClick={() => onExtend(25)}>Encore 25 min</PaperButton>}
              <InkButton onClick={onDismiss}>D'accord</InkButton>
            </>
          )}
          {kind === "classBreak" && <InkButton onClick={onDismiss}>D'accord</InkButton>}
        </div>
      </div>
    </div>
  );
}
