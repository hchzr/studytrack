// Les enregistrements du cours, rangés par semaine et lus dans l'app : la semaine en cours
// d'abord ouverte, une vidéo lue se coche (sur l'élément de théorie qui la cite, sinon ici).

import { useEffect, useState } from "react";
import type { Course } from "../../models/course.ts";
import { useData } from "../../data/dataContext.tsx";
import { cachedRecordings, loadRecordings, type Recording } from "../../services/courseRecordings.ts";
import { entryID, mediaspaceSignIn, playbackURL } from "../../services/mediaspace.ts";
import { listenNative } from "../../native/tauri.ts";
import { Icon } from "../icons.tsx";
import { VideoPlayer } from "../media/VideoPlayer.tsx";
import "../botafogo/botafogo.css";
import "./coursesite.css";

const WATCHED = "recordings.watched";

function localWatched(): Set<string> {
  try { return new Set(JSON.parse(localStorage.getItem(WATCHED) ?? "[]") as string[]); } catch { return new Set(); }
}

const minutes = (seconds: number) => (seconds > 0 ? `${Math.round(seconds / 60)} min` : "");
const day = new Intl.DateTimeFormat("fr-CH", { day: "numeric", month: "short" });

export function RecordingsView({ course }: { course: Course }) {
  const { save } = useData();
  const [recordings, setRecordings] = useState<Recording[] | null>(() => cachedRecordings(course));
  const [needsLogin, setNeedsLogin] = useState(false);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  const [playing, setPlaying] = useState<Recording | null>(null);
  const [watched, setWatched] = useState<Set<string>>(localWatched);
  const current = course.term?.isRunning ? course.currentWeek : null;
  const [open, setOpen] = useState<Set<number | null>>(() => new Set(current !== null ? [current] : []));

  useEffect(() => {
    let alive = true;
    setLoading(true);
    void loadRecordings(course).then((result) => {
      if (!alive) return;
      if (result.recordings.length > 0 || recordings === null) setRecordings(result.recordings);
      setNeedsLogin(result.needsLogin);
    }).finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [course.id, tick]);
  useEffect(() => listenNative<string>("site:signed-in", () => setTick((n) => n + 1)), []);

  /** L'élément de théorie qui cite cette vidéo, s'il y en a un. */
  const itemOf = (recording: Recording) => course.theoryItems.find((item) =>
    entryID(item.urlString) === recording.entryID || item.links.some((link) => entryID(link.url) === recording.entryID)) ?? null;
  const isWatched = (recording: Recording) => itemOf(recording)?.isWatched ?? watched.has(recording.entryID);
  const setSeen = (recording: Recording, value: boolean) => {
    const item = itemOf(recording);
    if (item) {
      item.watchedAt = value ? new Date() : null;
      void save(item);
    }
    const next = new Set(watched);
    if (value) next.add(recording.entryID); else next.delete(recording.entryID);
    try { localStorage.setItem(WATCHED, JSON.stringify([...next])); } catch { /* idem */ }
    setWatched(next);
  };

  const list = recordings ?? [];
  const weeks = [...new Set(list.map((recording) => recording.week))].sort((a, b) => (a ?? 99) - (b ?? 99));
  return (
    <div className="bf-course">
      <aside className="bf-side" style={{ width: 340 }}>
        <div className="bf-side-top">
          <span className="serif" style={{ fontSize: 15 }}>Enregistrements</span>
          <span className="bf-detail">
            {loading ? "Recherche des vidéos du cours…" : `${list.length} vidéo${list.length > 1 ? "s" : ""} · ${list.filter(isWatched).length} vue${list.filter(isWatched).length > 1 ? "s" : ""}`}
          </span>
          {needsLogin && (
            <button type="button" className="btn btn-primary" onClick={() => { void mediaspaceSignIn(); }}>
              Se connecter à MediaSpace pour tout voir
            </button>
          )}
        </div>
        <div className="bf-side-list">
          {weeks.map((week) => {
            const inWeek = list.filter((recording) => recording.week === week);
            const isOpen = open.has(week) || weeks.length === 1;
            const seen = inWeek.filter(isWatched).length;
            return (
              <div key={String(week)}>
                <button type="button" className="bf-disclosure" aria-expanded={isOpen}
                  onClick={() => { const next = new Set(open); if (isOpen) next.delete(week); else next.add(week); setOpen(next); }}>
                  <Icon name={isOpen ? "chevron.down" : "chevron.right"} size={12} strokeWidth={2.4} />
                  <span className="bf-title">{week === null ? "Sans semaine" : `Semaine ${week}`}</span>
                  {week !== null && week === current && <span className="bf-badge now">Cette semaine</span>}
                  <span className="bf-badge mono">{seen}/{inWeek.length}</span>
                </button>
                {isOpen && (
                  <div className="bf-rows">
                    {inWeek.map((recording) => (
                      <button key={recording.entryID} type="button"
                        className={`bf-row${playing?.entryID === recording.entryID ? " selected" : ""}${isWatched(recording) ? " read" : ""}`}
                        onClick={() => setPlaying(recording)}>
                        <Icon name={isWatched(recording) ? "checkmark.circle.fill" : "play.rectangle.fill"} size={14} />
                        <span style={{ flex: 1, minWidth: 0 }}>
                          {recording.title}
                          <span className="bf-detail">{[recording.createdAt ? day.format(recording.createdAt) : null, minutes(recording.durationSeconds)].filter(Boolean).join(" · ")}</span>
                        </span>
                      </button>
                    ))}
                  </div>
                )}
              </div>
            );
          })}
          {!loading && list.length === 0 && !needsLogin && (
            <p style={{ padding: 12, color: "var(--ink-tertiary)", fontSize: 13 }}>
              Aucune vidéo citée par ce cours (Moodle, sources, théorie).
            </p>
          )}
        </div>
      </aside>
      <div className="bf-main">
        {playing ? (
          <Player key={playing.entryID} recording={playing} watched={isWatched(playing)} onWatched={(value) => setSeen(playing, value)} />
        ) : (
          <div className="bf-center">
            <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Les cours filmés</span>
            <span>Choisis une vidéo : elle se lit ici, et se coche une fois vue.</span>
          </div>
        )}
      </div>
    </div>
  );
}

function Player({ recording, watched, onWatched }: { recording: Recording; watched: boolean; onWatched: (value: boolean) => void }) {
  const [src, setSrc] = useState<string | null | "loading">("loading");
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    setSrc("loading");
    void playbackURL(recording.entryID).then((url) => { if (alive) setSrc(url); });
    return () => { alive = false; };
  }, [recording.entryID, tick]);
  useEffect(() => listenNative<string>("site:signed-in", () => setTick((n) => n + 1)), []);
  return (
    <div className="bf-scroll">
      <div className="bf-page" style={{ maxWidth: 1100 }}>
        <h1 className="bf-page-title serif" style={{ fontSize: 22 }}>{recording.title}</h1>
        {src === "loading" && <p className="bf-detail">Préparation de la vidéo…</p>}
        {src === null && (
          <div className="bf-center" style={{ height: "auto", padding: 24 }}>
            <span>Cette vidéo demande la connexion à MediaSpace (SWITCH edu-ID), une fois.</span>
            <button type="button" className="btn btn-primary" onClick={() => { void mediaspaceSignIn(); }}>Se connecter</button>
          </div>
        )}
        {typeof src === "string" && src !== "loading" && <VideoPlayer src={src} onEnded={() => onWatched(true)} />}
        <div style={{ display: "flex", gap: 8 }}>
          <button type="button" className="btn" onClick={() => onWatched(!watched)}>
            <Icon name={watched ? "checkmark.circle.fill" : "circle"} size={14} /> {watched ? "Vue" : "Marquer comme vue"}
          </button>
        </div>
      </div>
    </div>
  );
}
