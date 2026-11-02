// Connexions — l'horaire (abonnement `.ics`), le calendrier académique, Moodle et les
// tâches liées. Sur le Mac, ces liens vivent dans l'iPhone et dans EventKit ; Windows n'a
// ni l'un ni l'autre : l'horaire arrive par son adresse `.ics`, les tâches par l'API de
// leur fournisseur (Todoist, Notion, Google Tasks, TickTick, webhook).
//
// Rien ne tourne en arrière-plan : chaque bouton fait un geste, et l'app ne relit
// l'horaire et les tâches qu'**une fois** au lancement (`launchSync`).

import { useState, type ReactNode } from "react";
import { useData } from "../../../data/dataContext.tsx";
import { TaskProvider } from "../../../models/enums.ts";
import { Button, Card, Section } from "../../kit.tsx";
import { SettingRow } from "./controls.tsx";
import { pickTextFile } from "../../../native/files.ts";
import { readConnection, writeConnection, type ConnectionKey } from "../../../native/settings.ts";
import { TaskServiceFactory, windowsProviders } from "../../../services/taskService.ts";
import {
  importTimetableText, refreshAcademicCalendar, refreshTimetableFeed, syncAllTasks, syncAnki, type Persistence,
} from "../../../services/connectionsRunner.ts";
import { ankiWebSync } from "../../../services/ankiWebSync.ts";
import { ankiLastSync } from "../../../services/ankiReviewSync.ts";
import { MoodleClient } from "../../../services/moodleClient.ts";
import { siteAvailable } from "../../../services/siteSession.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Institution } from "../../../domain/institution.ts";

/** Les champs de chaque fournisseur, dans l'ordre où la notice les demande. */
const FIELDS: Record<string, { key: ConnectionKey; label: string; secret: boolean }[]> = {
  todoist: [{ key: "todoistToken", label: "Jeton d'API", secret: true }],
  notion: [
    { key: "notionToken", label: "Jeton d'intégration", secret: true },
    { key: "notionDatabaseID", label: "Identifiant de la base", secret: false },
  ],
  webhook: [{ key: "webhookURL", label: "Adresse du webhook", secret: false }],
  googleTasks: [
    { key: "googleClientID", label: "Identifiant client", secret: false },
    { key: "googleClientSecret", label: "Secret client (facultatif)", secret: true },
    { key: "googleRefreshToken", label: "Jeton de renouvellement", secret: true },
  ],
  tickTick: [{ key: "tickTickToken", label: "Jeton d'accès", secret: true }],
};

function Field({ label, children }: { label: string; children: ReactNode }) {
  return <label className="settings-form-field"><span>{label}</span>{children}</label>;
}

export function ConnectionsSection() {
  const { store, commit } = useData();
  const [feed, setFeed] = useState(() => readConnection("timetableURLString"));
  const [busy, setBusy] = useState<string | null>(null);
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [moodle, setMoodle] = useState<string>("");
  const [open, setOpen] = useState<string | null>(null);
  const [, bump] = useState(0);

  const persistence = (): Persistence | null => (store ? { store, commit } : null);
  const run = async (name: string, work: (p: Persistence) => Promise<string>) => {
    const p = persistence();
    if (!p) return;
    setBusy(name);
    try {
      const message = await work(p);
      setNotes((current) => ({ ...current, [name]: message }));
    } catch (error) {
      setNotes((current) => ({ ...current, [name]: error instanceof Error ? error.message : String(error) }));
    } finally {
      setBusy(null);
    }
  };

  const moodleName = Institution.current.name;

  return (
    <Section title="Connexions">
      <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <Card>
        <SettingRow label="Horaire (.ics)"
          hint={notes.timetable ?? "L'adresse d'abonnement de « Mon horaire » : les cours, exercices et leurs salles arrivent seuls. Relu au lancement."}>
          <div className="settings-inline">
            <input className="field" type="url" placeholder="https://… ou webcal://…" value={feed} aria-label="Adresse de l'horaire"
              onChange={(e) => { setFeed(e.target.value); writeConnection("timetableURLString", e.target.value.trim()); }} />
            <Button size="sm" disabled={busy !== null || feed.trim() === ""}
              onClick={() => void run("timetable", (p) => refreshTimetableFeed(p, feed))}>
              {busy === "timetable" ? "Lecture…" : "Importer"}
            </Button>
            <Button size="sm" disabled={busy !== null} onClick={() => void run("timetable", async (p) => {
              const file = await pickTextFile("Horaire", ["ics"]);
              return file ? importTimetableText(p, file.text) : "Aucun fichier choisi.";
            })}>Fichier…</Button>
          </div>
        </SettingRow>
        <SettingRow label="Calendrier académique"
          hint={notes.academic ?? "Les dates du semestre, relues sur la page publique de l'EPFL (un instantané est déjà dans l'app)."}>
          <Button size="sm" disabled={busy !== null} onClick={() => void run("academic", refreshAcademicCalendar)}>
            {busy === "academic" ? "Lecture…" : "Mettre à jour"}
          </Button>
        </SettingRow>
        <SettingRow label={moodleName === "" ? "Moodle" : `Moodle · ${moodleName}`}
          hint={moodle !== "" ? moodle : siteAvailable()
            ? "Importer le contenu d'un cours se fait depuis sa page (Ajouter › Importer depuis Moodle). La connexion est gardée."
            : "La connexion se fait dans l'app Windows."}>
          <div className="settings-inline">
            <Button size="sm" disabled={!siteAvailable()} onClick={() => void MoodleClient.openLogin().catch((e: Error) => setMoodle(e.message))}>
              Se connecter
            </Button>
            <Button size="sm" disabled={!siteAvailable() || busy !== null} onClick={async () => {
              setBusy("moodle");
              setMoodle((await MoodleClient.background.isSignedIn()) ? "Connecté·e." : "Pas connecté·e.");
              setBusy(null);
            }}>Vérifier</Button>
          </div>
        </SettingRow>
      </Card>

      <Card>
        {windowsProviders.map((provider) => {
          const configured = TaskServiceFactory.service(provider) !== null;
          return (
            <div key={provider}>
              <SettingRow label={TaskProvider.label(provider)}
                hint={configured ? `${TaskProvider.capabilityLabel(provider)} — configuré.` : TaskProvider.setupSummary(provider)}>
                <Button size="sm" variant="ghost" onClick={() => setOpen(open === provider ? null : provider)}>
                  {open === provider ? "Fermer" : configured ? "Modifier" : "Configurer"}
                </Button>
              </SettingRow>
              {open === provider && (
                <div className="settings-form">
                  {FIELDS[provider].map((field) => (
                    <Field key={field.key} label={field.label}>
                      <input className="field" type={field.secret ? "password" : "text"} autoComplete="off" spellCheck={false}
                        defaultValue={readConnection(field.key)}
                        onChange={(e) => { writeConnection(field.key, e.target.value.trim()); bump((v) => v + 1); }} />
                    </Field>
                  ))}
                  <ol className="settings-hint">{TaskProvider.setupSteps(provider).map((step) => <li key={step}>{step}</li>)}</ol>
                </div>
              )}
            </div>
          );
        })}
        <SettingRow label="AnkiWeb"
          hint={notes.anki ?? (ankiWebSync.isSignedIn
            ? `Connecté·e (${ankiWebSync.username}). Le temps de révision est relevé au lancement${ankiLastSync() ? `, dernier relevé ${DateUtils.shortDay(ankiLastSync()!)} ${DateUtils.time(ankiLastSync()!)}` : ""}.`
            : "Le temps passé dans Anki, relevé sans rien saisir. Lecture seule : l'app n'écrit jamais dans ta collection.")}>
          {ankiWebSync.isSignedIn ? (
            <div className="settings-inline">
              <Button size="sm" disabled={busy !== null} onClick={() => void run("anki", (p) => syncAnki(p, true))}>
                {busy === "anki" ? "Lecture…" : "Relever maintenant"}
              </Button>
              <Button size="sm" variant="ghost" disabled={busy !== null}
                onClick={async () => { await ankiWebSync.signOut(); setNotes((n) => ({ ...n, anki: "Déconnecté·e." })); bump((v) => v + 1); }}>
                Se déconnecter
              </Button>
            </div>
          ) : (
            <Button size="sm" variant="ghost" onClick={() => setOpen(open === "anki" ? null : "anki")}>
              {open === "anki" ? "Fermer" : "Se connecter"}
            </Button>
          )}
        </SettingRow>
        {open === "anki" && !ankiWebSync.isSignedIn && (
          <form className="settings-form" onSubmit={async (event) => {
            event.preventDefault();
            const form = new FormData(event.currentTarget);
            setBusy("anki");
            const ok = await ankiWebSync.signIn(String(form.get("user") ?? "").trim(), String(form.get("password") ?? ""));
            setNotes((n) => ({ ...n, anki: ok ? "Connecté·e à AnkiWeb." : ankiWebSync.lastError ?? "Connexion impossible." }));
            if (ok) setOpen(null);
            setBusy(null);
          }}>
            <Field label="Adresse e-mail AnkiWeb"><input className="field" name="user" type="email" autoComplete="username" required /></Field>
            <Field label="Mot de passe"><input className="field" name="password" type="password" autoComplete="current-password" required /></Field>
            <div className="settings-inline"><Button type="submit" variant="primary" size="sm" disabled={busy !== null}>Se connecter</Button></div>
            <p className="settings-hint">Le mot de passe ne sert qu'à obtenir une clé, seule gardée sur cet appareil.</p>
          </form>
        )}
        <SettingRow label="Synchroniser les tâches"
          hint={notes.tasks ?? "Les tâches ouvertes apparaissent dans Aujourd'hui ; les cocher ici les coche chez le fournisseur."}>
          <Button size="sm" disabled={busy !== null || TaskServiceFactory.configuredServices().length === 0}
            onClick={() => void run("tasks", syncAllTasks)}>
            {busy === "tasks" ? "Lecture…" : "Synchroniser"}
          </Button>
        </SettingRow>
      </Card>
      </div>
    </Section>
  );
}
