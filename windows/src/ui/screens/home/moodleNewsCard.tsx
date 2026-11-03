// « Nouveau sur Moodle » sur l'accueil : ce que le dernier relevé a trouvé, par cours.
// Toucher un cours l'ouvre (son import Moodle range le neuf) ; « Vu » le retire.

import { useEffect, useState } from "react";
import { MoodleNewsKind } from "../../../domain/moodleNews.ts";
import { dismissMoodleNews, moodleNews, onMoodleNews, type CourseNews } from "../../../services/moodleWatcher.ts";
import { Card, Section } from "../../kit.tsx";
import { Icon, type IconName } from "../../icons.tsx";

const ICON: Record<string, IconName> = { series: "doc.text", solution: "checkmark.seal", deadline: "tray", lecture: "play.rectangle.fill", document: "folder" };

export function MoodleNewsCard({ onOpenCourse }: { onOpenCourse: (courseID: string) => void }) {
  const [news, setNews] = useState<CourseNews[]>(moodleNews);
  useEffect(() => onMoodleNews(() => setNews(moodleNews())), []);
  const shown = news.map((entry) => ({ ...entry, items: entry.items.filter((item) => MoodleNewsKind.defaults.has(item.kind)) }))
    .filter((entry) => entry.items.length > 0);
  if (shown.length === 0) return null;
  return (
    <Section title="Nouveau sur Moodle">
      <Card>
        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          {shown.map((entry) => (
            <div key={entry.courseID} style={{ display: "flex", gap: 10, alignItems: "flex-start" }}>
              <button type="button" onClick={() => onOpenCourse(entry.courseID)}
                style={{ flex: 1, minWidth: 0, border: 0, background: "none", padding: 0, textAlign: "left", cursor: "pointer", color: "var(--ink)", font: "inherit" }}>
                <div className="mono" style={{ fontSize: 12, color: "var(--ink-secondary)" }}>{entry.code}</div>
                {entry.items.slice(0, 4).map((item) => (
                  <div key={item.id} style={{ display: "flex", gap: 6, alignItems: "center", fontSize: 13 }}>
                    <Icon name={ICON[item.kind]} size={13} />
                    <span>{MoodleNewsKind.newLabel(item.kind)} · {item.name}</span>
                  </div>
                ))}
                {entry.items.length > 4 && <div style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>+{entry.items.length - 4}</div>}
              </button>
              <button type="button" className="btn btn-sm" onClick={() => dismissMoodleNews(entry.courseID)}>Vu</button>
            </div>
          ))}
        </div>
      </Card>
    </Section>
  );
}
