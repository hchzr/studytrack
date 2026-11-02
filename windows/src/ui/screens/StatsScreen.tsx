// Bilan — le temps d'étude **et** d'amphi, jamais confondus : où il est allé,
// quand, et ce qu'il a produit (théorie vue, exercices faits, corrections).
//
// Port de Views/Stats/StatsView.swift et StatsCharts.swift, mis en page pour
// une fenêtre de bureau (MacStatsView.swift) : les mêmes chiffres, les mêmes
// cartes, les graphiques en SVG et le journal corrigeable en bas.

import { useMemo, useState } from "react";
import { useData } from "../../data/dataContext.tsx";
import { DateUtils, capitalizedFirst } from "../../domain/dateUtils.ts";
import { StudyGoal } from "../../domain/studyGoal.ts";
import { Correctness, StudySession, TaskType } from "../../models/index.ts";
import { Button, Icon, IconButton, PageHeader, ProgressBar, Segmented } from "../kit.tsx";
import {
  Donut, LineChart, PaceBars, SplitBar, TimeBars,
  type LineSeries,
} from "./stats/charts.tsx";
import {
  coursesCount, exercisesCount, hoursValue, lineLabel, percent, sessionsCount,
} from "./stats/format.ts";
import { carnetTint, correctnessColor, taskColor, useDarkMode } from "./stats/palette.ts";
import { LegendChip, LegendDot, StatCard } from "./stats/parts.tsx";
import { SessionEditor } from "./stats/SessionEditor.tsx";
import "./stats/stats.css";
import { readFocusSettings } from "./focus/focusSettings.ts";

/** L'objectif réglé sur ce poste (le même que celui du chrono). */
const goalSettings = () => readFocusSettings();
import {
  LECTURE_CATEGORY, PERIOD_LABELS, buildStats, journalGroups, journalSessions, weekLabel,
  type Period, type StatsSnapshot,
} from "./stats/statsData.ts";

const PERIODS: Period[] = ["week", "month", "semester"];

export function StatsScreen() {
  const { store, version } = useData();
  const dark = useDarkMode();
  const [period, setPeriod] = useState<Period>("week");
  const [weekOffset, setWeekOffset] = useState(0);
  const [pinnedBin, setPinnedBin] = useState<Date | null>(null);
  const [selectedSplit, setSelectedSplit] = useState<string | null>(null);
  const [selectedCourse, setSelectedCourse] = useState<string | null>(null);
  const [selectedVerdict, setSelectedVerdict] = useState<Correctness | null>(null);
  const [selectedWeek, setSelectedWeek] = useState<Date | null>(null);
  const [showHistory, setShowHistory] = useState(false);
  const [editing, setEditing] = useState<{ session: StudySession; isNew: boolean } | null>(null);

  const snapshot = useMemo(
    () => (store ? buildStats(store, period, weekOffset, new Date(), dark) : null),
    [store, version, period, weekOffset, dark],
  );

  const choosePeriod = (value: Period): void => {
    setPeriod(value);
    setWeekOffset(0);
    setPinnedBin(null);
    setSelectedWeek(null);
  };

  const shiftWeek = (delta: number): void => {
    setWeekOffset((offset) => offset + delta);
    setPinnedBin(null);
  };

  const addManual = (): void => {
    // Une session d'une heure, il y a une heure : on la corrige dans la feuille.
    const session = new StudySession({
      course: null,
      taskType: "exercise",
      startedAt: new Date(Date.now() - 3_600_000),
      durationSeconds: 3600,
      isManual: true,
    });
    setEditing({ session, isNew: true });
  };

  if (!store || !snapshot) {
    return <p style={{ color: "var(--ink-secondary)" }}>Chargement…</p>;
  }

  return (
    <>
      <PageHeader
        title="Bilan"
        subtitle={snapshot.rangeLabel}
        actions={(
          <Button variant="primary" icon="plus" onClick={addManual} title="Ajouter une session passée">
            Ajouter
          </Button>
        )}
      />

      <div className="stats-toolbar">
        <Segmented
          ariaLabel="Période"
          value={period}
          options={PERIODS.map((value) => ({ value, label: PERIOD_LABELS[value] }))}
          onChange={choosePeriod}
        />
        {period === "week" && (
          <div className="hstack">
            <IconButton icon="chevron.left" label="Semaine précédente" bordered onClick={() => shiftWeek(-1)} />
            <IconButton icon="chevron.right" label="Semaine suivante" bordered
              onClick={() => shiftWeek(1)} disabled={weekOffset >= 0} />
          </div>
        )}
      </div>

      <Totals snapshot={snapshot} />

      <div className="stats-top" style={{ marginTop: 18 }}>
        <div className="stats-side">
          <SplitCard snapshot={snapshot} selected={selectedSplit} onSelect={setSelectedSplit} />
          <CoursePieCard snapshot={snapshot} selected={selectedCourse} onSelect={setSelectedCourse} />
        </div>
        <TimeChartCard
          snapshot={snapshot}
          pinnedBin={pinnedBin}
          onPin={(bin) => setPinnedBin((current) => (
            current && current.getTime() === bin.getTime() ? null : bin
          ))}
          onClear={() => setPinnedBin(null)}
        />
      </div>

      {period === "semester" && (
        <div style={{ marginTop: 18 }}>
          <WeeklyTrendCard
            snapshot={snapshot}
            selectedWeek={selectedWeek}
            onSelectWeek={(week) => setSelectedWeek((current) => (
              current && current.getTime() === week.getTime() ? null : week
            ))}
          />
        </div>
      )}

      <div className="stats-wide" style={{ marginTop: 18 }}>
        <div className="stats-side">
          <PaceCard snapshot={snapshot} />
          <CorrectionsCard
            snapshot={snapshot}
            selected={selectedVerdict}
            onSelect={setSelectedVerdict}
          />
        </div>
        <div className="stats-side">
          <ProgressSection snapshot={snapshot} dark={dark} />
        </div>
      </div>

      <div style={{ marginTop: 18 }}>
        <JournalCard
          snapshot={snapshot}
          dark={dark}
          pinnedBin={pinnedBin}
          onClearPin={() => setPinnedBin(null)}
          showHistory={showHistory}
          onToggleHistory={() => setShowHistory((value) => !value)}
          onEdit={(session) => setEditing({ session, isNew: false })}
          onAdd={addManual}
        />
      </div>

      {editing && (
        <SessionEditor
          session={editing.session}
          isNew={editing.isNew}
          courses={snapshot.courses}
          onClose={() => setEditing(null)}
        />
      )}
    </>
  );
}

// MARK: - Totaux

function Totals({ snapshot }: { snapshot: StatsSnapshot }) {
  const hasLecture = snapshot.lectureSeconds > 0;
  const total = snapshot.studySeconds + snapshot.lectureSeconds;
  const days = snapshot.activeDays;

  // L'objectif du jour (comme `settings.dailyGoalSeconds` du Mac) : seulement
  // quand les barres sont des jours — une barre de semaine ne se compare pas.
  const weekly = StudyGoal.weeklySeconds(goalSettings().weeklyGoalMinutes, snapshot.tracked, goalSettings().hoursPerCredit);
  const dailyGoal = StudyGoal.dailySeconds(weekly);
  const dayTotals = new Map<number, number>();
  for (const bar of snapshot.timeBars) {
    dayTotals.set(bar.bin.getTime(), (dayTotals.get(bar.bin.getTime()) ?? 0) + bar.seconds);
  }
  const goalDays = [...dayTotals.values()].filter((seconds) => seconds >= dailyGoal).length;

  return (
    <div className="card stats-figures">
      <Figure
        title="Étude"
        value={DateUtils.hoursLabel(snapshot.studySeconds)}
        detail={sessionsCount(snapshot.studySessions.length)}
      />
      {hasLecture && (
        <>
          <Figure
            title="Amphi"
            value={DateUtils.hoursLabel(snapshot.lectureSeconds)}
            detail={coursesCount(snapshot.lectures.length)}
          />
          <Figure title="Total" value={DateUtils.hoursLabel(total)} detail="étude + amphi" />
        </>
      )}
      <Figure
        title="Jours actifs"
        value={`${days}`}
        detail={days > 0 ? `${DateUtils.hoursLabel(Math.trunc(total / days))} par jour actif` : "sur la période"}
      />
      {!snapshot.binsByWeek && (
        <Figure title="Objectif atteint" value={`${goalDays}`} detail={`≥ ${DateUtils.hoursLabel(dailyGoal)} par jour`} />
      )}
    </div>
  );
}

function Figure({ title, value, detail }: { title: string; value: string; detail: string }) {
  return (
    <div className="stats-figure">
      <div className="t">{title}</div>
      <div className="v serif">{value}</div>
      <div className="d">{detail}</div>
    </div>
  );
}

// MARK: - Répartition

function SplitCard({ snapshot, selected, onSelect }: {
  snapshot: StatsSnapshot;
  selected: string | null;
  onSelect: (name: string | null) => void;
}) {
  const slices = snapshot.splitSlices;
  const total = slices.reduce((sum, slice) => sum + slice.seconds, 0);
  const chosen = slices.find((slice) => slice.name === selected) ?? null;
  const accessory = chosen
    ? `${chosen.name} · ${DateUtils.hoursLabel(chosen.seconds)} · ${percent(chosen.seconds, total)}`
    : undefined;

  return (
    <StatCard title="Répartition" accessory={accessory}>
      {total === 0 ? (
        <p style={{ color: "var(--ink-secondary)", fontSize: 13, margin: 0 }}>Rien sur cette période.</p>
      ) : (
        <>
          <SplitBar
            slices={slices}
            selected={chosen?.name ?? null}
            onSelect={(name) => onSelect(chosen?.name === name ? null : name)}
          />
          <div style={{ display: "flex", flexWrap: "wrap", gap: "8px 14px", marginTop: 12 }}>
            {slices.map((slice) => (
              <LegendChip
                key={slice.name}
                color={slice.color}
                opacity={slice.opacity}
                label={slice.name}
                value={percent(slice.seconds, total)}
                dimmed={chosen !== null && chosen.name !== slice.name}
              />
            ))}
          </div>
        </>
      )}
    </StatCard>
  );
}

// MARK: - Par matière

function CoursePieCard({ snapshot, selected, onSelect }: {
  snapshot: StatsSnapshot;
  selected: string | null;
  onSelect: (name: string | null) => void;
}) {
  const slices = snapshot.courseSlices;
  const total = slices.reduce((sum, slice) => sum + slice.seconds, 0);
  const chosen = slices.find((slice) => slice.name === selected) ?? null;

  return (
    <StatCard title="Par matière">
      {total === 0 ? (
        <p style={{ color: "var(--ink-secondary)", fontSize: 13, margin: 0 }}>Rien sur cette période.</p>
      ) : (
        <>
          <div style={{ display: "flex", alignItems: "center", gap: 18, minWidth: 0 }}>
            <Donut
              slices={slices}
              total={total}
              selected={chosen?.name ?? null}
              onSelect={(name) => onSelect(chosen?.name === name ? null : name)}
              innerRatio={0.58}
              inset={1.5}
              size={150}
            >
              <div>
                <div className="serif" style={{ fontSize: 20, lineHeight: 1.15 }}>
                  {DateUtils.hoursLabel(chosen?.seconds ?? total)}
                </div>
                <div style={{
                  fontSize: 11, color: "var(--ink-secondary)", maxWidth: 92,
                  overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
                }}>
                  {chosen?.name ?? "au total"}
                </div>
              </div>
            </Donut>

            <div style={{ display: "flex", flexDirection: "column", gap: 7, flex: 1, minWidth: 0 }}>
              {slices.map((slice) => (
                <LegendDot
                  key={slice.name}
                  color={slice.color}
                  label={slice.name}
                  value={percent(slice.seconds, total)}
                  dimmed={chosen !== null && chosen.name !== slice.name}
                />
              ))}
            </div>
          </div>
          {chosen && (
            <p style={{ fontSize: 12, color: "var(--ink-secondary)", margin: "12px 0 0" }}>
              {chosen.name} — {chosen.detail}
            </p>
          )}
        </>
      )}
    </StatCard>
  );
}

// MARK: - Le temps, jour par jour

function TimeChartCard({ snapshot, pinnedBin, onPin, onClear }: {
  snapshot: StatsSnapshot;
  pinnedBin: Date | null;
  onPin: (bin: Date) => void;
  onClear: () => void;
}) {
  const present = new Set(snapshot.timeBars.map((bar) => bar.category));
  const selectedBars = pinnedBin
    ? snapshot.timeBars.filter((bar) => bar.bin.getTime() === pinnedBin.getTime())
    : [];
  const studySeconds = selectedBars
    .filter((bar) => bar.category !== LECTURE_CATEGORY)
    .reduce((sum, bar) => sum + bar.seconds, 0);
  const lectureSeconds = selectedBars
    .filter((bar) => bar.category === LECTURE_CATEGORY)
    .reduce((sum, bar) => sum + bar.seconds, 0);

  const axisLabel = (date: Date): string => {
    if (snapshot.binsByWeek) return weekLabel(snapshot.term, date);
    if (snapshot.period === "week") return weekdayShort(date);
    return `${date.getDate()}`;
  };
  const tipTitle = (date: Date): string => (snapshot.binsByWeek
    ? `Semaine du ${DateUtils.shortDay(date)}`
    : capitalizedFirst(DateUtils.fullDayLabel(date)));
  // La ligne « objectif » du Mac, sur les barres de jours seulement.
  const goalHours = snapshot.binsByWeek ? undefined
    : StudyGoal.dailySeconds(StudyGoal.weeklySeconds(goalSettings().weeklyGoalMinutes, snapshot.tracked, goalSettings().hoursPerCredit)) / 3600;

  const title = snapshot.binsByWeek ? "Semaine par semaine" : "Jour par jour";

  return (
    <StatCard
      title={title}
      accessory={pinnedBin ? (
        <Button variant="ghost" size="sm" onClick={onClear}>Revenir à toute la période</Button>
      ) : undefined}
    >
      {pinnedBin ? (
        <div style={{ minHeight: 58 }}>
          <div style={{ fontSize: 13, fontWeight: 600 }}>
            {snapshot.binsByWeek
              ? `Semaine du ${DateUtils.shortDay(pinnedBin)}`
              : DateUtils.fullDayLabel(pinnedBin)}
          </div>
          <div style={{ fontSize: 12, color: "var(--ink-secondary)", marginTop: 3 }}>
            {DateUtils.durationLabel(studySeconds)} d'étude
            {lectureSeconds > 0 ? ` · ${DateUtils.durationLabel(lectureSeconds)} d'amphi` : ""}
          </div>
          <div style={{
            fontSize: 11, color: "var(--ink-tertiary)", marginTop: 3,
            overflow: "hidden", display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical",
          }}>
            {selectedBars
              .filter((bar) => bar.category !== LECTURE_CATEGORY)
              .sort((a, b) => b.seconds - a.seconds)
              .map((bar) => `${bar.category} ${DateUtils.durationLabel(bar.seconds)}`)
              .join(" · ")}
          </div>
        </div>
      ) : (
        <div style={{ display: "flex", flexWrap: "wrap", gap: "6px 12px", minHeight: 58, alignContent: "flex-start" }}>
          {snapshot.categoryOrder.filter((name) => present.has(name)).map((name) => {
            const style = snapshot.categoryStyles[name];
            return (
              <LegendChip
                key={name}
                color={style?.color ?? "var(--ink-secondary)"}
                opacity={style?.opacity ?? 1}
                label={name}
              />
            );
          })}
        </div>
      )}

      <TimeBars
        bars={snapshot.timeBars}
        bins={snapshot.bins}
        range={snapshot.range}
        categoryOrder={snapshot.categoryOrder}
        styles={snapshot.categoryStyles}
        selectedBin={pinnedBin}
        onSelect={onPin}
        axisLabel={axisLabel}
        xStride={snapshot.period === "month" ? 5 : 1}
        tipTitle={tipTitle}
        goalHours={goalHours}
      />
    </StatCard>
  );
}

// MARK: - Par semaine

function WeeklyTrendCard({ snapshot, selectedWeek, onSelectWeek }: {
  snapshot: StatsSnapshot;
  selectedWeek: Date | null;
  onSelectWeek: (week: Date) => void;
}) {
  const [studySeries, lectureSeries] = trendSeries(snapshot);
  const selectedIndex = selectedWeek
    ? snapshot.weeks.findIndex((week) => week.getTime() === selectedWeek.getTime())
    : null;

  let accessory: string | undefined;
  if (selectedWeek) {
    const values = snapshot.weeklyPoints.filter((point) => point.week.getTime() === selectedWeek.getTime());
    accessory = `${weekLabel(snapshot.term, selectedWeek)} : `
      + values.map((point) => `${point.series.toLowerCase()} ${hoursValue(point.hours)} h`).join(", ");
  } else if (snapshot.studyAverage > 0) {
    accessory = `≈ ${hoursValue(snapshot.studyAverage)} h d'étude / sem.`;
  }

  return (
    <StatCard title="Par semaine" accessory={accessory}>
      {snapshot.weeks.length === 0 ? (
        <p style={{ color: "var(--ink-secondary)", fontSize: 13, margin: 0 }}>Rien sur cette période.</p>
      ) : (
        <>
          <div style={{ display: "flex", gap: 14, marginBottom: 6 }}>
            <LegendChip color="var(--ink)" label="Étude" />
            <LegendChip color="var(--ink-tertiary)" label="Amphi" />
          </div>
          <LineChart
            weeks={snapshot.weeks}
            series={[studySeries, lectureSeries]}
            xLabel={(date) => weekLabel(snapshot.term, date)}
            formatY={(value) => `${Math.round(value)} h`}
            average={snapshot.studyAverage > 0 ? snapshot.studyAverage : undefined}
            selectedIndex={selectedIndex !== null && selectedIndex >= 0 ? selectedIndex : null}
            onSelect={(index) => onSelectWeek(snapshot.weeks[index])}
            plotHeight={150}
            xStride={2}
          />
        </>
      )}
    </StatCard>
  );
}

function trendSeries(snapshot: StatsSnapshot): [LineSeries, LineSeries] {
  const study: number[] = [];
  const lecture: number[] = [];
  for (const week of snapshot.weeks) {
    const points = snapshot.weeklyPoints.filter((point) => point.week.getTime() === week.getTime());
    study.push(points.find((point) => point.series === "Étude")?.hours ?? 0);
    lecture.push(points.find((point) => point.series === "Amphi")?.hours ?? 0);
  }
  return [
    { name: "Étude", color: "var(--ink)", values: study, fill: true },
    { name: "Amphi", color: "var(--ink-tertiary)", values: lecture, fill: true },
  ];
}

// MARK: - Fait / prévu

function PaceCard({ snapshot }: { snapshot: StatsSnapshot }) {
  return (
    <StatCard title="Fait / prévu à ce jour">
      <PaceBars rows={snapshot.paceRows} emptyLabel="Aucun cours suivi." />
      <p style={{ fontSize: 12, color: "var(--ink-secondary)", margin: "8px 0 0" }}>
        Trait : prévu à ce jour.
      </p>
    </StatCard>
  );
}

// MARK: - Corrections

function CorrectionsCard({ snapshot, selected, onSelect }: {
  snapshot: StatsSnapshot;
  selected: Correctness | null;
  onSelect: (value: Correctness | null) => void;
}) {
  const rows = snapshot.verdicts;
  const total = rows.reduce((sum, row) => sum + row.count, 0);
  const chosen = rows.find((row) => row.result === selected) ?? null;
  const shown = chosen ?? rows.find((row) => row.result === "correct") ?? null;
  const centerPercent = total === 0
    ? "—"
    : `${Math.round(((shown?.count ?? 0) / Math.max(total, 1)) * 100)} %`;

  return (
    <StatCard title="Corrections" accessory={exercisesCount(total)}>
      <div style={{ display: "flex", alignItems: "center", gap: 20, minWidth: 0 }}>
        <Donut
          slices={rows.map((row) => ({
            name: row.result,
            seconds: row.count,
            color: correctnessColor(row.result),
          }))}
          total={total}
          selected={chosen?.result ?? null}
          onSelect={(name) => {
            const value = Correctness.fromRaw(name);
            if (value) onSelect(chosen?.result === value ? null : value);
          }}
          innerRatio={0.64}
          inset={2}
          size={130}
        >
          <div>
            <div className="serif" style={{ fontSize: 22, lineHeight: 1.1 }}>{centerPercent}</div>
            <div style={{ fontSize: 11, color: "var(--ink-secondary)" }}>
              {shown ? lineLabel(shown.result) : "juste"}
            </div>
          </div>
        </Donut>

        <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 8 }}>
          {Correctness.allCases.map((result) => {
            const count = rows.find((row) => row.result === result)?.count ?? 0;
            const dimmed = chosen !== null && chosen.result !== result;
            return (
              <div key={result} style={{
                display: "flex", alignItems: "center", gap: 8, minWidth: 0,
                opacity: dimmed ? 0.45 : 1,
              }}>
                <span style={{
                  width: 9, height: 9, borderRadius: "50%",
                  background: correctnessColor(result), flexShrink: 0,
                }} />
                <span style={{ fontSize: 13, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                  {capitalizedFirst(lineLabel(result))}
                </span>
                <span style={{ flex: 1 }} />
                <span className="mono" style={{ fontSize: 13, color: "var(--ink-secondary)" }}>{count}</span>
              </div>
            );
          })}
          {snapshot.redoCount > 0 && (
            <div style={{ fontSize: 12, fontWeight: 600, color: "var(--wrong)", marginTop: 2 }}>
              {snapshot.redoCount} à refaire
            </div>
          )}
        </div>
      </div>
    </StatCard>
  );
}

// MARK: - Avancement

function ProgressSection({ snapshot, dark }: { snapshot: StatsSnapshot; dark: boolean }) {
  const [theorySeries, exerciseSeries] = doneSeries(snapshot, dark);
  return (
    <>
      <StatCard title="Avancement">
        {snapshot.progressRows.length === 0 ? (
          <p style={{ color: "var(--ink-secondary)", fontSize: 13, margin: 0 }}>Aucun cours suivi.</p>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
            {snapshot.progressRows.map((row, index) => (
              <div key={row.course.id}>
                {index > 0 && <div style={{ height: 1, background: "var(--rule)", marginBottom: 16 }} />}
                <div style={{ display: "flex", alignItems: "baseline", gap: 8, minWidth: 0 }}>
                  <span style={{ fontSize: 12, fontWeight: 600, color: row.color, flexShrink: 0 }}>
                    {row.course.displayCode}
                  </span>
                  <span style={{
                    fontSize: 13, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
                  }}>
                    {row.course.name}
                  </span>
                  <span style={{ flex: 1 }} />
                  {row.late > 0 && (
                    <span style={{ fontSize: 12, fontWeight: 600, color: "var(--wrong)", flexShrink: 0 }}>
                      {row.late} en retard
                    </span>
                  )}
                </div>
                <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", gap: 14, marginTop: 8 }}>
                  <ProgressAxis title="Théorie" done={row.progress.watchedCount} total={row.progress.videoCount} color={row.color} />
                  <ProgressAxis title="Exercices" done={row.progress.doneCount} total={row.progress.exerciseCount} color={row.color} />
                  <ProgressAxis title="Corrigés" done={row.progress.correctedCount} total={row.progress.doneCount} color={row.color} />
                </div>
              </div>
            ))}
          </div>
        )}
      </StatCard>

      <div style={{ marginTop: 14 }}>
        <StatCard
          title="Fait par semaine"
          accessory={(
            <span style={{ display: "inline-flex", gap: 10 }}>
              <LegendChip color={taskColor("theory", dark)} label="théorie" />
              <LegendChip color={taskColor("exercise", dark)} label="exercices" />
            </span>
          )}
        >
          {snapshot.weeks.length === 0 ? (
            <p style={{ color: "var(--ink-secondary)", fontSize: 13, margin: 0 }}>Rien sur cette période.</p>
          ) : (
            <LineChart
              weeks={snapshot.weeks}
              series={[theorySeries, exerciseSeries]}
              xLabel={(date) => weekLabel(snapshot.term, date)}
              formatY={(value) => `${Math.round(value)}`}
              selectedIndex={null}
              onSelect={() => undefined}
              plotHeight={150}
              xStride={2}
              integerAxis
            />
          )}
        </StatCard>
      </div>
    </>
  );
}

function doneSeries(snapshot: StatsSnapshot, dark: boolean): [LineSeries, LineSeries] {
  const theory: number[] = [];
  const exercises: number[] = [];
  for (const week of snapshot.weeks) {
    const points = snapshot.donePoints.filter((point) => point.week.getTime() === week.getTime());
    theory.push(points.find((point) => point.series === "Théorie")?.count ?? 0);
    exercises.push(points.find((point) => point.series === "Exercices")?.count ?? 0);
  }
  return [
    { name: "Théorie", color: taskColor("theory", dark), values: theory, markers: true },
    { name: "Exercices", color: taskColor("exercise", dark), values: exercises, markers: true },
  ];
}

function ProgressAxis({ title, done, total, color }: {
  title: string;
  done: number;
  total: number;
  color: string;
}) {
  const ratio = total <= 0 ? 0 : done / total;
  return (
    <div className="stats-progress-axis">
      <div className="row">
        <span className="muted" style={{ fontSize: 11, whiteSpace: "nowrap" }}>{title}</span>
        <span className="spacer" />
        <span className="mono" style={{ fontSize: 11, fontWeight: 500 }}>
          {total === 0 ? "—" : `${done}/${total}`}
        </span>
      </div>
      <div style={{ marginTop: 5, opacity: total === 0 ? 0.3 : 1 }}>
        <ProgressBar value={ratio} color={color} height={4} />
      </div>
    </div>
  );
}

// MARK: - Journal

function JournalCard({ snapshot, dark, pinnedBin, onClearPin, showHistory, onToggleHistory, onEdit, onAdd }: {
  snapshot: StatsSnapshot;
  dark: boolean;
  pinnedBin: Date | null;
  onClearPin: () => void;
  showHistory: boolean;
  onToggleHistory: () => void;
  onEdit: (session: StudySession) => void;
  onAdd: () => void;
}) {
  const shown = journalSessions(snapshot, pinnedBin);
  const groups = journalGroups(shown);
  // Sans jour choisi, les trois derniers jours actifs ; le reste attend l'historique.
  const visible = pinnedBin === null && !showHistory ? groups.slice(0, 3) : groups;
  const canExpand = pinnedBin === null && groups.length > visible.length;
  const canCollapse = pinnedBin === null && showHistory && groups.length > 3;

  const pinnedLabel = pinnedBin
    ? (snapshot.binsByWeek
      ? `S. du ${DateUtils.shortDay(pinnedBin)}`
      : DateUtils.relativeLabel(pinnedBin))
    : null;

  return (
    <section>
      <div className="stat-card-head">
        <h2 className="caps" style={{ margin: 0 }}>Sessions</h2>
        {pinnedBin && pinnedLabel ? (
          <Button size="sm" trailingIcon="xmark" aria-label="Revenir à toute la période" onClick={onClearPin}>
            {pinnedLabel}
          </Button>
        ) : shown.length > 0 ? (
          <span className="acc">{shown.length}</span>
        ) : undefined}
      </div>

      <div className="card" style={{ padding: visible.length === 0 ? 16 : 0, overflow: "hidden" }}>
        {visible.length === 0 ? (
          <div className="hstack" style={{ gap: 12 }}>
            <span className="muted" style={{ fontSize: 13 }}>
              {pinnedBin === null ? "Aucune session sur la période." : "Aucune session ce jour-là."}
            </span>
            <span className="spacer" />
            <Button size="sm" icon="plus" onClick={onAdd}>Ajouter</Button>
          </div>
        ) : (
          <>
            {visible.map((group, groupIndex) => (
              <div key={group.day.getTime()}>
                <div className="stats-day">
                  <span>{dayLabel(group.day)}</span>
                  <span className="mono">{DateUtils.hoursLabel(group.totalSeconds)}</span>
                </div>
                {group.sessions.map((session, sessionIndex) => (
                  <SessionRow
                    key={session.id}
                    session={session}
                    dark={dark}
                    testId={`session-${groupIndex}-${sessionIndex}`}
                    onEdit={() => onEdit(session)}
                  />
                ))}
              </div>
            ))}

            {(canExpand || canCollapse) && (
              <button
                type="button"
                className="stats-history"
                onClick={onToggleHistory}
              >
                <span>{canCollapse ? "Réduire" : "Tout l'historique"}</span>
                <Icon name={canCollapse ? "chevron.up" : "chevron.right"} size={14} />
              </button>
            )}
          </>
        )}
      </div>
    </section>
  );
}

function SessionRow({ session, dark, testId, onEdit }: {
  session: StudySession;
  dark: boolean;
  testId: string;
  onEdit: () => void;
}) {
  const subtitle = [
    DateUtils.time(session.startedAt),
    session.targetLabel,
    session.isManual ? "saisie" : null,
  ].filter((part): part is string => part !== null).join(" · ");

  return (
    <button
      type="button"
      className="stats-session"
      data-testid={testId}
      onClick={onEdit}
      title="Modifier la session"
    >
      <span style={{
        width: 8, height: 8, borderRadius: 3, flexShrink: 0,
        background: session.course ? carnetTint(session.course.colorHex, dark) : "var(--ink-secondary)",
      }} />
      <span style={{ flex: 1, minWidth: 0 }}>
        <span className="ttl">
          {session.course?.displayCode ?? "Sans cours"} · {TaskType.label(session.taskType)}
        </span>
        <span className="sub">{subtitle}</span>
      </span>
      <span className="mono" style={{ fontSize: 13, flexShrink: 0 }}>{session.durationLabel}</span>
    </button>
  );
}

/** « Lun. » : l'abréviation du jour, comme l'axe du Mac (`weekday(.abbreviated)`). */
function weekdayShort(date: Date): string {
  const label = new Intl.DateTimeFormat("fr-CH", { weekday: "short" }).format(date);
  return capitalizedFirst(label);
}

/** « Aujourd'hui », « Hier », sinon la date complète (initiale en capitale). */
function dayLabel(day: Date): string {
  const now = new Date();
  const today = DateUtils.isSameDay(day, now) || DateUtils.isSameDay(day, DateUtils.addDays(-1, now));
  const label = today ? DateUtils.relativeLabel(day) : DateUtils.fullDayLabel(day);
  return capitalizedFirst(label);
}
