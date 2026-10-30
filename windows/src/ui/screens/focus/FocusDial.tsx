// Le cadran du chrono : l'anneau gradué, l'horloge au centre, et les trois
// gestes (abandonner, démarrer/pause, terminer).
//
// L'anneau reprend `TimerRing` du Mac : un cercle de règle, les douze
// graduations, et un arc à la couleur du cours qui se remplit (ou se vide
// pendant une pause). Un SVG de 300 px, sans animation : le Mac a retiré
// l'animation continue de l'anneau, qui redessinait à 60 images par seconde.

import { useState, type CSSProperties, type ReactNode } from "react";
import type { FocusPhase } from "../../../domain/pomodoroEngine.ts";
import { Plural } from "../../../domain/plural.ts";

const SIZE = 300;
const CENTER = SIZE / 2;
const RADIUS = 147;
const LINE_WIDTH = 6;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

/** Les douze graduations, plus longues et plus sombres tous les trois crans. */
function Graduations() {
  return (
    <>
      {Array.from({ length: 12 }, (_, index) => (
        <line
          key={index}
          x1={CENTER}
          x2={CENTER}
          y1={18}
          y2={index % 3 === 0 ? 28 : 24}
          strokeWidth={1.5}
          strokeLinecap="round"
          style={{ stroke: "var(--ink-tertiary)", strokeOpacity: index % 3 === 0 ? 0.9 : 0.45 }}
          transform={`rotate(${index * 30} ${CENTER} ${CENTER})`}
        />
      ))}
    </>
  );
}

export function FocusDial({ status, clock, headline, progress, draining, tint, muted, dots }: {
  status: string;
  clock: string;
  headline: string;
  /** 0 → 1 ; 1 = anneau plein. */
  progress: number;
  /** Une pause se vide au lieu de se remplir. */
  draining: boolean;
  tint: string;
  /** Chiffres en retrait : le chrono est en pause. */
  muted: boolean;
  /** Les pastilles du cycle, sous le titre. */
  dots?: ReactNode;
}) {
  const fraction = Math.max(0.001, Math.min(1, draining ? 1 - progress : progress));
  return (
    <div style={{ position: "relative", width: SIZE, height: SIZE }}>
      <svg
        width={SIZE}
        height={SIZE}
        viewBox={`0 0 ${SIZE} ${SIZE}`}
        role="img"
        aria-label={`${status} ${clock}`}
        style={{ display: "block" }}
      >
        <circle cx={CENTER} cy={CENTER} r={RADIUS} fill="none" strokeWidth={LINE_WIDTH} style={{ stroke: "var(--rule)" }} />
        <Graduations />
        <circle
          cx={CENTER}
          cy={CENTER}
          r={RADIUS}
          fill="none"
          strokeWidth={LINE_WIDTH}
          strokeLinecap="round"
          strokeDasharray={`${CIRCUMFERENCE * fraction} ${CIRCUMFERENCE}`}
          transform={`rotate(-90 ${CENTER} ${CENTER})`}
          style={{ stroke: tint }}
        />
      </svg>
      <div style={{
        position: "absolute", inset: 0, display: "flex", flexDirection: "column",
        alignItems: "center", justifyContent: "center", gap: 8, padding: 44,
        textAlign: "center", pointerEvents: "none",
      }}>
        <div style={{
          fontSize: 11, fontWeight: 600, letterSpacing: 1.1, textTransform: "uppercase",
          color: tint, maxWidth: 190, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
        }}>{status}</div>
        <div className="serif" style={{
          fontSize: 66, lineHeight: 1, fontVariantNumeric: "tabular-nums",
          color: muted ? "var(--ink-secondary)" : "var(--ink)",
        }}>{clock}</div>
        <div style={{
          fontSize: 13, color: "var(--ink-secondary)", maxWidth: 210,
          overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
        }}>{headline}</div>
        {dots}
      </div>
    </div>
  );
}

/** Les blocs du cycle : pleins quand ils sont faits. */
export function PomodoroDots({ completed, every, tint }: { completed: number; every: number; tint: string }) {
  const total = Math.max(2, every);
  const inCycle = completed % total;
  return (
    <div
      title={Plural.count(completed, `${completed} bloc terminé`, `${completed} blocs terminés`)}
      style={{ display: "flex", gap: 5, marginTop: 4 }}
    >
      {Array.from({ length: total }, (_, index) => (
        <span key={index} style={{
          width: 6, height: 6, borderRadius: 3,
          background: index < inCycle ? tint : "var(--rule)",
        }} />
      ))}
    </div>
  );
}

// MARK: - Gestes

type GlyphName = "play" | "pause" | "skip" | "x" | "check";

function Glyph({ name, size }: { name: GlyphName; size: number }) {
  const stroke = { fill: "none", stroke: "currentColor", strokeWidth: 2.2, strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  switch (name) {
    case "play":
      return <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5.5v13l11-6.5z" /></svg>;
    case "pause":
      return <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><rect x="7" y="5" width="3.6" height="14" rx="1" /><rect x="13.4" y="5" width="3.6" height="14" rx="1" /></svg>;
    case "skip":
      return <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M6 5.5v13l9-6.5z" /><rect x="16.5" y="5" width="2.6" height="14" rx="1" /></svg>;
    case "x":
      return <svg width={size} height={size} viewBox="0 0 24 24" {...stroke} aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>;
    case "check":
      return <svg width={size} height={size} viewBox="0 0 24 24" {...stroke} aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7" /></svg>;
  }
}

function RoundButton({ size, prominent, tint, label, onClick, children }: {
  size: number;
  prominent?: boolean;
  tint?: string;
  label: string;
  onClick: () => void;
  children: ReactNode;
}) {
  const [hovering, setHovering] = useState(false);
  const style: CSSProperties = {
    width: size,
    height: size,
    borderRadius: "50%",
    border: "none",
    display: "grid",
    placeItems: "center",
    padding: 0,
    background: prominent ? (tint ?? "var(--ink)") : hovering ? "var(--rule)" : "var(--sheet-raised)",
    color: prominent ? "var(--ground)" : "var(--ink)",
    filter: prominent && hovering ? "brightness(1.07)" : undefined,
    transition: "background 120ms ease, filter 120ms ease",
  };
  return (
    <button
      type="button"
      title={label}
      aria-label={label}
      onClick={onClick}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
      style={style}
    >
      {children}
    </button>
  );
}

/** Le geste principal, et « abandonner » / « terminer » de part et d'autre. */
export function FocusControls({ phase, hasSession, tint, onToggle, onSkipBreak, onFinish, onDiscard }: {
  phase: FocusPhase;
  hasSession: boolean;
  tint: string;
  onToggle: () => void;
  onSkipBreak: () => void;
  onFinish: () => void;
  onDiscard: () => void;
}) {
  const onBreak = phase.type === "onBreak";
  const primary = () => {
    if (onBreak) onSkipBreak();
    else onToggle();
  };
  const icon: GlyphName = phase.type === "working" ? "pause" : onBreak ? "skip" : "play";
  const help = phase.type === "idle" ? "Démarrer"
    : phase.type === "working" ? "Pause"
    : phase.type === "onBreak" ? "Reprendre"
    : phase.type === "readyForBlock" ? `Bloc ${phase.block}`
    : "Reprendre";
  const sideVisible: CSSProperties = { visibility: hasSession ? "visible" : "hidden" };

  return (
    <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
      <div style={sideVisible}>
        <RoundButton size={45} label="Abandonner" onClick={onDiscard}>
          <Glyph name="x" size={18} />
        </RoundButton>
      </div>
      <RoundButton size={64} prominent tint={onBreak ? "var(--correct)" : tint} label={help} onClick={primary}>
        <Glyph name={icon} size={24} />
      </RoundButton>
      <div style={sideVisible}>
        <RoundButton size={45} label="Terminer" onClick={onFinish}>
          <Glyph name="check" size={18} />
        </RoundButton>
      </div>
    </div>
  );
}
