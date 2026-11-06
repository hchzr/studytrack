// Réglages › Comptes : les sites des cours (une fenêtre de connexion chacun, la session reste dans
// l'app), et Spotify. Le compte Polymestre et la synchronisation sont juste au-dessus
// (`SyncSection`). Le pendant de `ConnectionsView` (iPhone) et de « Comptes » (Mac).

import { useEffect, useState, useSyncExternalStore } from "react";
import { Button, Card, Section } from "../../kit.tsx";
import { Institution } from "../../../domain/institution.ts";
import { MoodleClient } from "../../../services/moodleClient.ts";
import { coursewareSignIn } from "../../../services/coursewareClient.ts";
import { mediaspaceSignIn } from "../../../services/mediaspace.ts";
import { edSignIn } from "../../../services/edClient.ts";
import { spotifyAccount } from "../../../services/spotifyAccount.ts";
import { SettingRow } from "./controls.tsx";

interface Site { title: string; purpose: string; open: () => Promise<void> }

function sites(): Site[] {
  return [
    { title: `Moodle (${Institution.current.name})`, purpose: "Séries, énoncés, théorie et échéances, mis à jour tout seuls.", open: () => MoodleClient.openLogin() },
    { title: "Courseware", purpose: "Les vidéos et exercices des MOOC des cours.", open: coursewareSignIn },
    { title: "MediaSpace", purpose: "Les enregistrements des cours, lus dans l'app.", open: mediaspaceSignIn },
    { title: "Ed Discussion", purpose: "Les questions et réponses des cours.", open: edSignIn },
  ];
}

export function AccountSection() {
  const [error, setError] = useState<string | null>(null);
  const spotify = useSyncExternalStore(spotifyAccount.subscribe, spotifyAccount.get);
  useEffect(() => { if (spotify.state.kind === "unknown") void spotifyAccount.refresh(); }, [spotify.state.kind]);
  const run = (action: () => Promise<void>) => { setError(null); action().catch((e: unknown) => setError(e instanceof Error ? e.message : String(e))); };
  return (
    <>
      <Section title="Sites des cours">
        <Card>
          {sites().map((site) => (
            <SettingRow key={site.title} label={site.title} hint={site.purpose}>
              <Button size="sm" onClick={() => run(site.open)}>Se connecter…</Button>
            </SettingRow>
          ))}
        </Card>
        <p className="settings-footnote">Une fois suffit : la session reste dans l'app. Ton mot de passe ne passe que par la page de ton école.</p>
      </Section>
      <Section title="Services">
        <Card>
          <SettingRow label="Spotify" hint="Pilote Spotify depuis la musique du mode étude, gratuit ou Premium. Non officiel.">
            {spotify.state.kind === "ready"
              ? <Button size="sm" onClick={() => run(() => spotifyAccount.signOut())}>Se déconnecter</Button>
              : <Button size="sm" onClick={() => run(() => spotifyAccount.signIn())}>Se connecter…</Button>}
          </SettingRow>
        </Card>
        {error && <p className="settings-error">{error}</p>}
      </Section>
    </>
  );
}
