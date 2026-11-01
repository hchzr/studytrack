// Compte et synchronisation — le pendant Windows de `SyncSettings` (Mac) et de
// `ConnectionsView` (iPhone). Rien n'est branché pour l'instant : on affiche
// l'état réel (base locale, aucun compte) et on ne propose aucun bouton qui
// ferait semblant de se connecter.

import { Section, Card } from "../../kit.tsx";
import { SettingRow } from "./controls.tsx";

const CONNECTIONS: readonly { title: string; purpose: string; status: string }[] = [
  { title: "Moodle", purpose: "Séries, énoncés, théorie et échéances, mis à jour tout seuls", status: "Pas connecté·e" },
  { title: "Courseware", purpose: "Vidéos des MOOC que les cours demandent de regarder", status: "Pas connecté·e" },
  { title: "Explique", purpose: "Cours en replay et exercices d'AICC (CS-101)", status: "Pas connecté·e" },
  { title: "MediaSpace", purpose: "Enregistrements des cours, lus dans l'app", status: "Pas connecté·e" },
  { title: "AnkiWeb", purpose: "Cartes, révisions et temps de révision", status: "Facultatif" },
  { title: "Calendrier", purpose: "Ton horaire et tes sessions dans l'agenda", status: "Accès à autoriser" },
];

function ConnectionCard({ title, purpose, status }: { title: string; purpose: string; status: string }) {
  return (
    <div className="settings-connection">
      <h3>{title}</h3>
      <p>{purpose}</p>
      <span className="settings-status">
        <span className="settings-status-dot" aria-hidden="true" />
        {status}
      </span>
    </div>
  );
}

export function AccountSection() {
  return (
    <>
      <Section title="Compte">
        <Card>
          <SettingRow label="Base" hint="Les données de cette installation : la base locale, synchronisée si tu l'as activée.">
            <span className="settings-value">locale</span>
          </SettingRow>
          <SettingRow label="Compte StudyTrack" hint="Groupes indisponibles dans cette version.">
            <span className="settings-value">aucun</span>
          </SettingRow>
        </Card>
        <p className="settings-footnote">
          Les données restent sur cet appareil ; la synchronisation se règle juste au-dessus. Les groupes se brancheront plus tard.
        </p>
      </Section>

      <Section title="Connexions aux sites">
        <div className="settings-connections">
          {CONNECTIONS.map((connection) => (
            <ConnectionCard key={connection.title} {...connection} />
          ))}
        </div>
        <p className="settings-footnote">
          Lecture seule pour l'instant : les connexions s'ouvriront depuis cet écran dans une prochaine version.
        </p>
      </Section>
    </>
  );
}
