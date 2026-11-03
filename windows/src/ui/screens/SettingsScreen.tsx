// Réglages — cinq pages, les mêmes que sur le Mac et l'iPhone : Général, Chrono, Mode étude,
// Comptes, Claude et IA. Chaque page montre l'essentiel ; les réglages rares attendent dans sa
// ligne « Avancé », repliée (retenue par page). Rien n'a été retiré : tout a sa place.

import { useState, type ReactNode } from "react";
import { PageHeader } from "../kit.tsx";
import { Icon, type IconName } from "../icons.tsx";
import { AppearanceSection } from "./settings/AppearanceSection.tsx";
import { ChronoSection } from "./settings/ChronoSection.tsx";
import { TermSection } from "./settings/TermSection.tsx";
import { CoursesSection } from "./settings/CoursesSection.tsx";
import { ConnectionsSection } from "./settings/ConnectionsSection.tsx";
import { AIReadingSection } from "./settings/AIReadingSection.tsx";
import { SyncSection } from "./settings/SyncSection.tsx";
import { AccountSection } from "./settings/AccountSection.tsx";
import { CountingSection } from "./settings/CountingSection.tsx";
import { StudyModeSection } from "./settings/StudyModeSection.tsx";
import { readPreference, writePreference } from "./settings/preferences.ts";
import "./settings/settings.css";

type Page = "general" | "chrono" | "study" | "accounts" | "claude";

const PAGES: { id: Page; title: string; icon: IconName; subtitle: string; advanced: string | null }[] = [
  { id: "general", title: "Général", icon: "gearshape", subtitle: "Apparence, semestre et cours.", advanced: "Horaire (.ics), calendrier académique, AnkiWeb, tâches." },
  { id: "chrono", title: "Chrono", icon: "timer", subtitle: "Objectif, Pomodoro et ce qui compte dans tes heures.", advanced: null },
  { id: "study", title: "Mode étude", icon: "moon", subtitle: "Ce que le mode étude propose en s'ouvrant.", advanced: "Ouvrir sans heure de fin." },
  { id: "accounts", title: "Comptes", icon: "person", subtitle: "Ton compte, la synchronisation, les sites des cours, Spotify.", advanced: null },
  { id: "claude", title: "Claude et IA", icon: "sparkles", subtitle: "L'IA qui lit tes PDF.", advanced: null },
];

const PAGE_KEY = "settings.page";

export function SettingsScreen() {
  const [page, setPage] = useState<Page>(() => {
    // `?settings=study` : ouvrir une page précise (captures, liens internes).
    const saved = new URLSearchParams(window.location.search).get("settings") ?? readPreference(PAGE_KEY);
    return PAGES.some((p) => p.id === saved) ? (saved as Page) : "general";
  });
  const [advanced, setAdvanced] = useState(() => new URLSearchParams(window.location.search).has("advanced") || readPreference(`settings.advanced.${page}`) === "true");
  const current = PAGES.find((p) => p.id === page) ?? PAGES[0];
  const choose = (next: Page) => {
    setPage(next);
    writePreference(PAGE_KEY, next);
    setAdvanced(readPreference(`settings.advanced.${next}`) === "true");
  };
  const toggleAdvanced = () => {
    const next = !advanced;
    setAdvanced(next);
    writePreference(`settings.advanced.${page}`, next ? "true" : "false");
  };

  return (
    <div className="settings-layout">
      <nav className="settings-nav" aria-label="Pages des réglages">
        {PAGES.map((item) => (
          <button key={item.id} type="button" className="settings-nav-item" aria-current={item.id === page ? "page" : undefined} onClick={() => choose(item.id)}>
            <Icon name={item.icon} size={16} />
            <span>{item.title}</span>
          </button>
        ))}
      </nav>
      <div className="settings-screen">
        <PageHeader title={current.title} subtitle={current.subtitle} />
        {pageContent(page, advanced)}
        {current.advanced && <AdvancedToggle open={advanced} summary={current.advanced} onToggle={toggleAdvanced} />}
        {advanced && page === "general" && <ConnectionsSection />}
      </div>
    </div>
  );
}

function pageContent(page: Page, advanced: boolean): ReactNode {
  switch (page) {
    case "general": return <><AppearanceSection /><TermSection /><CoursesSection /></>;
    case "chrono": return <><ChronoSection /><CountingSection /></>;
    case "study": return <StudyModeSection advanced={advanced} />;
    case "accounts": return <><SyncSection /><AccountSection /></>;
    case "claude": return <AIReadingSection />;
  }
}

/** « Avancé » : repliée, elle dit en une ligne ce qu'elle cache. */
function AdvancedToggle({ open, summary, onToggle }: { open: boolean; summary: string; onToggle: () => void }) {
  return (
    <button type="button" className="settings-advanced" aria-expanded={open} onClick={onToggle}>
      <Icon name="slider.horizontal.3" size={16} />
      <span className="settings-advanced-text">
        <span className="settings-label">Avancé</span>
        {!open && <span className="settings-hint">{summary}</span>}
      </span>
      <Icon name="chevron.right" size={14} style={{ transform: open ? "rotate(90deg)" : undefined, transition: "transform var(--t-fast)" }} />
    </button>
  );
}
