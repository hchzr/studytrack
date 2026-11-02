// Le chrono flottant (MiniTimerPanel / MiniTimerView du Mac) : une pilule avec
// l'anneau du cours, le temps et ce qu'on fait ; pause et terminer au survol.
// Rendue dans la petite fenêtre `?window=mini` ; l'état lui vient de la
// fenêtre principale (src/native/miniBridge.ts), elle ne lit rien d'autre.

import { useEffect, useState } from "react";
import { Icon, IconButton } from "../kit.tsx";
import { TimerText } from "../../domain/timerText.ts";
import {
  inactiveMini, miniProgress, miniSeconds, miniSubtitle, type MiniCommand, type MiniState,
} from "../../native/miniState.ts";
import { MINI_COMMAND, MINI_REQUEST, MINI_STATE } from "../../native/miniBridge.ts";
import { inNative } from "../../native/tauri.ts";
import "./mini.css";

const RING = 15;
const CIRC = 2 * Math.PI * RING;

/** Le message de la principale ; hors Tauri (aperçu), un état d'exemple. */
function useMiniState(): MiniState {
  const [state, setState] = useState<MiniState>(() => inNative() ? inactiveMini : previewState());
  useEffect(() => {
    if (!inNative()) return;
    let off: (() => void) | undefined;
    let cancelled = false;
    void (async () => {
      const { listen, emit } = await import("@tauri-apps/api/event");
      const unlisten = await listen<MiniState>(MINI_STATE, (event) => setState(event.payload));
      if (cancelled) { unlisten(); return; }
      off = unlisten;
      // L'écoute est en place : on demande l'état courant, une fois.
      await emit(MINI_REQUEST);
    })();
    return () => { cancelled = true; off?.(); };
  }, []);
  return state;
}

function previewState(): MiniState {
  const params = new URLSearchParams(window.location.search);
  const studying = params.get("study") === "1";
  return {
    active: true, phase: "working", running: false, countdown: true, seconds: 17 * 60 + 42,
    sentAt: Date.now(), ringValue: 7 * 60 + 18, ringLength: 25 * 60, studying,
    studyUntil: studying ? Date.now() + 38 * 60_000 : null, status: "Bloc 2", what: "Série 3 · Ex 2",
    courseCode: "MATH-101", tint: "#4F46E5",
  };
}

async function send(action: MiniCommand): Promise<void> {
  if (!inNative()) return;
  const { emit } = await import("@tauri-apps/api/event");
  await emit(MINI_COMMAND, action);
}

export function MiniTimer() {
  const state = useMiniState();
  // Une seconde de battement, seulement tant que le temps avance ou qu'une fin approche.
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    setNow(Date.now());
    if (!state.active || !(state.running || state.studyUntil !== null)) return;
    const id = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [state]);

  // La fenêtre transparente : le fond de page ne doit rien peindre.
  useEffect(() => { document.documentElement.classList.add("mini-window"); }, []);

  const progress = miniProgress(state, now);
  const primary = state.phase === "working" ? "Pause" : state.phase === "break" ? "Passer la pause" : "Reprendre";
  return (
    <div className="mini-frame">
      <div className="mini-pill" data-tauri-drag-region
        onContextMenu={(event) => { event.preventDefault(); void send("hide"); }}>
        <div className="mini-ring" data-tauri-drag-region>
          <svg viewBox="0 0 36 36" width="30" height="30" aria-hidden data-tauri-drag-region>
            <circle cx="18" cy="18" r={RING} fill="none" strokeWidth="3.5" style={{ stroke: "var(--rule)" }} />
            <circle cx="18" cy="18" r={RING} fill="none" strokeWidth="3.5" strokeLinecap="round"
              transform="rotate(-90 18 18)" strokeDasharray={CIRC} strokeDashoffset={CIRC * (1 - progress)}
              style={{ stroke: state.phase === "break" ? "var(--correct)" : state.tint }} />
          </svg>
          <span className="mini-glyph" style={{ color: state.phase === "break" ? "var(--correct)" : state.tint }}
            data-tauri-drag-region>
            {state.phase === "paused" && <Icon name="pause.fill" size={11} />}
            {state.phase === "break" && <Icon name="cup.and.saucer" size={11} />}
            {state.phase !== "paused" && state.phase !== "break" && state.studying && <Icon name="moon" size={11} />}
          </span>
        </div>
        <div className="mini-text" data-tauri-drag-region>
          <div className="mini-clock" data-tauri-drag-region>{TimerText.clock(miniSeconds(state, now))}</div>
          <div className="mini-sub" data-tauri-drag-region>{miniSubtitle(state, now)}</div>
        </div>
        <div className="mini-actions">
          <IconButton size="sm" bordered label={primary}
            icon={state.phase === "working" || state.phase === "break" ? "pause.fill" : "play.fill"}
            onClick={() => void send("toggle")} />
          {state.studying
            ? <IconButton size="sm" bordered label="Mode étude" icon="moon" onClick={() => void send("open")} />
            : <IconButton size="sm" bordered label="Terminer" icon="checkmark" onClick={() => void send("finish")} />}
        </div>
      </div>
    </div>
  );
}
