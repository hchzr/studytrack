// La musique du mode étude (le volet Musique du Mac) : ton compte **Spotify** piloté comme Music
// (ce qui joue sur n'importe quel appareil, commandes, position, volume, appareil, playlists), ou
// **le lecteur de ce PC** (ce que joue l'app Spotify, un navigateur…, par les commandes média de
// Windows), avec de quoi lancer une playlist dans l'app Spotify depuis son lien.

import { useEffect, useState, useSyncExternalStore } from "react";
import { SystemMedia, appName, type MediaState } from "../../../native/media.ts";
import { listenNative } from "../../../native/tauri.ts";
import { spotifyAccount } from "../../../services/spotifyAccount.ts";
import { deviceIcon, elapsed, spotifyURI as parseURI } from "../../../domain/spotifyWire.ts";
import { Segmented } from "../../kit.tsx";
import { Icon, type IconName } from "../../icons.tsx";

const SOURCE = "music.source";

export function MusicPane() {
  const [source, setSource] = useState<"spotify" | "system">(() => {
    try { return localStorage.getItem(SOURCE) === "system" ? "system" : "spotify"; } catch { return "spotify"; }
  });
  const choose = (value: "spotify" | "system") => {
    setSource(value);
    try { localStorage.setItem(SOURCE, value); } catch { /* pour la session */ }
  };
  return (
    <div style={{ height: "100%", overflowY: "auto" }}>
      <div style={{ display: "flex", justifyContent: "center", padding: "10px 0 0" }}>
        <Segmented value={source} onChange={choose} ariaLabel="Source"
          options={[{ value: "spotify", label: "Spotify" }, { value: "system", label: "Lecteur du PC" }]} />
      </div>
      <div style={{ maxWidth: 820, margin: "0 auto", padding: "20px 28px 40px", display: "flex", flexDirection: "column", gap: 22 }}>
        {source === "spotify" ? <SpotifyPanel /> : <><SystemPanel /><OpenInSpotify /></>}
      </div>
    </div>
  );
}

/** `https://open.spotify.com/playlist/…` ou `spotify:playlist:…` → l'adresse que l'app Spotify ouvre. */
export const spotifyURI = parseURI;

const fmt = (seconds: number) => {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

// ── Spotify (le compte) ──

function useSpotify() {
  return useSyncExternalStore(spotifyAccount.subscribe, spotifyAccount.get);
}

function SpotifyPanel() {
  const spotify = useSpotify();
  useEffect(() => {
    spotifyAccount.startWatching();
    // La fenêtre de connexion s'est fermée seule : on relit la session.
    const off = listenNative<string>("site:signed-in", (label) => {
      if (label !== "spotify") return;
      spotifyAccount.stopWatching();
      void spotifyAccount.refresh().then(() => spotifyAccount.startWatching());
    });
    return () => { off(); spotifyAccount.stopWatching(); };
  }, []);
  const state = spotify.state;
  if (state.kind === "unknown" || state.kind === "checking") return <span className="faint">…</span>;
  if (state.kind !== "ready") return <><ConnectCard failure={state.kind === "failed" ? state.message : null} /><SystemPanel /><OpenInSpotify /></>;
  return (
    <>
      <SpotifyPlayer />
      <Playlists />
      <LinkField />
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <span className="faint" style={{ fontSize: 12, flex: 1 }}>Connecté·e à Spotify (non officiel : StudyTrack parle à Spotify comme son lecteur web).</span>
        <button type="button" className="btn btn-sm" onClick={() => { void spotifyAccount.signOut(); }}>Se déconnecter</button>
      </div>
    </>
  );
}

function ConnectCard({ failure }: { failure: string | null }) {
  const [error, setError] = useState<string | null>(null);
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 10, padding: 18, borderRadius: 14, background: "var(--sheet-raised)" }}>
      <span className="serif" style={{ fontSize: 18, color: "var(--ink)" }}>Ton compte Spotify, piloté d'ici</span>
      <span style={{ color: "var(--ink-secondary)", fontSize: 14 }}>
        Connecte-toi une fois : ce qui joue sur ton ordinateur ou ton téléphone, les commandes, le volume, tes playlists — gratuit ou Premium. StudyTrack ne voit jamais ton mot de passe.
      </span>
      {(failure ?? error) && <span style={{ color: "var(--review)", fontSize: 13 }}>{failure ?? error}</span>}
      <div style={{ display: "flex", gap: 8 }}>
        <button type="button" className="btn btn-primary" onClick={() => {
          spotifyAccount.signIn().catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
        }}>Se connecter à Spotify</button>
        <button type="button" className="btn" onClick={() => { void spotifyAccount.refresh().then(() => { spotifyAccount.stopWatching(); spotifyAccount.startWatching(); }); }}>
          C'est fait
        </button>
      </div>
      <span className="faint" style={{ fontSize: 12 }}>Non officiel : StudyTrack parle à Spotify comme son lecteur web. Si Spotify change, le lecteur du PC reste là.</span>
    </section>
  );
}

function SpotifyPlayer() {
  const { now, error } = useSpotify();
  const [tick, setTick] = useState(() => Date.now());
  const [scrub, setScrub] = useState<number | null>(null);
  useEffect(() => {
    if (!now.isPlaying) return;
    const id = window.setInterval(() => setTick(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [now.isPlaying]);
  const active = now.devices.find((d) => d.id === now.activeDevice);
  const position = scrub ?? elapsed(now, tick);
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <div style={{ display: "flex", gap: 18, alignItems: "center" }}>
        {now.track?.artwork
          ? <img src={now.track.artwork} alt="" style={{ width: 132, height: 132, borderRadius: 10, objectFit: "cover", boxShadow: "0 8px 24px rgba(0,0,0,.3)" }} />
          : <div style={{ width: 132, height: 132, borderRadius: 10, background: "var(--sheet-raised)", display: "grid", placeItems: "center" }}><Icon name="music.note" size={30} /></div>}
        <div style={{ display: "flex", flexDirection: "column", gap: 4, minWidth: 0 }}>
          <span style={{ fontSize: 20, fontWeight: 600, color: "var(--ink)" }}>{now.track?.title || "Rien ne joue"}</span>
          {now.track?.artist && <span style={{ color: "var(--ink-secondary)" }}>{now.track.artist}</span>}
          {!now.track && (
            <span style={{ color: "var(--ink-secondary)", fontSize: 14 }}>
              {now.devices.length === 0 ? "Ouvre Spotify sur un appareil (ordinateur, téléphone…) : il se pilote ici." : "Choisis une playlist ci-dessous, ou lance la lecture."}
            </span>
          )}
          {now.devices.length > 0 && (
            <label style={{ display: "inline-flex", alignItems: "center", gap: 6, marginTop: 6, fontSize: 12, color: "var(--ink-secondary)" }}>
              <Icon name={(active ? deviceIcon(active.type) : "hifispeaker") as IconName} size={14} />
              <select className="field" style={{ padding: "2px 6px", fontSize: 12 }} value={now.activeDevice ?? ""} aria-label="Écouter sur"
                onChange={(e) => spotifyAccount.move(e.target.value)}>
                {!active && <option value="">Choisir un appareil</option>}
                {now.devices.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select>
            </label>
          )}
        </div>
      </div>
      {now.track && (
        <div style={{ display: "flex", flexDirection: "column", gap: 12, maxWidth: 420 }}>
          <div>
            <input type="range" min={0} max={Math.max(now.duration, 1)} step={1} value={Math.min(position, Math.max(now.duration, 1))} aria-label="Position"
              style={{ width: "100%", accentColor: "var(--ink)" }}
              onChange={(e) => setScrub(Number(e.target.value))}
              onPointerUp={() => { if (scrub !== null) { spotifyAccount.seek(scrub); setScrub(null); } }}
              onKeyUp={() => { if (scrub !== null) { spotifyAccount.seek(scrub); setScrub(null); } }} />
            <div className="mono faint" style={{ display: "flex", justifyContent: "space-between", fontSize: 11 }}>
              <span>{fmt(position)}</span><span>−{fmt(now.duration - position)}</span>
            </div>
          </div>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            <Glyph icon="shuffle" label="Aléatoire" active={now.shuffle} onClick={() => spotifyAccount.setShuffle(!now.shuffle)} />
            <Glyph icon="backward.fill" label="Précédent" onClick={() => spotifyAccount.previous()} />
            <button type="button" className="bar-play" title={now.isPlaying ? "Pause" : "Lecture"} onClick={() => spotifyAccount.togglePlayPause()} style={{ width: 54, height: 54 }}>
              <Icon name={now.isPlaying ? "pause.fill" : "play.fill"} size={22} />
            </button>
            <Glyph icon="forward.fill" label="Suivant" onClick={() => spotifyAccount.next()} />
            <Glyph icon={now.repeatTrack ? "repeat.1" : "repeat"} label="Répéter" active={now.repeatContext || now.repeatTrack} onClick={() => spotifyAccount.cycleRepeat()} />
          </div>
          {active?.volume != null && (
            <div style={{ display: "flex", alignItems: "center", gap: 10, color: "var(--ink-tertiary)" }}>
              <Icon name="speaker.fill" size={14} />
              <input type="range" min={0} max={1} step={0.01} defaultValue={active.volume} key={active.id} aria-label="Volume"
                style={{ flex: 1, accentColor: "var(--ink)" }}
                onPointerUp={(e) => spotifyAccount.setVolume(Number((e.target as HTMLInputElement).value))}
                onKeyUp={(e) => spotifyAccount.setVolume(Number((e.target as HTMLInputElement).value))} />
              <Icon name="speaker.wave.3.fill" size={14} />
            </div>
          )}
          {now.upNext.length > 0 && (
            <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
              <span style={{ fontSize: 12, fontWeight: 600, color: "var(--ink-secondary)" }}>À suivre</span>
              {now.upNext.slice(0, 5).map((t, i) => (
                <span key={`${t.uri}-${i}`} style={{ fontSize: 13, color: "var(--ink)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {t.artist ? `${t.title} · ${t.artist}` : t.title}
                </span>
              ))}
            </div>
          )}
        </div>
      )}
      {error && <span style={{ color: "var(--review)", fontSize: 13 }}>{error}</span>}
    </section>
  );
}

function Glyph({ icon, label, active, onClick }: { icon: IconName; label: string; active?: boolean; onClick: () => void }) {
  return (
    <button type="button" className="icon-btn" title={label} aria-label={label} aria-pressed={active} onClick={onClick}
      style={{ color: active ? "var(--correct)" : undefined }}>
      <Icon name={icon} size={18} />
    </button>
  );
}

function Playlists() {
  const { playlists, now } = useSpotify();
  if (playlists.length === 0) return null;
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      <span className="serif" style={{ fontSize: 16, color: "var(--ink)" }}>Tes playlists</span>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(120px, 1fr))", gap: 14 }}>
        {playlists.map((list) => (
          <button key={list.uri} type="button" title={list.owner ? `${list.name} — ${list.owner}` : list.name} onClick={() => spotifyAccount.play(list.uri)}
            style={{ all: "unset", cursor: "pointer", display: "flex", flexDirection: "column", gap: 6 }}>
            <div style={{ position: "relative", width: 120, height: 120, borderRadius: 8, overflow: "hidden", background: "var(--sheet-raised)", display: "grid", placeItems: "center" }}>
              {list.image ? <img src={list.image} alt="" style={{ width: "100%", height: "100%", objectFit: "cover" }} /> : <Icon name="music.note.list" size={24} />}
              {now.contextURI === list.uri && (
                <span style={{ position: "absolute", right: 6, bottom: 6, background: "rgba(0,0,0,.55)", borderRadius: 12, padding: 4, color: "white", display: "grid" }}>
                  <Icon name="speaker.wave.2" size={12} />
                </span>
              )}
            </div>
            <span style={{ fontSize: 12, fontWeight: 500, color: "var(--ink)", width: 120, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{list.name}</span>
          </button>
        ))}
      </div>
    </section>
  );
}

function LinkField() {
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const play = () => {
    const uri = parseURI(text);
    if (!uri) { setError("Colle un lien Spotify (playlist, album…)."); return; }
    setError(null);
    spotifyAccount.play(uri);
    setText("");
  };
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <span className="serif" style={{ fontSize: 16, color: "var(--ink)" }}>Lancer un lien</span>
      <div style={{ display: "flex", gap: 8 }}>
        <input className="field" style={{ flex: 1 }} placeholder="Lien d'une playlist ou d'un album (Partager › Copier le lien)" value={text}
          onChange={(e) => setText(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") play(); }} />
        <button type="button" className="btn btn-primary" disabled={!text.trim()} onClick={play}>Écouter</button>
      </div>
      {error && <span style={{ color: "var(--wrong)", fontSize: 13 }}>{error}</span>}
    </section>
  );
}

// ── Le lecteur du PC ──

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
    const uri = parseURI(text);
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
      <span className="serif" style={{ fontSize: 16, color: "var(--ink)" }}>Ouvrir dans l'app Spotify</span>
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
    <section style={{ display: "flex", flexDirection: "column", gap: 10, alignItems: "flex-start" }}>
      <span className="serif" style={{ fontSize: 18, color: "var(--ink)" }}>Ce qui joue sur ce PC</span>
      {state === null ? <span>…</span> : !state.available ? (
        <span style={{ color: "var(--ink-secondary)", fontSize: 13 }}>Rien ne joue. Lance ta musique (Spotify, un navigateur…) : elle se pilote ici.</span>
      ) : (
        <>
          <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>{state.title || "Sans titre"}</span>
          <span style={{ color: "var(--ink-secondary)" }}>{[state.artist, appName(state.app)].filter(Boolean).join(" · ")}</span>
          <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
            <button type="button" className="icon-btn" title="Précédent" onClick={() => act("previous")}><Icon name="backward.fill" size={20} /></button>
            <button type="button" className="bar-play" title={state.playing ? "Pause" : "Lecture"} onClick={() => act("toggle")} style={{ width: 54, height: 54 }}>
              <Icon name={state.playing ? "pause.fill" : "play.fill"} size={22} />
            </button>
            <button type="button" className="icon-btn" title="Suivant" onClick={() => act("next")}><Icon name="forward.fill" size={20} /></button>
          </div>
        </>
      )}
    </section>
  );
}
