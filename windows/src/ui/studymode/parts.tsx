// Les pièces visuelles du mode étude : sur-titres, pastilles de cours, boutons
// encre/papier, le grand cadran, le bouton qu'il faut tenir, la liste des
// sous-questions et les marques rapides — les mêmes formes que
// StudyTrackMac/StudyMode et StudyKit/ExerciseParts, sur le papier de nuit.

import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import type { Course } from "../../models/course.ts";
import type { Exercise, SubQuestion } from "../../models/exercise.ts";
import { Correctness } from "../../models/enums.ts";
import { StudyMode } from "../../domain/studyMode.ts";
import { TimerText } from "../../domain/timerText.ts";
import type { FocusTimerState } from "../../domain/focusTimerState.ts";
import type { PomodoroSettings } from "../../domain/pomodoroEngine.ts";
import { displaySecondsOf, statusLabelOf } from "../screens/focus/timerView.ts";
import { MathText } from "../screens/course/common.tsx";

// MARK: Petites formes

/** Un sur-titre : petites capitales espacées (Kicker). */
export function Kicker({ children, color }: { children: ReactNode; color?: string }) {
  return (
    <div style={{
      fontSize: 11, fontWeight: 600, letterSpacing: 1.1, textTransform: "uppercase",
      color: color ?? "var(--ink-secondary)",
    }}>{children}</div>
  );
}

/** Une pastille de cours : point de couleur, code (CourseTag). */
export function CourseTag({ code, tint }: { code: string; tint: string }) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 5, fontSize: 12, fontWeight: 600, color: tint }}>
      <span aria-hidden style={{ width: 6, height: 6, borderRadius: 3, background: tint }} />
      {code}
    </span>
  );
}

/** Une pastille de cours choisissable (CourseChip) : point, code, sélection teintée. */
export function CourseChip({ title, color, selected, help, onClick }: {
  title: string;
  color: string;
  selected: boolean;
  /** Le nom du cours, en info-bulle. */
  help?: string;
  onClick: () => void;
}) {
  const [hovering, setHovering] = useState(false);
  return (
    <button
      type="button"
      title={help ?? title}
      aria-pressed={selected}
      onClick={onClick}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
      style={{
        display: "inline-flex", alignItems: "center", gap: 5, borderRadius: 999,
        padding: "4px 12px", fontSize: 14, fontWeight: selected ? 600 : 400,
        color: "var(--ink)", border: `1px solid ${selected ? color : "transparent"}`,
        background: selected ? `color-mix(in srgb, ${color} 14%, transparent)`
          : hovering ? "var(--rule)" : "var(--sheet-raised)",
      }}
    >
      <span aria-hidden style={{ width: 7, height: 7, borderRadius: 4, background: color }} />
      {title}
    </button>
  );
}

/** Le bouton encre : le geste principal (InkButtonStyle). */
export function InkButton({ onClick, children, wide, tint }: {
  onClick: () => void;
  children: ReactNode;
  wide?: boolean;
  tint?: string;
}) {
  const [hovering, setHovering] = useState(false);
  return (
    <button
      type="button"
      onClick={onClick}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
      style={{
        border: "none", borderRadius: 999, padding: "9px 18px", fontSize: 14, fontWeight: 600,
        background: tint ?? "var(--ink)", color: "var(--ground)",
        filter: hovering ? "brightness(1.08)" : undefined,
        width: wide ? "100%" : undefined,
      }}
    >
      {children}
    </button>
  );
}

/** Le bouton papier : le geste secondaire (PaperButtonStyle). */
export function PaperButton({ onClick, children, wide }: {
  onClick: () => void;
  children: ReactNode;
  wide?: boolean;
}) {
  const [hovering, setHovering] = useState(false);
  return (
    <button
      type="button"
      onClick={onClick}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
      style={{
        borderRadius: 999, padding: "9px 16px", fontSize: 14,
        border: "1px solid var(--rule)", background: hovering ? "var(--rule)" : "var(--sheet-raised)",
        color: "var(--ink)", width: wide ? "100%" : undefined,
      }}
    >
      {children}
    </button>
  );
}

// MARK: Glyphes

/** Les quelques symboles SF dont l'écran a besoin, en caractères de texte. */
export function Glyph({ name }: { name: string }): ReactNode {
  switch (name) {
    case "play": return "▶";
    case "pause": return "❙❙";
    case "forward": return "⏭";
    case "checkmark": return "✓";
    case "checkmark.seal": return "✓";
    case "checkmark.circle": return "◎";
    case "checkmark.circle.fill": return "✓";
    case "circle": return "○";
    case "plus": return "+";
    case "infinity": return "∞";
    case "ellipsis": return "⋯";
    case "lock.fill": return "🔒";
    case "exclamationmark.triangle": return "⚠";
    case "timer": return "◷";
    case "cup.and.saucer": return "☕";
    case "hourglass": return "⏳";
    case "person.wave.2": return "☺";
    case "pause.circle": return "❙❙";
    case "arrow.right": return "→";
    case "arrow.counterclockwise": return "↺";
    case "sidebar.right": return "▤";
    case "sparkle": return "✦";
    case "doc.text": return "▤";
    case "text.alignleft": return "≡";
    case "list.bullet.rectangle": return "☰";
    case "mappin": return "◉";
    case "person.2": return "❥❥";
    case "checklist": return "☑";
    case "graduationcap": return "◈";
    case "play.rectangle": return "▶";
    case "book.pages": return "▤";
    case "video": return "▶";
    case "text.bubble": return "❝";
    case "globe": return "◉";
    case "sparkles": return "✦";
    case "pencil.and.scribble": return "✎";
    case "pin": return "★";
    case "bookmark": return "⚐";
    case "square.grid.2x2": return "▦";
    default: return "•";
  }
}

// MARK: Le fond

/**
 * Le fond : le papier de nuit, et une lueur de la couleur du cours
 * (StudyBackground). Le fond d'écran flouté du Mac (DeskGround) n'a pas
 * d'équivalent Windows : le papier de nuit seul.
 */
export function StudyBackground({ tint }: { tint: string }) {
  return (
    <div aria-hidden style={{ position: "absolute", inset: 0, overflow: "hidden", pointerEvents: "none" }}>
      <div style={{
        position: "absolute", inset: 0, opacity: 0.14,
        background: `radial-gradient(900px circle at top left, ${tint}, transparent 75%)`,
      }} />
      <div style={{
        position: "absolute", inset: 0, opacity: 0.06,
        background: `radial-gradient(700px circle at bottom right, ${tint}, transparent 75%)`,
      }} />
    </div>
  );
}

// MARK: Le cadran

/** Le grand cadran : ce qui reste du mode étude, le temps de travail dessous (StudyDial). */
export function StudyDial({ state, cycle, now, tint, size }: {
  state: FocusTimerState;
  cycle: PomodoroSettings;
  now: Date;
  tint: string;
  size: number;
}) {
  const radius = size / 2 - 12;
  const circumference = 2 * Math.PI * radius;
  const fraction = Math.max(0.001, Math.min(1, StudyMode.progress(state, now)));
  const onBreak = state.breakEndsAt !== undefined && state.breakEndsAt > now;
  const paused = state.runningSince === undefined && state.breakEndsAt === undefined;
  const status = paused
    ? "En pause"
    : statusLabelOf(state, cycle, now) ?? (StudyMode.isOpenEnded(state) ? "Sans fin" : "Reste");
  return (
    <div style={{ position: "relative", width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ display: "block" }}>
        <circle cx={size / 2} cy={size / 2} r={radius} fill="none" strokeWidth={5}
          style={{ stroke: "var(--rule)" }} />
        {Array.from({ length: 12 }, (_, index) => (
          <line key={index} x1={size / 2} x2={size / 2} y1={4} y2={index % 3 === 0 ? 14 : 10}
            strokeWidth={1.2} strokeLinecap="round"
            style={{ stroke: "var(--ink-tertiary)", strokeOpacity: index % 3 === 0 ? 0.8 : 0.4 }}
            transform={`rotate(${index * 30} ${size / 2} ${size / 2})`} />
        ))}
        <circle cx={size / 2} cy={size / 2} r={radius} fill="none" strokeWidth={5} strokeLinecap="round"
          strokeDasharray={`${circumference * fraction} ${circumference}`}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
          style={{ stroke: tint }} />
      </svg>
      <div style={{
        position: "absolute", inset: 0, display: "flex", flexDirection: "column",
        alignItems: "center", justifyContent: "center", gap: 6, textAlign: "center",
        pointerEvents: "none", padding: size * 0.16,
      }}>
        <div style={{
          fontSize: 11, fontWeight: 600, letterSpacing: 1.1, textTransform: "uppercase",
          color: onBreak ? "var(--correct)" : tint,
        }}>{status}</div>
        <div className="serif" style={{
          fontSize: Math.round(size * 0.24), lineHeight: 1, fontVariantNumeric: "tabular-nums",
          color: "var(--ink)",
        }}>{TimerText.clock(StudyMode.clock(state, now))}</div>
        <div style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 13, color: "var(--ink-secondary)" }}>
          <Glyph name={onBreak ? "cup.and.saucer" : "timer"} />
          <span className="mono">{TimerText.clock(displaySecondsOf(state, cycle, now))}</span>
          {state.pomodoro ? (onBreak ? "de pause" : "du bloc") : "de travail"}
        </div>
      </div>
    </div>
  );
}

/** Un petit anneau de progression, pour la barre du haut (TimerRing sans graduations). */
export function SmallRing({ progress, tint, size = 24 }: { progress: number; tint: string; size?: number }) {
  const radius = size / 2 - 3;
  const circumference = 2 * Math.PI * radius;
  const fraction = Math.max(0.001, Math.min(1, progress));
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden style={{ display: "block" }}>
      <circle cx={size / 2} cy={size / 2} r={radius} fill="none" strokeWidth={3} style={{ stroke: "var(--rule)" }} />
      <circle cx={size / 2} cy={size / 2} r={radius} fill="none" strokeWidth={3} strokeLinecap="round"
        strokeDasharray={`${circumference * fraction} ${circumference}`}
        transform={`rotate(-90 ${size / 2} ${size / 2})`}
        style={{ stroke: tint }} />
    </svg>
  );
}

// MARK: Tenir pour agir

/**
 * Un bouton qu'il faut tenir : le temps d'y penser (HoldButton, le geste
 * `HoldToActButton` de StudyKit). Un clic simple ne fait rien tant qu'on n'a
 * pas tenu ; un appui bref dit quoi faire.
 */
export function HoldButton({ title, glyph, hold, onAct, tint }: {
  title: string;
  glyph: string;
  /** Secondes à tenir ; `0` : un clic suffit. */
  hold: number;
  onAct: () => void;
  tint?: string;
}) {
  const [progress, setProgress] = useState(0);
  const startAt = useRef<number | null>(null);
  const frame = useRef<number | null>(null);

  useEffect(() => () => {
    if (frame.current !== null) cancelAnimationFrame(frame.current);
  }, []);

  const stop = () => {
    if (frame.current !== null) cancelAnimationFrame(frame.current);
    frame.current = null;
    startAt.current = null;
    setProgress(0);
  };

  const begin = () => {
    if (hold <= 0) {
      onAct();
      return;
    }
    startAt.current = performance.now();
    const step = () => {
      const started = startAt.current;
      if (started === null) return;
      const held = (performance.now() - started) / 1000;
      if (held >= hold) {
        stop();
        onAct();
        return;
      }
      setProgress(held / hold);
      frame.current = requestAnimationFrame(step);
    };
    frame.current = requestAnimationFrame(step);
  };

  const pressing = progress > 0;
  return (
    <button
      type="button"
      title={hold > 0 ? `Maintiens ${Math.trunc(hold)} s` : title}
      onMouseDown={begin}
      onMouseUp={stop}
      onMouseLeave={stop}
      onTouchStart={(event) => { event.preventDefault(); begin(); }}
      onTouchEnd={stop}
      style={{
        display: "inline-flex", alignItems: "center", gap: 7, borderRadius: 999,
        padding: "8px 18px", fontSize: 14, fontWeight: 600,
        border: `1px solid ${tint ? `color-mix(in srgb, ${tint} 60%, transparent)` : "var(--rule)"}`,
        background: "var(--sheet-raised)",
        color: "var(--ink)", position: "relative", overflow: "hidden", userSelect: "none",
      }}
    >
      {hold > 0 && progress > 0 && (
        <span aria-hidden style={{
          position: "absolute", inset: 0, width: `${progress * 100}%`,
          background: tint ?? "var(--selection)", opacity: 0.5,
        }} />
      )}
      <span aria-hidden><Glyph name={glyph} /></span>
      <span style={{ position: "relative" }}>{pressing ? "Maintiens…" : title}</span>
    </button>
  );
}

// MARK: L'exercice, en ses pièces

/** Les sous-questions de l'exercice en cours : cocher sans quitter le chrono
 *  (SubQuestionChecklist, sur le papier de nuit). */
export function SubQuestionChecklist({ exercise, tint, onToggle }: {
  exercise: Exercise;
  tint: string;
  onToggle: (question: SubQuestion) => void;
}) {
  const questions = exercise.leafSubQuestions;
  const nextID = questions.find((question) => !question.isDone)?.id;
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
      <div style={{ display: "flex", alignItems: "baseline" }}>
        <Kicker color="var(--ink-secondary)">Questions</Kicker>
        <div style={{ flex: 1 }} />
        <span className="mono" style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
          {questions.filter((question) => question.isDone).length}/{questions.length}
        </span>
      </div>
      {questions.map((question) => (
        <button
          key={question.id}
          type="button"
          onClick={() => onToggle(question)}
          aria-pressed={question.isDone}
          aria-label={`${question.path}${question.text === "" ? "" : ` — ${question.text}`}`}
          style={{
            display: "flex", alignItems: "flex-start", gap: 8, width: "100%", textAlign: "left",
            padding: "4px 6px", borderRadius: 6, border: "none", fontSize: 14,
            background: question.id === nextID ? "var(--sheet)" : "transparent",
            color: "var(--ink)",
          }}
        >
          <span aria-hidden style={{ color: question.isDone ? tint : "var(--ink-tertiary)", lineHeight: 1.4 }}>
            {question.isDone ? "◉" : "○"}
          </span>
          <span className="mono" style={{ fontSize: 13, color: "var(--ink-secondary)" }}>{question.path}</span>
          <span style={{ flex: 1, lineHeight: 1.35, color: question.isDone ? "var(--ink-tertiary)" : "var(--ink)" }}>
            {question.text !== "" && <MathText text={question.text} />}
          </span>
        </button>
      ))}
    </div>
  );
}

/** Fait / juste / moyen / faux, en une rangée (ExerciseQuickMark). */
export function ExerciseQuickMark({ exercise, onToggleDone, onCorrect }: {
  exercise: Exercise;
  onToggleDone: (exercise: Exercise) => void;
  onCorrect: (exercise: Exercise, result: Correctness | null) => void;
}) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
      <button
        type="button"
        onClick={() => onToggleDone(exercise)}
        aria-pressed={exercise.isDone}
        style={{
          display: "inline-flex", alignItems: "center", gap: 6, borderRadius: 999,
          padding: "5px 12px", fontSize: 14, fontWeight: 600, border: "none",
          background: exercise.isDone ? "color-mix(in srgb, var(--correct) 14%, transparent)" : "var(--sheet-raised)",
          color: exercise.isDone ? "var(--correct)" : "var(--ink)",
        }}
      >
        <Glyph name={exercise.isDone ? "checkmark.circle.fill" : "checkmark.circle"} />
        {exercise.isDone ? "Fait" : "Fait ?"}
      </button>
      <div style={{ flex: 1 }} />
      {Correctness.allCases.map((result) => {
        const selected = exercise.correctness === result;
        const color = result === "correct" ? "var(--correct)" : result === "partial" ? "var(--review)" : "var(--wrong)";
        return (
          <button
            key={result}
            type="button"
            title={Correctness.label(result)}
            aria-pressed={selected}
            onClick={() => onCorrect(exercise, selected ? null : result)}
            style={{
              borderRadius: 999, padding: "3px 9px", fontSize: 12, fontWeight: 500,
              border: "none",
              background: selected ? color : `color-mix(in srgb, ${color} 12%, transparent)`,
              color: selected ? "var(--ground)" : color,
            }}
          >
            {Correctness.shortLabel(result)}
          </button>
        );
      })}
    </div>
  );
}

/** Une carte du bureau : du verre sur le papier de nuit (glassCard). */
export function GlassCard({ children, style }: { children: ReactNode; style?: CSSProperties }) {
  return (
    <div style={{
      padding: 16, borderRadius: 20, background: "var(--sheet)", border: "1px solid var(--rule)",
      ...style,
    }}>{children}</div>
  );
}

/** La couleur d'un cours, ou l'encre pour une session libre (MacTargets.tint). */
export function tintOfCourse(course: Course | null): string {
  return course?.colorHex ?? "var(--ink)";
}
