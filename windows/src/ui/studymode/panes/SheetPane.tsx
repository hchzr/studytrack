// La fiche de révision du cours, au centre (RevisionSheetView, réduit) : les
// chapitres et leurs entrées — définitions, théorèmes, formules, méthodes,
// pièges. Sur le Mac, « Relire » y ouvre la section du polycopié ; le lien
// d'origine reste indiqué, la lecture Botafogo n'est pas portée.

import type { Course } from "../../../models/course.ts";
import { RevisionSheet, RevisionEntryKind } from "../../../domain/revisionSheet.ts";
import { useState } from "react";
import { Segmented } from "../../kit.tsx";
import { StudyMap } from "../../../domain/studyMap.ts";
import { ConceptPanel, LearningPathView, MindMapView, readStudyMap, updateStudyMap } from "../../studymap/StudyMapViews.tsx";
import { DiagramsView } from "../../studymap/DiagramViews.tsx";
import { ListenView } from "../../studymap/ListenView.tsx";
import { enrichStudyMap } from "../../../services/studyMapMaker.ts";

type SheetTab = "fiche" | "carte" | "schemas" | "parcours" | "ecouter";
import { RichInline } from "../../rich/RichText.tsx";
import { makeRevisionSheet } from "../../../services/revisionSheetMaker.ts";
import { openInApp } from "../openers.ts";
import { Glyph, Kicker, tintOfCourse } from "../parts.tsx";

/** Le genre d'une entrée, en pastille discrète. */
function KindTag({ kind, tint }: { kind: RevisionEntryKind; tint: string }) {
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 4, borderRadius: 999, padding: "1px 8px",
      fontSize: 11, fontWeight: 600, color: tint,
      background: `color-mix(in srgb, ${tint} 12%, transparent)`,
      border: `1px solid color-mix(in srgb, ${tint} 35%, transparent)`,
      whiteSpace: "nowrap",
    }}>
      {RevisionEntryKind.label(kind)}
    </span>
  );
}

export function SheetPane({ course, save }: { course: Course | null; save?: (instance: object) => Promise<void> }) {
  const [making, setMaking] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [, bump] = useState(0);
  const [tab, setTab] = useState<SheetTab>("fiche");
  const [chapter, setChapter] = useState<string | null>(null);
  const [concept, setConcept] = useState<string | null>(null);
  const [enriching, setEnriching] = useState<string | null>(null);
  const make = async () => {
    if (!course || making) return;
    setFailure(null);
    setMaking("Préparation…");
    try {
      await makeRevisionSheet(course, setMaking);
      await save?.(course);
      bump((n) => n + 1);
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error));
    } finally {
      setMaking(null);
    }
  };
  if (!course) {
    return (
      <div style={{ height: "100%", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 10, textAlign: "center" }}>
        <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>Pas de cours</span>
        <span style={{ color: "var(--ink-secondary)", fontSize: 14 }}>Choisis-en un pour la session.</span>
      </div>
    );
  }
  const tint = tintOfCourse(course);
  const sheet = RevisionSheet.decode(course.revisionSheetRaw);
  const map = readStudyMap(course);
  const change = (edit: (map: StudyMap) => void) => {
    if (!save) return;
    updateStudyMap(course, save, edit);
    bump((n) => n + 1);
  };

  // « Comprendre avec Claude » : relier les notions, les expliquer, dessiner les schémas.
  const done = chapter ? map.enrichedChapters?.[chapter] !== undefined : map.enrichedAt !== null;
  const comprehend = save && sheet !== null ? (
    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
      <button type="button" className="btn" disabled={enriching !== null} onClick={() => {
        setEnriching("…");
        setFailure(null);
        void enrichStudyMap(course, chapter, readStudyMap(course), setEnriching)
          .then((next) => { updateStudyMap(course, save, (m) => Object.assign(m, next)); bump((n) => n + 1); },
            (error: unknown) => setFailure(error instanceof Error ? error.message : String(error)))
          .finally(() => setEnriching(null));
      }}>
        {enriching ? "Claude travaille…" : chapter ? (done ? "Refaire ce chapitre" : "Comprendre ce chapitre") : (done ? "Refaire les liens" : "Comprendre avec Claude")}
      </button>
      {enriching && enriching !== "…" && <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>{enriching}</span>}
    </div>
  ) : null;

  return (
    <div style={{ height: "100%", display: "flex", minHeight: 0 }}>
    <div style={{ flex: 1, minWidth: 0, overflowY: "auto", padding: "24px 28px 40px" }}>
      <div style={{ maxWidth: 820, display: "flex", flexDirection: "column", gap: 22 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
          <Kicker color={tint}>{course.displayCode} · Fiche</Kicker>
          <div style={{ flex: 1 }} />
          {sheet !== null && (
            <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>
              {sheet.entries.length} entrées
            </span>
          )}
          {sheet !== null && save && (
            <button type="button" className="btn" disabled={making !== null} onClick={() => { void make(); }}>
              {making ? "En cours…" : "Refaire la fiche"}
            </button>
          )}
        </div>

        {sheet !== null && (
          <div style={{ display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
            <Segmented<SheetTab> ariaLabel="Vue de la fiche" value={tab} onChange={setTab}
              options={[{ value: "fiche", label: "Fiche" }, { value: "carte", label: "Carte" }, { value: "schemas", label: "Schémas" }, { value: "parcours", label: "Parcours" }, { value: "ecouter", label: "Écouter" }]} />
            {sheet.chapters.length > 1 && (
              <select className="select" value={chapter ?? ""} onChange={(event) => setChapter(event.target.value || null)} aria-label="Chapitre">
                <option value="">Tout le cours</option>
                {sheet.chapters.filter((item) => item.entries.length > 0).map((item) => <option key={item.id} value={item.id}>{item.title.replace(/\$/g, "")}</option>)}
              </select>
            )}
          </div>
        )}

        {sheet !== null && tab === "schemas" && (
          <DiagramsView sheet={sheet} map={map} chapter={chapter} tint={tint} openConcept={setConcept} comprehend={comprehend} />
        )}
        {sheet !== null && tab === "ecouter" && (
          <ListenView courseName={course.name} code={course.displayCode} sheet={sheet} map={map} chapter={chapter} />
        )}
        {sheet !== null && (tab === "carte" || tab === "parcours") && comprehend}
        {sheet !== null && tab === "parcours" && (
          <LearningPathView sheet={sheet} map={map} chapter={chapter} tint={tint} openConcept={setConcept} selectChapter={setChapter} />
        )}
        {sheet !== null && tab === "carte" && (
          <MindMapView sheet={sheet} map={map} courseTitle={course.name} chapter={chapter} tint={tint} openConcept={setConcept}
            toggleCollapsed={(id) => change((m) => { if (m.collapsed.has(id)) m.collapsed.delete(id); else m.collapsed.add(id); })} />
        )}

        {making && <div style={{ fontSize: 13, color: "var(--ink-secondary)" }}>{making}</div>}
        {failure && <div style={{ fontSize: 13, color: "var(--wrong)" }}>{failure}</div>}

        {tab !== "fiche" && sheet !== null ? null : sheet === null ? (
          // Pas de fiche : le dire, et comment en avoir une.
          <div style={{ display: "flex", flexDirection: "column", gap: 8, alignItems: "flex-start" }}>
            <span className="serif" style={{ fontSize: 26, color: "var(--ink)" }}>Pas encore de fiche</span>
            <span style={{ fontSize: 14, color: "var(--ink-secondary)" }}>
              Tout le cours sur une page — à faire une fois. Avec un polycopié Botafogo, ses définitions et
              théorèmes sont repris tels quels ; Claude (par ton abonnement) ajoute les méthodes des séries,
              ou écrit toute la fiche à partir des documents du cours.
            </span>
            {save && (
              <button type="button" className="btn btn-primary" disabled={making !== null} onClick={() => { void make(); }}>
                {making ? "En cours…" : "Faire la fiche"}
              </button>
            )}
          </div>
        ) : (
          sheet.chapters.map((chapter) => (
            <section key={chapter.id} style={{ display: "flex", flexDirection: "column", gap: 12 }}>
              <h2 className="serif" style={{ fontSize: 24, margin: 0, color: "var(--ink)" }}>
                {chapter.title}
              </h2>
              <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
                {chapter.entries.map((entry) => (
                  <div key={entry.id} style={{
                    padding: 16, borderRadius: 14, background: "var(--sheet)", border: "1px solid var(--rule)",
                    display: "flex", flexDirection: "column", gap: 6,
                  }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                      <KindTag kind={entry.kind} tint={tint} />
                      <span className="serif" style={{ fontSize: 17, color: "var(--ink)" }}>{entry.title}</span>
                      <div style={{ flex: 1 }} />
                      {entry.source !== "" && (
                        <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>{entry.source}</span>
                      )}
                    </div>
                    <p className="serif" style={{
                      margin: 0, fontSize: 15, lineHeight: 1.55, color: "var(--ink-secondary)", whiteSpace: "pre-wrap",
                    }}>
                      <RichInline text={entry.body} />
                    </p>
                    {entry.link !== "" && /^https?:\/\//i.test(entry.link) && (
                      <button
                        type="button"
                        onClick={() => { void openInApp(entry.link); }}
                        style={{
                          alignSelf: "flex-start", border: "none", background: "transparent", padding: 0,
                          fontSize: 12, color: tint, cursor: "pointer",
                          display: "inline-flex", alignItems: "center", gap: 4,
                        }}
                      >
                        Relire <Glyph name="arrow.right" />
                      </button>
                    )}
                  </div>
                ))}
              </div>
            </section>
          ))
        )}
      </div>
    </div>
    {sheet !== null && concept !== null && (
      <ConceptPanel sheet={sheet} map={map} conceptKey={concept} tint={tint} openConcept={setConcept} close={() => setConcept(null)}
        setMastery={(level) => change((m) => { m.progress[concept] = { level, at: new Date() }; })} />
    )}
    </div>
  );
}
