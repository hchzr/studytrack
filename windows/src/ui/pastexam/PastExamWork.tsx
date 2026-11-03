// Une annale, travaillée dans l'app (PastExamWorkView du Mac, sans le découpage par question) :
// à gauche le sujet, à droite son corrigé — caché tant qu'on ne l'a pas demandé. À la fin,
// « J'ai fini » note la date et la sûreté, comme partout.

import { useEffect, useState } from "react";
import type { PastExam } from "../../models/pastExam.ts";
import { ConfidenceLevel } from "../../models/enums.ts";
import { SeriesPDFStore } from "../../services/seriesPDFStore.ts";
import { Icon } from "../icons.tsx";
import { PDFPane } from "../pdf/PDFPane.tsx";

type Load = { kind: "none" } | { kind: "loading" } | { kind: "failed"; message: string } | { kind: "ready"; bytes: Uint8Array };

function usePDF(address: string): Load {
  const [state, setState] = useState<Load>({ kind: "none" });
  useEffect(() => {
    let url: URL;
    try { url = new URL(address); } catch { setState({ kind: "none" }); return; }
    let alive = true;
    setState({ kind: "loading" });
    SeriesPDFStore.download(url).then(
      (bytes) => { if (alive) setState({ kind: "ready", bytes }); },
      (error: unknown) => {
        if (!alive) return;
        const kind = (error as { kind?: string }).kind;
        setState({ kind: "failed", message: kind === "notSignedIn" ? "Connecte-toi à Moodle (Le cours › Moodle), puis rouvre l'annale." : "Document illisible." });
      },
    );
    return () => { alive = false; };
  }, [address]);
  return state;
}

function Side({ load, empty }: { load: Load; empty: string }) {
  if (load.kind === "ready") return <PDFPane bytes={load.bytes} />;
  return (
    <div className="bf-center">
      {load.kind === "loading" ? "Téléchargement…" : load.kind === "failed" ? load.message : empty}
    </div>
  );
}

export function PastExamWork({ exam, save, close }: { exam: PastExam; save: (instance: object) => Promise<void>; close: () => void }) {
  const subject = usePDF(exam.urlString);
  const [revealed, setRevealed] = useState(false);
  const solution = usePDF(revealed ? exam.solutionURLString : "");
  const [, bump] = useState(0);
  const finish = (level: ConfidenceLevel) => {
    exam.workedAt = exam.workedAt ?? new Date();
    exam.confidenceRaw = level;
    void save(exam).then(() => bump((n) => n + 1));
  };
  useEffect(() => {
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") close(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [close]);

  return (
    <div role="dialog" aria-label={exam.title} style={{
      position: "fixed", inset: 0, zIndex: 300, display: "flex", flexDirection: "column", background: "var(--ground, var(--sheet))", color: "var(--ink)",
    }}>
      <header style={{ display: "flex", alignItems: "center", gap: 10, padding: "12px 18px", borderBottom: "1px solid var(--rule)" }}>
        <span className="serif" style={{ fontSize: 20, flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{exam.title}</span>
        <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>J'ai fini :</span>
        {(["green", "orange", "red"] as ConfidenceLevel[]).map((level) => (
          <button key={level} type="button" className="btn" aria-pressed={exam.confidence === level}
            style={exam.confidence === level ? { borderColor: "var(--ink)" } : undefined} onClick={() => finish(level)}>
            {ConfidenceLevel.label(level)}
          </button>
        ))}
        <button type="button" className="icon-btn" title="Fermer (Échap)" onClick={close}><Icon name="xmark" size={16} /></button>
      </header>
      <div style={{ flex: 1, minHeight: 0, display: "flex" }}>
        <div style={{ flex: 1, minWidth: 0, position: "relative", borderRight: "1px solid var(--rule)" }}>
          <Side load={subject} empty="Pas de sujet lié : ajoute son lien dans « Modifier… »." />
        </div>
        <div style={{ flex: 1, minWidth: 0, position: "relative" }}>
          {exam.solutionURLString === "" ? <div className="bf-center">Pas de corrigé lié.</div>
            : revealed ? <Side load={solution} empty="" />
              : (
                <div className="bf-center">
                  <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Le corrigé</span>
                  <span>Caché tant que tu ne l'as pas demandé : cherche d'abord.</span>
                  <button type="button" className="btn btn-primary" onClick={() => setRevealed(true)}>Voir le corrigé</button>
                </div>
              )}
        </div>
      </div>
    </div>
  );
}
