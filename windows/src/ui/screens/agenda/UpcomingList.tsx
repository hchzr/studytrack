// « À venir » : les échéances des 30 prochains jours, une ligne par échéance
// avec sa date, son cours et le compte à rebours (MacAgendaView, DeadlineLine).

import { useOpenCourse } from "./openCourse.ts";
import type { CSSProperties } from "react";
import { DateUtils } from "../../../domain/dateUtils.ts";
import type { Deadline } from "../../../domain/deadline.ts";
import { Card, Icon, Section, cx } from "../../kit.tsx";
import { deadlineIcon } from "./WeekGrid.tsx";

export function UpcomingList({ items }: { items: Deadline[] }) {
  const open = useOpenCourse();
  if (items.length === 0) return null;

  return (
    <Section title="À venir · 30 jours">
      <Card style={{ padding: "4px 14px" }}>
        {items.map((item) => (
          <div key={item.id} className={cx("list-row up-row", open && "hoverable")}
            role={open ? "button" : undefined} tabIndex={open ? 0 : undefined}
            onClick={open ? () => open(item.courseID, item.targetID) : undefined}
            onKeyDown={open ? (e) => { if (e.key === "Enter") open(item.courseID, item.targetID); } : undefined}>
            <span className="up-date mono">{DateUtils.shortDay(item.date)}</span>
            <span
              className={cx("up-icon", item.kind === "exam" && "exam")}
              style={{ "--dl": item.colorHex } as CSSProperties}
            >
              <Icon name={deadlineIcon(item.kind)} size={15} />
            </span>
            <div className="up-main">
              <div className="up-title">{item.title}</div>
              <div className="up-sub">{item.courseCode} · {item.detail}</div>
            </div>
            <span className={cx("up-count mono", item.kind === "exam" && "exam")}>
              {DateUtils.countdownLabel(item.date)}
            </span>
          </div>
        ))}
      </Card>
    </Section>
  );
}
