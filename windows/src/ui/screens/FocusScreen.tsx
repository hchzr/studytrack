// La page Chrono : le cadran en grand, et tout ce qui tourne autour d'une
// session — sur quoi, la suite, le temps par exercice, le récapitulatif.
//
// Portée de `MacFocusView` : le cadran, les trois gestes, le choix du cours et
// du travail, le cycle Pomodoro, le récapitulatif et l'objectif du jour. Le mode
// étude du Mac (fenêtre verrouillée, sites filtrés) n'est pas ici : il n'a pas
// d'équivalent Windows dans cette app.

import { useMemo } from "react";
import { useData } from "../../data/dataContext.tsx";
import { Course, StudySession } from "../../models/index.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { StudyGoal } from "../../domain/studyGoal.ts";
import { StudyMode } from "../../domain/studyMode.ts";
import { PageHeader } from "../kit.tsx";
import { FocusDial, FocusControls, PomodoroDots } from "./focus/FocusDial.tsx";
import {
  FocusGoalBar,
  FocusRecapCard,
  FocusSegmentsCard,
  FocusSessionCard,
  FocusSetupCard,
  TogetherLabel,
} from "./focus/FocusCards.tsx";
import { useFocusTimer } from "./focus/useFocusTimer.ts";
import {
  courseHeadlineOf,
  displayClockOf,
  idleClockOf,
  pomodoroStatusOf,
  ringProgressOf,
  statusLineOf,
  tintOf,
} from "./focus/timerView.ts";

export function FocusScreen({ onEnterStudyMode }: { onEnterStudyMode?: () => void }) {
  const { store, version } = useData();
  const timer = useFocusTimer();

  const courses = useMemo(
    () => (store
      ? store.fetch(Course).filter((course) => course.isTracked).sort((a, b) => a.code.localeCompare(b.code))
      : []),
    [store, version],
  );
  const course = courses.find((entry) => entry.id === timer.courseID) ?? null;

  const sessions = useMemo(
    () => (store ? store.fetch(StudySession) : []),
    [store, version],
  );
  const dayStart = DateUtils.startOfDay(timer.now);
  const savedSeconds = useMemo(
    () => sessions
      .filter((session) => session.startedAt.getTime() >= dayStart.getTime())
      .reduce((sum, session) => sum + session.durationSeconds, 0),
    [sessions, dayStart.getTime()],
  );

  const goal = useMemo(
    () => (store
      ? StudyGoal.dailySeconds(StudyGoal.weeklySecondsIn(store, timer.settings.weeklyGoalMinutes, timer.settings.hoursPerCredit))
      : 0),
    [store, version, timer.settings],
  );

  // Le cadran : ce que montre l'anneau, l'horloge et les mots au-dessus.
  const onBreak = timer.phase.type === "onBreak";
  const tint = tintOf(course);
  const dialTint = onBreak ? "var(--correct)" : tint;
  const clock = timer.state
    ? displayClockOf(timer.state, timer.cycle, timer.now)
    : idleClockOf(timer.pomodoro, timer.cycle);
  const ring = ringProgressOf(timer.state, timer.cycle, timer.now);
  const status = statusLineOf(timer.state, timer.cycle, timer.now, course?.displayCode ?? null, timer.pomodoro);
  const headline = courseHeadlineOf(course, timer.taskType, timer.targetID);
  const muted = timer.phase.type === "paused" || timer.phase.type === "readyForBlock";
  const statusInfo = pomodoroStatusOf(timer.state, timer.cycle, timer.now);
  const dots = timer.state?.pomodoro && statusInfo ? (
    <PomodoroDots completed={statusInfo.completedBlocks} every={timer.settings.cycle.longBreakEvery} tint={dialTint} />
  ) : undefined;

  // L'objectif du jour compte la session en cours, à la minute (TodayStudyText).
  const liveSeconds = savedSeconds + (timer.state ? Math.trunc(timer.elapsedNow) : 0);

  return (
    <>
      <PageHeader title="Chrono" />
      <div style={{
        display: "grid",
        gridTemplateColumns: "repeat(auto-fit, minmax(340px, 1fr))",
        gap: 32,
        alignItems: "start",
        justifyItems: "center",
        maxWidth: 920,
        margin: "0 auto",
      }}>
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 24, width: "100%" }}>
          {timer.state?.groupSession && <TogetherLabel name={timer.state.groupSession.groupName} />}
          <FocusDial
            status={status}
            clock={clock}
            headline={headline}
            progress={ring.progress}
            draining={ring.draining}
            tint={dialTint}
            muted={muted}
            dots={dots}
          />
          <FocusControls
            phase={timer.phase}
            hasSession={timer.state !== null}
            tint={tint}
            onToggle={timer.toggle}
            onSkipBreak={timer.skipBreak}
            onFinish={() => { void timer.finish(); }}
            onDiscard={timer.discard}
          />
          <div style={{ width: "100%", maxWidth: 380 }}>
            <FocusGoalBar seconds={liveSeconds} goal={goal} />
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 16, width: "100%", maxWidth: 560 }}>
          {onEnterStudyMode && (timer.state
            ? (StudyMode.isActive(timer.state, timer.now) ? (
              // En session de mode étude : ce qui reste, et la porte du bureau.
              <StudyModeCard
                title={StudyMode.isOpenEnded(timer.state)
                  ? "Mode étude · sans fin"
                  : `Mode étude · reste ${minutesLabel(StudyMode.remaining(timer.state, timer.now))}`}
                button="Ouvrir"
                locked
                onOpen={onEnterStudyMode}
              />
            ) : (
              <StudyModeCard button={timer.phase.type === "idle" ? "Entrer…" : "Verrouiller…"} onOpen={onEnterStudyMode} />
            ))
            : (
              <StudyModeCard button="Entrer…" onOpen={onEnterStudyMode} />
            ))}
          {!timer.state && timer.recap && (
            <FocusRecapCard
              recap={timer.recap}
              courses={courses}
              onUndo={() => { void timer.undoRecap(); }}
              onDismiss={timer.dismissRecap}
            />
          )}
          {!timer.state && <FocusSetupCard api={timer} courses={courses} />}
          {timer.state && <FocusSessionCard api={timer} courses={courses} />}
          {timer.state && <FocusSegmentsCard api={timer} courses={courses} />}
        </div>
      </div>
    </>
  );
}

/** « 25 min », « 1 h 05 » — les minutes qui restent, arrondies au-dessus. */
function minutesLabel(seconds: number): string {
  const minutes = Math.ceil(Math.max(0, seconds) / 60);
  if (minutes >= 60) {
    const hours = Math.floor(minutes / 60);
    return `${hours} h ${minutes % 60 === 0 ? "" : `${minutes % 60}`.padStart(2, "0")}`.trim();
  }
  return `${minutes} min`;
}

/**
 * Le mode étude, proposé à côté du chrono (le `studyCard` du Mac) : une
 * session ouverte s'y verrouille ; une en cours s'y rouvre.
 */
function StudyModeCard({ title, button, locked, onOpen }:
  { title?: string; button: string; locked?: boolean; onOpen: () => void }) {
  return (
    <div className="card" style={{ display: "flex", alignItems: "center", gap: 14, padding: 14 }}>
      <span aria-hidden style={{
        width: 40, height: 40, flexShrink: 0, borderRadius: 12, display: "grid", placeItems: "center",
        background: "var(--sheet-raised)", fontSize: 18,
      }}>{locked ? "🔒" : "🌙"}</span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div className="serif" style={{ fontSize: 16 }}>{title ?? "Mode étude"}</div>
        {!title && <div style={{ fontSize: 12, color: "var(--ink-secondary)" }}>Seulement tes outils de cours.</div>}
      </div>
      <button onClick={onOpen} style={{
        border: "none", borderRadius: 9, padding: "7px 14px",
        background: "var(--ink)", color: "var(--ground)", fontWeight: 600,
      }}>{button}</button>
    </div>
  );
}
