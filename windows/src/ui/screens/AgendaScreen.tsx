// Agenda — la semaine en colonnes, les échéances du jour et ce qui vient.
//
// Port de MacAgendaView (la grille horaire) avec les apports d'AgendaView :
// sessions planifiées dans la grille, numéro de semaine du semestre, et le seul
// geste de présence autorisé côté Swift — marquer un cours magistral terminé
// « manqué » (`isSkipped.toggle()` puis `save()`).

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useData } from "../../data/dataContext.tsx";
import { Deadline } from "../../domain/deadline.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { AcademicTerm, Course, LinkedCalendarEvent, PlannedSession } from "../../models/index.ts";
import { PageHeader } from "../kit.tsx";
import { UpcomingList } from "./agenda/UpcomingList.tsx";
import { WeekGrid } from "./agenda/WeekGrid.tsx";
import {
  buildWeekEntries, fallbackWeekNumber, visibleWeekDays, weekDays, weekLabel, weekNumberFor,
} from "./agenda/weekModel.ts";

export function AgendaScreen() {
  const { store, save, version } = useData();
  const [weekOffset, setWeekOffset] = useState(0);
  const [now, setNow] = useState(() => new Date());

  // La ligne « maintenant » et l'état passé/futur des cours suivent l'horloge.
  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 60_000);
    return () => clearInterval(timer);
  }, []);

  // ⌘/Ctrl + ← → : le raccourci du Mac pour changer de semaine.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!event.metaKey && !event.ctrlKey) return;
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      event.preventDefault();
      setWeekOffset((offset) => offset + (event.key === "ArrowRight" ? 1 : -1));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const tracked = useMemo(
    () => store!.fetch(Course).filter((course) => course.isTracked).sort((a, b) => a.code.localeCompare(b.code)),
    [store, version],
  );
  const allEvents = useMemo(
    () => store!.fetch(LinkedCalendarEvent).slice().sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime()),
    [store, version],
  );
  const plannedSessions = useMemo(
    () => store!.fetch(PlannedSession).slice().sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime()),
    [store, version],
  );

  const weekStart = DateUtils.addWeeks(weekOffset, DateUtils.startOfWeek(now));
  const weekEnd = DateUtils.addDays(7, weekStart);
  const term = AcademicTerm.resolve(
    tracked.map((course) => course.term).filter((value): value is AcademicTerm => value !== null),
    now,
  );
  const weekNumber = weekNumberFor(weekStart, term)
    ?? (term === null && tracked.length > 0 ? fallbackWeekNumber(weekStart, now) : null);

  const entries = buildWeekEntries(allEvents, plannedSessions, weekStart, weekEnd);
  const deadlines = Deadline.between(tracked, weekStart, weekEnd);
  const coming = Deadline.upcoming(tracked, 30);
  const days = visibleWeekDays(weekDays(weekStart), entries, deadlines);

  const toggleSkipped = (event: LinkedCalendarEvent) => {
    event.isSkipped = !event.isSkipped;
    void save(event);
  };

  return (
    <div style={{ maxWidth: 1180, margin: "0 auto" }}>
      <PageHeader title="Agenda" subtitle="La semaine, les échéances et les sessions planifiées." />

      <div className="card" style={{
        display: "flex", alignItems: "flex-end", justifyContent: "space-between",
        gap: 16, marginBottom: 20,
      }}>
        <div>
          <div style={{
            fontSize: 11, textTransform: "uppercase", letterSpacing: 0.6,
            color: "var(--ink-tertiary)", marginBottom: 4,
          }}>
            {weekNumber !== null ? `Semaine ${weekNumber}` : "Hors semestre"}
          </div>
          <div className="serif" style={{ fontSize: 24 }}>{weekLabel(weekStart)}</div>
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <PaperButton title="Semaine précédente" onClick={() => setWeekOffset((offset) => offset - 1)}>
            ‹
          </PaperButton>
          <PaperButton
            title="Revenir à cette semaine"
            disabled={weekOffset === 0}
            onClick={() => setWeekOffset(0)}
          >
            Aujourd'hui
          </PaperButton>
          <PaperButton title="Semaine suivante" onClick={() => setWeekOffset((offset) => offset + 1)}>
            ›
          </PaperButton>
        </div>
      </div>

      <div style={{ marginBottom: 28 }}>
        <WeekGrid days={days} entries={entries} deadlines={deadlines} now={now} onToggleSkipped={toggleSkipped} />
        {entries.length === 0 && deadlines.length === 0 && (
          <p style={{ color: "var(--ink-secondary)", margin: "10px 2px 0" }}>
            Aucun cours ni échéance cette semaine.
          </p>
        )}
      </div>

      <UpcomingList items={coming} />
    </div>
  );
}

function PaperButton({ children, title, onClick, disabled = false }: {
  children: ReactNode;
  title: string;
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      title={title}
      aria-label={title}
      onClick={onClick}
      disabled={disabled}
      style={{
        padding: "6px 10px", borderRadius: 10, border: "1px solid var(--rule)",
        background: "var(--sheet)", color: "var(--ink)", fontSize: 13,
        minWidth: 32, opacity: disabled ? 0.4 : 1, cursor: disabled ? "default" : "pointer",
      }}
    >
      {children}
    </button>
  );
}
