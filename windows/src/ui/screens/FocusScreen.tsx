// La page Chrono : le cadran en grand, et tout ce qui tourne autour d'une
// session — sur quoi, la suite, le temps par exercice, le récapitulatif.
//
// Portée de `MacFocusView` : le cadran, les trois gestes, le choix du cours et
// du travail, le cycle Pomodoro, le récapitulatif et l'objectif du jour ; le
// mode étude s'ouvre par `onEnterStudyMode` (le bureau immersif a son écran).

import { useMemo } from "react";
import { useData } from "../../data/dataContext.tsx";
import { Course, StudySession } from "../../models/index.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { StudyGoal } from "../../domain/studyGoal.ts";
import { StudyMode } from "../../domain/studyMode.ts";
import { PageHeader, Button, Card, Icon, Section } from "../kit.tsx";
import { timerController } from "../timerController.ts";
import { SessionRow } from "./home/todayParts.tsx";
import "./focus/focus.css";
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

  // Les sessions d'aujourd'hui, la plus récente d'abord (rappel au repos).
  const todaySessions = useMemo(
    () => sessions
      .filter((session) => session.startedAt.getTime() >= dayStart.getTime())
      .sort((a, b) => b.startedAt.getTime() - a.startedAt.getTime()),
    [sessions, dayStart.getTime()],
  );

  return (
    <>
      <PageHeader title="Chrono" />
      <div className="f-page">
        <div className="f-dial-col">
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
            locked={timer.state !== null && timerController.isLocked}
            tint={tint}
            onToggle={timer.toggle}
            onSkipBreak={timer.skipBreak}
            onFinish={() => { void timer.finish(); }}
            onDiscard={timer.discard}
          />
          <div className="f-goal">
            <FocusGoalBar seconds={liveSeconds} goal={goal} />
          </div>
        </div>

        <div className="f-cards">
          {!timer.state && timer.recap && (
            <FocusRecapCard
              recap={timer.recap}
              courses={courses}
              onUndo={() => { void timer.undoRecap(); }}
              onDismiss={timer.dismissRecap}
            />
          )}
          {!timer.state && <FocusSetupCard api={timer} courses={courses} />}
          {onEnterStudyMode && (timer.state && StudyMode.isActive(timer.state, timer.now) ? (
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
          ))}
          {timer.state && <FocusSessionCard api={timer} courses={courses} />}
          {timer.state && <FocusSegmentsCard api={timer} courses={courses} />}
          {!timer.state && todaySessions.length > 0 && (
            <Section title="Sessions du jour" style={{ marginBottom: 0 }}>
              <Card className="t-list">
                {todaySessions.slice(0, 5).map((session) => <SessionRow key={session.id} session={session} />)}
              </Card>
            </Section>
          )}
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
    <Card className="f-study">
      <span className="f-study-icon"><Icon name={locked ? "lock" : "moon"} size={20} /></span>
      <div className="f-study-body">
        <div className="serif f-study-title">{title ?? "Mode étude"}</div>
        {!title && <div className="t-sub">Seulement tes outils de cours.</div>}
      </div>
      <Button variant="primary" onClick={onOpen}>{button}</Button>
    </Card>
  );
}
