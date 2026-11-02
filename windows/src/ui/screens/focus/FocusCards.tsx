// Les cartes autour du cadran : ce qu'on va chronométrer, ce qu'on fait
// maintenant, la répartition de la session, le récapitulatif et l'objectif du
// jour — les mêmes blocs que MacFocusView, adaptés à une fenêtre de bureau.

import type { ReactNode } from "react";
import type { Course } from "../../../models/course.ts";
import { TaskType } from "../../../models/enums.ts";
import type { Exercise } from "../../../models/exercise.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { allocation, currentTargetElapsed } from "../../../domain/focusTimerState.ts";
import { TimerText } from "../../../domain/timerText.ts";
import { useData } from "../../../data/dataContext.tsx";
import { Button, Card, Checkbox, Icon, ProgressBar, Switch, cx } from "../../kit.tsx";
import type { FocusRecap, FocusTimerApi } from "./useFocusTimer.ts";
import { headlineOf, targetOptionsFor, tintOf, upNextOf, type TargetOptions } from "./timerView.ts";
import { taskTypeIcon } from "../home/todayParts.tsx";
import "./focus.css";

function CardTitle({ children, trailing }: { children: ReactNode; trailing?: ReactNode }) {
  return (
    <div className="f-card-title">
      <h2 className="serif">{children}</h2>
      <span className="spacer" />
      {trailing}
    </div>
  );
}

/** Le menu des cibles d'un cours : ce qui est à faire d'abord (`TargetMenu`). */
function TargetSelect({ value, options, onChange }:
  { value: string | undefined; options: TargetOptions; onChange: (id: string | undefined) => void }) {
  return (
    <select className="select pill" aria-label="Cible" value={value ?? ""}
      onChange={(event) => onChange(event.target.value === "" ? undefined : event.target.value)}>
      <option value="">Tout le cours</option>
      {options.upNext.length > 0 && (
        <optgroup label="À faire">
          {options.upNext.map((option) => <option key={option.id} value={option.id}>{option.label}</option>)}
        </optgroup>
      )}
      {options.done.length > 0 && (
        <optgroup label={options.doneLabel}>
          {options.done.map((option) => <option key={option.id} value={option.id}>{option.label}</option>)}
        </optgroup>
      )}
    </select>
  );
}

// MARK: - Nouvelle session

/** Au repos : le cours, le travail, la cible, le mode (`TimerSetup`). */
export function FocusSetupCard({ api, courses }: { api: FocusTimerApi; courses: Course[] }) {
  const course = courses.find((entry) => entry.id === api.courseID) ?? null;
  const options = course ? targetOptionsFor(course, api.taskType) : null;
  return (
    <Card className="f-card">
      <CardTitle>Nouvelle session</CardTitle>
      <div className="f-setup">
        <select className="select pill" aria-label="Cours" value={api.courseID ?? ""}
          onChange={(event) => api.chooseCourse(event.target.value === "" ? undefined : event.target.value)}>
          <option value="">Sans cours</option>
          {courses.map((entry) => (
            <option key={entry.id} value={entry.id}>{entry.displayCode} · {entry.name}</option>
          ))}
        </select>
        <select className="select pill" aria-label="Type de travail" value={api.taskType}
          onChange={(event) => api.chooseTaskType(event.target.value as TaskType)}>
          {TaskType.choices.map((choice) => (
            <option key={choice} value={choice}>{TaskType.label(choice)}</option>
          ))}
        </select>
        {course && options && <TargetSelect value={api.targetID} options={options} onChange={api.chooseTarget} />}
      </div>
      <Switch checked={api.pomodoro} onChange={api.setPomodoro}
        label={`Pomodoro · ${api.settings.cycle.focusMinutes}/${api.settings.cycle.shortBreakMinutes} min`} />
    </Card>
  );
}

// MARK: - En session

/** Les questions à cocher de l'exercice en cours (`SubQuestionChecklist`). */
function SubQuestionChecklist({ exercise, tint }: { exercise: Exercise; tint: string }) {
  const { save } = useData();
  const questions = exercise.leafSubQuestions;
  const next = questions.find((question) => !question.isDone)?.id;
  const toggle = (index: number) => {
    const question = questions[index];
    if (!question) return;
    question.isDone = !question.isDone;
    question.doneAt = question.isDone ? new Date() : null;
    exercise.refreshCompletion();
    void save(exercise);
  };
  return (
    <div className="stack" style={{ gap: 2 }}>
      <div className="hstack">
        <span className="t-kicker">Questions</span>
        <span className="spacer" />
        <span className="mono muted" style={{ fontSize: 12 }}>
          {questions.filter((question) => question.isDone).length}/{questions.length}
        </span>
      </div>
      {questions.map((question, index) => (
        <button key={question.id} type="button" className={cx("f-q", question.isDone && "done", question.id === next && "next")}
          aria-pressed={question.isDone} onClick={() => toggle(index)}>
          <Icon name={question.isDone ? "checkmark.circle" : "circle"} size={15}
            color={question.isDone ? tint : "var(--ink-tertiary)"} />
          <span className="mono f-q-path">{question.path}</span>
          <span className="f-q-text">{question.text === "" ? " " : question.text}</span>
        </button>
      ))}
    </div>
  );
}

/** Pendant une session : la cible, son temps, et ce qui vient ensuite. */
export function FocusSessionCard({ api, courses }: { api: FocusTimerApi; courses: Course[] }) {
  const course = courses.find((entry) => entry.id === api.courseID) ?? null;
  const options = course ? targetOptionsFor(course, api.taskType) : null;
  const upNext = course ? upNextOf(course, api.taskType, api.targetID) : [];
  const targetSeconds = api.state ? currentTargetElapsed(api.state, api.now) : 0;
  const exercise = course?.allExercises.find((entry) => entry.id === api.targetID) ?? null;

  return (
    <Card className="f-card">
      <CardTitle trailing={course && options ? (
        <TargetSelect value={api.targetID} options={options}
          onChange={(id) => api.retarget(course.id, api.taskType, id)} />
      ) : undefined}>
        Sur quoi
      </CardTitle>

      {api.targetID && (
        <div className="f-line">
          <span>Sur cet exercice</span>
          <span className="spacer" />
          <span className="mono">{TimerText.clock(targetSeconds)}</span>
        </div>
      )}

      {exercise?.hasSubQuestions && (
        <>
          <hr className="divider" />
          <SubQuestionChecklist exercise={exercise} tint={tintOf(course)} />
        </>
      )}

      <hr className="divider" />
      <span className="t-kicker">Ensuite</span>
      {course ? (
        upNext.length === 0
          ? <span className="muted" style={{ fontSize: 13 }}>Rien d'autre à faire pour l'instant.</span>
          : (
            <div className="f-next">
              {upNext.map((item) => (
                <button key={item.id} type="button" className="f-next-row"
                  onClick={() => api.retarget(course.id, item.taskType, item.id)}>
                  <Icon name={taskTypeIcon(item.taskType)} size={14} color={tintOf(course)} />
                  <span className="t-ellipsis">{item.title}</span>
                  <span className="go">Passer<Icon name="arrow.right" size={12} /></span>
                </button>
              ))}
            </div>
          )
      ) : (
        <div className="stack" style={{ gap: 8, alignItems: "flex-start" }}>
          <span className="muted" style={{ fontSize: 13 }}>Pas de cours choisi.</span>
          <select className="select pill" aria-label="Choisir un cours" value=""
            onChange={(event) => {
              if (event.target.value !== "") api.retarget(event.target.value, api.taskType, undefined);
            }}>
            <option value="">Choisir un cours</option>
            {courses.map((entry) => <option key={entry.id} value={entry.id}>{entry.displayCode}</option>)}
          </select>
        </div>
      )}
    </Card>
  );
}

/** La répartition du temps de la session, cible par cible (`segmentsCard`). */
export function FocusSegmentsCard({ api, courses }: { api: FocusTimerApi; courses: Course[] }) {
  if (!api.state || (api.state.segments?.length ?? 0) === 0) return null;
  const parts = allocation(api.state, api.now);
  if (parts.length <= 1) return null;
  return (
    <Card className="f-card" style={{ gap: 8 }}>
      <CardTitle>Cette session</CardTitle>
      {parts.map((part, index) => {
        const partCourse = courses.find((entry) => entry.id === part.courseID) ?? null;
        return (
          <div key={index} className="f-part">
            <span className="f-part-bar" style={{ background: tintOf(partCourse) }} />
            <span className="t-ellipsis">
              {headlineOf(partCourse, TaskType.fromRaw(part.taskTypeRaw) ?? "other", part.targetID)}
            </span>
            <span className="mono f-part-time">{TimerText.clock(part.seconds)}</span>
          </div>
        );
      })}
    </Card>
  );
}

// MARK: - Récapitulatif

/** Un élément de théorie travaillé : « Vu » se coche tout de suite (`RecapRow`). */
function WatchedMark({ course, targetID }: { course: Course | null; targetID: string | undefined }) {
  const { save } = useData();
  const item = targetID ? course?.theoryItems.find((entry) => entry.id === targetID) ?? null : null;
  if (!item) return null;
  return (
    <div style={{ paddingLeft: 11 }}>
      <Checkbox checked={item.isWatched} label="Vu"
        onChange={(next) => {
          item.watchedAt = next ? (item.watchedAt ?? new Date()) : null;
          void save(item);
        }} />
    </div>
  );
}

/** Après « Terminer » : ce qui a été compté, et de quoi annuler un geste de trop. */
export function FocusRecapCard({ recap, courses, onUndo, onDismiss }: {
  recap: FocusRecap;
  courses: Course[];
  onUndo: () => void;
  onDismiss: () => void;
}) {
  return (
    <Card className="f-card">
      <div className="f-recap-head">
        <Icon name={recap.discarded ? "xmark.circle" : "checkmark.circle"} size={20}
          color={recap.discarded ? "var(--ink-secondary)" : "var(--correct)"} />
        <h2 className="serif">{recap.discarded ? "Trop court, pas gardé" : "Enregistré"}</h2>
        {!recap.discarded && (
          <span className="serif f-recap-total">{DateUtils.durationLabel(recap.totalSeconds)}</span>
        )}
      </div>

      {recap.parts.map((part) => {
        const course = courses.find((entry) => entry.id === part.courseID) ?? null;
        return (
          <div key={part.session.id} className="stack" style={{ gap: 6 }}>
            <div className="f-part">
              <span className="f-part-bar" style={{ background: tintOf(course), height: 16 }} />
              <strong style={{ fontWeight: 600 }}>{course?.displayCode ?? "Libre"}</strong>
              <span className="muted t-ellipsis">{headlineOf(course, part.taskType, part.targetID)}</span>
              <span className="mono f-part-time">{DateUtils.durationLabel(part.seconds)}</span>
            </div>
            <WatchedMark course={course} targetID={part.targetID} />
          </div>
        );
      })}

      <div className="f-recap-actions">
        {!recap.discarded && <Button variant="ghost" size="sm" icon="arrow.counterclockwise" onClick={onUndo}>Annuler</Button>}
        <span className="spacer" />
        <Button variant="primary" size="sm" onClick={onDismiss}>OK</Button>
      </div>
    </Card>
  );
}

// MARK: - Objectif du jour

/** « 2 h 10 / 3 h » et une barre ; la session en cours s'ajoute à la minute. */
export function FocusGoalBar({ seconds, goal }: { seconds: number; goal: number }) {
  const progress = Math.min(1, seconds / Math.max(goal, 1));
  const done = progress >= 1;
  return (
    <div className="f-goalbar">
      <div className="f-goalbar-head">
        <span>Aujourd'hui</span>
        <span className={cx("mono", done && "done")}>
          {DateUtils.hoursLabel(seconds)} / {DateUtils.hoursLabel(goal)}
        </span>
      </div>
      <ProgressBar value={Math.max(progress, 0.001)} color={done ? "var(--correct)" : "var(--review)"} />
    </div>
  );
}

/** La ligne de la session de groupe, quand le chrono vient d'un autre appareil. */
export function TogetherLabel({ name }: { name: string }) {
  return (
    <div className="f-together">
      <Icon name="person.2" size={15} />
      Session ensemble · {name}
    </div>
  );
}
