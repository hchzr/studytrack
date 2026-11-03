// Réglages › Chrono › « Ce qui compte » (CountingSection.swift) : ce qui entre dans tes heures
// travaillées — Aujourd'hui, le bilan, la charge, les groupes.

import { useState } from "react";
import { Card, Section, Select, Switch } from "../../kit.tsx";
import { readCounting, writeCounting, type Counting, type LectureCounting } from "../../../domain/studyCounting.ts";
import { SettingRow } from "./controls.tsx";

const FOOTER: Record<LectureCounting, string> = {
  automatic: "Un cours compte une fois fini, sauf marqué manqué. Jamais compté deux fois avec un chrono.",
  confirmed: "Un cours compte quand tu le coches dans l'agenda (« J'y étais »).",
  off: "Les cours en amphi ne comptent pas, même chronométrés.",
};

export function CountingSection() {
  const [counting, setCounting] = useState<Counting>(readCounting);
  const update = (patch: Partial<Counting>) => {
    const next = { ...counting, ...patch };
    writeCounting(next);
    setCounting(next);
  };
  const flag = (label: string, key: "exerciseSessions" | "timer" | "manual" | "anki") => (
    <SettingRow label={label}>
      <Switch checked={counting[key]} ariaLabel={label} onChange={(value) => update({ [key]: value })} />
    </SettingRow>
  );
  return (
    <Section title="Ce qui compte">
      <Card>
        <SettingRow label="Cours en amphi">
          <Select<LectureCounting> value={counting.lectures} ariaLabel="Cours en amphi"
            options={[{ value: "automatic", label: "Tout seuls" }, { value: "confirmed", label: "Si confirmés" }, { value: "off", label: "Jamais" }]}
            onChange={(value) => update({ lectures: value })} />
        </SettingRow>
        {flag("Séances d'exercices de l'horaire", "exerciseSessions")}
        {flag("Chrono", "timer")}
        {flag("Saisies à la main", "manual")}
        {flag("Anki", "anki")}
      </Card>
      <p className="settings-footnote">{FOOTER[counting.lectures]}</p>
    </Section>
  );
}
