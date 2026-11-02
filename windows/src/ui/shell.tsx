// La coquille de l'app : une barre latérale et une page, comme le
// `NavigationSplitView` du Mac (MacRootView.swift). En haut les pages
// (aujourd'hui, chrono avec son horloge, agenda, bilan), puis les cours suivis
// (anneau d'avancement, retard, menu contextuel), et en bas le bouton du mode
// étude et l'état de la synchronisation. Ctrl+K cherche, Ctrl+Maj+E ouvre le
// mode étude. Réglages : la roue en bas (le Mac les met dans leur fenêtre, ⌘,).

import { lazy, Suspense, useEffect, useMemo, useRef, useState, useSyncExternalStore, type MouseEvent as ReactMouseEvent, type ReactNode } from "react";
import { useData } from "../data/dataContext.tsx";
import { Course } from "../models/index.ts";
import { ProgressEngine } from "../domain/progressEngine.ts";
import { syncService, type SyncStatus } from "../services/syncService.ts";
import { timerController } from "./timerController.ts";
import { displayClockOf } from "./screens/focus/timerView.ts";
import { EmptyState, Icon, IconButton, cx, useContextMenu, type IconName } from "./kit.tsx";
import { TodayScreen } from "./screens/TodayScreen.tsx";
import { CoursesScreen } from "./screens/CoursesScreen.tsx";
import { CourseScreen } from "./screens/CourseScreen.tsx";
import { FocusScreen } from "./screens/FocusScreen.tsx";
import { AgendaScreen } from "./screens/AgendaScreen.tsx";
import { StatsScreen } from "./screens/StatsScreen.tsx";
import { SettingsScreen } from "./screens/SettingsScreen.tsx";
import { StudyModeView } from "./studymode/StudyModeView.tsx";
import "./shell.css";

// La palette n'est chargée qu'au premier Ctrl+K : rien au démarrage.
const CommandPalette = lazy(() => import("./palette/CommandPalette.tsx").then((m) => ({ default: m.CommandPalette })));

export type Page =
  | { kind: "today" } | { kind: "courses" } | { kind: "focus" }
  | { kind: "agenda" } | { kind: "stats" } | { kind: "settings" }
  | { kind: "course"; id: string; item?: string | null };

type TabKind = Exclude<Page["kind"], "course">;
const TABS: { kind: TabKind; label: string; icon: IconName }[] = [
  { kind: "today", label: "Aujourd'hui", icon: "sun.max" },
  { kind: "focus", label: "Chrono", icon: "timer" },
  { kind: "agenda", label: "Agenda", icon: "calendar" },
  { kind: "stats", label: "Bilan", icon: "chart.bar.xaxis" },
];
const PAGE_KINDS: TabKind[] = ["today", "courses", "focus", "agenda", "stats", "settings"];

/** La page demandée dans l'adresse (`?page=…`), ou rien. */
function pageFromParams(): Page | null {
  const raw = new URLSearchParams(window.location.search).get("page");
  if (!raw) return null;
  if (raw.startsWith("course:")) return { kind: "course", id: raw.slice("course:".length) };
  if ((PAGE_KINDS as string[]).includes(raw)) return { kind: raw as TabKind };
  return null;
}

export function Shell() {
  const { store, save, remove } = useData();
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
  const [studyCourse, setStudyCourse] = useState<string | undefined>(undefined);
  const [palette, setPalette] = useState(false);
  const begun = useRef(false);
  const menu = useContextMenu();

  // Les sessions s'écrivent dès que les données sont ouvertes, quel que soit
  // l'écran d'où le chrono part (barre latérale, mode étude, palette).
  useEffect(() => {
    if (store) timerController.attach({ store, save, remove });
  }, [store, save, remove]);

  useEffect(() => {
    if (!store || begun.current) return;
    begun.current = true;
    const raw = new URLSearchParams(window.location.search).get("study");
    if (!raw?.startsWith("begin:")) return;
    const minutes = Number(raw.slice("begin:".length));
    const course = trackedOf(store.fetch(Course))[0];
    timerController.enterStudy(Number.isFinite(minutes) && minutes > 0 ? minutes : 50, {
      courseID: course?.id,
      taskType: "exercise",
    });
  }, [store]);

  // Ctrl+K : chercher ; Ctrl+Maj+E : le mode étude (⌘K et ⇧⌘E du Mac).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
      const key = e.key.toLowerCase();
      if (key === "k" && !e.shiftKey) { e.preventDefault(); setPalette((open) => !open); }
      if (key === "e" && e.shiftKey) { e.preventDefault(); openStudy(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // La barre latérale liste les cours suivis, comme le Mac (tracked,
  // MacRootView.swift) — pas `isActive`, qui n'y filtre rien.
  const courses = useMemo(() => (store ? trackedOf(store.fetch(Course)) : []), [store]);
  const snap = useSyncExternalStore(timerController.subscribe, timerController.snapshot);
  const timedCourseID = snap.state ? snap.state.courseID : undefined;

  if (!store) return <div className="shell-loading">Chargement…</div>;

  const current = page.kind === "course" ? store.fetch(Course).find((c) => c.id === page.id) ?? null : null;
  const activeKey = page.kind === "course" ? `course:${page.id}` : page.kind;
  const openCourse = (id: string, item?: string | null) => setPage({ kind: "course", id, item });
  function openStudy(courseID?: string) { setStudyCourse(courseID); setStudyMode(true); }

  const courseMenu = (course: Course) => menu.open([
    { label: "Chronométrer", icon: "timer", action: () => {
      timerController.chooseCourse(course.id);
      if (timerController.phase().type === "idle") timerController.start();
      setPage({ kind: "focus" });
    } },
    { label: "Mode étude…", icon: "moon", action: () => openStudy(course.id) },
    { label: "Ouvrir", icon: "arrow.right", action: () => openCourse(course.id) },
    "divider",
    { label: "Archiver", icon: "tray", action: async () => {
      course.isTracked = false;
      await save(course);
      if (page.kind === "course" && page.id === course.id) setPage({ kind: "today" });
    } },
  ]);

  return (
    <div className="shell">
      <nav className="sidebar" aria-label="Navigation">
        <div className="sidebar-scroll">
          <div className="sidebar-brand serif">StudyTrack</div>
          <div className="sidebar-group">
            {TABS.map((t) => (
              <SidebarRow key={t.kind} icon={t.icon} label={t.label} active={activeKey === t.kind}
                onClick={() => setPage({ kind: t.kind })}
                trailing={t.kind === "focus" ? <SidebarClock /> : undefined} />
            ))}
          </div>

          <div className="sidebar-heading">
            <button type="button" className={cx("sidebar-heading-link", activeKey === "courses" && "active")}
              onClick={() => setPage({ kind: "courses" })}>Cours</button>
            <IconButton icon="plus" label="Ajouter un cours" size="sm"
              onClick={() => setPage({ kind: "courses" })} />
          </div>
          <div className="sidebar-group">
            {courses.map((c) => (
              <CourseRow key={c.id} course={c} active={activeKey === `course:${c.id}`}
                timed={timedCourseID === c.id}
                onClick={() => openCourse(c.id)} onContextMenu={courseMenu(c)} />
            ))}
            {courses.length === 0 && <p className="sidebar-empty">Aucun cours suivi.</p>}
          </div>
        </div>

        <div className="sidebar-footer">
          <button type="button" className="study-button" onClick={() => openStudy()}>
            <Icon name="moon" size={15} />
            <span>{timerController.isStudying ? "Revenir au mode étude" : "Mode étude"}</span>
            <kbd>Ctrl ⇧ E</kbd>
          </button>
          <div className="hstack">
            <SyncFooter />
            <span className="spacer" />
            <IconButton icon="magnifyingglass" label="Chercher (Ctrl+K)" size="sm" onClick={() => setPalette(true)} />
            <IconButton icon="gearshape" label="Réglages" size="sm"
              className={activeKey === "settings" ? "active" : undefined}
              onClick={() => setPage({ kind: "settings" })} />
          </div>
        </div>
      </nav>

      <main className="shell-main">
        {page.kind === "today" && (courses.length === 0
          ? <NoCourses onAdd={() => setPage({ kind: "courses" })} />
          : <TodayScreen onOpenCourse={openCourse} onOpenFocus={() => setPage({ kind: "focus" })}
              onEnterStudyMode={(courseID) => openStudy(courseID)} />)}
        {page.kind === "courses" && <CoursesScreen onOpenCourse={openCourse} />}
        {page.kind === "focus" && <FocusScreen onEnterStudyMode={() => openStudy()} />}
        {page.kind === "agenda" && <AgendaScreen onOpenCourse={openCourse} />}
        {page.kind === "stats" && <StatsScreen />}
        {page.kind === "settings" && <SettingsScreen />}
        {page.kind === "course" && current && <CourseScreen key={`${current.id}:${page.kind === "course" ? page.item ?? "" : ""}`} course={current}
          focusTarget={page.kind === "course" ? page.item : null} />}
        {page.kind === "course" && !current && <EmptyState icon="books.vertical" title="Cours introuvable" />}
      </main>

      {studyMode && <StudyModeView initialCourseID={studyCourse} onExit={() => setStudyMode(false)} />}
      {palette && (
        <Suspense fallback={null}>
          <CommandPalette
            onClose={() => setPalette(false)}
            onOpenCourse={(id, item) => { setPalette(false); openCourse(id, item); }}
            onNavigate={(kind) => { setPalette(false); setPage({ kind }); }}
            onStudyMode={() => { setPalette(false); openStudy(); }}
          />
        </Suspense>
      )}
      {menu.element}
    </div>
  );
}

function trackedOf(all: Course[]): Course[] {
  return all.filter((c) => c.isTracked).sort((a, b) => a.code.localeCompare(b.code));
}

function SidebarRow({ icon, label, active, onClick, trailing }:
  { icon: IconName; label: string; active: boolean; onClick: () => void; trailing?: ReactNode }) {
  return (
    <button type="button" className={cx("sidebar-row", active && "active")} onClick={onClick}
      aria-current={active ? "page" : undefined}>
      <Icon name={icon} size={16} className="sidebar-row-icon" />
      <span className="sidebar-row-label">{label}</span>
      {trailing}
    </button>
  );
}

/**
 * L'horloge du chrono à côté de « Chrono » quand une session tourne. Le
 * battement ne vit que pendant la session : au repos, rien ne tourne.
 */
function SidebarClock() {
  const snap = useSyncExternalStore(timerController.subscribe, timerController.snapshot);
  const running = snap.state !== null;
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    if (!running) return;
    setNow(new Date());
    const id = window.setInterval(() => setNow(new Date()), 1000);
    return () => window.clearInterval(id);
  }, [running]);
  if (!running) return null;
  return <span className="sidebar-clock mono">{displayClockOf(snap.state, snap.settings.cycle, now)}</span>;
}

/** Un cours de la barre latérale : anneau d'avancement, code, nom, retard (CourseSidebarRow). */
function CourseRow({ course, active, timed, onClick, onContextMenu }: {
  course: Course; active: boolean; timed: boolean;
  onClick: () => void; onContextMenu: (e: ReactMouseEvent) => void;
}) {
  const progress = ProgressEngine.progress(course);
  const late = ProgressEngine.lateCount(course);
  return (
    <button type="button" className={cx("sidebar-row course", active && "active")}
      onClick={onClick} onContextMenu={onContextMenu} aria-current={active ? "page" : undefined}>
      <MiniRing value={progress.completion} color={course.colorHex} />
      <span className="sidebar-course-text">
        <span className="sidebar-course-code">{course.displayCode}</span>
        <span className="sidebar-course-name">{course.name}</span>
      </span>
      {timed && <Icon name="timer" size={13} color={course.colorHex} label="En cours" />}
      {late > 0 && <span className="sidebar-late mono" title={`${late} en retard`}>{late}</span>}
    </button>
  );
}

/** L'anneau d'avancement de la barre latérale (ProgressRingMini). */
function MiniRing({ value, color }: { value: number; color: string }) {
  const r = 7;
  const c = 2 * Math.PI * r;
  const v = Math.max(0, Math.min(1, value));
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" style={{ flexShrink: 0 }}>
      <circle cx="9" cy="9" r={r} fill="none" stroke={color} strokeOpacity="0.22" strokeWidth="2.4" />
      <circle cx="9" cy="9" r={r} fill="none" stroke={color} strokeWidth="2.4" strokeLinecap="round"
        strokeDasharray={`${c * v} ${c}`} transform="rotate(-90 9 9)" />
    </svg>
  );
}

/** L'état de la synchronisation, en une ligne (SyncFooter du Mac, version Supabase). */
function SyncFooter() {
  const [status, setStatus] = useState<SyncStatus | null>(null);
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    let alive = true;
    const refresh = () => { void syncService.status().then((s) => { if (alive) setStatus(s); }); };
    refresh();
    const off = syncService.subscribe(refresh);
    // Le « il y a 5 min » vieillit à la minute — comme le TimelineView du Mac.
    const id = window.setInterval(() => setNow(new Date()), 60_000);
    return () => { alive = false; off(); window.clearInterval(id); };
  }, []);
  if (!status) return null;
  const { text, icon, failed } = describeSync(status, now);
  return (
    <span className={cx("sync-footer", failed && "failed")} title={status.lastError ?? text}>
      <Icon name={icon} size={13} />
      <span>{text}</span>
    </span>
  );
}

export function describeSync(s: SyncStatus, now: Date): { text: string; icon: IconName; failed: boolean } {
  if (!s.configured || !s.signedIn || !s.enabled) return { text: "Sur cet appareil", icon: "icloud.slash", failed: false };
  if (s.lastError) return { text: "Synchronisation en échec", icon: "exclamationmark.triangle", failed: true };
  if (!s.lastSyncAt) return { text: "Synchronisation…", icon: "arrow.clockwise", failed: false };
  const minutes = Math.floor((now.getTime() - new Date(s.lastSyncAt).getTime()) / 60_000);
  if (minutes < 1) return { text: "Synchronisé à l'instant", icon: "icloud", failed: false };
  const rtf = new Intl.RelativeTimeFormat("fr-CH", { numeric: "auto" });
  const ago = minutes < 60 ? rtf.format(-minutes, "minute")
    : minutes < 1440 ? rtf.format(-Math.floor(minutes / 60), "hour")
    : rtf.format(-Math.floor(minutes / 1440), "day");
  return { text: `Synchronisé ${ago}`, icon: "icloud", failed: false };
}

/** Sans cours suivi : la page seule le dit, la barre latérale reste utilisable. */
function NoCourses({ onAdd }: { onAdd: () => void }) {
  return (
    <EmptyState icon="books.vertical" title="Pas encore de cours"
      action={<button type="button" className="btn btn-primary" onClick={onAdd}>Ajouter un cours</button>}>
      Ajoute tes cours ici, ou active la synchronisation dans les réglages pour retrouver ceux de ton Mac
      et de ton iPhone. Le chrono marche déjà.
    </EmptyState>
  );
}
