// Courseware (Open edX) dans l'app (StudyKit/CoursewareViews.swift) : le plan à gauche
// (chapitres, séquences, unités, ce qui est fait), au centre l'unité — ses vidéos lues ici,
// ses textes, ses problèmes à résoudre et vérifier par Courseware.

import { useEffect, useState } from "react";
import { SiteHTML as SiteHTMLParser, type EdXBlock, type EdXOutline, type EdXProblem, type EdXProblemResult, type EdXUnit } from "../../domain/siteContent.ts";
import { Courseware, coursewareSignIn } from "../../services/coursewareClient.ts";
import { SiteError } from "../../services/siteSession.ts";
import { listenNative } from "../../native/tauri.ts";
import { Icon } from "../icons.tsx";
import { VideoPlayer } from "../media/VideoPlayer.tsx";
import { SiteBlocks } from "../rich/SiteBlocks.tsx";
import { SiteHTML } from "../rich/SiteHTML.tsx";
import "../botafogo/botafogo.css";
import "./coursesite.css";

type Load<T> = { kind: "loading" } | { kind: "login" } | { kind: "failed"; message: string } | { kind: "ready"; value: T };

function failure(error: unknown): Load<never> {
  if (error instanceof SiteError && error.kind === "notSignedIn") return { kind: "login" };
  return { kind: "failed", message: error instanceof Error ? error.message : "Courseware ne répond pas." };
}

function SignIn() {
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="bf-center">
      <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Connecte-toi à Courseware</span>
      <span>Une fois, dans la fenêtre de l'école : elle se ferme seule, et le cours s'affiche ici.</span>
      <button type="button" className="btn btn-primary" onClick={() => {
        setError(null);
        void coursewareSignIn().catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
      }}>Se connecter</button>
      {error && <span style={{ color: "var(--wrong)" }}>{error}</span>}
    </div>
  );
}

const opened = new Map<string, string>();

export function CoursewareView({ courseKey, openWeb }: { courseKey: string; openWeb: (url: string) => void }) {
  const [outline, setOutline] = useState<Load<EdXOutline>>({ kind: "loading" });
  const [tick, setTick] = useState(0);
  const [unitID, setUnitID] = useState<string | null>(() => opened.get(courseKey) ?? null);
  useEffect(() => {
    let alive = true;
    Courseware.outline(courseKey).then((value) => { if (alive) setOutline({ kind: "ready", value }); }, (e: unknown) => { if (alive) setOutline(failure(e)); });
    return () => { alive = false; };
  }, [courseKey, tick]);
  useEffect(() => listenNative<string>("site:signed-in", () => setTick((n) => n + 1)), []);

  if (outline.kind === "loading") return <div className="bf-center">Lecture du plan de Courseware…</div>;
  if (outline.kind === "login") return <SignIn />;
  if (outline.kind === "failed") return <div className="bf-center">{outline.message}<button type="button" className="btn" onClick={() => setTick((n) => n + 1)}>Réessayer</button></div>;
  const plan = outline.value;
  const units = plan.units;
  const unit = units.find((item) => item.id === unitID) ?? null;
  const open = (id: string) => { opened.set(courseKey, id); setUnitID(id); };
  const index = unit ? units.indexOf(unit) : -1;
  return (
    <div className="bf-course">
      <aside className="bf-side">
        <div className="bf-side-list" style={{ paddingTop: 10 }}>
          {plan.chapters.map((chapter) => (
            <div key={chapter.id}>
              <div className="bf-group-title serif">{chapter.title}</div>
              {chapter.sequences.map((sequence) => (
                <div key={sequence.id}>
                  <div className="bf-detail" style={{ padding: "6px 8px 2px" }}>{sequence.title}</div>
                  <div className="bf-rows">
                    {sequence.units.map((item) => (
                      <button key={item.id} type="button" className={`bf-row${item.id === unitID ? " selected" : ""}${item.completed ? " read" : ""}`} onClick={() => open(item.id)}>
                        <Icon name={item.completed ? "checkmark.circle.fill" : unitIcon(item)} size={14} />
                        <span style={{ flex: 1, minWidth: 0 }}>{item.title}</span>
                      </button>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          ))}
        </div>
      </aside>
      <div className="bf-main">
        {unit ? (
          <div className="bf-scroll">
            <article className="bf-page">
              <span className="bf-trail">{(() => { const place = plan.place(unit.id); return place ? `${place.chapter.title} › ${place.sequence.title}` : ""; })()}</span>
              <h1 className="bf-page-title serif">{unit.title}</h1>
              {unit.blocks.map((block) => <Block key={block.id} block={block} courseKey={courseKey} openWeb={openWeb} />)}
              <div className="bf-neighbours">
                {index > 0 ? <button type="button" className="bf-neighbour" onClick={() => open(units[index - 1].id)}><small>Précédent</small>{units[index - 1].title}</button> : <span style={{ flex: 1 }} />}
                {index + 1 < units.length ? <button type="button" className="bf-neighbour next" onClick={() => open(units[index + 1].id)}><small>Suivant</small>{units[index + 1].title}</button> : <span style={{ flex: 1 }} />}
              </div>
            </article>
          </div>
        ) : (
          <div className="bf-center">
            <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Courseware</span>
            {plan.resumeUnit && <button type="button" className="btn btn-primary" onClick={() => open(plan.resumeUnit!.id)}>Reprendre : {plan.resumeUnit.title}</button>}
          </div>
        )}
      </div>
    </div>
  );
}

function unitIcon(unit: EdXUnit) {
  if (unit.blocks.some((block) => block.kind === "problem")) return "checklist" as const;
  if (unit.blocks.some((block) => block.kind === "video")) return "play.rectangle.fill" as const;
  return "doc.text" as const;
}

function Block({ block, courseKey, openWeb }: { block: EdXBlock; courseKey: string; openWeb: (url: string) => void }) {
  if (block.kind === "video") {
    if (block.youTubeID && !block.videoURL) {
      return (
        <button type="button" className="bf-media-link" onClick={() => openWeb(`https://www.youtube.com/watch?v=${block.youTubeID}`)}>
          <Icon name="play.rectangle.fill" size={16} /> <span>{block.title || "Vidéo"}</span><span className="bf-media-host">YouTube</span>
        </button>
      );
    }
    if (!block.videoURL) return null;
    return (
      <figure className="bf-video">
        <VideoPlayer src={block.videoURL} onEnded={() => { void Courseware.complete(block.id, courseKey); }} />
        {block.title && <figcaption>{block.title}</figcaption>}
      </figure>
    );
  }
  if (block.kind === "problem" && block.viewURL) return <Problem address={block.viewURL} openWeb={openWeb} />;
  if (block.viewURL) return <HTMLBlock address={block.viewURL} openWeb={openWeb} />;
  return null;
}

function HTMLBlock({ address, openWeb }: { address: string; openWeb: (url: string) => void }) {
  const [html, setHTML] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    Courseware.blockHTML(address).then((value) => { if (alive) setHTML(value); }, () => { if (alive) setHTML(""); });
    return () => { alive = false; };
  }, [address]);
  if (html === null) return <p className="bf-detail">Chargement…</p>;
  if (html === "") return null;
  let base: URL | null = null;
  try { base = new URL(address); } catch { /* relative */ }
  return <SiteBlocks blocks={SiteHTMLParser.blocks(html, base)} openWeb={openWeb} />;
}

function Problem({ address, openWeb }: { address: string; openWeb: (url: string) => void }) {
  const [problem, setProblem] = useState<EdXProblem | null | "loading">("loading");
  const [answers, setAnswers] = useState<Record<string, string[]>>({});
  const [result, setResult] = useState<EdXProblemResult | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let alive = true;
    Courseware.problem(address).then((value) => {
      if (!alive) return;
      setProblem(value);
      if (value) {
        const initial: Record<string, string[]> = {};
        for (const group of value.groups) {
          const checked = group.options.filter((option) => option.checked).map((option) => option.value);
          initial[group.name] = checked.length > 0 ? checked : group.value ? [group.value] : [];
        }
        setAnswers(initial);
      }
    }, () => { if (alive) setProblem(null); });
    return () => { alive = false; };
  }, [address]);
  if (problem === "loading") return <p className="bf-detail">Chargement du problème…</p>;
  if (!problem) return null;
  const set = (name: string, values: string[]) => setAnswers({ ...answers, [name]: values });
  return (
    <section className="bf-quiz">
      {problem.title && <header className="serif">{problem.title}</header>}
      <SiteHTML html={problem.prompt} onLink={openWeb} />
      {problem.groups.map((group) => (
        <div key={group.name} className="bf-quiz-choices">
          {group.type === "select" ? (
            <select className="select" value={answers[group.name]?.[0] ?? ""} onChange={(e) => set(group.name, [e.target.value])}>
              <option value="">Choisir…</option>
              {group.options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          ) : group.type === "checkbox" || group.type === "radio" ? group.options.map((option) => {
            const on = answers[group.name]?.includes(option.value) ?? false;
            return (
              <button key={option.value} type="button" className={`bf-choice${on ? " picked" : ""}`} onClick={() => {
                const current = answers[group.name] ?? [];
                set(group.name, group.type === "radio" ? [option.value] : on ? current.filter((v) => v !== option.value) : [...current, option.value]);
              }}>
                <span className="bf-choice-box" aria-hidden>{on ? "●" : ""}</span>
                <SiteHTML html={option.label} onLink={openWeb} />
              </button>
            );
          }) : (
            <input className="field" value={answers[group.name]?.[0] ?? ""} onChange={(e) => set(group.name, [e.target.value])} placeholder="Ta réponse" />
          )}
        </div>
      ))}
      {result && (
        <p style={{ margin: 0, color: result.isCorrect ? "var(--correct)" : result.verdict === "partially-correct" ? "var(--review)" : "var(--wrong)" }}>
          {result.isCorrect ? "Juste." : result.verdict === "partially-correct" ? "En partie juste." : "Pas encore."}
          {result.score !== null && result.total !== null && ` ${result.score}/${result.total}`}
        </p>
      )}
      <div className="bf-quiz-actions">
        <button type="button" className="btn btn-primary" disabled={busy} onClick={() => {
          setBusy(true);
          void Courseware.check(problem, answers).then(setResult, () => setResult({ verdict: "erreur", score: null, total: null, isCorrect: false })).finally(() => setBusy(false));
        }}>{busy ? "Vérification…" : "Vérifier"}</button>
      </div>
    </section>
  );
}
