// L'énoncé d'une série dans son PDF : en entier, ou exercice par exercice — le
// même choix que l'énoncé du chrono sur le Mac (`ExercisePDFView`).

import { useEffect, useMemo, useState } from "react";
import type { ExerciseSeries } from "../../models/exercise.ts";
import type { SeriesPDFError } from "../../services/seriesPDFStore.ts";
import { IconButton, Select } from "../kit.tsx";
import { ExercisePDFView, PDFPane } from "./PDFPane.tsx";
import { PDFDownloadNotice } from "./PDFDownloadNotice.tsx";
import { cropExercise } from "./cropExercise.ts";
import "./pdf.css";

export function SeriesPDFDialog({ series, bytes, loading = false, error = null, onRetry, exerciseID, onClose }: {
  series: ExerciseSeries; bytes: Uint8Array | null; loading?: boolean; error?: SeriesPDFError | null;
  onRetry?: () => void; exerciseID?: string | null; onClose: () => void;
}) {
  const exercises = series.sortedExercises;
  const [choice, setChoice] = useState<string>(exerciseID ?? "");
  const index = exercises.findIndex((e) => e.id === choice);
  const current = index >= 0 ? exercises[index] : null;
  const next = index >= 0 ? exercises[index + 1] ?? null : null;
  const crop = useMemo(() => (current ? cropExercise(current) : null), [current]);
  const cropNext = useMemo(() => (next ? cropExercise(next) : null), [next]);

  useEffect(() => {
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);

  const title = series.title === "" ? `Série ${series.seriesNumber}` : series.title;
  return (
    <div className="overlay pdf-overlay" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <div className="dialog pdf-dialog" role="dialog" aria-modal="true" aria-label={`Énoncé : ${title}`}>
        <div className="cs-dialog-head">
          <h2 className="serif">{title}</h2>
          <Select ariaLabel="Exercice" value={choice}
            options={[{ value: "", label: "Tout le PDF" }, ...exercises.map((e) => ({ value: e.id, label: e.displayNumber }))]}
            onChange={setChoice} />
          <IconButton icon="xmark" label="Fermer" onClick={onClose} />
        </div>
        <div className="pdf-dialog-body">
          {bytes === null
            ? <PDFDownloadNotice loading={loading} error={error} onRetry={onRetry ?? (() => {})} />
            : crop ? <ExercisePDFView bytes={bytes} exercise={crop} next={cropNext} /> : <PDFPane bytes={bytes} />}
        </div>
      </div>
    </div>
  );
}
