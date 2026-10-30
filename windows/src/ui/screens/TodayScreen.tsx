// Aujourd'hui — l'écran d'accueil. Exemplaire du motif : lire le `ModelStore`
// via `useData()`, afficher des objets du modèle, rester dans la langue Carnet.
// À enrichir (carte de la semaine, prochain geste) en portant TodayView/MacTodayView.

import { useMemo } from "react";
import { useData } from "../../data/dataContext.tsx";
import { Course, StudySession, PlannedSession } from "../../models/index.ts";
import { PageHeader, Section, Card } from "../kit.tsx";

const sameDay = (a: Date, b: Date) =>
  a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

const hm = (seconds: number) => {
  const m = Math.round(seconds / 60);
  return m >= 60 ? `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")}` : `${m} min`;
};

export function TodayScreen({ onOpenCourse }: { onOpenCourse: (id: string) => void }) {
  const { store } = useData();
  const now = new Date();

  const courses = useMemo(
    () => store!.fetch(Course).filter((c) => c.isActive).sort((a, b) => a.code.localeCompare(b.code)),
    [store],
  );
  const todaySessions = useMemo(
    () => store!.fetch(StudySession).filter((s) => sameDay(s.startedAt, now)).sort((a, b) => +b.startedAt - +a.startedAt),
    [store],
  );
  const todayPlanned = useMemo(
    () => store!.fetch(PlannedSession).filter((p) => sameDay(p.startsAt, now)).sort((a, b) => +a.startsAt - +b.startsAt),
    [store],
  );
  const totalToday = todaySessions.reduce((n, s) => n + s.durationSeconds, 0);

  const dateLabel = now.toLocaleDateString("fr-CH", { weekday: "long", day: "numeric", month: "long" });

  return (
    <>
      <PageHeader title="Aujourd'hui" subtitle={`${dateLabel} · ${hm(totalToday)} étudiées`} />

      <Section title="Au programme">
        {todayPlanned.length === 0
          ? <Card><span style={{ color: "var(--ink-secondary)" }}>Rien de planifié aujourd'hui.</span></Card>
          : todayPlanned.map((p) => (
            <div key={p.id} style={{ marginBottom: 8 }}>
              <Card accent={p.course?.colorHex}>
                <div style={{ display: "flex", justifyContent: "space-between" }}>
                  <strong>{p.title || p.course?.name || "Session"}</strong>
                  <span className="mono" style={{ color: "var(--ink-secondary)" }}>
                    {p.startsAt.toLocaleTimeString("fr-CH", { hour: "2-digit", minute: "2-digit" })}
                  </span>
                </div>
              </Card>
            </div>
          ))}
      </Section>

      <Section title="Mes cours">
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))", gap: 12 }}>
          {courses.map((c) => (
            <button key={c.id} onClick={() => onOpenCourse(c.id)} style={{ textAlign: "left", border: "none", padding: 0, background: "none" }}>
              <Card accent={c.colorHex}>
                <div className="serif" style={{ fontSize: 18 }}>{c.name}</div>
                <div style={{ color: "var(--ink-secondary)", fontSize: 13, marginTop: 4 }}>
                  {c.code}{c.credits ? ` · ${c.credits} crédits` : ""}
                </div>
              </Card>
            </button>
          ))}
        </div>
      </Section>

      <Section title="Sessions du jour">
        {todaySessions.length === 0
          ? <span style={{ color: "var(--ink-secondary)" }}>Aucune session enregistrée aujourd'hui.</span>
          : todaySessions.map((s) => (
            <div key={s.id} style={{ display: "flex", justifyContent: "space-between", padding: "8px 0",
              borderBottom: "1px solid var(--rule)" }}>
              <span>{s.course?.name ?? "Étude"}</span>
              <span className="mono" style={{ color: "var(--ink-secondary)" }}>{hm(s.durationSeconds)}</span>
            </div>
          ))}
      </Section>
    </>
  );
}
