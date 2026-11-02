// Le cadran du chrono : l'anneau gradué, l'horloge au centre, et les trois
// gestes (abandonner, démarrer/pause, terminer).
//
// L'anneau reprend `TimerRing` du Mac : un cercle de règle, les douze
// graduations, et un arc à la couleur du cours qui se remplit (ou se vide
// pendant une pause). Un SVG de 300 px, sans animation : le Mac a retiré
// l'animation continue de l'anneau, qui redessinait à 60 images par seconde.

import type { CSSProperties, ReactNode } from "react";
import type { FocusPhase } from "../../../domain/pomodoroEngine.ts";
import { Plural } from "../../../domain/plural.ts";
import { Icon, cx, type IconName } from "../../kit.tsx";
import "./focus.css";

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
          className="f-dial-tick"
          x1={CENTER}
          x2={CENTER}
          y1={18}
          y2={index % 3 === 0 ? 28 : 24}
          strokeWidth={1.5}
          strokeLinecap="round"
          strokeOpacity={index % 3 === 0 ? 0.9 : 0.45}
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
    <div className="f-dial">
      <svg width={SIZE} height={SIZE} viewBox={`0 0 ${SIZE} ${SIZE}`} role="img" aria-label={`${status} ${clock}`}>
        <circle className="f-dial-ring-track" cx={CENTER} cy={CENTER} r={RADIUS} fill="none" strokeWidth={LINE_WIDTH} />
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
      <div className="f-dial-center">
        <div className="f-dial-status t-ellipsis" style={{ color: tint }}>{status}</div>
        <div className={cx("serif f-dial-clock", muted && "muted")}>{clock}</div>
        <div className="f-dial-headline t-ellipsis">{headline}</div>
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
    <div className="f-dots" style={{ ["--tint" as string]: tint }}
      title={Plural.count(completed, `${completed} bloc terminé`, `${completed} blocs terminés`)}>
      {Array.from({ length: total }, (_, index) => <span key={index} className={index < inCycle ? "on" : undefined} />)}
    </div>
  );
}

// MARK: - Gestes

function RoundButton({ prominent, tint, label, icon, iconSize, onClick }: {
  prominent?: boolean;
  tint?: string;
  label: string;
  icon: IconName;
  iconSize: number;
  onClick: () => void;
}) {
  const style = tint ? ({ ["--tint" as string]: tint } as CSSProperties) : undefined;
  return (
    <button type="button" className={cx("f-round", prominent && "prominent")} title={label} aria-label={label}
      onClick={onClick} style={style}>
      <Icon name={icon} size={iconSize} strokeWidth={prominent ? 2 : 2.2} />
    </button>
  );
}

/** Le geste principal, et « abandonner » / « terminer » de part et d'autre. */
export function FocusControls({ phase, hasSession, locked, tint, onToggle, onSkipBreak, onFinish, onDiscard }: {
  phase: FocusPhase;
  hasSession: boolean;
  /** Le mode étude verrouille : ni abandonner ni terminer (`timer.isLocked`). */
  locked?: boolean;
  tint: string;
  onToggle: () => void;
  onSkipBreak: () => void;
  onFinish: () => void;
  onDiscard: () => void;
}) {
  const onBreak = phase.type === "onBreak";
  const icon: IconName = phase.type === "working" ? "pause.fill" : onBreak ? "forward.end.fill" : "play.fill";
  const help = phase.type === "idle" ? "Démarrer"
    : phase.type === "working" ? "Pause"
    : phase.type === "readyForBlock" ? `Bloc ${phase.block}`
    : "Reprendre";
  const showSides = hasSession && !locked;

  return (
    <div className="f-controls">
      <div className="f-side">
        {showSides && <RoundButton icon="xmark" iconSize={18} label="Abandonner" onClick={onDiscard} />}
      </div>
      <RoundButton prominent tint={onBreak ? "var(--correct)" : tint} icon={icon} iconSize={24} label={help}
        onClick={onBreak ? onSkipBreak : onToggle} />
      <div className="f-side">
        {showSides && <RoundButton icon="checkmark" iconSize={18} label="Terminer" onClick={onFinish} />}
      </div>
    </div>
  );
}
