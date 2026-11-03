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
import { Button, Chip, Icon, type IconName, type MenuItem } from "../kit.tsx";
import "./studymode.css";

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

/** Une pastille de cours choisissable (CourseChip) : point de couleur, code. */
export function CourseChip({ title, color, selected, help, onClick }: {
  title: string;
  color: string;
  selected: boolean;
  /** Le nom du cours, en info-bulle. */
  help?: string;
  onClick: () => void;
}) {
  return (
    <span title={help ?? title} style={{ display: "inline-flex" }}>
      <Chip selected={selected} dot={color} onClick={onClick}>{title}</Chip>
    </span>
  );
}

/** Le bouton encre : le geste principal (InkButtonStyle). */
export function InkButton({ onClick, children, wide, tint, large }: {
  onClick: () => void;
  children: ReactNode;
  wide?: boolean;
  tint?: string;
  large?: boolean;
}) {
  return (
    <Button
      variant="primary"
      size={large ? "lg" : "md"}
      onClick={onClick}
      style={{
        width: wide ? "100%" : undefined,
        ...(tint ? { background: tint, borderColor: tint, color: "var(--ground)" } : { color: "var(--ground)" }),
      }}
    >
      {children}
    </Button>
  );
}

/** Le bouton papier : le geste secondaire (PaperButtonStyle). */
export function PaperButton({ onClick, children, wide, large }: {
  onClick: () => void;
  children: ReactNode;
  wide?: boolean;
  large?: boolean;
}) {
  return (
    <Button size={large ? "lg" : "md"} onClick={onClick} style={{ width: wide ? "100%" : undefined, background: "var(--sheet-raised)" }}>
      {children}
    </Button>
  );
}

// MARK: Icônes

/** Les symboles SF de l'écran, ramenés aux icônes du kit (le plus proche quand
 *  le nom exact n'existe pas : `infinity`, `lock.fill`, `mappin`… ). */
const SF_TO_ICON: Record<string, IconName> = {
  "play": "play.fill", "pause": "pause.fill", "forward": "forward.end.fill",
  "checkmark.seal": "checkmark.circle", "checkmark.circle.fill": "checkmark.circle",
  "infinity": "repeat", "lock.fill": "lock", "pause.circle": "pause.fill",
  "person.wave.2": "person.2", "text.alignleft": "note.text", "list.bullet.rectangle": "list.bullet",
  "mappin": "map", "checklist": "checkmark.square", "play.rectangle": "play.fill", "video": "play.fill",
  "book.pages": "book", "text.bubble": "quote.opening", "globe": "link", "pencil.and.scribble": "pencil",
  "pin": "bookmark", "square.grid.2x2": "square.stack.3d.up",
};

/** Une icône à partir du nom SF que le Swift emploie. */
export function Glyph({ name, size = 15 }: { name: string; size?: number }): ReactNode {
  const mapped = SF_TO_ICON[name] ?? name;
  return <Icon name={mapped as IconName} size={size} />;
}

// MARK: Menus

/**
 * Un menu déroulant sous son bouton (le `Menu` de SwiftUI), dans le papier de
 * nuit : le menu du kit passe par un portail hors de la racine sombre, et
 * lirait donc les couleurs claires de l'app. Se ferme au clic dehors, à Échap ;
 * flèches haut/bas.
 */
export function DropMenu({ trigger, items, align = "left" }: {
  trigger: (props: { open: boolean; toggle: () => void }) => ReactNode;
  items: MenuItem[];
  align?: "left" | "right";
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    ref.current?.querySelector<HTMLButtonElement>(".study-menu button:not(:disabled)")?.focus();
    const down = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    };
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") { setOpen(false); return; }
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
      event.preventDefault();
      const buttons = [...(ref.current?.querySelectorAll<HTMLButtonElement>(".study-menu button:not(:disabled)") ?? [])];
      const at = buttons.indexOf(document.activeElement as HTMLButtonElement);
      const next = event.key === "ArrowDown" ? (at + 1) % buttons.length : (at - 1 + buttons.length) % buttons.length;
      buttons[next]?.focus();
    };
    document.addEventListener("mousedown", down);
    window.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("mousedown", down);
      window.removeEventListener("keydown", key);
    };
  }, [open]);

  return (
    <div ref={ref} style={{ position: "relative" }}>
      {trigger({ open, toggle: () => setOpen((value) => !value) })}
      {open && (
        <div className="study-menu" role="menu" style={{ top: "100%", marginTop: 6, [align]: 0 }}>
          {items.map((item, index) => item === "divider"
            ? <hr key={index} />
            : (
              <button key={index} type="button" role="menuitem" disabled={item.disabled}
                className={item.danger ? "danger" : undefined}
                onClick={() => { setOpen(false); item.action(); }}>
                {item.icon && <Icon name={item.icon} size={14} />}
                {item.label}
              </button>
            ))}
        </div>
      )}
    </div>
  );
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
        position: "absolute", inset: 0, opacity: 0.22,
        background: `radial-gradient(1000px circle at 8% 0%, ${tint}, transparent 72%)`,
      }} />
      <div style={{
        position: "absolute", inset: 0, opacity: 0.1,
        background: `radial-gradient(800px circle at 100% 100%, ${tint}, transparent 72%)`,
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
export function HoldButton({ title, glyph, hold, onAct, tint, help }: {
  title: string;
  /** L'infobulle ; par défaut « Maintiens N s » (ou le titre sans maintien). */
  help?: string;
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
      className="btn hold-btn"
      title={help ?? (hold > 0 ? `Maintiens ${Math.trunc(hold)} s` : title)}
      onMouseDown={begin}
      onMouseUp={stop}
      onMouseLeave={stop}
      onBlur={stop}
      onKeyDown={(event) => {
        if ((event.key === "Enter" || event.key === " ") && !event.repeat) {
          event.preventDefault();
          begin();
        }
      }}
      onKeyUp={stop}
      onTouchStart={(event) => { event.preventDefault(); begin(); }}
      onTouchEnd={stop}
      style={{
        background: "var(--sheet-raised)",
        borderColor: tint ? `color-mix(in srgb, ${tint} 60%, transparent)` : undefined,
        color: tint ?? undefined,
      }}
    >
      {hold > 0 && progress > 0 && (
        <span aria-hidden className="hold-fill" style={{ width: `${progress * 100}%`, background: tint ?? "var(--selection)" }} />
      )}
      <Glyph name={glyph} size={15} />
      <span>{pressing ? "Maintiens…" : title}</span>
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
          <span aria-hidden style={{ color: question.isDone ? tint : "var(--ink-tertiary)", display: "grid", paddingTop: 2 }}>
            <Icon name={question.isDone ? "checkmark.circle" : "circle"} size={15} />
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
    <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", maxWidth: 440 }}>
      <Button
        size="sm"
        icon={exercise.isDone ? "checkmark.circle" : "circle"}
        aria-pressed={exercise.isDone}
        onClick={() => onToggleDone(exercise)}
        style={exercise.isDone ? {
          background: "color-mix(in srgb, var(--correct) 14%, transparent)",
          borderColor: "transparent", color: "var(--correct)", fontWeight: 600,
        } : { fontWeight: 600 }}
      >
        {exercise.isDone ? "Fait" : "Fait ?"}
      </Button>
      <div style={{ flex: 1 }} />
      {Correctness.allCases.map((result) => {
        const selected = exercise.correctness === result;
        const color = result === "correct" ? "var(--correct)" : result === "partial" ? "var(--review)" : "var(--wrong)";
        return (
          <button
            key={result}
            type="button"
            className="btn btn-sm"
            title={Correctness.label(result)}
            aria-pressed={selected}
            onClick={() => onCorrect(exercise, selected ? null : result)}
            style={{
              borderColor: "transparent", fontWeight: 600,
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

/** Une carte du bureau : du verre sur la lueur du cours (glassCard). */
export function GlassCard({ children, style }: { children: ReactNode; style?: CSSProperties }) {
  return (
    <div className="desk-glass" style={{ padding: 16, borderRadius: 20, ...style }}>{children}</div>
  );
}

/** La couleur d'un cours, ou l'encre pour une session libre (MacTargets.tint). */
export function tintOfCourse(course: Course | null): string {
  return course?.colorHex ?? "var(--ink)";
}
