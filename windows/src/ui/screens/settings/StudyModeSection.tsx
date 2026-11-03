// Réglages › Mode étude (StudySettingsPane du Mac) : ce que le mode étude propose en s'ouvrant —
// la durée, le blocage, le Pomodoro — et la veille. Les mêmes clés que l'écran du mode étude, qui
// retient aussi le dernier choix fait là-bas.

import { useState } from "react";
import { Card, Section, Stepper, Switch } from "../../kit.tsx";
import { readStudyLocks, studyDuration, studyOpenEnded, studyPomodoro, writeStudyLocks } from "../../studymode/studyPalette.ts";
import { studyLockNote } from "../../../native/studyLock.ts";
import { SettingRow } from "./controls.tsx";
import { KeepAwakeRow } from "./ChronoSection.tsx";

export function StudyModeSection({ advanced }: { advanced: boolean }) {
  const [minutes, setMinutes] = useState(studyDuration.read);
  const [locks, setLocks] = useState(readStudyLocks);
  const [pomodoro, setPomodoro] = useState(studyPomodoro.read);
  const [openEnded, setOpenEnded] = useState(studyOpenEnded.read);
  return (
    <>
      <Section title="Session">
        <Card>
          <SettingRow label="Durée" hint="Proposée en ouvrant le mode étude ; un cours à suivre prend sa propre fin.">
            <Stepper value={minutes} min={15} max={240} step={5} label="durée" format={(v) => `${v} min`}
              onChange={(v) => { studyDuration.write(v); setMinutes(v); }} />
          </SettingRow>
          <SettingRow label="Bloquer le reste" hint={studyLockNote()}>
            <Switch checked={locks} ariaLabel="Bloquer le reste" onChange={(v) => { writeStudyLocks(v); setLocks(v); }} />
          </SettingRow>
          <SettingRow label="Pomodoro" hint="Coché d'office en ouvrant le mode étude.">
            <Switch checked={pomodoro} ariaLabel="Pomodoro" onChange={(v) => { studyPomodoro.write(v); setPomodoro(v); }} />
          </SettingRow>
          <KeepAwakeRow />
        </Card>
      </Section>
      {advanced && (
        <Section title="Avancé">
          <Card>
            <SettingRow label="Sans heure de fin" hint="Le mode étude s'ouvre sans durée : tu termines quand tu as fini.">
              <Switch checked={openEnded} ariaLabel="Sans heure de fin" onChange={(v) => { studyOpenEnded.write(v); setOpenEnded(v); }} />
            </SettingRow>
          </Card>
        </Section>
      )}
    </>
  );
}
