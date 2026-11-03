// Claude dans le bureau (ClaudePane du Mac) : une conversation **par série**, gardée d'un
// lancement à l'autre par Claude Code. Elle connaît la série (PDF joint au début), l'exercice
// en cours et ses questions cochées ; changer d'exercice reste dans la même conversation.
// Par l'abonnement Claude de l'étudiant·e, pas d'une clé d'API.

import { useEffect, useMemo, useRef, useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { Exercise, ExerciseSeries } from "../../../models/exercise.ts";
import { ClaudeTutor, type ClaudeContext, type SeriesContext } from "../../../domain/claudeTutor.ts";
import { ClaudeConversation, claudeSetup, type ChatMessage } from "../../../services/claudeConversation.ts";
import { FreeTutorConversation } from "../../../services/freeTutor.ts";
import { linesFromData, plainText } from "../../../services/pdfLayoutExtractor.ts";
import { SeriesPDFStore } from "../../../services/seriesPDFStore.ts";
import { Icon } from "../../icons.tsx";
import { RichInline } from "../../rich/RichText.tsx";
import { openInApp } from "../openers.ts";

type Conversation = ClaudeConversation | FreeTutorConversation;
const conversations = new Map<string, Conversation>();
/** L'exercice dont Claude a déjà le contexte, par conversation. */
const announced = new Map<string, string>();

function seriesContext(course: Course, series: ExerciseSeries, pdf: boolean): SeriesContext {
  return {
    courseCode: course.displayCode, courseName: course.name,
    title: series.title || `Série ${series.seriesNumber}`, week: series.plannedWeek || null,
    exercises: series.sortedExercises.map((exercise) => ({
      number: exercise.exerciseNumber, title: exercise.title,
      status: exercise.isDone ? "fait" : exercise.subQuestions.some((q) => q.isDone) ? "commencé" : "pas commencé",
    })),
    pdfAttached: pdf,
  };
}

function exerciseContext(course: Course, exercise: Exercise): ClaudeContext {
  const questions = exercise.leafSubQuestions;
  return {
    courseCode: course.displayCode, courseName: course.name,
    exercise: exercise.displayNumber + (exercise.title && exercise.title !== exercise.displayNumber ? ` — ${exercise.title}` : ""),
    statement: exercise.statement || null,
    questions: questions.map((question) => question.text || question.label),
    doneQuestions: questions.filter((question) => question.isDone).length,
    hint: exercise.hint || null,
  };
}

function useConversation(key: string | null, make: () => Conversation): Conversation | null {
  const conversation = useMemo(() => {
    if (key === null) return null;
    let found = conversations.get(key);
    if (!found) {
      found = make();
      conversations.set(key, found);
      void found.loadHistory();
    }
    return found;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  const [, bump] = useState(0);
  useEffect(() => conversation?.subscribe(() => bump((n) => n + 1)), [conversation]);
  return conversation;
}

export function ClaudePane({ course, series, exercise, tint, general = false, context = "" }: {
  course: Course | null; series: ExerciseSeries | null; exercise: Exercise | null; tint: string;
  /** La page « Claude » : une conversation libre (le semestre en contexte), sans série. */
  general?: boolean; context?: string;
}) {
  const [installed, setInstalled] = useState<boolean | null>(null);
  useEffect(() => { void claudeSetup().then((info) => setInstalled(info?.found ?? false)); }, []);
  // Claude Code sur le PC : Claude par l'abonnement. Sinon : le tuteur gratuit du serveur.
  const free = installed === false;
  const key = installed === null ? null
    : general ? `general:${free ? "free" : "claude"}`
    : series ? `series:${series.id}:${free ? "free" : "claude"}` : null;
  const conversation = useConversation(key, () => free
    ? new FreeTutorConversation(key!)
    : new ClaudeConversation(key!, ClaudeTutor.sessionID(general ? "general" : series!.id, "isolated"), ClaudeTutor.systemPrompt("tutor")));
  const [text, setText] = useState("");
  const scroller = useRef<HTMLDivElement | null>(null);
  useEffect(() => { scroller.current?.scrollTo({ top: scroller.current.scrollHeight }); }, [conversation?.messages.length, conversation?.messages[conversation.messages.length - 1]?.text]);

  if (!conversation || (!general && (!course || !series))) {
    return <div className="bf-center">{installed === null ? "…" : "Choisis une série : Claude t'accompagne exercice par exercice."}</div>;
  }

  const send = async (shown: string) => {
    const value = shown.trim();
    if (!value || conversation.busy) return;
    setText("");
    let prefix = "";
    const attachments = [];
    if (general || !course || !series) {
      // La page Claude : le semestre en contexte au premier message, puis la conversation.
      const opening = conversation.messages.length === 0 && context ? `[StudyTrack]\n${context}\n[/StudyTrack]\n\n` : "";
      await conversation.send(value, opening + value);
      return;
    }
    if (conversation.messages.length === 0) {
      // Le début : la série entière (et son PDF s'il est sur l'appareil), l'exercice en cours.
      // Claude lit le PDF joint ; le tuteur gratuit en reçoit le texte.
      const pdf = await SeriesPDFStore.localFile(series.id).catch(() => null);
      let pdfText = "";
      if (pdf && conversation instanceof FreeTutorConversation) {
        pdfText = await linesFromData(pdf).then(plainText).catch(() => "");
      } else if (pdf) {
        attachments.push({ kind: { type: "pdf" as const }, data: pdf, name: `${series.title || "Série"}.pdf` });
      }
      prefix = ClaudeTutor.openingMessage(seriesContext(course, series, pdf !== null), exercise ? exerciseContext(course, exercise) : null, null) + "\n\n"
        + (pdfText ? `[StudyTrack]\nTexte de l'énoncé (PDF de la série) :\n${pdfText.slice(0, 40_000)}\n[/StudyTrack]\n\n` : "");
      if (exercise) announced.set(conversation.key, exercise.id);
    } else if (exercise && announced.get(conversation.key) !== exercise.id) {
      prefix = ClaudeTutor.exerciseSwitch(exerciseContext(course, exercise));
      announced.set(conversation.key, exercise.id);
    }
    if (conversation instanceof ClaudeConversation) await conversation.send(value, prefix + value, attachments);
    else await conversation.send(value, prefix + value);
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", minHeight: 0 }}>
      <div className="bf-page-bar">
        <Icon name="sparkles" size={15} />
        <span className="bf-trail" style={{ color: "var(--ink)" }}>{free ? "Tuteur" : "Claude"}{series ? ` · ${series.title || `Série ${series.seriesNumber}`}` : ""}{exercise ? ` · ${exercise.displayNumber}` : ""}</span>
        {free && (
          <button type="button" className="link-btn" title="Claude (par ton abonnement) répond mieux et lit le PDF de la série"
            onClick={() => { void openInApp("https://claude.com/product/claude-code", "Claude Code"); }}>
            Gratuit{conversation instanceof FreeTutorConversation && conversation.model ? ` · ${conversation.model}` : ""} — passer à Claude
          </button>
        )}
        {conversation.activity && <span className="bf-detail">{conversation.activity}</span>}
      </div>
      <div ref={scroller} style={{ flex: 1, overflowY: "auto", padding: "18px 24px", display: "flex", flexDirection: "column", gap: 14 }}>
        {conversation.messages.length === 0 && (
          <div style={{ color: "var(--ink-secondary)", fontSize: 14, maxWidth: 560 }}>
            {general ? "Pose ta question : Claude connaît tes cours et ce qui t'attend cette semaine." : <>Pose ta question, ou commence par une action ci-dessous. Claude a la série{exercise ? `, ${exercise.displayNumber}` : ""} et ce que tu as coché ; il guide plutôt que de donner la réponse.</>}
          </div>
        )}
        {conversation.messages.map((message, index) => <Bubble key={index} message={message} tint={tint} />)}
        {conversation.error && <div style={{ color: "var(--wrong)", fontSize: 13 }}>{conversation.error}</div>}
      </div>
      <div style={{ display: "flex", gap: 6, flexWrap: "wrap", padding: "0 18px 8px" }}>
        {!general && Object.values(ClaudeTutor.quickActions).map((action) => (
          <button key={action.label} type="button" className="btn" disabled={conversation.busy} onClick={() => { void send(action.prompt); }}>
            {action.label}
          </button>
        ))}
      </div>
      <form onSubmit={(event) => { event.preventDefault(); void send(text); }}
        style={{ display: "flex", gap: 8, padding: "0 18px 16px", alignItems: "flex-end" }}>
        <textarea className="field" rows={2} value={text} placeholder="Écris à Claude (Entrée pour envoyer, Maj+Entrée pour une ligne)"
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void send(text); } }}
          style={{ flex: 1, resize: "none" }} />
        <button type="submit" className="btn btn-primary" disabled={conversation.busy || !text.trim()}>
          {conversation.busy ? "…" : "Envoyer"}
        </button>
      </form>
    </div>
  );
}

function Bubble({ message, tint }: { message: ChatMessage; tint: string }) {
  const text = message.fromStudent ? message.text : ClaudeTutor.withoutVerdicts(message.text);
  const paragraphs = text.split(/\n{2,}/);
  return (
    <div style={{
      alignSelf: message.fromStudent ? "flex-end" : "stretch", maxWidth: message.fromStudent ? "80%" : "100%",
      padding: message.fromStudent ? "8px 12px" : 0, borderRadius: 14,
      background: message.fromStudent ? `color-mix(in srgb, ${tint} 18%, var(--sheet-raised))` : "transparent",
      color: "var(--ink)", lineHeight: 1.6, fontSize: 15,
    }}>
      {message.streaming && text === "" ? <span style={{ color: "var(--ink-tertiary)" }}>…</span>
        : paragraphs.map((paragraph, index) => (
          <p key={index} style={{ margin: index === 0 ? 0 : "8px 0 0", whiteSpace: "pre-wrap" }}><RichInline text={paragraph} /></p>
        ))}
    </div>
  );
}
