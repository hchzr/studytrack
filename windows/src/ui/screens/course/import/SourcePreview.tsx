// La page du PDF, cadrée sur l'exercice (StudyKit/SeriesEditing.swift › SourcePreviewSheet) :
// on compare à la vraie feuille au lieu de faire confiance à la lecture.

import { useEffect, useRef, useState } from "react";
import { Button, EmptyState, IconButton } from "../../../kit.tsx";

export interface SourcePreviewTarget {
  title: string;
  page: number;
  top?: number;
  bottom?: number;
}

export function SourcePreview({ preview, pages, onClose }: { preview: SourcePreviewTarget; pages: Uint8Array[]; onClose: () => void }) {
  const [whole, setWhole] = useState(false);
  const [failed, setFailed] = useState(false);
  const canvas = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);

  useEffect(() => {
    const bytes = pages[preview.page];
    if (!bytes || bytes.length === 0) { setFailed(true); return; }
    setFailed(false);
    const url = URL.createObjectURL(new Blob([bytes as BlobPart], { type: "image/jpeg" }));
    const image = new Image();
    image.onload = () => {
      const target = canvas.current;
      if (!target) return;
      let start = 0;
      let end = 1;
      if (!whole && preview.top !== undefined) {
        start = Math.max(0, preview.top - 0.02);
        end = Math.min(1, Math.max(start + 0.12, (preview.bottom ?? Math.min(1, preview.top + 0.45)) + 0.01));
      }
      const sy = Math.round(start * image.height);
      const sh = Math.max(1, Math.round((end - start) * image.height));
      target.width = image.width;
      target.height = sh;
      target.getContext("2d")?.drawImage(image, 0, sy, image.width, sh, 0, 0, image.width, sh);
      URL.revokeObjectURL(url);
    };
    image.onerror = () => { setFailed(true); URL.revokeObjectURL(url); };
    image.src = url;
  }, [pages, preview, whole]);

  return (
    <div className="overlay imp-preview-overlay" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <div className="dialog imp-preview" role="dialog" aria-modal="true" aria-label={preview.title}>
        <div className="cs-dialog-head">
          <h2 className="serif">{preview.title}</h2>
          <IconButton icon="xmark" label="Fermer" onClick={onClose} />
        </div>
        <div className="imp-preview-body">
          {failed ? <EmptyState icon="doc.text" title="Page indisponible" />
            : <canvas ref={canvas} aria-label={`Page ${preview.page + 1} du PDF`} />}
        </div>
        <div className="cs-dialog-foot">
          <Button size="sm" disabled={preview.top === undefined} onClick={() => setWhole(!whole)}>
            {whole ? "Seulement l'exercice" : "Page entière"}
          </Button>
          <span className="spacer" />
          <Button variant="primary" onClick={onClose}>OK</Button>
        </div>
      </div>
    </div>
  );
}
