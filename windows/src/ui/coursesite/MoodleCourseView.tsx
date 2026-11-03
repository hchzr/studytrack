// La page Moodle du cours, lue dans l'app (CoursePane › moodleList + MoodleActivityReader du
// Mac) : les sections à gauche (la semaine en cours en évidence), au centre la section ou
// l'activité ouverte — page, dossier, devoir, forum et ses discussions, document PDF.
// Rien ne sort vers le navigateur : un lien hors de Moodle s'ouvre dans une fenêtre StudyTrack.

import { useCallback, useEffect, useState } from "react";
import type { MoodleActivityContent, MoodleCoursePage, MoodleCoursePageActivity } from "../../domain/siteContent.ts";
import { moodleActivity, moodleCoursePage } from "../../services/moodleReader.ts";
import { MoodleClient } from "../../services/moodleClient.ts";
import { SiteError } from "../../services/siteSession.ts";
import { SeriesPDFStore } from "../../services/seriesPDFStore.ts";
import { listenNative } from "../../native/tauri.ts";
import { Icon, type IconName } from "../icons.tsx";
import { PDFPane } from "../pdf/PDFPane.tsx";
import { SiteHTML } from "../rich/SiteHTML.tsx";
import "../botafogo/botafogo.css";
import "./coursesite.css";

type Load<T> = { kind: "loading" } | { kind: "login" } | { kind: "failed"; message: string } | { kind: "ready"; value: T };

/** Ce qui est ouvert au centre. */
export type MoodleReading =
  | { kind: "section"; number: number }
  | { kind: "activity"; module: string; id: number; title: string }
  | { kind: "pdf"; title: string; address: string };

const pages = new Map<number, MoodleCoursePage>();

function moduleIcon(module: string): IconName {
  switch (module) {
    case "resource": return "doc.text";
    case "folder": return "folder";
    case "url": return "link";
    case "page": return "note.text";
    case "assign": return "tray";
    case "forum": return "person.2";
    case "quiz": return "checklist";
    case "label": return "text.alignleft";
    default: return "square.stack.3d.up";
  }
}

function errorLoad(error: unknown): Load<never> {
  if (error instanceof SiteError && error.kind === "notSignedIn") return { kind: "login" };
  return { kind: "failed", message: error instanceof Error ? error.message : "Moodle ne répond pas." };
}

/** Une adresse Moodle d'activité (`/mod/<module>/view.php?id=…`) → l'activité. */
function activityOf(href: string): { module: string; id: number } | null {
  const match = /\/mod\/(\w+)\/view\.php\?(?:.*&)?id=(\d+)/.exec(href);
  if (match) return { module: match[1], id: Number(match[2]) };
  const discussion = /\/mod\/forum\/discuss\.php\?(?:.*&)?d=(\d+)/.exec(href);
  if (discussion) return { module: "discussion", id: Number(discussion[1]) };
  return null;
}

const isPDFLink = (href: string) => /pluginfile\.php/.test(href) && /\.pdf($|[?#])/i.test(href);

export function MoodleCourseView({ courseID, title, openWeb, reading, onReading }: {
  courseID: number;
  title: string;
  openWeb: (url: string) => void;
  reading: MoodleReading | null;
  onReading: (reading: MoodleReading | null) => void;
}) {
  const [page, setPage] = useState<Load<MoodleCoursePage>>(() => {
    const cached = pages.get(courseID);
    return cached ? { kind: "ready", value: cached } : { kind: "loading" };
  });

  const reload = useCallback(async () => {
    setPage((current) => (current.kind === "ready" ? current : { kind: "loading" }));
    try {
      const value = await moodleCoursePage(courseID);
      pages.set(courseID, value);
      setPage({ kind: "ready", value });
    } catch (error) {
      setPage(errorLoad(error));
    }
  }, [courseID]);

  useEffect(() => { void reload(); }, [reload]);
  // Connecté·e dans la fenêtre de l'école : on relit tout de suite.
  useEffect(() => listenNative<string>("site:signed-in", () => { void reload(); }), [reload]);

  const onLink = (href: string) => {
    const activity = activityOf(href);
    if (activity && href.includes(new URL(MoodleClient.home).host)) {
      onReading({ kind: "activity", ...activity, title: "" });
      return;
    }
    if (isPDFLink(href)) {
      onReading({ kind: "pdf", title: decodeURIComponent(href.split("/").pop()?.split("?")[0] ?? "Document"), address: href });
      return;
    }
    openWeb(href);
  };

  if (page.kind === "loading") return <div className="bf-center">Lecture de la page Moodle…</div>;
  if (page.kind === "login") return <SignIn />;
  if (page.kind === "failed") {
    return (
      <div className="bf-center">
        <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Moodle n'a pas pu être lu</span>
        <span>{page.message}</span>
        <button type="button" className="btn" onClick={() => void reload()}>Réessayer</button>
      </div>
    );
  }

  const course = page.value;
  const current = course.sections.find((section) => section.isCurrent) ?? null;
  const shownSection = reading?.kind === "section" ? reading.number : null;
  return (
    <div className="bf-course">
      <aside className="bf-side">
        <div className="bf-side-top">
          <span className="serif" style={{ fontSize: 15 }}>{course.title || title}</span>
        </div>
        <div className="bf-side-list">
          {course.sections.map((section) => {
            const done = section.activities.filter((activity) => activity.completed).length;
            const counted = section.activities.filter((activity) => activity.module !== "label").length;
            return (
              <button key={section.number} type="button"
                className={`bf-row${shownSection === section.number ? " selected" : ""}`}
                onClick={() => onReading({ kind: "section", number: section.number })}>
                <Icon name={section.isCurrent ? "calendar" : "folder"} size={14} />
                <span style={{ flex: 1, minWidth: 0 }}>
                  {section.title}
                  {section.isCurrent && <span className="bf-detail" style={{ color: "var(--bf-tint, var(--ink))" }}>Cette semaine</span>}
                </span>
                {counted > 0 && <span className="bf-badge mono">{done}/{counted}</span>}
              </button>
            );
          })}
        </div>
      </aside>
      <div className="bf-main">
        {reading === null || reading.kind === "section" ? (
          <SectionView course={course}
            number={reading?.kind === "section" ? reading.number : current?.number ?? course.sections[0]?.number ?? 0}
            onOpen={(activity) => openActivity(activity, onReading, openWeb)} onLink={onLink} />
        ) : reading.kind === "pdf" ? (
          <PDFReading title={reading.title} address={reading.address} back={() => onReading(null)} openWeb={openWeb} />
        ) : (
          <ActivityView module={reading.module} id={reading.id} title={reading.title}
            back={() => onReading(null)} onLink={onLink} openWeb={openWeb} onReading={onReading} />
        )}
      </div>
    </div>
  );
}

function openActivity(activity: MoodleCoursePageActivity, onReading: (r: MoodleReading) => void, openWeb: (url: string) => void) {
  if (activity.isVideo && activity.url) { openWeb(activity.url); return; }
  if (activity.module === "resource") { onReading({ kind: "pdf", title: activity.name, address: activity.url }); return; }
  if (activity.module === "label") return;
  if (["page", "folder", "assign", "forum", "url"].includes(activity.module)) {
    onReading({ kind: "activity", module: activity.module, id: activity.id, title: activity.name });
    return;
  }
  // Quiz, outils externes… : Moodle lui-même, dans une fenêtre de l'app.
  if (activity.url) openWeb(activity.url);
}

function SignIn() {
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="bf-center">
      <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Connecte-toi à Moodle</span>
      <span>Une fois, dans la fenêtre de l'école : elle se ferme seule, et la page du cours s'affiche ici.</span>
      <button type="button" className="btn btn-primary" onClick={() => {
        setError(null);
        void MoodleClient.openLogin().catch((e: unknown) => setError(e instanceof Error ? e.message : "La fenêtre ne s'est pas ouverte."));
      }}>Se connecter</button>
      {error && <span style={{ color: "var(--wrong)" }}>{error}</span>}
    </div>
  );
}

function SectionView({ course, number, onOpen, onLink }: {
  course: MoodleCoursePage; number: number;
  onOpen: (activity: MoodleCoursePageActivity) => void; onLink: (href: string) => void;
}) {
  const section = course.sections.find((item) => item.number === number) ?? course.sections[0];
  if (!section) return <div className="bf-center">Cette page Moodle est vide.</div>;
  return (
    <div className="bf-scroll">
      <article className="bf-page">
        {section.isCurrent && <span className="bf-badge now" style={{ alignSelf: "flex-start" }}>Cette semaine</span>}
        <h1 className="bf-page-title serif">{section.title}</h1>
        {section.summary && <SiteHTML html={section.summary} onLink={onLink} />}
        <div className="ms-activities">
          {section.activities.map((activity) => activity.module === "label" ? (
            <div key={activity.id} className="ms-label"><SiteHTML html={activity.html} onLink={onLink} /></div>
          ) : (
            <button key={activity.id} type="button" className="ms-activity" onClick={() => onOpen(activity)}>
              <Icon name={activity.completed ? "checkmark.circle.fill" : moduleIcon(activity.module)} size={18} />
              <span className="ms-activity-text">
                <span className="ms-activity-name">{activity.name}</span>
                <span className="bf-detail">{[activity.kindLabel, ...activity.dates].filter(Boolean).join(" · ")}</span>
              </span>
              <Icon name="chevron.right" size={13} />
            </button>
          ))}
        </div>
      </article>
    </div>
  );
}

function ActivityView({ module, id, title, back, onLink, openWeb, onReading }: {
  module: string; id: number; title: string; back: () => void;
  onLink: (href: string) => void; openWeb: (url: string) => void; onReading: (reading: MoodleReading) => void;
}) {
  const [content, setContent] = useState<Load<MoodleActivityContent>>({ kind: "loading" });
  useEffect(() => {
    let alive = true;
    setContent({ kind: "loading" });
    moodleActivity(module, id).then(
      (value) => { if (alive) setContent({ kind: "ready", value }); },
      (error: unknown) => { if (alive) setContent(errorLoad(error)); },
    );
    return () => { alive = false; };
  }, [module, id]);

  const bar = (
    <div className="bf-page-bar">
      <button type="button" className="icon-btn" title="Revenir à la section" onClick={back}><Icon name="chevron.left" size={15} /></button>
      <span className="bf-trail">Moodle</span>
    </div>
  );
  if (content.kind === "loading") return <>{bar}<div className="bf-center">Ouverture…</div></>;
  if (content.kind === "login") return <>{bar}<SignIn /></>;
  if (content.kind === "failed") return <>{bar}<div className="bf-center">{content.message}</div></>;
  const value = content.value;
  return (
    <>
      {bar}
      <div className="bf-scroll">
        <article className="bf-page">
          <h1 className="bf-page-title serif">{value.title || title}</h1>
          {value.unavailable && <p className="ms-notice">{value.notice || "Cette activité n'est pas encore ouverte."}</p>}
          {value.dates.length > 0 && <ul className="ms-dates">{value.dates.map((date) => <li key={date}>{date}</li>)}</ul>}
          {value.html && <SiteHTML html={value.html} onLink={onLink} />}
          {value.target && (
            <button type="button" className="bf-media-link" onClick={() => openWeb(value.target!)}>
              <Icon name="link" size={16} /> <span>{value.target}</span>
            </button>
          )}
          {value.files.length > 0 && (
            <div className="ms-activities">
              {value.files.map((file) => (
                <button key={file.url} type="button" className="ms-activity" onClick={() => {
                  if (/\.pdf($|[?#])/i.test(file.url)) onReading({ kind: "pdf", title: file.name, address: file.url });
                  else openWeb(file.url);
                }}>
                  <Icon name="doc.text" size={18} />
                  <span className="ms-activity-text"><span className="ms-activity-name">{file.name}</span></span>
                  <Icon name="chevron.right" size={13} />
                </button>
              ))}
            </div>
          )}
          {value.status.length > 0 && (
            <section className="bf-aside"><header>Remise</header>{value.status.map((line) => <div key={line}>{line}</div>)}</section>
          )}
          {value.discussions.length > 0 && (
            <div className="ms-activities">
              {value.discussions.map((discussion) => (
                <button key={discussion.id} type="button" className="ms-activity"
                  onClick={() => onReading({ kind: "activity", module: "discussion", id: discussion.id, title: discussion.title })}>
                  <Icon name="quote.opening" size={16} />
                  <span className="ms-activity-text">
                    <span className="ms-activity-name">{discussion.title}</span>
                    <span className="bf-detail">{[discussion.author, discussion.date].filter(Boolean).join(" · ")}</span>
                  </span>
                  <Icon name="chevron.right" size={13} />
                </button>
              ))}
            </div>
          )}
          {value.posts.map((post, index) => (
            <section key={index} className="ms-post">
              <header>
                {post.subject && <strong>{post.subject}</strong>}
                <span className="bf-detail">{[post.author, post.date].filter(Boolean).join(" · ")}</span>
              </header>
              <SiteHTML html={post.html} onLink={onLink} />
            </section>
          ))}
        </article>
      </div>
    </>
  );
}

/** Un PDF de Moodle (ou public), téléchargé avec la session et montré ici. */
function PDFReading({ title, address, back, openWeb }: { title: string; address: string; back: () => void; openWeb: (url: string) => void }) {
  const [bytes, setBytes] = useState<Load<Uint8Array>>({ kind: "loading" });
  useEffect(() => {
    let alive = true;
    setBytes({ kind: "loading" });
    let url: URL;
    try { url = new URL(address); } catch { setBytes({ kind: "failed", message: "Adresse illisible." }); return; }
    SeriesPDFStore.download(url).then(
      (value) => { if (alive) setBytes({ kind: "ready", value }); },
      (error: unknown) => {
        if (!alive) return;
        const kind = (error as { kind?: string }).kind;
        if (kind === "notSignedIn") setBytes({ kind: "login" });
        else if (kind === "notPDF") { setBytes({ kind: "failed", message: "Ce n'est pas un PDF : ouvert dans une fenêtre." }); openWeb(address); }
        else setBytes({ kind: "failed", message: error instanceof Error ? error.message : "Téléchargement impossible." });
      },
    );
    return () => { alive = false; };
  }, [address]);
  return (
    <>
      <div className="bf-page-bar">
        <button type="button" className="icon-btn" title="Revenir" onClick={back}><Icon name="chevron.left" size={15} /></button>
        <span className="bf-trail">{title}</span>
      </div>
      <div style={{ flex: 1, minHeight: 0, position: "relative" }}>
        {bytes.kind === "loading" && <div className="bf-center">Téléchargement…</div>}
        {bytes.kind === "login" && <SignIn />}
        {bytes.kind === "failed" && <div className="bf-center">{bytes.message}</div>}
        {bytes.kind === "ready" && <PDFPane bytes={bytes.value} />}
      </div>
    </>
  );
}
