// « À venir » : les échéances des 30 prochains jours, une ligne par échéance
// avec sa date, son cours et le compte à rebours (MacAgendaView, DeadlineLine).

import { DateUtils } from "../../../domain/dateUtils.ts";
import type { Deadline } from "../../../domain/deadline.ts";
import { Card, Section } from "../../kit.tsx";
import { deadlineGlyph } from "./weekModel.ts";

export function UpcomingList({ items }: { items: Deadline[] }) {
  if (items.length === 0) return null;

  return (
    <Section title="À venir · 30 jours">
      <Card>
        {items.map((item, index) => (
          <div key={item.id} style={{
            display: "flex", alignItems: "center", gap: 12, padding: "10px 4px",
            borderTop: index === 0 ? "none" : "1px solid var(--rule)",
          }}>
            <span className="mono" style={{
              width: 92, flexShrink: 0, fontSize: 12, color: "var(--ink-secondary)",
            }}>
              {DateUtils.shortDay(item.date)}
            </span>

            <span style={{ flexShrink: 0, fontSize: 12, color: item.kind === "exam" ? "var(--wrong)" : item.colorHex }}>
              {deadlineGlyph(item.kind)}
            </span>

            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontWeight: 500, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {item.title}
              </div>
              <div style={{
                fontSize: 12, color: "var(--ink-secondary)", overflow: "hidden",
                textOverflow: "ellipsis", whiteSpace: "nowrap",
              }}>
                {item.courseCode} · {item.detail}
              </div>
            </div>

            <span className="mono" style={{
              flexShrink: 0, fontSize: 12, fontWeight: 600,
              color: item.kind === "exam" ? "var(--wrong)" : "var(--ink-secondary)",
            }}>
              {DateUtils.countdownLabel(item.date)}
            </span>
          </div>
        ))}
      </Card>
    </Section>
  );
}
