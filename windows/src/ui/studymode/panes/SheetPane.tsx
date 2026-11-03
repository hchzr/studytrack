// La fiche de révision du cours, au centre (RevisionSheetView, réduit) : les
// chapitres et leurs entrées — définitions, théorèmes, formules, méthodes,
// pièges. Sur le Mac, « Relire » y ouvre la section du polycopié ; le lien
// d'origine reste indiqué, la lecture Botafogo n'est pas portée.

import type { Course } from "../../../models/course.ts";
import { RevisionSheet, RevisionEntryKind } from "../../../domain/revisionSheet.ts";
import { useState } from "react";
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

  return (
    <div style={{ height: "100%", overflowY: "auto", padding: "24px 28px 40px" }}>
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

        {making && <div style={{ fontSize: 13, color: "var(--ink-secondary)" }}>{making}</div>}
        {failure && <div style={{ fontSize: 13, color: "var(--wrong)" }}>{failure}</div>}

        {sheet === null ? (
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
  );
}
