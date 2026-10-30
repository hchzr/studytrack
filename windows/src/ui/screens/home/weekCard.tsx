// La semaine en un coup d'œil (StudyTrack/Views/Home/TodayWeekCard.swift) :
// les heures depuis lundi, jour par jour, et l'avancement de la semaine — théorie,
// séries, corrigés, tous cours confondus. Puis une ligne par cours suivie.

import { DateUtils } from "../../../domain/dateUtils.ts";
import { ExamKind } from "../../../models/enums.ts";
import type { WeekCourseSummary } from "../../../domain/progressEngine.ts";
import { Plural } from "../../../domain/plural.ts";

/** Pastille d'un cours : un point de couleur et son code, comme `CourseTag`. */
export function CourseTag({ code, tint, size = 12 }:
  { code: string; tint: string; size?: number }) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 5, minWidth: 0 }}>
      <span style={{ width: 6, height: 6, borderRadius: "50%", background: tint, flexShrink: 0 }} />
      <span style={{ color: tint, fontSize: size, fontWeight: 600, letterSpacing: 0.3 }}>{code}</span>
    </span>
  );
}

/** Une barre « fait / prévu », avec son libellé et son compte. */
export function ProgressAxis({ label, done, total, tint, height = 4, labelSize = 12 }:
  { label: string; done: number; total: number; tint: string; height?: number; labelSize?: number }) {
  const ratio = total <= 0 ? 0 : Math.min(1, done / total);
  const complete = total > 0 && done === total;
  return (
    <div style={{ flex: 1, minWidth: 0 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 6 }}>
        <span style={{
          color: "var(--ink-secondary)", fontSize: labelSize, overflow: "hidden",
          textOverflow: "ellipsis", whiteSpace: "nowrap",
        }}>{label}</span>
        <span className="mono" style={{
          fontSize: labelSize, fontWeight: 500,
          color: complete ? "var(--correct)" : "var(--ink)",
        }}>{total === 0 ? "—" : `${done}/${total}`}</span>
      </div>
      <div style={{
        height, borderRadius: height, marginTop: 4,
        background: "var(--rule)", opacity: total === 0 ? 0.3 : 1, overflow: "hidden",
      }}>
        <div style={{ width: `${ratio * 100}%`, height: "100%", borderRadius: height, background: tint }} />
      </div>
    </div>
  );
}

interface AxisValue { done: number; total: number }

/** Les sept jours de la semaine, du lundi au dimanche (barres + initiale). */
function DayStrip({ days, weekStart, now }: { days: number[]; weekStart: Date; now: Date }) {
  const todayIndex = Math.min(Math.max(DateUtils.daysBetween(weekStart, now), 0), 6);
  const peak = Math.max(...days, 3600);
  return (
    <div style={{ display: "flex", alignItems: "flex-end", gap: 6, minWidth: 190 }}>
      {Array.from({ length: 7 }, (_, index) => {
        const seconds = days[index] ?? 0;
        const isToday = index === todayIndex;
        const height = seconds === 0 ? 0 : Math.max(3, (40 * seconds) / peak);
        return (
          <div key={index} style={{ flex: 1, display: "flex", flexDirection: "column", gap: 4 }}>
            <div style={{
              height: 40, display: "flex", alignItems: "flex-end",
              borderRadius: 3, background: "var(--sheet-raised)", overflow: "hidden",
              opacity: index > todayIndex ? 0.5 : 1,
            }}>
              <div style={{
                width: "100%", height, borderRadius: 3,
                background: isToday ? "var(--ink)" : "var(--ink-tertiary)",
              }} />
            </div>
            <span className="mono" style={{
              textAlign: "center", fontSize: 10, fontWeight: isToday ? 700 : 400,
              color: isToday ? "var(--ink)" : "var(--ink-tertiary)",
            }}>{DateUtils.weekdayInitial(DateUtils.addDays(index, weekStart))}</span>
          </div>
        );
      })}
    </div>
  );
}

/**
 * « Depuis lundi » : le total, le jour même, la bande des sept jours et les trois
 * axes de la semaine. Un total attendu comparé à un mercredi ne dit rien d'utile :
 * ce qui compte est ce qui est fait, d'où des barres et pas un retard.
 */
export function WeekTimeCard({ days, weekStart, theory, series, corrections, late, goal, now }:
  {
    days: number[]; weekStart: Date; theory: AxisValue; series: AxisValue;
    corrections: AxisValue; late: number; goal: number; now: Date;
  }) {
  const total = days.reduce((sum, value) => sum + value, 0);
  const todayIndex = Math.min(Math.max(DateUtils.daysBetween(weekStart, now), 0), 6);
  const today = days[todayIndex] ?? 0;
  return (
    <div className="card" style={{ padding: 18, display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <span style={{
          fontSize: 11, textTransform: "uppercase", letterSpacing: 0.7,
          color: "var(--ink-tertiary)",
        }}>Depuis lundi</span>
        <span style={{ color: "var(--ink-tertiary)", fontSize: 11 }}>
          {today > 0 ? `dont ${DateUtils.durationLabel(today)} aujourd'hui` : "rien encore aujourd'hui"}
        </span>
      </div>

      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", gap: 20, flexWrap: "wrap" }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
          <div style={{ display: "flex", alignItems: "baseline", gap: 6, flexWrap: "wrap" }}>
            <span className="serif" style={{ fontSize: 30 }}>{DateUtils.hoursLabel(total)}</span>
            {goal > 0 && (
              <span style={{ fontSize: 13, color: total >= goal ? "var(--correct)" : "var(--ink-secondary)" }}>
                / {DateUtils.hoursLabel(goal)}
              </span>
            )}
          </div>
          <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
            cette semaine · lundi → dimanche
          </span>
        </div>
        <DayStrip days={days} weekStart={weekStart} now={now} />
      </div>

      <div style={{ height: 1, background: "var(--rule)" }} />

      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", gap: 18 }}>
        <ProgressAxis label="Théorie" done={theory.done} total={theory.total} tint="var(--ink)" height={5} />
        <ProgressAxis label="Séries" done={series.done} total={series.total} tint="var(--ink)" height={5} />
        <ProgressAxis label="Corrigés" done={corrections.done} total={corrections.total} tint="var(--ink)" height={5} />
      </div>

      {late > 0 && (
        <div style={{ fontSize: 12, color: "var(--wrong)", display: "flex", gap: 6, alignItems: "center" }}>
          <span aria-hidden>!</span>
          <span>{Plural.count(late, "1 élément des semaines passées à rattraper", `${late} éléments des semaines passées à rattraper`)}</span>
        </div>
      )}
    </div>
  );
}

/** Une ligne de cours dans sa semaine : les trois axes, le retard en mots, l'examen proche. */
export function WeekCourseRow({ summary, onOpen }:
  { summary: WeekCourseSummary; onOpen: (id: string) => void }) {
  const course = summary.course;
  const week = summary.week;
  const tint = course.colorHex;
  const late = summary.late;
  const ahead = summary.ahead;
  const nextExam = course.nextExam;
  const examSoon = nextExam !== null && DateUtils.daysBetween(new Date(), nextExam.date) <= 14;
  return (
    <button onClick={() => onOpen(course.id)} style={{
      display: "flex", alignItems: "stretch", gap: 12, width: "100%", textAlign: "left",
      padding: "12px 4px", border: "none", background: "none", borderRadius: 8,
    }}>
      <span style={{ width: 4, borderRadius: 2, background: tint, flexShrink: 0 }} />
      <span style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 8 }}>
        <span style={{ display: "flex", alignItems: "baseline", gap: 8, minWidth: 0 }}>
          <CourseTag code={course.displayCode} tint={tint} />
          <span style={{
            fontSize: 14, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
            color: "var(--ink)", flex: 1, minWidth: 0,
          }}>{course.name === "" ? course.displayCode : course.name}</span>
          <StandingLabel late={late} ahead={ahead} complete={week.isComplete} />
        </span>

        {week.hasItems && (
          <span style={{ display: "flex", gap: 14 }}>
            <ProgressAxis label="Théorie" done={week.watchedCount} total={week.videoCount} tint={tint} height={4} labelSize={11} />
            <ProgressAxis label="Exercices" done={week.doneCount} total={week.exerciseCount} tint={tint} height={4} labelSize={11} />
            {week.doneCount > 0 && (
              <ProgressAxis label="Corrigés" done={week.correctedCount} total={week.doneCount} tint={tint} height={4} labelSize={11} />
            )}
          </span>
        )}

        {!summary.corrections.isEmpty && (
          <span style={{
            fontSize: 11, fontWeight: 500,
            color: summary.corrections.toRedo > 0 ? "var(--wrong)" : "var(--ink-secondary)",
          }}>{correctionsLine(summary)}</span>
        )}

        {examSoon && nextExam && (
          <span style={{
            fontSize: 11, fontWeight: 500,
            color: DateUtils.daysBetween(new Date(), nextExam.date) <= 3 ? "var(--wrong)" : "var(--ink-secondary)",
          }}>
            {ExamKind.label(nextExam.kind)} {DateUtils.countdownLabel(nextExam.date).toLowerCase()}
          </span>
        )}
      </span>
    </button>
  );
}

function StandingLabel({ late, ahead, complete }: { late: number; ahead: number; complete: boolean }) {
  if (late > 0) {
    return <span style={{ fontSize: 11, fontWeight: 600, color: "var(--wrong)", whiteSpace: "nowrap" }}>{late} en retard</span>;
  }
  if (complete) {
    return <span style={{ fontSize: 11, fontWeight: 600, color: "var(--correct)", whiteSpace: "nowrap" }}>✓ semaine faite</span>;
  }
  if (ahead > 0) {
    return <span style={{ fontSize: 11, fontWeight: 600, color: "var(--correct)", whiteSpace: "nowrap" }}>{ahead} d'avance</span>;
  }
  return <span style={{ fontSize: 11, color: "var(--ink-secondary)", whiteSpace: "nowrap" }}>à jour</span>;
}

function correctionsLine(summary: WeekCourseSummary): string {
  const parts: string[] = [];
  if (summary.corrections.toCorrect > 0) parts.push(`${summary.corrections.toCorrect} à corriger`);
  if (summary.corrections.toRedo > 0) parts.push(`${summary.corrections.toRedo} à refaire`);
  return parts.join(" · ");
}
