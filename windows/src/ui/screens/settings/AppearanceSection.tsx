// Apparence : clair, sombre, ou le réglage du système. Le Mac suit l'apparence
// de macOS ; sur Windows on garde le même choix explicite, appliqué sur
// `<html data-theme>` pour que tokens.css bascule toute la palette.

import { useEffect, useState } from "react";
import { Section, Card, Segmented } from "../../kit.tsx";
import { SettingRow } from "./controls.tsx";
import {
  applyAppearance, readAppearance, writePreference, PREFERENCE_KEYS, type Appearance,
} from "./preferences.ts";

const CHOICES: readonly { value: Appearance; label: string }[] = [
  { value: "system", label: "Système" },
  { value: "light", label: "Clair" },
  { value: "dark", label: "Sombre" },
];

export function AppearanceSection() {
  const [appearance, setAppearance] = useState<Appearance>(() => readAppearance());

  // Le module a déjà appliqué le thème au chargement ; cet effet couvre un
  // changement venu d'un autre onglet ou un remontage de l'écran.
  useEffect(() => { applyAppearance(appearance); }, [appearance]);

  const choose = (value: Appearance) => {
    setAppearance(value);
    writePreference(PREFERENCE_KEYS.appearance, value);
    applyAppearance(value);
  };

  return (
    <Section title="Apparence">
      <Card>
        <SettingRow
          label="Thème"
          hint="« Système » suit le réglage de Windows ; le choix reste sur cet appareil."
        >
          <Segmented ariaLabel="Thème" value={appearance} options={[...CHOICES]} onChange={choose} />
        </SettingRow>

        <div className="settings-preview" aria-hidden="true">
          <div className="settings-preview-sheet">
            <span className="serif" style={{ fontSize: 19 }}>Carnet</span>
            <span style={{ color: "var(--ink-secondary)", fontSize: 12 }}>
              Le papier, l'encre et les filets suivent le thème.
            </span>
          </div>
        </div>
      </Card>
    </Section>
  );
}
