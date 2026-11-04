// La grille de la semaine : une colonne par jour, les heures utiles de la
// semaine, les cours et les sessions posés à leur heure. Le week-end disparaît
// s'il est vide, et sans aucun cours la grille cède la place à un état vide.
//
// Le clic sur un cours terminé marque « manqué » (ou le rétablit), le seul geste
// de présence que l'agenda Swift autorise (`isSkipped.toggle()` + `save()`).

import { countsEvent, isCheckable, readCounting } from "../../../domain/studyCounting.ts";
import { useOpenCourse } from "./openCourse.ts";
import type { CSSProperties } from "react";
import { DateUtils } from "../../../domain/dateUtils.ts";
import type { Deadline } from "../../../domain/deadline.ts";
import type { LinkedCalendarEvent } from "../../../models/linkedCalendarEvent.ts";
import { EmptyState, Icon, cx, type IconName } from "../../kit.tsx";
import {
  HOUR_HEIGHT, assignLanes, entryColor, entryLayout, hourRange, weekdayAbbrev,
} from "./weekModel.ts";
import type { Lane, WeekEntry } from "./weekModel.ts";

interface WeekGridProps {
  days: Date[];
  entries: WeekEntry[];
  deadlines: Deadline[];
  now: Date;
  onToggleSkipped: (event: LinkedCalendarEvent) => void;
}

/** Les icônes des échéances (`Deadline.icon` côté Swift), dans le jeu d'icônes de l'app. */
export function deadlineIcon(kind: Deadline["kind"]): IconName {
  switch (kind) {
    case "exam": return "graduationcap";
    case "due": return "tray";
    case "solutions": return "checkmark.circle";
  }
}

export function WeekGrid({ days, entries, deadlines, now, onToggleSkipped }: WeekGridProps) {
  const columns = `48px repeat(${days.length}, minmax(0, 1fr))`;
  const range = hourRange(entries);

  return (
    <div className="card wk">
      <div className="wk-head" style={{ gridTemplateColumns: columns }}>
        <div className="wk-corner" />
        {days.map((day) => (
          <DayHeader
            key={day.toISOString()}
            day={day}
            now={now}
            deadlines={deadlines.filter((item) => DateUtils.isSameDay(item.date, day))}
          />
        ))}
      </div>

      {range === null ? (
        <div className="wk-empty">
          <EmptyState icon="calendar" title="Aucun cours cette semaine">
            Les cours de l'horaire EPFL et les sessions planifiées apparaîtront ici.
          </EmptyState>
        </div>
      ) : (
        <Body days={days} entries={entries} now={now} range={range} columns={columns} onToggleSkipped={onToggleSkipped} />
      )}
    </div>
  );
}

function Body({ days, entries, now, range, columns, onToggleSkipped }: {
  days: Date[];
  entries: WeekEntry[];
  now: Date;
  range: { first: number; last: number };
  columns: string;
  onToggleSkipped: (event: LinkedCalendarEvent) => void;
}) {
  const hours = Array.from({ length: range.last - range.first + 1 }, (_, index) => range.first + index);
  const height = hours.length * HOUR_HEIGHT;

  return (
    <div className="wk-body" style={{ gridTemplateColumns: columns }}>
      <div className="wk-hours" style={{ height }}>
        {hours.map((hour, index) => (
          <div key={hour} className="wk-hour mono" style={{ top: index * HOUR_HEIGHT }}>{hour} h</div>
        ))}
      </div>

      {days.map((day) => (
        <DayColumn
          key={day.toISOString()}
          day={day}
          hours={hours}
          height={height}
          firstHour={range.first}
          entries={entries.filter((entry) => DateUtils.isSameDay(entry.start, day))}
          now={now}
          onToggleSkipped={onToggleSkipped}
        />
      ))}
    </div>
  );
}

function DayHeader({ day, now, deadlines }: { day: Date; now: Date; deadlines: Deadline[] }) {
  const open = useOpenCourse();
  const today = DateUtils.isSameDay(day, now);
  return (
    <div className={cx("wk-day", today && "today")}>
      <div className="wk-dayname">
        <small>{weekdayAbbrev(day)}</small>
        <b className="serif">{day.getDate()}</b>
        {today && <span className="wk-dot" />}
      </div>

      {deadlines.map((item) => (
        <div
          key={item.id}
          role={open ? "button" : undefined}
          tabIndex={open ? 0 : undefined}
          onClick={open ? () => open(item.courseID, item.targetID) : undefined}
          className={cx("wk-deadline", item.kind === "exam" && "exam")}
          style={{ "--dl": item.colorHex } as CSSProperties}
          title={`${item.courseCode} · ${item.detail}`}
        >
          <Icon name={deadlineIcon(item.kind)} size={12} />
          <span>{item.title}</span>
        </div>
      ))}
    </div>
  );
}

function DayColumn({ day, hours, height, firstHour, entries, now, onToggleSkipped }: {
  day: Date;
  hours: number[];
  height: number;
  firstHour: number;
  entries: WeekEntry[];
  now: Date;
  onToggleSkipped: (event: LinkedCalendarEvent) => void;
}) {
  const today = DateUtils.isSameDay(day, now);
  const nowTop = today ? (now.getHours() - firstHour + now.getMinutes() / 60) * HOUR_HEIGHT : null;
  const showNow = nowTop !== null && nowTop > 0 && nowTop < height;
  const lanes = assignLanes(entries);

  return (
    <div className="wk-col" style={{ height }}>
      {hours.map((hour, index) => (
        <div key={hour} className="wk-line" style={{ top: index * HOUR_HEIGHT }} />
      ))}

      {entries.map((entry, index) => (
        <EntryTile key={entry.id} entry={entry} firstHour={firstHour} now={now} onToggleSkipped={onToggleSkipped}
          lane={lanes[index]} gridHeight={height} />
      ))}

      {showNow && <div className="wk-now" style={{ top: nowTop }} />}
    </div>
  );
}

function EntryTile({ entry, firstHour, now, onToggleSkipped, lane, gridHeight }: {
  entry: WeekEntry;
  firstHour: number;
  now: Date;
  onToggleSkipped: (event: LinkedCalendarEvent) => void;
  lane: Lane;
  gridHeight: number;
}) {
  const layout = entryLayout(entry, firstHour);
  const top = layout.top;
  // Coupée au bas de la grille : une entrée qui finit après la dernière heure, ou le lendemain.
  const height = DateUtils.isSameDay(entry.start, entry.end)
    ? Math.max(18, Math.min(layout.height, gridHeight - top - 2))
    : Math.max(18, gridHeight - top - 2);
  const inset = lane.lanes > 1 ? 1.5 : 3;
  const left = `calc(${(lane.lane / lane.lanes) * 100}% + ${inset}px)`;
  const width = `calc(${100 / lane.lanes}% - ${inset * 2}px)`;
  const tint = entryColor(entry);
  const past = entry.end.getTime() < now.getTime();
  const event = entry.event;
  // Un clic ouvre le cours de l'entrée (la grille du Mac fait pareil).
  const open = useOpenCourse();
  const courseID = event?.course?.id ?? entry.session?.course?.id ?? null;
  // Une séance commencée se coche (« j'y étais ») ou se décoche (« manqué ») selon ce qui
  // compte dans les heures (Réglages › Chrono › Ce qui compte).
  const counting = readCounting();
  const canToggle = event !== null && isCheckable(counting, event, now);
  const checked = event !== null && countsEvent(counting, event, now);

  const title = event !== null ? (entry.courseCode ?? entry.title) : entry.title;
  const details = event !== null
    ? [entry.isLecture ? "Cours" : entry.kindLabel, entry.location === "" ? null : entry.location,
        entry.isSkipped ? "manqué" : null]
    : [entry.courseCode, entry.location === "" ? null : entry.location,
        entry.session?.groupName === "" ? null : entry.session?.groupName ?? null];
  const detail = details.filter((part): part is string => part !== null && part !== "").join(" · ");
  const tooltip = `${event?.title ?? entry.title}\n${DateUtils.time(entry.start)} – ${DateUtils.time(entry.end)}`
    + (detail === "" ? "" : `\n${detail}`);
  const toggleLabel = event === null ? ""
    : checked ? `Marquer ${event.title} manqué` : `J'étais à ${event.title}`;

  return (
    <div
      title={tooltip}
      onClick={open && courseID ? () => open(courseID, null) : undefined}
      className={cx("wk-tile", open && courseID && "openable", (entry.isSkipped || past) && "dim", entry.isSkipped && "skipped")}
      style={{ top, height, left, width, right: "auto", "--tint": tint, "--fill": entry.isLecture ? 0.16 : 0.09 } as CSSProperties}
    >
      <div className={cx("wk-tile-title", canToggle && "padded")}>{title}</div>

      {height > 34 && detail !== "" && <div className="wk-tile-detail">{detail}</div>}

      {canToggle && event !== null && (
        <button
          type="button"
          className={cx("wk-skip", !checked && "off")}
          aria-pressed={checked}
          aria-label={toggleLabel}
          title={toggleLabel}
          onClick={(e) => { e.stopPropagation(); onToggleSkipped(event); }}
        >
          <Icon name="checkmark" size={11} />
        </button>
      )}
    </div>
  );
}
