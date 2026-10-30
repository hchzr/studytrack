// La grille de la semaine : une colonne par jour, les heures de 8 h à 19 h, les
// cours et les sessions posés à leur heure. Le week-end disparaît s'il est vide.
//
// Le clic sur un cours terminé marque « manqué » (ou le rétablit), le seul geste
// de présence que l'agenda Swift autorise (`isSkipped.toggle()` + `save()`).

import { DateUtils } from "../../../domain/dateUtils.ts";
import type { Deadline } from "../../../domain/deadline.ts";
import type { LinkedCalendarEvent } from "../../../models/linkedCalendarEvent.ts";
import {
  GRID_HEIGHT, HOURS, HOUR_HEIGHT, deadlineGlyph, entryColor, entryLayout, weekdayAbbrev, withAlpha,
} from "./weekModel.ts";
import type { WeekEntry } from "./weekModel.ts";

interface WeekGridProps {
  days: Date[];
  entries: WeekEntry[];
  deadlines: Deadline[];
  now: Date;
  onToggleSkipped: (event: LinkedCalendarEvent) => void;
}

export function WeekGrid({ days, entries, deadlines, now, onToggleSkipped }: WeekGridProps) {
  const columns = `48px repeat(${days.length}, minmax(0, 1fr))`;

  return (
    <div className="card" style={{ padding: 0, overflow: "hidden" }}>
      <div style={{ display: "grid", gridTemplateColumns: columns, borderBottom: "1px solid var(--rule)" }}>
        <div />
        {days.map((day) => (
          <DayHeader
            key={day.toISOString()}
            day={day}
            now={now}
            deadlines={deadlines.filter((item) => DateUtils.isSameDay(item.date, day))}
          />
        ))}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: columns, padding: "8px 0" }}>
        <div style={{ position: "relative", height: GRID_HEIGHT }}>
          {HOURS.map((hour, index) => (
            <div key={hour} className="mono" style={{
              position: "absolute", top: index * HOUR_HEIGHT, right: 6, transform: "translateY(-50%)",
              fontSize: 11, color: "var(--ink-tertiary)",
            }}>
              {hour} h
            </div>
          ))}
        </div>

        {days.map((day, index) => (
          <DayColumn
            key={day.toISOString()}
            day={day}
            first={index === 0}
            entries={entries.filter((entry) => DateUtils.isSameDay(entry.start, day))}
            now={now}
            onToggleSkipped={onToggleSkipped}
          />
        ))}
      </div>
    </div>
  );
}

function DayHeader({ day, now, deadlines }: { day: Date; now: Date; deadlines: Deadline[] }) {
  const today = DateUtils.isSameDay(day, now);
  return (
    <div style={{ padding: 8, minWidth: 0, background: today ? "var(--marker)" : "transparent" }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 5 }}>
        <span style={{ fontSize: 11, fontWeight: 600, color: today ? "var(--ink)" : "var(--ink-secondary)" }}>
          {weekdayAbbrev(day)}
        </span>
        <span className="serif" style={{ fontSize: 18, fontWeight: today ? 600 : 400 }}>
          {day.getDate()}
        </span>
        {today && <span style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--wrong)" }} />}
      </div>

      {deadlines.map((item) => (
        <div
          key={item.id}
          title={`${item.courseCode} · ${item.detail}`}
          style={{
            display: "flex", alignItems: "center", gap: 4, marginTop: 4, padding: "3px 6px",
            borderRadius: 5, minWidth: 0, fontSize: 11, lineHeight: 1.25,
            background: item.kind === "exam" ? "var(--wrong)" : withAlpha(item.colorHex, 0.14),
            color: item.kind === "exam" ? "var(--ground)" : "var(--ink)",
          }}
        >
          <span style={{ flexShrink: 0 }}>{deadlineGlyph(item.kind)}</span>
          <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.title}</span>
        </div>
      ))}
    </div>
  );
}

function DayColumn({ day, first, entries, now, onToggleSkipped }: {
  day: Date;
  first: boolean;
  entries: WeekEntry[];
  now: Date;
  onToggleSkipped: (event: LinkedCalendarEvent) => void;
}) {
  const today = DateUtils.isSameDay(day, now);
  const nowTop = today ? (now.getHours() - 8 + now.getMinutes() / 60) * HOUR_HEIGHT : null;
  const showNow = nowTop !== null && nowTop > 0 && nowTop < GRID_HEIGHT;

  return (
    <div style={{
      position: "relative", height: GRID_HEIGHT, minWidth: 0,
      borderLeft: first ? "none" : "1px solid var(--rule)",
    }}>
      {HOURS.map((hour, index) => (
        <div key={hour} style={{
          position: "absolute", top: index * HOUR_HEIGHT, left: 0, right: 0, height: 1,
          background: "var(--rule)", opacity: 0.6,
        }} />
      ))}

      {entries.map((entry) => (
        <EntryTile key={entry.id} entry={entry} now={now} onToggleSkipped={onToggleSkipped} />
      ))}

      {showNow && (
        <div style={{
          position: "absolute", top: nowTop, left: 0, right: 0, height: 1.5,
          background: "var(--wrong)", zIndex: 3, pointerEvents: "none",
        }} />
      )}
    </div>
  );
}

function EntryTile({ entry, now, onToggleSkipped }: {
  entry: WeekEntry;
  now: Date;
  onToggleSkipped: (event: LinkedCalendarEvent) => void;
}) {
  const { top, height } = entryLayout(entry);
  const tint = entryColor(entry);
  const past = entry.end.getTime() < now.getTime();
  const event = entry.event;
  // Un cours magistral terminé se marque manqué — une séance d'exercices se
  // chronomètre, elle ne se coche pas ici.
  const canToggle = event !== null && event.isLecture && event.course !== null
    && event.endsAt.getTime() <= now.getTime();

  const title = event !== null ? (entry.courseCode ?? entry.title) : entry.title;
  const details = event !== null
    ? [entry.isLecture ? "Cours" : entry.kindLabel, entry.location === "" ? null : entry.location,
        entry.isSkipped ? "manqué" : null]
    : [entry.courseCode, entry.location === "" ? null : entry.location,
        entry.session?.groupName === "" ? null : entry.session?.groupName ?? null];
  const detail = details.filter((part): part is string => part !== null && part !== "").join(" · ");
  const tooltip = `${event?.title ?? entry.title}\n${DateUtils.time(entry.start)} – ${DateUtils.time(entry.end)}`
    + (detail === "" ? "" : `\n${detail}`);

  return (
    <div
      title={tooltip}
      style={{
        position: "absolute", top, left: 3, right: 3, height, padding: "4px 6px", overflow: "hidden",
        borderRadius: 6, borderLeft: `3px solid ${tint}`,
        background: withAlpha(tint, entry.isLecture ? 0.16 : 0.09),
        opacity: entry.isSkipped || past ? 0.55 : 1,
      }}
    >
      <div style={{
        fontSize: 11, fontWeight: 600, lineHeight: 1.2, paddingRight: canToggle ? 18 : 0,
        overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
      }}>
        {title}
      </div>

      {height > 34 && detail !== "" && (
        <div style={{
          marginTop: 1, fontSize: 10, lineHeight: 1.2, color: "var(--ink-secondary)",
          display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden",
        }}>
          {detail}
        </div>
      )}

      {canToggle && event !== null && (
        <button
          type="button"
          aria-pressed={!event.isSkipped}
          aria-label={event.isSkipped ? `Compter ${event.title} comme suivi` : `Marquer ${event.title} manqué`}
          title={event.isSkipped ? `Compter ${event.title} comme suivi` : `Marquer ${event.title} manqué`}
          onClick={() => onToggleSkipped(event)}
          style={{
            position: "absolute", top: 3, right: 3, width: 16, height: 16, padding: 0,
            display: "grid", placeItems: "center", borderRadius: "50%", lineHeight: 1, fontSize: 10,
            border: event.isSkipped ? "1px solid var(--ink-secondary)" : "none",
            background: event.isSkipped ? "transparent" : tint,
            color: event.isSkipped ? "var(--ink-secondary)" : "var(--ground)",
          }}
        >
          {event.isSkipped ? "" : "✓"}
        </button>
      )}
    </div>
  );
}
