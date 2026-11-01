// Synchronisation entre appareils — le compte Supabase et l'opt-in, pendant
// Windows de `SyncSettings` (Mac). Off par défaut, comme le plan Apple : se
// connecter n'envoie rien, et tout se débraye. Les données restent lisibles
// par leur seul auteur (RLS côté serveur).

import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { useData } from "../../../data/dataContext.tsx";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Plural } from "../../../domain/plural.ts";
import { Section, Card } from "../../kit.tsx";
import { SettingRow, Switch } from "./controls.tsx";
import { syncService, type SyncStatus } from "../../../services/syncService.ts";

/** Un champ « libellé au-dessus, contrôle dessous », comme le formulaire de cours. */
function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="settings-form-field">
      <span>{label}</span>
      {children}
    </label>
  );
}

/** « lun. 28 sept. à 08:15 » — l'heure de la dernière passe. */
function syncMoment(iso: string): string {
  const date = new Date(iso);
  return `${DateUtils.shortDay(date)} à ${DateUtils.time(date)}`;
}

/** Le compte-rendu de la dernière passe : envoyées, reçues, gardées, rattrapées. */
function reportLine(status: SyncStatus): string {
  const r = status.lastReport;
  if (!r) return "—";
  const parts = [
    `${r.pushed} ${Plural.count(r.pushed, "envoyée", "envoyées")}`,
    `${r.pulled} ${Plural.count(r.pulled, "reçue", "reçues")}`,
    `${r.keptLocal} ${Plural.count(r.keptLocal, "gardée ici", "gardées ici")}`,
    `${r.orphans} ${Plural.count(r.orphans, "rattrapée", "rattrapées")}`,
  ];
  return parts.join(" · ");
}

export function SyncSection() {
  const { reload } = useData();
  const [status, setStatus] = useState<SyncStatus | null>(null);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  /** Le geste en vol, pour désactiver les boutons le temps qu'il finisse. */
  const [busy, setBusy] = useState<"in" | "up" | "sync" | null>(null);

  useEffect(() => {
    // L'état vient du service (asynchrone : la session se relit), et chaque
    // notification — connexion, drapeau, passe — le rafraîchit.
    const refresh = () => { void syncService.status().then(setStatus); };
    refresh();
    return syncService.subscribe(refresh);
  }, []);

  const authenticate = async (mode: "in" | "up") => {
    if (busy !== null) return;
    setBusy(mode);
    setError(null);
    try {
      if (mode === "in") await syncService.signIn(email.trim(), password);
      else await syncService.signUp(email.trim(), password);
      setPassword("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "La connexion a échoué.");
    } finally {
      setBusy(null);
    }
  };

  const signOut = async () => {
    if (busy !== null) return;
    setBusy("sync");
    try {
      await syncService.signOut();
    } finally {
      setBusy(null);
    }
  };

  const syncNow = async () => {
    if (busy !== null) return;
    setBusy("sync");
    try {
      const report = await syncService.syncNow();
      // Une lecture a pu changer le graphe sous l'écran : on le relit.
      if (report !== null) await reload();
    } finally {
      setBusy(null);
    }
  };

  // Le temps du premier rendu, rien ne s'affiche : l'état arrive tout de suite.
  if (status === null) return null;

  if (!status.configured) {
    return (
      <Section title="Synchronisation">
        <Card>
          <p className="settings-empty">Ce build n'embarque pas de projet Supabase.</p>
          <p className="settings-hint">
            Il manque <code className="mono">VITE_SUPABASE_URL</code> ou{" "}
            <code className="mono">VITE_SUPABASE_ANON_KEY</code> à la compilation.
            Toutes tes données restent sur cet appareil — rien d'autre ne change.
          </p>
        </Card>
        <p className="settings-footnote">
          Les valeurs se posent dans <code className="mono">windows/.env</code> (voir
          Support/SUPABASE.md et .env.example), puis on relance le build.
        </p>
      </Section>
    );
  }

  if (!status.signedIn) {
    return (
      <Section title="Synchronisation">
        <Card>
          <form className="settings-form" onSubmit={(event: FormEvent<HTMLFormElement>) => {
            event.preventDefault();
            void authenticate("in");
          }}>
            <div className="settings-form-head">
              <h3 className="serif">Compte StudyTrack</h3>
              <p className="settings-hint">
                Un compte pour retrouver cours, séries et sessions sur un autre appareil.
                Personne d'autre que toi ne peut les lire.
              </p>
            </div>

            <div className="settings-form-grid">
              <Field label="Adresse e-mail">
                <input className="settings-input" type="email" required value={email} autoComplete="email"
                  aria-label="Adresse e-mail" onChange={(event) => setEmail(event.target.value)} />
              </Field>
              <Field label="Mot de passe">
                <input className="settings-input" type="password" required value={password}
                  autoComplete="current-password" aria-label="Mot de passe"
                  onChange={(event) => setPassword(event.target.value)} />
              </Field>
            </div>

            {error && (
              <p className="settings-hint" style={{ color: "var(--wrong)" }} role="alert">{error}</p>
            )}

            <div className="settings-actions">
              <button type="button" className="settings-button" disabled={busy !== null}
                onClick={() => void authenticate("up")}>
                {busy === "up" ? "Création…" : "Créer un compte"}
              </button>
              <button type="submit" className="settings-button settings-button--primary"
                disabled={busy !== null || email.trim() === "" || password === ""}>
                {busy === "in" ? "Connexion…" : "Se connecter"}
              </button>
            </div>
          </form>
        </Card>
        <p className="settings-footnote">
          Un compte n'envoie rien tout seul : la synchronisation s'active après, et elle se débraye.
        </p>
      </Section>
    );
  }

  return (
    <Section title="Synchronisation">
      <Card>
        <SettingRow label="Compte" hint="Le compte Supabase relié à cet appareil.">
          <span className="settings-value">{status.email ?? "—"}</span>
        </SettingRow>

        <SettingRow
          label="Synchroniser mes données entre mes appareils"
          hint="Éteint : rien ne quitte cet appareil. Le premier allumage envoie ce qui est ici, puis les changements suivent."
        >
          <Switch
            checked={status.enabled}
            ariaLabel="Synchroniser mes données entre mes appareils"
            onChange={(value) => syncService.setEnabled(value)}
          />
        </SettingRow>

        <SettingRow label="Dernière synchronisation">
          <span className="settings-value">
            {status.lastSyncAt ? syncMoment(status.lastSyncAt) : "jamais"}
          </span>
        </SettingRow>

        <SettingRow label="Dernier rapport" hint="Lignes envoyées, reçues, gardées ici, rattrapées.">
          <span className="settings-value mono" style={{ fontWeight: 600 }}>{reportLine(status)}</span>
        </SettingRow>

        {status.lastError && (
          <p className="settings-hint" style={{ color: "var(--wrong)" }} role="alert">
            {status.lastError}
          </p>
        )}

        <div className="settings-actions">
          <button type="button" className="settings-button" disabled={busy !== null}
            onClick={() => void signOut()}>
            Se déconnecter
          </button>
          <button type="button" className="settings-button settings-button--primary"
            disabled={!status.enabled || busy !== null} onClick={() => void syncNow()}>
            {busy === "sync" ? "Synchronisation…" : "Synchroniser maintenant"}
          </button>
        </div>
      </Card>
      <p className="settings-footnote">
        Une passe toutes les cinq minutes tant que c'est allumé, et trois secondes après chaque
        changement. Le premier allumage envoie l'existant.
      </p>
    </Section>
  );
}
