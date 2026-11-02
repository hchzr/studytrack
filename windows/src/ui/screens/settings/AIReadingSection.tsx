// « IA de lecture » : l'analyse par modèle de langage à l'import d'une série
// (`settings.aiExtractionEnabled`, activée par défaut). Le service est la fonction
// Supabase `extract-series` : aucune clé n'est saisie dans l'app. « Tester » dit si
// elle est joignable, déployée ou en échec — trois gestes différents à faire.

import { useState } from "react";
import { Button, Card, Section, Switch } from "../../kit.tsx";
import { readAIExtraction, writeAIExtraction } from "../../../native/settings.ts";
import { SeriesAIExtractor, type SharedVerdict } from "../../../services/seriesAIExtractor.ts";
import { SettingRow } from "./controls.tsx";

function describe(verdict: SharedVerdict): string {
  switch (verdict.kind) {
    case "ready": return "La fonction d'analyse répond.";
    case "notDeployed": return `La fonction d'analyse n'est pas déployée sur le projet Supabase (HTTP ${verdict.status}). L'import par motifs fonctionne quand même.`;
    case "failing": return `La fonction répond mais l'analyse échoue : ${verdict.detail}`;
    case "unconfigured": return "Aucun projet Supabase n'est configuré dans cette version : l'import se fait par motifs.";
  }
}

export function AIReadingSection() {
  const [enabled, setEnabled] = useState(readAIExtraction);
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState<string | null>(null);

  const test = async () => {
    setTesting(true);
    setResult(null);
    try { setResult(describe(await SeriesAIExtractor.diagnoseShared())); } finally { setTesting(false); }
  };

  return (
    <Section title="IA de lecture">
      <Card>
        <SettingRow label="Analyser les PDF avec l'IA"
          hint="À l'import d'une série, un modèle relit les pages pour les questions et les bonus. Tu relis toujours avant d'importer.">
          <Switch checked={enabled} ariaLabel="Analyser les PDF avec l'IA"
            onChange={(value) => { writeAIExtraction(value); setEnabled(value); }} />
        </SettingRow>
        <SettingRow label="Service" hint={result ?? "IA StudyTrack, sans clé à saisir."}>
          <Button size="sm" onClick={() => void test()} disabled={testing || !enabled}>{testing ? "Test…" : "Tester"}</Button>
        </SettingRow>
      </Card>
    </Section>
  );
}
