// Section et semestre — la page « SchoolSetupView » du Mac, ramenée dans les
// réglages Windows. Les dates pilotent le numéro de semaine affiché partout ;
// changer de section recopie le code sur les cours qui n'en ont pas encore,
// comme le faisait l'onboarding.

import { useMemo, useState } from "react";
import { useData } from "../../../data/dataContext.tsx";
import { AcademicTerm, Course, EPFLCatalog, TermSeason } from "../../../models/index.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Section, Card } from "../../kit.tsx";
import { SettingRow, Stepper } from "./controls.tsx";
import { readSectionCode, writeSectionCode } from "./preferences.ts";

const seasons = TermSeason.allCases;

export function TermSection() {
  const { store, save, version } = useData();
  const [sectionCode, setSectionCode] = useState(() => readSectionCode());

  const terms = useMemo(
    () => (store ? AcademicTerm.sorted(store.fetch(AcademicTerm)) : []),
    [store, version],
  );
  // Même choix que `SchoolSetupView` : le semestre en cours, sinon le plus récent.
  const term = terms.find((candidate) => candidate.isRunning) ?? terms[0] ?? null;

  const changeSection = async (code: string) => {
    setSectionCode(code);
    writeSectionCode(code);
    if (!store) return;
    // Les cours déjà saisis suivent la section, sinon deux écrans diraient deux
    // vérités différentes. On modifie tout avant d'enregistrer : `save()`
    // recharge le graphe et remplacerait les références restantes.
    const untagged = store.fetch(Course).filter((course) => course.sectionCode === "");
    for (const course of untagged) course.sectionCode = code;
    for (const course of untagged) await save(course);
  };

  const changeStart = async (value: string) => {
    if (!term) return;
    const parsed = DateUtils.parse(value);
    if (!parsed) return;
    term.startDate = DateUtils.startOfWeek(parsed);
    term.endDate = DateUtils.addTeachingWeeks(term.totalWeeks, term.startDate);
    await save(term);
  };

  const changeWeeks = async (weeks: number) => {
    if (!term) return;
    term.totalWeeks = weeks;
    term.endDate = DateUtils.addTeachingWeeks(weeks, term.startDate);
    await save(term);
  };

  const changeSeason = async (raw: string) => {
    if (!term) return;
    const season = TermSeason.fromRaw(raw);
    if (!season) return;
    term.seasonRaw = season;
    await save(term);
  };

  return (
    <Section title="Section et semestre">
      <Card>
        <SettingRow label="Section EPFL" hint="Recopiée sur les cours qui n'ont pas encore de section.">
          <select
            className="settings-select"
            value={sectionCode}
            aria-label="Section EPFL"
            onChange={(event) => void changeSection(event.target.value)}
          >
            <option value="">Non renseignée</option>
            {EPFLCatalog.sections.map((section) => (
              <option key={section.code} value={section.code}>
                {section.name} ({section.code})
              </option>
            ))}
          </select>
        </SettingRow>

        {term ? (
          <>
            <SettingRow label="Début (semaine 1)">
              <input
                className="settings-input"
                type="date"
                value={DateUtils.dateOnly(term.startDate)}
                aria-label="Début du semestre"
                onChange={(event) => void changeStart(event.target.value)}
              />
            </SettingRow>

            <SettingRow label="Durée">
              <Stepper
                value={term.totalWeeks}
                min={8}
                max={24}
                label="Durée du semestre"
                format={(weeks) => `${weeks} sem.`}
                onChange={(weeks) => void changeWeeks(weeks)}
              />
            </SettingRow>

            <SettingRow label="Semestre" hint={term.displayName}>
              <select
                className="settings-select"
                value={term.season}
                aria-label="Semestre"
                onChange={(event) => void changeSeason(event.target.value)}
              >
                {seasons.map((season) => (
                  <option key={season} value={season}>{TermSeason.label(season)}</option>
                ))}
              </select>
            </SettingRow>

            <SettingRow label="Fin estimée">
              <span className="settings-value">{DateUtils.shortDay(term.endDate)}</span>
            </SettingRow>

            <SettingRow label="Semaine courante">
              <span className="settings-value mono" style={{ fontWeight: 600 }}>
                {DateUtils.clampedWeek(new Date(), term)} / {term.totalWeeks}
              </span>
            </SettingRow>
          </>
        ) : (
          <SettingRow label="Aucun semestre">
            <span className="settings-value">—</span>
          </SettingRow>
        )}
      </Card>
      <p className="settings-footnote">Dates du calendrier académique de l'EPFL.</p>
    </Section>
  );
}
