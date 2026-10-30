// Aujourd'hui — le tableau de bord de la semaine (MacTodayView.swift,
// StudyTrack/Views/Home/TodayView.swift + TodayWeekCard.swift).
//
// On y lit le `ModelStore` via `useData()` et on laisse le domaine calculer :
// `StudyTime` pour les heures, `ProgressEngine` pour la théorie / les séries /
// les corrigés, `Deadline` pour les échéances. L'écran ne recompte rien.

import { useData } from "../../data/dataContext.tsx";
import { Course } from "../../models/index.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { PageHeader, Section, Card } from "../kit.tsx";
import { buildHomeData } from "./home/todayModel.ts";
import { WeekTimeCard, WeekCourseRow } from "./home/weekCard.tsx";
import { DeadlineRow, GoalRing, NextActionCard, PlanRow, SessionRow } from "./home/todayParts.tsx";

const rowStyle = (first: boolean) => ({
  borderTop: first ? "none" : "1px solid var(--rule)",
  padding: "0 4px",
});

export function TodayScreen({ onOpenCourse }: { onOpenCourse: (id: string) => void }) {
  const { store } = useData();
  const now = new Date();
  if (!store) return null;

  const courses = store.fetch(Course).sort((a, b) => a.code.localeCompare(b.code));
  const data = buildHomeData(store, courses, now);
  const {
    term, summaries, weekStart, days, weekTotal, theory, series, corrections, late,
    weeklyGoal, dailyGoal, todayTotal, todaySessions, todayItems, deadlines, nextAction,
  } = data;

  const termLine = term
    ? term.hasEnded
      ? "semestre terminé"
      : term.hasNotStarted
        ? "semestre à venir"
        : `semaine ${term.currentWeek} sur ${term.totalWeeks}`
    : null;
  const dateLabel = DateUtils.fullDayLabel(now);
  const weekTitle = term?.isRunning ? `Semaine ${term.currentWeek}` : "Cette semaine";
  const sessionsTotal = todaySessions.reduce((sum, session) => sum + session.durationSeconds, 0);

  const headerActions = (
    <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
      <div style={{ textAlign: "right" }}>
        <div className="mono" style={{ fontSize: 24 }}>{DateUtils.hoursLabel(todayTotal)}</div>
        <div style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
          sur {DateUtils.hoursLabel(dailyGoal)} · {DateUtils.hoursLabel(weekTotal)} cette semaine
        </div>
      </div>
      <GoalRing seconds={todayTotal} goal={dailyGoal} />
    </div>
  );

  return (
    <>
      <PageHeader
        title="Aujourd'hui"
        subtitle={[dateLabel, termLine].filter((part): part is string => part !== null).join(" · ")}
        actions={headerActions}
      />

      {summaries.length === 0 ? (
        <Card>
          <div className="serif" style={{ fontSize: 20 }}>Aucun cours suivi</div>
          <div style={{ color: "var(--ink-secondary)", marginTop: 6 }}>
            Séries, vidéos et échéances, lues sur Moodle. Ajoute un cours depuis l'écran Cours.
          </div>
        </Card>
      ) : (
        <>
          <Section title={weekTitle}>
            <WeekTimeCard
              days={days}
              weekStart={weekStart}
              theory={theory}
              series={series}
              corrections={corrections}
              late={late}
              goal={weeklyGoal}
              now={now}
            />
          </Section>

          <div style={{
            display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))",
            gap: 24, alignItems: "start", marginBottom: 28,
          }}>
            <div style={{ display: "flex", flexDirection: "column", gap: 24, minWidth: 0 }}>
              <NextActionCard action={nextAction} onOpen={onOpenCourse} />

              <Section title="Horaire du jour">
                <Card>
                  {todayItems.length === 0 ? (
                    <span style={{ color: "var(--ink-secondary)", fontSize: 13 }}>Rien à l'horaire.</span>
                  ) : (
                    <>
                      {todayItems.slice(0, 8).map((item, index) => (
                        <div key={item.id} style={rowStyle(index === 0)}>
                          <PlanRow item={item} now={now} onOpen={onOpenCourse} />
                        </div>
                      ))}
                      {todayItems.length > 8 && (
                        <div style={{
                          color: "var(--ink-secondary)", fontSize: 12, padding: "8px 6px 4px",
                        }}>+ {todayItems.length - 8} autres</div>
                      )}
                    </>
                  )}
                </Card>
              </Section>
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: 24, minWidth: 0 }}>
              <Section title={todaySessions.length > 0
                ? `Sessions du jour · ${DateUtils.hoursLabel(sessionsTotal)}`
                : "Sessions du jour"}>
                <Card>
                  {todaySessions.length === 0 ? (
                    <span style={{ color: "var(--ink-secondary)", fontSize: 13 }}>Pas encore de session.</span>
                  ) : todaySessions.map((session, index) => (
                    <div key={session.id} style={rowStyle(index === 0)}>
                      <SessionRow session={session} />
                    </div>
                  ))}
                </Card>
              </Section>

              {deadlines.length > 0 && (
                <Section title="Échéances · 14 jours">
                  <Card>
                    {deadlines.map((deadline, index) => (
                      <div key={deadline.id} style={rowStyle(index === 0)}>
                        <DeadlineRow item={deadline} onOpen={onOpenCourse} />
                      </div>
                    ))}
                  </Card>
                </Section>
              )}
            </div>
          </div>

          <Section title={`${weekTitle} · cours suivis`}>
            <Card>
              {summaries.map((summary, index) => (
                <div key={summary.course.id} style={rowStyle(index === 0)}>
                  <WeekCourseRow summary={summary} onOpen={onOpenCourse} />
                </div>
              ))}
            </Card>
          </Section>
        </>
      )}
    </>
  );
}
