// Importer le contenu d'un cours depuis Moodle : se connecter, retrouver le cours,
// le lire, le ranger (règles + IA), relire, écrire (Polymestre/Views/Courses/
// ContentImport.swift › ContentImportView / ContentReviewView, et StudyKit/
// MoodleCourseViews.swift).
//
// Le Mac n'importe rien de Moodle (il lit ce que l'iPhone a rangé) : Windows, sans
// iPhone, a donc l'import. La connexion est celle de l'école dans une fenêtre à part
// (Tequila / Microsoft) ; la session sert ensuite à toutes les lectures.

import { useEffect, useRef, useState } from "react";
import { listenNative } from "../../../../native/tauri.ts";
import type { Course } from "../../../../models/course.ts";
import { useData } from "../../../../data/dataContext.tsx";
import { Button, EmptyState, Icon, IconButton } from "../../../kit.tsx";
import { MoodleClient } from "../../../../services/moodleClient.ts";
import { SiteError, closeSiteLogin, siteAvailable } from "../../../../services/siteSession.ts";
import { MoodleCourseMatcher, MoodleCourseRef } from "../../../../domain/moodleImport.ts";
import { CourseImportPipeline } from "../../../../services/courseImportPipeline.ts";
import { ContentSource, type ContentDraft } from "../../../../domain/courseContentImport.ts";
import { ContentDraftWriter, type ContentImportResult } from "../../../../domain/courseContentWriter.ts";
import { Institution } from "../../../../domain/institution.ts";
import { AppLog } from "../../../../domain/appLog.ts";
import { ContentDraftSections, summaryLine } from "./ContentDraftSections.tsx";
import "./import.css";

type Phase =
  | { name: "unavailable" | "checking" | "login" | "finding" | "reading" | "writing" }
  | { name: "choose"; refs: MoodleCourseRef[] }
  | { name: "review" }
  | { name: "done"; result: ContentImportResult }
  | { name: "failed"; message: string };

export function MoodleImportSheet({ course, onClose, initialDraft }: {
  course: Course; onClose: () => void;
  /** Un brouillon déjà lu (`?import=moodle` : captures et essais, sans session Moodle). */
  initialDraft?: ContentDraft;
}) {
  const { store, saveMany } = useData();
  const [phase, setPhase] = useState<Phase>(initialDraft ? { name: "review" } : { name: siteAvailable() ? "checking" : "unavailable" });
  const [progress, setProgress] = useState("");
  const [counter, setCounter] = useState<{ done: number; total: number } | null>(null);
  const [draft, setDraft] = useState<ContentDraft | null>(initialDraft ?? null);
  const [notes, setNotes] = useState<string[]>([]);
  const [, bump] = useState(0);
  const abort = useRef<AbortController | null>(null);
  const client = MoodleClient.background;
  const totalWeeks = course.term?.totalWeeks ?? 14;
  const moodle = Institution.current.name;

  useEffect(() => {
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") close(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  });
  useEffect(() => { if (siteAvailable() && !initialDraft) void start(); return () => abort.current?.abort(); },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    []);

  // La fenêtre de connexion se ferme seule une fois connecté·e (native/site.rs) : on enchaîne
  // sans attendre « C'est fait ».
  const phaseRef = useRef(phase.name);
  phaseRef.current = phase.name;
  useEffect(() => listenNative<string>("site:signed-in", (label) => {
    if (label === "moodle" && phaseRef.current === "login") void start();
  }),
  // eslint-disable-next-line react-hooks/exhaustive-deps
  []);

  function close() { abort.current?.abort(); void closeSiteLogin("moodle"); onClose(); }

  const fail = (error: unknown) => {
    if (error instanceof SiteError && error.kind === "notSignedIn") { setPhase({ name: "login" }); return; }
    const message = error instanceof Error ? error.message : String(error);
    void AppLog.record("error", "import", "Import Moodle échoué", message);
    setPhase({ name: "failed", message });
  };

  /** Connecté·e ? sinon la fenêtre de connexion ; puis retrouver le cours. */
  async function start() {
    setPhase({ name: "checking" });
    if (!(await client.isSignedIn())) { setPhase({ name: "login" }); return; }
    void closeSiteLogin("moodle");
    await find();
  }

  /** Le cours Moodle du cours de l'app : son lien, sinon une recherche sur le code. */
  async function find() {
    setPhase({ name: "finding" });
    try {
      const linked = MoodleCourseMatcher.linkedID([course.moodleURLString, ...course.contentSources]);
      if (linked !== null) {
        await read(new MoodleCourseRef({ id: linked, fullname: course.name, shortname: course.code }));
        return;
      }
      const enrolled = await client.enrolled("all");
      const match = await client.resolve(course.code, enrolled);
      if (match.type === "unique") await read(match.ref);
      else if (match.type === "ambiguous") setPhase({ name: "choose", refs: match.refs });
      else setPhase({ name: "failed", message: `Aucun cours Moodle trouvé pour ${course.code}. Colle son adresse dans « Modifier le cours ».` });
    } catch (error) { fail(error); }
  }

  /** Lit le cours (plan, activités), le range avec l'IA, et ouvre la relecture. */
  async function read(ref: MoodleCourseRef) {
    abort.current?.abort();
    const controller = new AbortController();
    abort.current = controller;
    setPhase({ name: "reading" });
    setProgress("lecture du plan du cours…");
    setCounter(null);
    try {
      const snapshot = await client.snapshot(ref, {
        outline: (sections) => setProgress(`${sections.length} sections lues`),
        activities: (done, total) => { setProgress("ouverture des activités…"); setCounter({ done, total }); },
        signal: controller.signal,
      });
      const outcome = await CourseImportPipeline.draft(snapshot, course.term?.startDate ?? null, totalWeeks, setProgress, controller.signal);
      if (controller.signal.aborted) return;
      setDraft(outcome.draft);
      setNotes(outcome.notes);
      setPhase({ name: "review" });
    } catch (error) { if (!controller.signal.aborted) fail(error); }
  }

  /** Écrit dans le cours ce qui est coché, puis garde tout. */
  async function apply() {
    if (!draft || !store) return;
    setPhase({ name: "writing" });
    try {
      const result = ContentDraftWriter.apply(draft, course, store);
      const touched: object[] = [course, ...course.theoryItems, ...course.series, ...course.series.flatMap((s) => s.exercises),
        ...course.exams, ...course.pastExams];
      await saveMany(touched);
      setPhase({ name: "done", result });
    } catch (error) { fail(error); }
  }

  const title = phase.name === "review" ? "Relecture" : `Importer depuis ${moodle}`;
  const refresh = () => bump((v) => v + 1);

  return (
    <div className="overlay imp-overlay" onMouseDown={(event) => { if (event.target === event.currentTarget) close(); }}>
      <div className="dialog imp-dialog" role="dialog" aria-modal="true" aria-label={title}>
        <div className="cs-dialog-head">
          <h2 className="serif">{title}</h2>
          <IconButton icon="xmark" label="Fermer" onClick={close} />
        </div>
        <div className="imp-body">
          {phase.name === "unavailable" && (
            <EmptyState icon="icloud.slash" title="Disponible dans l'app Windows">
              La connexion à {moodle} se fait dans une fenêtre de l'app ; l'aperçu navigateur n'a pas de session.
            </EmptyState>
          )}
          {(phase.name === "checking" || phase.name === "finding" || phase.name === "writing") && (
            <Working label={phase.name === "checking" ? `Connexion à ${moodle}…` : phase.name === "finding" ? "Recherche du cours…" : "Écriture…"} />
          )}
          {phase.name === "login" && (
            <div className="imp-source">
              <EmptyState icon="lock" title={`Connecte-toi à ${moodle}`}>
                Une fenêtre s'ouvre sur la page de connexion de l'école. Une fois connecté·e, reviens ici : la connexion est gardée pour les imports suivants.
              </EmptyState>
              <div className="imp-actions center">
                <Button icon="arrow.up.right.square" onClick={() => void MoodleClient.openLogin().catch(fail)}>Ouvrir la page de connexion</Button>
                <Button variant="primary" icon="checkmark" onClick={() => void start()}>C'est fait</Button>
              </div>
            </div>
          )}
          {phase.name === "choose" && (
            <div className="imp-source">
              <p className="imp-foot">Plusieurs cours Moodle correspondent à {course.code} : choisis le tien.</p>
              {phase.refs.map((ref) => (
                <button key={ref.id} type="button" className="imp-choice" onClick={() => void read(ref)}>
                  <Icon name="book" size={20} />
                  <span><strong>{ref.fullname}</strong><small>{ref.shortname}</small></span>
                  <Icon name="chevron.right" size={14} />
                </button>
              ))}
            </div>
          )}
          {phase.name === "reading" && (
            <Working label={`Lecture de ${course.code}`} detail={counter ? `${progress} ${counter.done}/${counter.total}` : progress} />
          )}
          {phase.name === "review" && draft && (
            <div className="imp-review">
              <section className="imp-block">
                <strong>{draft.courseTitle === "" ? ContentSource.label(draft.source) : draft.courseTitle}</strong>
                <span className="imp-foot mono">{summaryLine(draft)}</span>
                {draft.sections.some((s) => s.isIncluded && s.weekIsInferred) && (
                  <span className="imp-foot">Vérifie les semaines marquées « proposée ».</span>
                )}
                {notes.map((note) => <span key={note} className="imp-foot">{note}</span>)}
              </section>
              <ContentDraftSections draft={draft} totalWeeks={totalWeeks} onChange={refresh} />
            </div>
          )}
          {phase.name === "done" && (
            <EmptyState icon="checkmark.circle" title="Import terminé">{phase.result.message}</EmptyState>
          )}
          {phase.name === "failed" && (
            <div className="imp-source">
              <p className="imp-warn"><Icon name="exclamationmark.triangle.fill" size={14} /> {phase.message}</p>
              <div className="imp-actions"><Button onClick={() => void start()}>Réessayer</Button></div>
            </div>
          )}
        </div>
        <div className="cs-dialog-foot">
          <span className="spacer" />
          {phase.name === "review" && draft ? (
            <>
              <Button onClick={close}>Annuler</Button>
              <Button variant="primary" disabled={draft.isEmpty} onClick={() => void apply()}>
                {draft.isEmpty ? "Rien à importer" : `Importer ${draft.theoryCount + draft.seriesCount} éléments`}
              </Button>
            </>
          ) : (
            <Button variant={phase.name === "done" ? "primary" : "default"} onClick={close}>{phase.name === "done" ? "OK" : "Fermer"}</Button>
          )}
        </div>
      </div>
    </div>
  );
}

function Working({ label, detail }: { label: string; detail?: string }) {
  return (
    <div className="imp-step">
      <span className="imp-step-mark"><span className="imp-spinner" role="progressbar" aria-label="En cours" /></span>
      <span><strong>{label}</strong>{detail && <small>{detail}</small>}</span>
    </div>
  );
}
