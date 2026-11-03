// Chrono et objectif — le volet « Chrono » de `PomodoroSettingsPane` (Mac).
// Les valeurs s'écrivent sous les mêmes clés que celles que l'écran Chrono relit
// (`focusSettings.ts`) : un changement ici se retrouve au prochain affichage du
// chrono. Rester sur la valeur par défaut n'écrit rien de plus que le choix.
//
// Le chrono flottant et « Garder éveillé » (volet Mode étude du Mac) vivent
// dans la couche native (src/native/settings.ts). Hors de portée sur Windows :
// sons, temps dans la barre des menus.

import { useState } from "react";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { makePomodoroSettings } from "../../../domain/pomodoroEngine.ts";
import { Card, Section, Select, Stepper, Switch } from "../../kit.tsx";
import { readFloatingTimer, readKeepAwakeMode, writeFloatingTimer, writeKeepAwakeMode } from "../../../native/settings.ts";
import type { KeepAwakeMode } from "../../../domain/keepAwakePolicy.ts";
import { readFocusSettings } from "../focus/focusSettings.ts";
import { SettingRow } from "./controls.tsx";
import { writePreference } from "./preferences.ts";

type Settings = ReturnType<typeof readFocusSettings>;

/** Les clés partagées avec l'écran Chrono (`readFocusSettings`). */
const KEYS = {
  weeklyGoalMinutes: "settings.weeklyGoalMinutes",
  pomodoroDefault: "settings.pomodoroDefault",
  focusMinutes: "settings.pomodoroFocusMinutes",
  shortBreakMinutes: "settings.pomodoroBreakMinutes",
  longBreakMinutes: "settings.pomodoroLongBreakMinutes",
  longBreakEvery: "settings.pomodoroLongBreakEvery",
  autoStartFocus: "settings.pomodoroAutoStartFocus",
} as const;

/** Le pied du choix « Garder éveillé », repris du Mac (« le Mac » → « le PC »). */
const KEEP_AWAKE_FOOTER: Record<KeepAwakeMode, string> = {
  off: "Le PC se met en veille comme d'habitude.",
  system: "Seulement pendant que le chrono tourne : la musique continue, l'écran s'éteint comme d'habitude. En pause, le PC dort.",
  display: "Seulement pendant que le chrono tourne. L'écran peut s'éteindre pendant une pause Pomodoro, en mode économie d'énergie ou sous 20 % de batterie. Fermer le capot endort toujours le PC.",
};

/** « Garder éveillé » (Réglages › Mode étude). */
export function KeepAwakeRow() {
  const [keepAwake, setKeepAwake] = useState<KeepAwakeMode>(readKeepAwakeMode);
  return (
    <SettingRow label="Garder éveillé" hint={KEEP_AWAKE_FOOTER[keepAwake]}>
      <Select<KeepAwakeMode> value={keepAwake} ariaLabel="Garder éveillé"
        options={[
          { value: "off", label: "Non" },
          { value: "system", label: "Le PC" },
          { value: "display", label: "Le PC et l'écran" },
        ]}
        onChange={(value) => { writeKeepAwakeMode(value); setKeepAwake(value); }} />
    </SettingRow>
  );
}

export function ChronoSection() {
  const [settings, setSettings] = useState<Settings>(() => readFocusSettings());
  const [floating, setFloating] = useState(readFloatingTimer);
  const { cycle } = settings;

  const setNumber = (key: string, apply: (current: Settings) => Settings) => (value: number) => {
    writePreference(key, String(value));
    setSettings((current) => apply(current));
  };
  const setFlag = (key: string, apply: (current: Settings, value: boolean) => Settings) => (value: boolean) => {
    writePreference(key, value ? "true" : "false");
    setSettings((current) => apply(current, value));
  };
  const setCycle = (patch: Partial<Settings["cycle"]>) => (current: Settings): Settings =>
    ({ ...current, cycle: makePomodoroSettings({ ...current.cycle, ...patch }) });

  return (
    <>
      <Section title="Chrono">
        <Card>
          <SettingRow label="Objectif de la semaine" hint="À zéro, la charge EPFL des cours suivis fait foi.">
            <Stepper
              value={settings.weeklyGoalMinutes} min={0} max={6000} step={60} label="objectif de la semaine"
              format={(minutes) => (minutes === 0 ? "Charge EPFL" : DateUtils.hoursLabel(minutes * 60))}
              onChange={setNumber(KEYS.weeklyGoalMinutes, (c) => c)}
            />
          </SettingRow>
        </Card>
      </Section>

      <Section title="Pomodoro">
        <Card>
          <SettingRow label="Démarrer en Pomodoro" hint="Coché d'office pour une nouvelle session.">
            <Switch
              checked={settings.pomodoroDefault} ariaLabel="Démarrer en Pomodoro"
              onChange={setFlag(KEYS.pomodoroDefault, (c, v) => ({ ...c, pomodoroDefault: v }))}
            />
          </SettingRow>
          <SettingRow label="Bloc de travail">
            <Stepper value={cycle.focusMinutes} min={5} max={120} step={5} label="bloc de travail"
              format={(value) => `${value} min`}
              onChange={(value) => setNumber(KEYS.focusMinutes, setCycle({ focusMinutes: value }))(value)} />
          </SettingRow>
          <SettingRow label="Pause courte">
            <Stepper value={cycle.shortBreakMinutes} min={1} max={30} label="pause courte"
              format={(value) => `${value} min`}
              onChange={(value) => setNumber(KEYS.shortBreakMinutes, setCycle({ shortBreakMinutes: value }))(value)} />
          </SettingRow>
          <SettingRow label="Pause longue">
            <Stepper value={cycle.longBreakMinutes} min={5} max={60} step={5} label="pause longue"
              format={(value) => `${value} min`}
              onChange={(value) => setNumber(KEYS.longBreakMinutes, setCycle({ longBreakMinutes: value }))(value)} />
          </SettingRow>
          <SettingRow label="Pause longue tous les">
            <Stepper value={cycle.longBreakEvery} min={2} max={8} label="fréquence de la pause longue"
              format={(value) => `${value} blocs`}
              onChange={(value) => setNumber(KEYS.longBreakEvery, setCycle({ longBreakEvery: value }))(value)} />
          </SettingRow>
          <SettingRow label="Relancer après la pause">
            <Switch
              checked={cycle.autoStartFocus} ariaLabel="Relancer après la pause"
              onChange={setFlag(KEYS.autoStartFocus, (c, v) => setCycle({ autoStartFocus: v })(c))}
            />
          </SettingRow>
        </Card>
        <p className="settings-footnote">Les nouvelles durées s'appliquent à la prochaine session.</p>
      </Section>
      <Section title="Fenêtre">
        <Card>
          <SettingRow label="Chrono flottant" hint="Une petite fenêtre au-dessus des autres pendant une session.">
            <Switch checked={floating} ariaLabel="Chrono flottant"
              onChange={(value) => { writeFloatingTimer(value); setFloating(value); }} />
          </SettingRow>
        </Card>
      </Section>
    </>
  );
}
