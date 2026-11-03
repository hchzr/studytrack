// La page « Claude » (le Mac : la conversation hors d'un cours) : une conversation libre, avec en
// contexte tes cours suivis et ce qui t'attend dans les deux semaines. Par Claude Code s'il est
// installé (ton abonnement), sinon par le tuteur gratuit.

import { useData } from "../../data/dataContext.tsx";
import { Course } from "../../models/index.ts";
import { Deadline } from "../../domain/deadline.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { ClaudePane } from "../studymode/panes/ClaudePane.tsx";

export function ClaudeScreen() {
  const { store } = useData();
  const tracked = store ? store.fetch(Course).filter((c) => c.isTracked) : [];
  const coming = Deadline.upcoming(tracked, 14).slice(0, 12);
  const context = [
    `Mes cours : ${tracked.map((c) => `${c.displayCode} (${c.name}, semaine ${c.currentWeek})`).join(" ; ") || "aucun"}.`,
    coming.length > 0 ? `À venir : ${coming.map((d) => `${DateUtils.fullDayLabel(d.date)} — ${d.title}`).join(" ; ")}.` : "",
  ].filter(Boolean).join("\n");
  return (
    <div style={{ height: "100%", minHeight: 0 }}>
      <ClaudePane course={null} series={null} exercise={null} tint="var(--ink)" general context={context} />
    </div>
  );
}
