// La coquille de l'app : une barre latérale et une page, comme le
// `NavigationSplitView` du Mac (MacRootView.swift). Pages : aujourd'hui, cours,
// chrono, agenda, stats, réglages ; un cours ouvre sa page détaillée.

import { useEffect, useMemo, useRef, useState } from "react";
import { useData } from "../data/dataContext.tsx";
import { Course } from "../models/index.ts";
import { timerController } from "./timerController.ts";
import { TodayScreen } from "./screens/TodayScreen.tsx";
import { CoursesScreen } from "./screens/CoursesScreen.tsx";
import { CourseScreen } from "./screens/CourseScreen.tsx";
import { FocusScreen } from "./screens/FocusScreen.tsx";
import { AgendaScreen } from "./screens/AgendaScreen.tsx";
import { StatsScreen } from "./screens/StatsScreen.tsx";
import { SettingsScreen } from "./screens/SettingsScreen.tsx";
import { StudyModeView } from "./studymode/StudyModeView.tsx";

export type Page =
  | { kind: "today" } | { kind: "courses" } | { kind: "focus" }
  | { kind: "agenda" } | { kind: "stats" } | { kind: "settings" }
  | { kind: "course"; id: string };

type TabKind = Exclude<Page["kind"], "course">;
const TABS: { kind: TabKind; label: string }[] = [
  { kind: "today", label: "Aujourd'hui" },
  { kind: "courses", label: "Cours" },
  { kind: "focus", label: "Chrono" },
  { kind: "agenda", label: "Agenda" },
  { kind: "stats", label: "Stats" },
  { kind: "settings", label: "Réglages" },
];

/** La page demandée dans l'adresse (`?page=…`), ou rien. */
function pageFromParams(): Page | null {
  const raw = new URLSearchParams(window.location.search).get("page");
  if (!raw) return null;
  if (raw.startsWith("course:")) return { kind: "course", id: raw.slice("course:".length) };
  if (TABS.some((t) => t.kind === raw)) return { kind: raw as TabKind };
  return null;
}

export function Shell() {
  const { store } = useData();
  // La page de départ sur l'adresse, pour les captures et les essais —
  // l'équivalent du `-debugPage` du Mac (`?page=course:<id>`, `?page=agenda`).
  const [page, setPage] = useState<Page>(() => pageFromParams() ?? { kind: "today" });
  // `?study=1` : le mode étude ouvert d'office (l'équivalent du `-studyPreview`
  // du Mac — l'écran sans rien bloquer, pour les essais et les captures).
  // `?study=begin:50` : et la session lancée d'office (le `-debugTimer start`
  // du Mac), sur le premier cours suivi — une session de mode étude sans
  // toucher un bouton.
  const [studyMode, setStudyMode] = useState(() =>
    new URLSearchParams(window.location.search).get("study") !== null);
  const begun = useRef(false);
  useEffect(() => {
    if (!store || begun.current) return;
    begun.current = true;
    const raw = new URLSearchParams(window.location.search).get("study");
    if (!raw?.startsWith("begin:")) return;
    const minutes = Number(raw.slice("begin:".length));
    const course = store.fetch(Course).filter((c) => c.isTracked).sort((a, b) => a.code.localeCompare(b.code))[0];
    timerController.enterStudy(Number.isFinite(minutes) && minutes > 0 ? minutes : 50, {
      courseID: course?.id,
      taskType: "exercise",
    });
  }, [store]);

  // La barre latérale liste les cours suivis, comme le Mac (tracked,
  // MacRootView.swift) — pas `isActive`, qui n'y filtre rien.
  const courses = useMemo(
    () => (store ? store.fetch(Course).filter((c) => c.isTracked).sort((a, b) => a.code.localeCompare(b.code)) : []),
    [store],
  );

  if (!store) return <div style={{ padding: 40, color: "var(--ink-secondary)" }}>Chargement…</div>;

  const current = page.kind === "course" ? store.fetch(Course).find((c) => c.id === page.id) ?? null : null;
  const activeKey = page.kind === "course" ? `course:${page.id}` : page.kind;

  return (
    <div style={{ display: "flex", height: "100vh", overflow: "hidden" }}>
      <nav style={{ width: 240, flexShrink: 0, background: "var(--ground)", borderRight: "1px solid var(--rule)",
        padding: 12, display: "flex", flexDirection: "column", gap: 2, overflowY: "auto" }}>
        <div className="serif" style={{ fontSize: 22, padding: "8px 10px 12px" }}>StudyTrack</div>
        <button onClick={() => setStudyMode(true)} className="card" style={{ margin: "0 6px 10px", padding: "8px 10px", textAlign: "left", background: "var(--sheet-raised)" }}>Entrer en mode étude</button>
        {TABS.map((t) => (
          <SidebarRow key={t.kind} label={t.label} active={activeKey === t.kind} onClick={() => setPage({ kind: t.kind })} />
        ))}
        {courses.length > 0 && (
          <div style={{ marginTop: 16, padding: "6px 10px", fontSize: 11, textTransform: "uppercase",
            letterSpacing: 0.5, color: "var(--ink-tertiary)" }}>Mes cours</div>
        )}
        {courses.map((c) => (
          <SidebarRow key={c.id} label={c.name} dotColor={c.colorHex} active={activeKey === `course:${c.id}`}
            onClick={() => setPage({ kind: "course", id: c.id })} />
        ))}
      </nav>
      <main style={{ flex: 1, overflowY: "auto", padding: 28 }}>
        {page.kind === "today" && <TodayScreen onOpenCourse={(id) => setPage({ kind: "course", id })} />}
        {page.kind === "courses" && <CoursesScreen onOpenCourse={(id) => setPage({ kind: "course", id })} />}
        {page.kind === "focus" && <FocusScreen onEnterStudyMode={() => setStudyMode(true)} />}
        {page.kind === "agenda" && <AgendaScreen />}
        {page.kind === "stats" && <StatsScreen />}
        {page.kind === "settings" && <SettingsScreen />}
        {page.kind === "course" && current && <CourseScreen course={current} />}
        {page.kind === "course" && !current && <p>Cours introuvable.</p>}
      </main>
      {studyMode && <StudyModeView onExit={() => setStudyMode(false)} />}
    </div>
  );
}

function SidebarRow({ label, active, onClick, dotColor }:
  { label: string; active: boolean; onClick: () => void; dotColor?: string }) {  return (
    <button onClick={onClick} style={{
      display: "flex", alignItems: "center", gap: 8, width: "100%", textAlign: "left",
      padding: "8px 10px", borderRadius: 10, border: "none",
      background: active ? "var(--selection)" : "transparent",
      color: active ? "#fff" : "var(--ink)", fontSize: 14,
    }}>
      {dotColor && <span style={{ width: 9, height: 9, borderRadius: 3, background: dotColor, flexShrink: 0 }} />}
      <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{label}</span>
    </button>
  );
}

