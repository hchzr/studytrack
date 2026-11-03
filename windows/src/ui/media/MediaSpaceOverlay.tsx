// Une vidéo MediaSpace par-dessus le volet, lue dans l'app (NativeVideo du Mac).

import { useEffect, useState } from "react";
import { entryID, mediaspaceSignIn, playbackURL } from "../../services/mediaspace.ts";
import { listenNative } from "../../native/tauri.ts";
import { Icon } from "../icons.tsx";
import { VideoPlayer } from "./VideoPlayer.tsx";

export function MediaSpaceOverlay({ link, title, close, openWeb }: { link: string; title?: string; close: () => void; openWeb: (url: string) => void }) {
  const [state, setState] = useState<{ kind: "loading" } | { kind: "login" } | { kind: "ready"; src: string }>({ kind: "loading" });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    const id = entryID(link);
    setState({ kind: "loading" });
    if (!id) { setState({ kind: "login" }); return; }
    void playbackURL(id).then((src) => { if (alive) setState(src ? { kind: "ready", src } : { kind: "login" }); });
    return () => { alive = false; };
  }, [link, tick]);
  useEffect(() => listenNative<string>("site:signed-in", () => setTick((n) => n + 1)), []);
  useEffect(() => {
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") close(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [close]);
  return (
    <div role="dialog" aria-label={title ?? "Vidéo"} style={{
      position: "absolute", inset: 0, zIndex: 20, background: "color-mix(in srgb, var(--ground, #000) 92%, transparent)",
      display: "flex", flexDirection: "column", padding: 20, gap: 12,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <span className="serif" style={{ flex: 1, fontSize: 18, color: "var(--ink)" }}>{title ?? "Vidéo du cours"}</span>
        <button type="button" className="btn" onClick={() => openWeb(link)}>Ouvrir MediaSpace</button>
        <button type="button" className="icon-btn" title="Fermer (Échap)" onClick={close}><Icon name="xmark" size={16} /></button>
      </div>
      <div style={{ flex: 1, minHeight: 0, display: "grid", placeItems: "center" }}>
        {state.kind === "loading" && <span style={{ color: "var(--ink-secondary)" }}>Préparation de la vidéo…</span>}
        {state.kind === "login" && (
          <div className="bf-center">
            <span>Cette vidéo demande la connexion à MediaSpace (SWITCH edu-ID), une fois.</span>
            <button type="button" className="btn btn-primary" onClick={() => { void mediaspaceSignIn(); }}>Se connecter</button>
          </div>
        )}
        {state.kind === "ready" && <div style={{ width: "100%", maxWidth: 1100 }}><VideoPlayer src={state.src} /></div>}
      </div>
    </div>
  );
}
