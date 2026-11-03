// La musique du bureau (le volet Musique du Mac) : ce que joue le lecteur du système
// (Spotify, Apple Music, un navigateur…), le piloter sans quitter le mode étude, et la règle
// des pauses — la musique se tait pendant la pause du rythme, revient avec le travail.

import { useEffect, useState } from "react";
import { SystemMedia, appName, readPauseOnBreak, writePauseOnBreak, type MediaState } from "../../../native/media.ts";
import { Icon } from "../../icons.tsx";
import { Switch } from "../../kit.tsx";
import { openInApp } from "../openers.ts";

export function MusicPane() {
  const [state, setState] = useState<MediaState | null>(null);
  const [pauseOnBreak, setPauseOnBreak] = useState(readPauseOnBreak);
  const refresh = () => { void SystemMedia.state().then(setState); };
  // Relu à l'ouverture, après chaque geste, et toutes les 4 s tant que le volet est ouvert.
  useEffect(() => {
    refresh();
    const id = window.setInterval(refresh, 4000);
    return () => window.clearInterval(id);
  }, []);
  const act = (action: "toggle" | "next" | "previous") => { void SystemMedia.command(action).then(() => window.setTimeout(refresh, 300)); };

  return (
    <div className="bf-center" style={{ gap: 18 }}>
      <Icon name="music.note" size={30} />
      {state === null ? <span>…</span> : !state.available ? (
        <>
          <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>Rien ne joue</span>
          <span style={{ maxWidth: 460 }}>Lance ta musique dans Spotify, Apple Music ou un navigateur : elle apparaît ici, et se pilote sans quitter le mode étude.</span>
          <div style={{ display: "flex", gap: 8 }}>
            <button type="button" className="btn" onClick={() => { void openInApp("https://open.spotify.com", "Spotify"); }}>Spotify</button>
            <button type="button" className="btn" onClick={() => { void openInApp("https://music.apple.com", "Apple Music"); }}>Apple Music</button>
          </div>
        </>
      ) : (
        <>
          <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
            <span className="serif" style={{ fontSize: 26, color: "var(--ink)" }}>{state.title || "Sans titre"}</span>
            <span>{[state.artist, appName(state.app)].filter(Boolean).join(" · ")}</span>
          </div>
          <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
            <button type="button" className="icon-btn" title="Précédent" onClick={() => act("previous")}><Icon name="chevron.left" size={20} /></button>
            <button type="button" className="bar-play" title={state.playing ? "Pause" : "Lecture"} onClick={() => act("toggle")}
              style={{ width: 54, height: 54 }}>
              <Icon name={state.playing ? "pause.fill" : "play.fill"} size={22} />
            </button>
            <button type="button" className="icon-btn" title="Suivant" onClick={() => act("next")}><Icon name="chevron.right" size={20} /></button>
          </div>
        </>
      )}
      <label style={{ display: "flex", alignItems: "center", gap: 10, fontSize: 13 }}>
        <Switch checked={pauseOnBreak} ariaLabel="Pause pendant les pauses" onChange={(value) => { writePauseOnBreak(value); setPauseOnBreak(value); }} />
        En pause pendant les pauses du rythme, reprise au travail
      </label>
    </div>
  );
}
