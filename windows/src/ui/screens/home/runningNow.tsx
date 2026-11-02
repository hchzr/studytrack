// La session en cours, en grand, sur Aujourd'hui (`RunningNowCard` du Mac).
// Ne se monte que pendant une session : le battement du chrono ne tourne pas au repos.

import { Course } from "../../../models/index.ts";
import { Button, Card } from "../../kit.tsx";
import { timerController } from "../../timerController.ts";
import { useData } from "../../../data/dataContext.tsx";
import { useFocusTimer } from "../focus/useFocusTimer.ts";
import { courseHeadlineOf, displayClockOf, statusLineOf, tintOf } from "../focus/timerView.ts";
import "./today.css";

export function RunningNowCard({ onOpenFocus, onEnterStudyMode }: { onOpenFocus?: () => void; onEnterStudyMode?: () => void }) {
  const { store } = useData();
  const timer = useFocusTimer();
  const state = timer.state;
  if (!state || !store) return null;
  const course = store.fetch(Course).find((entry) => entry.id === timer.courseID) ?? null;
  const onBreak = timer.phase.type === "onBreak";
  const tint = onBreak ? "var(--correct)" : tintOf(course);
  const status = statusLineOf(state, timer.cycle, timer.now, course?.displayCode ?? null, timer.pomodoro);
  const clock = displayClockOf(state, timer.cycle, timer.now);
  const paused = timer.phase.type === "paused" || timer.phase.type === "readyForBlock";
  return (
    <Card accent={tint} className="t-running">
      <div className="t-running-body">
        <span className="t-kicker" style={{ color: tint }}>{status}</span>
        <span className="serif t-running-title t-ellipsis">
          {courseHeadlineOf(course, timer.taskType, timer.targetID)}
        </span>
        <span className="t-sub t-ellipsis">{course?.name ?? "Session libre"}</span>
      </div>
      <span className="serif t-running-clock" style={{ color: paused ? "var(--ink-secondary)" : "var(--ink)" }}>
        {clock}
      </span>
      <div className="t-running-actions">
        <Button variant="primary" icon={timer.phase.type === "working" ? "pause.fill" : "play.fill"}
          onClick={onBreak ? timer.skipBreak : timer.toggle}>
          {timer.phase.type === "working" ? "Pause" : "Reprendre"}
        </Button>
        <Button icon="checkmark" onClick={() => { void timer.finish(); }}>Terminer</Button>
        {/* En mode étude : y revenir ; sinon ouvrir le chrono (comme le Mac). */}
        {timerController.isStudying
          ? onEnterStudyMode && <Button variant="ghost" icon="moon" onClick={onEnterStudyMode}>Mode étude</Button>
          : onOpenFocus && <Button variant="ghost" trailingIcon="arrow.right" onClick={onOpenFocus}>Ouvrir</Button>}
      </div>
    </Card>
  );
}
