// L'état du téléchargement d'un énoncé distant : progression, ou l'erreur en français
// avec la suite à donner (se connecter à Moodle, réessayer).

import { useState } from "react";
import { MoodleClient } from "../../services/moodleClient.ts";
import type { SeriesPDFError } from "../../services/seriesPDFStore.ts";
import { Button } from "../kit.tsx";

export function PDFDownloadNotice({ loading, error, onRetry }: {
  loading: boolean; error: SeriesPDFError | null; onRetry: () => void;
}) {
  const [loginError, setLoginError] = useState<string | null>(null);
  if (loading) return <div className="muted" role="status" style={{ padding: 12, fontSize: 13 }}>Téléchargement de l'énoncé…</div>;
  if (error === null) return null;
  const signIn = async () => {
    setLoginError(null);
    try { await MoodleClient.openLogin(); } catch (failure) { setLoginError(failure instanceof Error ? failure.message : String(failure)); }
  };
  return (
    <div role="alert" style={{ padding: 12, display: "flex", flexDirection: "column", gap: 8, alignItems: "flex-start", fontSize: 13 }}>
      <span style={{ color: "var(--ink-secondary)" }}>{error.message}</span>
      {loginError !== null && <span style={{ color: "var(--wrong)" }}>{loginError}</span>}
      <div style={{ display: "flex", gap: 8 }}>
        {error.kind === "notSignedIn" && <Button size="sm" onClick={() => void signIn()}>Se connecter à Moodle</Button>}
        <Button size="sm" onClick={onRetry}>Réessayer</Button>
      </div>
    </div>
  );
}
