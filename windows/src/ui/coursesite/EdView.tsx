// Ed Discussion dans l'app (StudyKit/EdViews.swift) : les fils du cours (nouveaux d'abord,
// épinglés et répondus marqués), un fil avec ses réponses et commentaires, répondre, poser
// une question ; les sondages ; les leçons, diapositive par diapositive, avec leurs questions.

import { useEffect, useState, type ReactNode } from "react";
import { EdDiscussion, type EdCourse, type EdLesson, type EdPoll, type EdPost, type EdQuestion, type EdSlide, type EdThread, type SiteBlock } from "../../domain/siteContent.ts";
import { Ed, edForget, edSignIn } from "../../services/edClient.ts";
import { SiteError } from "../../services/siteSession.ts";
import { listenNative } from "../../native/tauri.ts";
import { Icon } from "../icons.tsx";
import { Segmented } from "../kit.tsx";
import { RichInline } from "../rich/RichText.tsx";
import "../botafogo/botafogo.css";
import "./coursesite.css";

type Load<T> = { kind: "loading" } | { kind: "login" } | { kind: "failed"; message: string } | { kind: "ready"; value: T };

function failure(error: unknown): Load<never> {
  if (error instanceof SiteError && error.kind === "notSignedIn") return { kind: "login" };
  return { kind: "failed", message: error instanceof Error ? error.message : "Ed ne répond pas." };
}

function useLoad<T>(load: () => Promise<T>, deps: unknown[]): [Load<T>, () => void] {
  const [state, setState] = useState<Load<T>>({ kind: "loading" });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    setState((current) => (current.kind === "ready" ? current : { kind: "loading" }));
    load().then((value) => { if (alive) setState({ kind: "ready", value }); }, (error: unknown) => { if (alive) setState(failure(error)); });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return [state, () => setTick((n) => n + 1)];
}

const dateFormat = new Intl.DateTimeFormat("fr-CH", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
const when = (iso: string | null) => {
  if (!iso) return "";
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? "" : dateFormat.format(date);
};

/** Les blocs d'un message d'Ed (texte et formules, images, fichiers, liens). */
export function SiteBlocks({ blocks, openWeb }: { blocks: SiteBlock[]; openWeb: (url: string) => void }) {
  return (
    <div className="bf-blocks">
      {blocks.map((block, index) => {
        switch (block.type) {
          case "markdown":
            return block.text.split(/\n{2,}/).map((paragraph, i) => (
              <p key={`${index}-${i}`} className="bf-p" style={{ whiteSpace: "pre-wrap" }}><RichInline text={paragraph} onLink={openWeb} /></p>
            ));
          case "image": return <img key={index} className="bf-img" src={block.url} alt="" loading="lazy" />;
          case "file": case "video": case "link":
            return (
              <button key={index} type="button" className="bf-media-link" onClick={() => openWeb(block.url)}>
                <Icon name={block.type === "video" ? "play.rectangle.fill" : block.type === "file" ? "doc.text" : "link"} size={16} />
                <span>{block.title || block.url}</span>
              </button>
            );
        }
      })}
    </div>
  );
}

function Centered({ children }: { children: ReactNode }) {
  return <div className="bf-center">{children}</div>;
}

function SignIn() {
  const [error, setError] = useState<string | null>(null);
  return (
    <Centered>
      <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Connecte-toi à Ed</span>
      <span>Une fois, dans la fenêtre d'Ed : elle se ferme seule, et les discussions du cours s'affichent ici.</span>
      <button type="button" className="btn btn-primary" onClick={() => {
        setError(null);
        void edSignIn().catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
      }}>Se connecter à Ed</button>
      {error && <span style={{ color: "var(--wrong)" }}>{error}</span>}
    </Centered>
  );
}

export function EdView({ code, openWeb }: { code: string; openWeb: (url: string) => void }) {
  const [courses, reload] = useLoad<EdCourse[]>(() => Ed.courses(), []);
  useEffect(() => listenNative<string>("ed:signed-in", () => { edForget(); reload(); }), [reload]);
  const [part, setPart] = useState<"threads" | "lessons">("threads");

  if (courses.kind === "loading") return <Centered>Lecture d'Ed…</Centered>;
  if (courses.kind === "login") return <SignIn />;
  if (courses.kind === "failed") return <Centered>{courses.message}<button type="button" className="btn" onClick={reload}>Réessayer</button></Centered>;
  const course = EdDiscussion.match(code, courses.value);
  if (!course) return <Centered>Pas de cours Ed trouvé pour {code}.</Centered>;
  return (
    <div className="cs-pane">
      <div className="cs-sources">
        <span className="serif" style={{ fontSize: 15, flex: 1 }}>{course.name || course.code}</span>
        <Segmented ariaLabel="Ed" value={part} onChange={setPart}
          options={[{ value: "threads", label: "Discussions" }, { value: "lessons", label: "Leçons" }]} />
      </div>
      <div className="cs-body">
        {part === "threads" ? <Threads course={course.id} openWeb={openWeb} /> : <Lessons course={course.id} openWeb={openWeb} />}
      </div>
    </div>
  );
}

// MARK: Les fils

function Threads({ course, openWeb }: { course: number; openWeb: (url: string) => void }) {
  const [threads, reload] = useLoad<EdThread[]>(() => Ed.threads(course), [course]);
  const [open, setOpen] = useState<number | "new" | null>(null);
  const [query, setQuery] = useState("");
  if (threads.kind !== "ready") {
    return threads.kind === "login" ? <SignIn /> : <Centered>{threads.kind === "failed" ? threads.message : "Lecture des discussions…"}</Centered>;
  }
  const needle = query.trim().toLowerCase();
  const shown = threads.value.filter((thread) => needle === "" || thread.title.toLowerCase().includes(needle) || (thread.category ?? "").toLowerCase().includes(needle));
  return (
    <div className="bf-course">
      <aside className="bf-side" style={{ width: 330 }}>
        <div className="bf-side-top">
          <div style={{ display: "flex", gap: 8 }}>
            <input className="field" type="search" placeholder="Chercher" value={query} onChange={(e) => setQuery(e.target.value)} style={{ flex: 1 }} />
            <button type="button" className="btn btn-primary" onClick={() => setOpen("new")}><Icon name="plus" size={14} /> Question</button>
          </div>
        </div>
        <div className="bf-side-list">
          {shown.map((thread) => (
            <button key={thread.id} type="button" className={`bf-row${open === thread.id ? " selected" : ""}`} onClick={() => setOpen(thread.id)}>
              <Icon name={thread.isPinned ? "bookmark" : thread.type === "question" ? (thread.isAnswered ? "checkmark.circle.fill" : "questionmark") : "quote.opening"} size={14} />
              <span style={{ flex: 1, minWidth: 0 }}>
                <RichInline text={thread.title} />
                <span className="bf-detail">{[thread.category, when(thread.createdAt), thread.replyCount ? `${thread.replyCount} rép.` : null].filter(Boolean).join(" · ")}</span>
              </span>
            </button>
          ))}
        </div>
      </aside>
      <div className="bf-main">
        {open === "new" ? <NewThread course={course} done={(id) => { reload(); setOpen(id); }} cancel={() => setOpen(null)} />
          : open !== null ? <ThreadView key={open} id={open} openWeb={openWeb} />
            : <Centered>Choisis une discussion, ou pose une question.</Centered>}
      </div>
    </div>
  );
}

function ThreadView({ id, openWeb }: { id: number; openWeb: (url: string) => void }) {
  const [post, reload] = useLoad<EdPost | null>(() => Ed.thread(id), [id]);
  if (post.kind !== "ready") return post.kind === "login" ? <SignIn /> : <Centered>{post.kind === "failed" ? post.message : "Ouverture…"}</Centered>;
  if (!post.value) return <Centered>Discussion illisible.</Centered>;
  const root = post.value;
  return (
    <div className="bf-scroll">
      <article className="bf-page">
        <PostCard post={root} openWeb={openWeb} root />
        {EdDiscussion.pollIDs(root.content).map((poll) => <Poll key={poll} id={poll} />)}
        {root.replies.map((reply) => <Reply key={reply.id} post={reply} openWeb={openWeb} onSent={reload} />)}
        <Composer label="Répondre" onSend={async (text, answer) => { await Ed.reply({ thread: id }, text, answer); reload(); }} allowAnswer />
      </article>
    </div>
  );
}

function PostCard({ post, openWeb, root = false }: { post: EdPost; openWeb: (url: string) => void; root?: boolean }) {
  return (
    <section className={root ? "" : "ms-post"} style={post.isEndorsed ? { borderColor: "var(--correct)" } : undefined}>
      <header style={{ display: "flex", gap: 8, alignItems: "baseline", marginBottom: 6 }}>
        <strong>{post.author}</strong>
        <span className="bf-detail">{when(post.date)}</span>
        {post.isAnswer && <span className="bf-badge now">Réponse</span>}
        {post.isEndorsed && <span className="bf-badge" style={{ color: "var(--correct)" }}>Validée</span>}
      </header>
      <SiteBlocks blocks={EdDiscussion.blocks(post.content)} openWeb={openWeb} />
    </section>
  );
}

function Reply({ post, openWeb, onSent }: { post: EdPost; openWeb: (url: string) => void; onSent: () => void }) {
  const [replying, setReplying] = useState(false);
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <PostCard post={post} openWeb={openWeb} />
      <div style={{ marginLeft: 22, display: "flex", flexDirection: "column", gap: 8 }}>
        {post.replies.map((inner) => <PostCard key={inner.id} post={inner} openWeb={openWeb} />)}
        {replying
          ? <Composer label="Commenter" onSend={async (text) => { await Ed.reply({ comment: post.id }, text, false); setReplying(false); onSent(); }} onCancel={() => setReplying(false)} />
          : <button type="button" className="link-btn" style={{ alignSelf: "flex-start" }} onClick={() => setReplying(true)}>Commenter</button>}
      </div>
    </div>
  );
}

function Composer({ label, onSend, onCancel, allowAnswer = false }: {
  label: string; onSend: (text: string, isAnswer: boolean) => Promise<void>; onCancel?: () => void; allowAnswer?: boolean;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const send = async (answer: boolean) => {
    setBusy(true);
    setError(null);
    try { await onSend(text, answer); setText(""); } catch (e) { setError(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <textarea className="field" rows={4} value={text} placeholder="Markdown et formules $…$ acceptés" onChange={(e) => setText(e.target.value)} />
      {error && <span style={{ color: "var(--wrong)", fontSize: 12 }}>{error}</span>}
      <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
        {onCancel && <button type="button" className="btn" onClick={onCancel}>Annuler</button>}
        {allowAnswer && <button type="button" className="btn" disabled={busy || !text.trim()} onClick={() => void send(false)}>Commenter</button>}
        <button type="button" className="btn btn-primary" disabled={busy || !text.trim()} onClick={() => void send(allowAnswer)}>{busy ? "Envoi…" : label}</button>
      </div>
    </div>
  );
}

function NewThread({ course, done, cancel }: { course: number; done: (id: number | null) => void; cancel: () => void }) {
  const [categories] = useLoad<string[]>(() => Ed.categories(course), [course]);
  const [title, setTitle] = useState("");
  const [category, setCategory] = useState("");
  const [text, setText] = useState("");
  const [question, setQuestion] = useState(true);
  const [anonymous, setAnonymous] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const list = categories.kind === "ready" ? categories.value : [];
  const chosen = category || list[0] || "General";
  return (
    <div className="bf-scroll">
      <div className="bf-page" style={{ gap: 12 }}>
        <h1 className="bf-page-title serif">Nouvelle {question ? "question" : "publication"}</h1>
        <Segmented ariaLabel="Type" value={question ? "q" : "p"} onChange={(v) => setQuestion(v === "q")}
          options={[{ value: "q", label: "Question" }, { value: "p", label: "Publication" }]} />
        <input className="field" placeholder="Titre" value={title} onChange={(e) => setTitle(e.target.value)} />
        {list.length > 0 && (
          <select className="select" value={chosen} onChange={(e) => setCategory(e.target.value)}>
            {list.map((name) => <option key={name} value={name}>{name}</option>)}
          </select>
        )}
        <textarea className="field" rows={10} placeholder="Ton message (Markdown, formules $…$)" value={text} onChange={(e) => setText(e.target.value)} />
        <label style={{ display: "flex", gap: 8, alignItems: "center", fontSize: 13 }}>
          <input type="checkbox" checked={anonymous} onChange={(e) => setAnonymous(e.target.checked)} /> Anonyme pour les autres étudiant·es
        </label>
        {error && <span style={{ color: "var(--wrong)" }}>{error}</span>}
        <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
          <button type="button" className="btn" onClick={cancel}>Annuler</button>
          <button type="button" className="btn btn-primary" disabled={busy || !title.trim() || !text.trim()} onClick={() => {
            setBusy(true);
            setError(null);
            Ed.postThread(course, { title: title.trim(), category: chosen, markdown: text, isQuestion: question, isPrivate: false, isAnonymous: anonymous })
              .then(done, (e: unknown) => setError(e instanceof Error ? e.message : String(e)))
              .finally(() => setBusy(false));
          }}>{busy ? "Envoi…" : "Publier sur Ed"}</button>
        </div>
      </div>
    </div>
  );
}

function Poll({ id }: { id: number }) {
  const [poll, reload] = useLoad<EdPoll | null>(() => Ed.poll(id), [id]);
  const [picked, setPicked] = useState<Set<number>>(new Set());
  if (poll.kind !== "ready" || !poll.value) return null;
  const value = poll.value;
  const voted = value.chosen !== null;
  return (
    <section className="bf-quiz">
      <header className="serif"><RichInline text={value.question || "Sondage"} /></header>
      <div className="bf-quiz-choices">
        {value.options.map((option, index) => (
          <button key={index} type="button" className={`bf-choice${picked.has(index) || value.chosen?.includes(index) ? " picked" : ""}`}
            disabled={voted || value.isClosed}
            onClick={() => {
              const next = new Set(value.multipleChoice ? picked : []);
              if (picked.has(index)) next.delete(index); else next.add(index);
              setPicked(next);
            }}>
            <span style={{ flex: 1 }}><RichInline text={option} /></span>
            {value.showsResults && <span className="mono bf-detail">{Math.round(value.share(index) * 100)} %</span>}
          </button>
        ))}
      </div>
      {!voted && !value.isClosed && (
        <div className="bf-quiz-actions">
          <button type="button" className="btn btn-primary" disabled={picked.size === 0}
            onClick={() => { void Ed.vote(id, [...picked]).then(reload); }}>Voter</button>
        </div>
      )}
    </section>
  );
}

// MARK: Les leçons

function Lessons({ course, openWeb }: { course: number; openWeb: (url: string) => void }) {
  const [lessons] = useLoad<EdLesson[]>(() => Ed.lessons(course), [course]);
  const [open, setOpen] = useState<EdLesson | null>(null);
  if (lessons.kind !== "ready") return lessons.kind === "login" ? <SignIn /> : <Centered>{lessons.kind === "failed" ? lessons.message : "Lecture des leçons…"}</Centered>;
  if (lessons.value.length === 0) return <Centered>Pas de leçon sur Ed pour ce cours.</Centered>;
  return (
    <div className="bf-course">
      <aside className="bf-side">
        <div className="bf-side-list" style={{ paddingTop: 10 }}>
          {lessons.value.map((lesson) => (
            <button key={lesson.id} type="button" className={`bf-row${open?.id === lesson.id ? " selected" : ""}`} onClick={() => setOpen(lesson)}>
              <Icon name={lesson.status === "completed" ? "checkmark.circle.fill" : "book"} size={14} />
              <span style={{ flex: 1, minWidth: 0 }}>{lesson.title}{lesson.module && <span className="bf-detail">{lesson.module}</span>}</span>
            </button>
          ))}
        </div>
      </aside>
      <div className="bf-main">
        {open ? <LessonView key={open.id} lesson={open} openWeb={openWeb} /> : <Centered>Choisis une leçon.</Centered>}
      </div>
    </div>
  );
}

function LessonView({ lesson, openWeb }: { lesson: EdLesson; openWeb: (url: string) => void }) {
  const [slides] = useLoad<EdSlide[]>(() => Ed.slides(lesson.id), [lesson.id]);
  const [index, setIndex] = useState(0);
  const slide = slides.kind === "ready" ? slides.value[index] : undefined;
  useEffect(() => { if (slide && slide.type !== "quiz") void Ed.complete(slide.id); }, [slide?.id]);
  if (slides.kind !== "ready") return <Centered>{slides.kind === "failed" ? slides.message : "Ouverture…"}</Centered>;
  if (!slide) return <Centered>Leçon vide.</Centered>;
  const total = slides.value.length;
  return (
    <>
      <div className="bf-page-bar">
        <span className="bf-trail">{lesson.title} · {index + 1}/{total}</span>
        <button type="button" className="icon-btn" disabled={index === 0} onClick={() => setIndex(index - 1)}><Icon name="chevron.left" size={15} /></button>
        <button type="button" className="icon-btn" disabled={index + 1 >= total} onClick={() => setIndex(index + 1)}><Icon name="chevron.right" size={15} /></button>
      </div>
      <div className="bf-scroll">
        <article className="bf-page">
          <h1 className="bf-page-title serif">{slide.title || lesson.title}</h1>
          <SiteBlocks blocks={EdDiscussion.blocks(slide.content)} openWeb={openWeb} />
          {slide.type === "quiz" && <SlideQuestions slide={slide.id} openWeb={openWeb} />}
        </article>
      </div>
    </>
  );
}

function SlideQuestions({ slide, openWeb }: { slide: number; openWeb: (url: string) => void }) {
  const [questions] = useLoad<EdQuestion[]>(() => Ed.questions(slide), [slide]);
  if (questions.kind !== "ready") return null;
  return <>{questions.value.map((question) => <QuestionCard key={question.id} question={question} openWeb={openWeb} />)}</>;
}

function QuestionCard({ question, openWeb }: { question: EdQuestion; openWeb: (url: string) => void }) {
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [text, setText] = useState("");
  const [result, setResult] = useState<{ correct: boolean | null; explanation: string | null } | null>(null);
  const choice = question.kind === "choice-multiple" || question.kind === "choice-single";
  return (
    <section className="bf-quiz">
      <SiteBlocks blocks={EdDiscussion.blocks(question.content)} openWeb={openWeb} />
      {choice ? (
        <div className="bf-quiz-choices">
          {question.answers.map((answer, index) => (
            <button key={index} type="button" className={`bf-choice${picked.has(index) ? " picked" : ""}`} onClick={() => {
              const next = new Set(question.kind === "choice-multiple" ? picked : []);
              if (picked.has(index)) next.delete(index); else next.add(index);
              setPicked(next);
            }}>
              <span><RichInline text={answer} /></span>
            </button>
          ))}
        </div>
      ) : (
        <input className="field" value={text} placeholder="Ta réponse" onChange={(e) => setText(e.target.value)} />
      )}
      {result && (
        <p style={{ margin: 0, color: result.correct === true ? "var(--correct)" : result.correct === false ? "var(--wrong)" : "var(--ink-secondary)" }}>
          {result.correct === true ? "Juste." : result.correct === false ? "Pas tout à fait." : "Réponse envoyée."}
          {result.explanation && <> <RichInline text={result.explanation} /></>}
        </p>
      )}
      <div className="bf-quiz-actions">
        <button type="button" className="btn btn-primary" disabled={choice ? picked.size === 0 : !text.trim()}
          onClick={() => { void Ed.answer(question.id, EdDiscussion.response(picked, text, question.kind)).then(setResult, () => setResult({ correct: null, explanation: "Ed a refusé la réponse." })); }}>
          Vérifier
        </button>
      </div>
    </section>
  );
}
