// Le chiffrement de bout en bout de la synchronisation, dans Réglages › Synchronisation :
// activer, ajouter un appareil (code + QR), clé de secours, réinitialiser le coffre.
// Voir docs/sync-e2ee.md. La WebSocket d'appairage n'existe que pendant l'écran « Ajouter
// un appareil » ; fermer l'écran la ferme.

import { useEffect, useMemo, useState } from "react";
import qrcode from "qrcode-generator";
import { Button } from "../../kit.tsx";
import { syncService, type SyncStatus } from "../../../services/syncService.ts";
import type { PairingHost, HostState } from "../../../services/syncPairing.ts";

/** Le QR en SVG, sans dépendance de rendu : un carré noir par module. */
export function QRCodeSvg({ text, size = 176 }: { text: string; size?: number }) {
  const svg = useMemo(() => {
    const qr = qrcode(0, "M");
    qr.addData(text);
    qr.make();
    const n = qr.getModuleCount();
    const cells: string[] = [];
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) cells.push(`M${c + 4} ${r + 4}h1v1h-1z`);
    return { n, path: cells.join("") };
  }, [text]);
  const side = svg.n + 8; // quatre modules de marge blanche
  return (
    <svg role="img" aria-label="QR code d'appairage" width={size} height={size} viewBox={`0 0 ${side} ${side}`}
      shapeRendering="crispEdges" style={{ background: "#fff", borderRadius: 8 }}>
      <path d={svg.path} fill="#000" />
    </svg>
  );
}

type Panel = null | "confirm-recovery" | "recovery-created" | "pair-host" | "pair-join" | "restore" | "show-recovery" | "reset";

const privacyLine = "Tes données sont chiffrées sur tes appareils ; le serveur ne peut pas les lire. Il voit seulement quand une ligne change et combien il y en a.";

function RecoveryKeyBox({ keyText }: { keyText: string }) {
  return (
    <div className="settings-preview">
      <p className="settings-label">Clé de secours — garde-la hors de l'app</p>
      <p className="mono" style={{ fontSize: 15, letterSpacing: 1, lineHeight: 1.7, userSelect: "all", wordBreak: "break-all" }}>{keyText}</p>
      <p className="settings-hint">
        Sans cette clé ni un autre appareil connecté, tes données chiffrées sont perdues pour de bon.
        Note-la sur papier ou dans un gestionnaire de mots de passe.
      </p>
      <div className="settings-actions">
        <Button onClick={() => void navigator.clipboard?.writeText(keyText)}>Copier</Button>
      </div>
    </div>
  );
}

function PairHost({ onClose }: { onClose: () => void }) {
  const [host, setHost] = useState<PairingHost | null>(null);
  const [state, setState] = useState<HostState>("waiting");
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let current: PairingHost | null = null;
    let cancelled = false;
    syncService.startPairing((s, m) => { setState(s); setMessage(m); })
      .then((h) => { if (cancelled) h.cancel(); else { current = h; setHost(h); } })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "L'appairage a échoué."));
    return () => { cancelled = true; current?.cancel(); };
  }, []);

  return (
    <div className="settings-preview">
      <p className="settings-label">Ajouter un appareil</p>
      {error && <p className="settings-error" role="alert">{error}</p>}
      {host && state === "waiting" && (
        <>
          <p className="settings-hint">
            Sur le nouvel appareil, connecte-toi au même compte, puis « Entrer un code d'appairage ».
            Le code est valable 10 minutes et ne sert qu'une fois.
          </p>
          <div style={{ display: "flex", gap: 16, alignItems: "center", flexWrap: "wrap" }}>
            <QRCodeSvg text={host.qr} />
            <p className="mono" style={{ fontSize: 20, fontWeight: 600, letterSpacing: 1, userSelect: "all" }}>{host.code}</p>
          </div>
        </>
      )}
      {state === "verifying" && <p className="settings-hint">Vérification en cours…</p>}
      {state === "done" && <p className="settings-label" role="status">Appareil ajouté</p>}
      {(state === "failed" || state === "expired") && message && <p className="settings-error" role="alert">{message}</p>}
      <div className="settings-actions">
        <Button onClick={onClose}>{state === "done" ? "Terminé" : "Fermer"}</Button>
      </div>
    </div>
  );
}

function TextEntry({ label, hint, placeholder, action, busyLabel, onSubmit, onClose }: {
  label: string; hint: string; placeholder: string; action: string; busyLabel: string;
  onSubmit: (text: string) => Promise<void>; onClose: () => void;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const submit = async () => {
    setBusy(true); setError(null);
    try { await onSubmit(text); setDone(true); }
    catch (e) { setError(e instanceof Error ? e.message : "Ça n'a pas marché."); }
    finally { setBusy(false); }
  };
  return (
    <div className="settings-preview">
      <p className="settings-label">{label}</p>
      <p className="settings-hint">{hint}</p>
      {!done && (
        <input className="field mono" value={text} placeholder={placeholder} aria-label={label} autoCapitalize="characters"
          spellCheck={false} disabled={busy} onChange={(e) => setText(e.target.value)} style={{ width: "100%", marginTop: 8 }} />
      )}
      {done && <p className="settings-label" role="status">Appareil ajouté</p>}
      {error && <p className="settings-error" role="alert">{error}</p>}
      <div className="settings-actions">
        <Button onClick={onClose}>{done ? "Terminé" : "Annuler"}</Button>
        {!done && <Button variant="primary" disabled={busy || text.trim() === ""} onClick={() => void submit()}>{busy ? busyLabel : action}</Button>}
      </div>
    </div>
  );
}

export function EncryptionPanel({ status }: { status: SyncStatus }) {
  const [panel, setPanel] = useState<Panel>(null);
  const [recovery, setRecovery] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmReset, setConfirmReset] = useState("");
  const state = status.encryption;

  useEffect(() => {
    // Le coffre se relit à l'ouverture de l'écran (une petite requête).
    void syncService.refreshVault().catch(() => {});
  }, []);

  const run = async (work: () => Promise<void>) => {
    setBusy(true); setError(null);
    try { await work(); }
    catch (e) { setError(e instanceof Error ? e.message : "Ça n'a pas marché."); }
    finally { setBusy(false); }
  };

  const activate = () => run(async () => { setRecovery(await syncService.enableEncryption()); setPanel("recovery-created"); });
  const showRecovery = () => run(async () => {
    const key = await syncService.recoveryKey();
    if (!key) throw new Error("Cet appareil n'a pas la clé du compte.");
    setRecovery(key); setPanel("show-recovery");
  });
  const reset = () => run(async () => { setRecovery(await syncService.resetVault()); setConfirmReset(""); setPanel("recovery-created"); });

  return (
    <>
      <p className="settings-hint" style={{ margin: "10px 0" }}>{privacyLine}</p>

      {state === "unknown" && <p className="settings-hint">Lecture du coffre du compte…</p>}

      {state === "noVault" && panel === null && (
        <div className="settings-actions">
          <Button variant="primary" disabled={busy} onClick={() => void activate()}>
            {busy ? "Activation…" : "Activer la synchronisation chiffrée"}
          </Button>
        </div>
      )}

      {(state === "needsKey" || state === "keyMismatch") && panel === null && (
        <>
          <p className="settings-label">Ce compte est chiffré : ajoute cet appareil depuis un appareil déjà connecté.</p>
          <div className="settings-actions">
            {status.pairingAvailable && <Button variant="primary" onClick={() => setPanel("pair-join")}>Entrer un code d'appairage</Button>}
            <Button onClick={() => setPanel("restore")}>Utiliser la clé de secours</Button>
          </div>
        </>
      )}

      {state === "ready" && panel === null && (
        <div className="settings-actions">
          {status.pairingAvailable && <Button onClick={() => setPanel("pair-host")}>Ajouter un appareil</Button>}
          <Button disabled={busy} onClick={() => setPanel("confirm-recovery")}>Afficher la clé de secours</Button>
        </div>
      )}

      {panel === "recovery-created" && recovery && (
        <>
          <RecoveryKeyBox keyText={recovery} />
          <div className="settings-actions"><Button variant="primary" onClick={() => { setRecovery(null); setPanel(null); }}>J'ai noté la clé</Button></div>
        </>
      )}
      {panel === "confirm-recovery" && (
        <div className="settings-preview">
          <p className="settings-label">Afficher la clé de secours ?</p>
          <p className="settings-hint">Elle donne accès à toutes tes données chiffrées. Vérifie que personne ne regarde l'écran.</p>
          <div className="settings-actions">
            <Button onClick={() => setPanel(null)}>Annuler</Button>
            <Button variant="primary" disabled={busy} onClick={() => void showRecovery()}>Afficher</Button>
          </div>
        </div>
      )}
      {panel === "show-recovery" && recovery && (
        <>
          <RecoveryKeyBox keyText={recovery} />
          <div className="settings-actions"><Button onClick={() => { setRecovery(null); setPanel(null); }}>Masquer</Button></div>
        </>
      )}
      {panel === "pair-host" && <PairHost onClose={() => setPanel(null)} />}
      {panel === "pair-join" && (
        <TextEntry label="Entrer un code d'appairage" placeholder="XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX" action="Ajouter" busyLabel="Appairage…"
          hint="Sur un appareil déjà connecté : Réglages › Synchronisation › Ajouter un appareil. Saisis le code affiché."
          onSubmit={(text) => syncService.joinPairing(text)} onClose={() => setPanel(null)} />
      )}
      {panel === "restore" && (
        <TextEntry label="Utiliser la clé de secours" placeholder="XXXX-XXXX-…" action="Restaurer" busyLabel="Vérification…"
          hint="La clé de secours de 54 caractères, montrée à l'activation du chiffrement."
          onSubmit={(text) => syncService.restoreFromRecoveryKey(text)} onClose={() => setPanel(null)} />
      )}
      {panel === "reset" && (
        <div className="settings-preview">
          <p className="settings-label">Réinitialiser le coffre</p>
          <p className="settings-hint">
            À n'utiliser que si tous tes appareils et ta clé de secours sont perdus. Les données chiffrées de ce compte
            seront effacées du serveur, définitivement, et les autres appareils ne pourront plus les lire.
            Cet appareil créera un coffre neuf et renverra ses propres données.
          </p>
          <input className="field" value={confirmReset} placeholder="Tape RÉINITIALISER pour confirmer" aria-label="Confirmation"
            onChange={(e) => setConfirmReset(e.target.value)} style={{ width: "100%", marginTop: 8 }} />
          <div className="settings-actions">
            <Button onClick={() => { setPanel(null); setConfirmReset(""); }}>Annuler</Button>
            <Button variant="primary" disabled={busy || confirmReset.trim().toUpperCase() !== "RÉINITIALISER"} onClick={() => void reset()}>
              Réinitialiser le coffre
            </Button>
          </div>
        </div>
      )}

      {error && <p className="settings-error" role="alert">{error}</p>}
      {(state === "needsKey" || state === "keyMismatch" || state === "ready") && panel === null && (
        <div className="settings-actions">
          <Button disabled={busy} onClick={() => setPanel("reset")}>Réinitialiser le coffre</Button>
        </div>
      )}
      {status.skippedForeignKey > 0 && (
        <p className="settings-error" role="alert">
          Clé différente : {status.skippedForeignKey} ligne(s) chiffrée(s) avec une autre clé ont été ignorées.
        </p>
      )}
      {status.skippedUnreadable > 0 && (
        <p className="settings-hint">{status.skippedUnreadable} ligne(s) illisible(s) ont été ignorées.</p>
      )}
    </>
  );
}
