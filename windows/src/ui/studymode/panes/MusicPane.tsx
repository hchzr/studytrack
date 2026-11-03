// La musique du bureau (le volet Musique du Mac) :
//   • Spotify Connect : ce qui joue sur n'importe lequel de tes appareils Spotify, le piloter,
//     le déplacer vers ce PC ou une enceinte, lancer une playlist ;
//   • sans Spotify : le lecteur du système (Apple Music, un navigateur…), lecture et pause.

import { useEffect, useState } from "react";
import { SystemMedia, appName, type MediaState } from "../../../native/media.ts";
import {
  Spotify, onSpotifyChange, spotifyClientID, spotifyConnected, spotifySignIn, spotifySignOut,
  type SpotifyDevice, type SpotifyPlayback, type SpotifyPlaylist,
} from "../../../services/spotify.ts";
import { Icon } from "../../icons.tsx";

export function MusicPane() {
  const [connected, setConnected] = useState<boolean | null>(null);
  useEffect(() => {
    const check = () => { void spotifyConnected().then(setConnected); };
    check();
    return onSpotifyChange(check);
  }, []);
  return (
    <div style={{ height: "100%", overflowY: "auto" }}>
      <div style={{ maxWidth: 820, margin: "0 auto", padding: "24px 28px 40px", display: "flex", flexDirection: "column", gap: 20 }}>
        {connected === null ? null : connected ? <SpotifyPanel /> : <SystemPanel />}
      </div>
    </div>
  );
}

function ConnectSpotify() {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const hasApp = spotifyClientID() !== "";
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 8, padding: 16, borderRadius: 14, border: "1px solid var(--rule)" }}>
      <span className="serif" style={{ fontSize: 18, color: "var(--ink)" }}>Spotify Connect</span>
      <span style={{ fontSize: 13, color: "var(--ink-secondary)" }}>
        Pilote Spotify sur tous tes appareils (ce PC, ton téléphone, une enceinte) sans quitter le mode étude :
        ce qui joue, morceau suivant, changer d'appareil, lancer une playlist. Le pilotage demande Spotify Premium.
      </span>
      {hasApp ? (
        <button type="button" className="btn btn-primary" style={{ alignSelf: "flex-start" }} disabled={busy} onClick={() => {
          setBusy(true);
          setError(null);
          void spotifySignIn().catch((e: unknown) => setError(e instanceof Error ? e.message : String(e))).finally(() => setBusy(false));
        }}>{busy ? "Termine dans ton navigateur…" : "Se connecter à Spotify"}</button>
      ) : (
        <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>Ce build n'a pas d'app Spotify : ajoute son identifiant dans Réglages › Musique.</span>
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
      <ConnectSpotify />
      <section style={{ display: "flex", flexDirection: "column", gap: 10, alignItems: "flex-start" }}>
        <span className="serif" style={{ fontSize: 18, color: "var(--ink)" }}>Ce qui joue sur ce PC</span>
        {state === null ? <span>…</span> : !state.available ? (
          <span style={{ color: "var(--ink-secondary)", fontSize: 13 }}>Rien ne joue. Lance ta musique (Apple Music, un navigateur…) : elle se pilote ici.</span>
        ) : (
          <>
            <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>{state.title || "Sans titre"}</span>
            <span style={{ color: "var(--ink-secondary)" }}>{[state.artist, appName(state.app)].filter(Boolean).join(" · ")}</span>
            <Controls playing={state.playing} onPrevious={() => act("previous")} onToggle={() => act("toggle")} onNext={() => act("next")} />
          </>
        )}
      </section>
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

function SpotifyPanel() {
  const [playback, setPlayback] = useState<SpotifyPlayback | null>(null);
  const [devices, setDevices] = useState<SpotifyDevice[]>([]);
  const [playlists, setPlaylists] = useState<SpotifyPlaylist[]>([]);
  const [error, setError] = useState<string | null>(null);
  const refresh = () => {
    void Spotify.playback().then(setPlayback, (e: unknown) => setError(e instanceof Error ? e.message : String(e)));
    void Spotify.devices().then(setDevices, () => {});
  };
  useEffect(() => {
    refresh();
    void Spotify.playlists().then(setPlaylists, () => {});
    const id = window.setInterval(refresh, 4000);
    return () => window.clearInterval(id);
  }, []);
  const run = (action: () => Promise<void>) => {
    setError(null);
    void action().then(() => window.setTimeout(refresh, 400), (e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  };
  const track = playback?.track ?? null;
  const active = playback?.device ?? devices.find((d) => d.isActive) ?? null;
  return (
    <>
      <section style={{ display: "flex", gap: 18, alignItems: "center" }}>
        {track?.artwork
          ? <img src={track.artwork} alt="" style={{ width: 120, height: 120, borderRadius: 12, objectFit: "cover" }} />
          : <div style={{ width: 120, height: 120, borderRadius: 12, background: "var(--sheet-raised)", display: "grid", placeItems: "center" }}><Icon name="music.note" size={30} /></div>}
        <div style={{ display: "flex", flexDirection: "column", gap: 6, minWidth: 0, flex: 1 }}>
          <span className="serif" style={{ fontSize: 24, color: "var(--ink)" }}>{track?.title ?? "Rien ne joue"}</span>
          <span style={{ color: "var(--ink-secondary)" }}>{track ? [track.artists, track.album].filter(Boolean).join(" · ") : "Lance une playlist ci-dessous, ou ouvre Spotify sur un appareil."}</span>
          <Controls playing={playback?.isPlaying ?? false}
            onPrevious={() => run(Spotify.previous)}
            onToggle={() => run(playback?.isPlaying ? Spotify.pause : () => Spotify.play())}
            onNext={() => run(Spotify.next)} />
        </div>
      </section>
      {error && <span style={{ color: "var(--wrong)", fontSize: 13 }}>{error}</span>}

      <section style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <span className="serif" style={{ fontSize: 16, color: "var(--ink)" }}>Écouter sur</span>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          {devices.length === 0 && <span style={{ fontSize: 13, color: "var(--ink-tertiary)" }}>Aucun appareil : ouvre Spotify sur ce PC ou ton téléphone.</span>}
          {devices.map((d) => (
            <button key={d.id} type="button" className="btn" aria-pressed={d.isActive}
              style={d.isActive ? { borderColor: "var(--ink)" } : undefined} onClick={() => run(() => Spotify.transfer(d.id, true))}>
              {d.name} <span style={{ color: "var(--ink-tertiary)", fontSize: 11 }}>{d.type}</span>
            </button>
          ))}
        </div>
      </section>

      <section style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <span className="serif" style={{ fontSize: 16, color: "var(--ink)" }}>Tes playlists</span>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))", gap: 8 }}>
          {playlists.map((p) => {
            return (
              <div key={p.id} style={{ display: "flex", gap: 10, alignItems: "center", padding: 8, borderRadius: 12, border: "1px solid var(--rule)" }}>
                {p.image ? <img src={p.image} alt="" style={{ width: 44, height: 44, borderRadius: 8, objectFit: "cover" }} /> : <Icon name="music.note" size={20} />}
                <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
                  <span style={{ fontSize: 13, color: "var(--ink)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{p.name}</span>
                  <span style={{ fontSize: 11, color: "var(--ink-tertiary)" }}>{p.tracks} titres</span>
                </div>
                <button type="button" className="icon-btn" title="Écouter" onClick={() => run(() => Spotify.play(p.uri, active?.id))}><Icon name="play.fill" size={14} /></button>
              </div>
            );
          })}
        </div>
      </section>
      <button type="button" className="link-btn" style={{ alignSelf: "flex-start" }} onClick={() => { void spotifySignOut(); }}>Se déconnecter de Spotify</button>
    </>
  );
}
