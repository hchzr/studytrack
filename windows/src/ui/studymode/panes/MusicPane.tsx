// La musique du bureau (le volet Musique du Mac), sans compte ni abonnement : ce que joue le
// lecteur du PC (l'app Spotify, Apple Music, un navigateur), le piloter, et lancer une playlist
// Spotify dans l'app Spotify depuis son lien.

import { useEffect, useState } from "react";
import { SystemMedia, appName, type MediaState } from "../../../native/media.ts";
import { Icon } from "../../icons.tsx";

export function MusicPane() {
  return (
    <div style={{ height: "100%", overflowY: "auto" }}>
      <div style={{ maxWidth: 820, margin: "0 auto", padding: "24px 28px 40px", display: "flex", flexDirection: "column", gap: 20 }}>
        <SystemPanel />
      </div>
    </div>
  );
}

/** `https://open.spotify.com/playlist/…` ou `spotify:playlist:…` → l'adresse que l'app Spotify ouvre. */
export function spotifyURI(text: string): string | null {
  const value = text.trim();
  const uri = /^spotify:(playlist|album|artist|track|show|episode):([A-Za-z0-9]+)$/.exec(value);
  if (uri) return value;
  const web = /open\.spotify\.com\/(?:intl-[a-z-]+\/)?(playlist|album|artist|track|show|episode)\/([A-Za-z0-9]+)/.exec(value);
  return web ? `spotify:${web[1]}:${web[2]}` : null;
}

const SAVED = "spotify.savedLinks";

/** Lancer une playlist dans l'app Spotify du PC (gratuit ou Premium) : son lien, gardé pour la prochaine fois. */
function OpenInSpotify() {
  const [text, setText] = useState("");
  const [saved, setSaved] = useState<{ uri: string; label: string }[]>(() => {
    try { return JSON.parse(localStorage.getItem(SAVED) ?? "[]"); } catch { return []; }
  });
  const [error, setError] = useState<string | null>(null);
  const open = async (uri: string) => {
    try {
      const { openUrl } = await import("@tauri-apps/plugin-opener");
      await openUrl(uri);
    } catch {
      setError("L'app Spotify ne s'ouvre pas : est-elle installée ?");
    }
  };
  const add = () => {
    const uri = spotifyURI(text);
    if (!uri) { setError("Colle un lien Spotify (playlist, album…)."); return; }
    setError(null);
    const next = [{ uri, label: uri.split(":")[1] === "playlist" ? "Playlist" : uri.split(":")[1] }, ...saved.filter((s) => s.uri !== uri)].slice(0, 8);
    setSaved(next);
    try { localStorage.setItem(SAVED, JSON.stringify(next)); } catch { /* pour la session */ }
    setText("");
    void open(uri);
  };
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <span className="serif" style={{ fontSize: 16, color: "var(--ink)" }}>Lancer dans Spotify</span>
      <div style={{ display: "flex", gap: 8 }}>
        <input className="field" style={{ flex: 1 }} placeholder="Lien d'une playlist ou d'un album (Partager › Copier le lien)" value={text}
          onChange={(event) => setText(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") add(); }} />
        <button type="button" className="btn btn-primary" disabled={!text.trim()} onClick={add}>Écouter</button>
      </div>
      {saved.length > 0 && (
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          {saved.map((item, index) => (
            <button key={item.uri} type="button" className="chip" title={item.uri} onClick={() => { void open(item.uri); }}>
              {item.label} {index + 1}
            </button>
          ))}
        </div>
      )}
      {error && <span style={{ color: "var(--wrong)", fontSize: 13 }}>{error}</span>}
    </section>
  );
}

function SystemPanel() {
  const [state, setState] = useState<MediaState | null>(null);
  const refresh = () => { void SystemMedia.state().then(setState); };
  useEffect(() => {
    refresh();
    const id = window.setInterval(refresh, 4000);
    return () => window.clearInterval(id);
  }, []);
  const act = (action: "toggle" | "next" | "previous") => { void SystemMedia.command(action).then(() => window.setTimeout(refresh, 300)); };
  return (
    <>
      <section style={{ display: "flex", flexDirection: "column", gap: 10, alignItems: "flex-start" }}>
        <span className="serif" style={{ fontSize: 18, color: "var(--ink)" }}>Ce qui joue sur ce PC</span>
        {state === null ? <span>…</span> : !state.available ? (
          <span style={{ color: "var(--ink-secondary)", fontSize: 13 }}>Rien ne joue. Lance ta musique (Spotify, Apple Music, un navigateur…) : elle se pilote ici.</span>
        ) : (
          <>
            <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>{state.title || "Sans titre"}</span>
            <span style={{ color: "var(--ink-secondary)" }}>{[state.artist, appName(state.app)].filter(Boolean).join(" · ")}</span>
            <Controls playing={state.playing} onPrevious={() => act("previous")} onToggle={() => act("toggle")} onNext={() => act("next")} />
          </>
        )}
      </section>
      <OpenInSpotify />
    </>
  );
}

function Controls({ playing, onPrevious, onToggle, onNext }: { playing: boolean; onPrevious: () => void; onToggle: () => void; onNext: () => void }) {
  return (
    <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
      <button type="button" className="icon-btn" title="Précédent" onClick={onPrevious}><Icon name="chevron.left" size={20} /></button>
      <button type="button" className="bar-play" title={playing ? "Pause" : "Lecture"} onClick={onToggle} style={{ width: 54, height: 54 }}>
        <Icon name={playing ? "pause.fill" : "play.fill"} size={22} />
      </button>
      <button type="button" className="icon-btn" title="Suivant" onClick={onNext}><Icon name="chevron.right" size={20} /></button>
    </div>
  );
}
