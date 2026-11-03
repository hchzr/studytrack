// L'accueil du bureau (StudyDeskHome + LectureDeskView + RevisionDeskView) :
// ce qu'on voit en entrant dépend du moment — la série en cours, le cours à
// l'horaire, la révision avant l'examen. Les cartes que le Mac réarrange à la
// main (DeskWidgets) sont ici en grille fixe, les mêmes pour chacun.

import { useState, type ReactNode } from "react";
import { Icon } from "../../kit.tsx";
import type { Course } from "../../../models/course.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import { TaskType } from "../../../models/enums.ts";
import { DeskMoment, LectureClock, LectureMark, LectureMarks, RevisionFocus, type DeskMoment as DeskMomentValue } from "../../../domain/deskMoment.ts";
import { openInApp } from "../openers.ts";
import { DeskSchedule, kindLabelOf, type ScheduledClass } from "../../../domain/deskSchedule.ts";
import { Deadline } from "../../../domain/deadline.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { SeriesReview } from "../../../domain/seriesReview.ts";
import { StudyMode } from "../../../domain/studyMode.ts";
import { RevisionSheet } from "../../../domain/revisionSheet.ts";
import { upNextOf, headlineOf } from "../../screens/focus/timerView.ts";
import { MathText } from "../../screens/course/common.tsx";
import { timerController } from "../../timerController.ts";
import type { StudyTimerApi } from "../useStudyTimer.ts";
import type { StudyPane } from "../paneKind.ts";
import { lecturePhaseLabel } from "../helpers.ts";
import {
  CourseTag, ExerciseQuickMark, GlassCard, Glyph, InkButton, Kicker, StudyDial,
  SubQuestionChecklist, tintOfCourse,
} from "../parts.tsx";

/** Une ligne « ensuite » : y passer sans couper le chrono (UpNextList). */
function UpNextRow({ title, tint, onPick }: { title: string; tint: string; onPick: () => void }) {
  return (
    <button type="button" className="study-row" onClick={onPick}
      style={{ gap: 8, padding: "5px 8px", borderRadius: 8, fontSize: 14 }}>
      <span aria-hidden style={{ width: 7, height: 7, borderRadius: 4, background: tint, flexShrink: 0 }} />
      <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{title}</span>
      <div style={{ flex: 1 }} />
      <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>Passer</span>
    </button>
  );
}

/** Le temps du bureau : le cadran, seul au centre de sa carte. */
function DialCard({ timer, tint }: { timer: StudyTimerApi; tint: string }) {
  const state = timer.state;
  if (!state) return null;
  return (
    <GlassCard style={{ display: "grid", placeItems: "center" }}>
      <StudyDial state={state} cycle={timer.cycle} now={timer.now} tint={tint} size={240} />
    </GlassCard>
  );
}

/** L'horaire du jour, et le prochain créneau (todayCard). */
function TodayCard({ classes, now }: { classes: ScheduledClass[]; now: Date }) {
  const upcoming = classes.filter((klass) => klass.slot.end.getTime() > now.getTime()).slice(0, 4);
  return (
    <GlassCard>
      <h3 className="serif" style={{ fontSize: 20, margin: "0 0 10px", color: "var(--ink)" }}>Aujourd'hui</h3>
      {upcoming.length === 0 && (
        <p style={{ margin: 0, fontSize: 14, color: "var(--ink-secondary)" }}>Plus rien à l'horaire.</p>
      )}
      {upcoming.map((klass) => (
        <div key={klass.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "4px 0" }}>
          <span aria-hidden style={{ width: 3, height: 30, borderRadius: 2, background: klass.colorHex, flexShrink: 0 }} />
          <span style={{ minWidth: 0 }}>
            <span style={{ display: "block", fontSize: 14, fontWeight: 500, color: "var(--ink)" }}>
              {`${klass.slot.courseCode} · ${kindLabelOf(klass.slot)}`}
            </span>
            <span style={{ display: "block", fontSize: 12, color: "var(--ink-secondary)" }}>
              {`${DateUtils.time(klass.slot.start)} – ${DateUtils.time(klass.slot.end)}${klass.location === "" ? "" : ` · ${klass.location}`}`}
            </span>
          </span>
        </div>
      ))}
    </GlassCard>
  );
}

/** Les échéances de la semaine, tous cours suivis (deadlinesCard). */
function DeadlinesCard({ courses, now }: { courses: Course[]; now: Date }) {
  const list = Deadline.upcoming(courses, 7, DateUtils.startOfDay(now)).slice(0, 5);
  return (
    <GlassCard>
      <h3 className="serif" style={{ fontSize: 20, margin: "0 0 10px", color: "var(--ink)" }}>Échéances</h3>
      {list.length === 0 && (
        <p style={{ margin: 0, fontSize: 14, color: "var(--ink-secondary)" }}>Rien cette semaine.</p>
      )}
      {list.map((deadline) => (
        <div key={deadline.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "4px 0" }}>
          <span aria-hidden style={{ width: 3, height: 26, borderRadius: 2, background: deadline.colorHex, flexShrink: 0 }} />
          <span style={{ minWidth: 0 }}>
            <span style={{ display: "block", fontSize: 14, fontWeight: 500, color: "var(--ink)",
              overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {deadline.title}
            </span>
            <span style={{ display: "block", fontSize: 12, color: "var(--ink-secondary)" }}>
              {`${deadline.courseCode} · ${DateUtils.shortDay(deadline.date)}`}
            </span>
          </span>
        </div>
      ))}
    </GlassCard>
  );
}

/** La théorie de la semaine, à cocher au fil du cours (TheoryTick). */
function TheoryTick({ item, onToggle }: { item: TheoryItem; onToggle: () => void }) {
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-pressed={item.isWatched}
      style={{
        display: "flex", alignItems: "center", gap: 10, width: "100%", textAlign: "left",
        padding: "6px 0", border: "none", background: "transparent", fontSize: 14, color: "var(--ink)",
      }}
    >
      <span aria-hidden style={{ display: "grid", color: item.isWatched ? "var(--correct)" : "var(--ink-tertiary)" }}>
        <Icon name={item.isWatched ? "checkmark.circle" : "circle"} size={16} />
      </span>
      <span style={{ flex: 1 }}>{item.numberAndTitle}</span>
    </button>
  );
}


// MARK: Repère, annales, théorie (LectureDeskView / RevisionDeskView)

const MARKS_KEY = "lecture.marks";
function readMarks(): LectureMark[] {
  try {
    const raw = JSON.parse(localStorage.getItem(MARKS_KEY) ?? "[]") as { id: string; courseID: string; classStart: string; at: string }[];
    return raw.map((m) => ({ id: m.id, courseID: m.courseID, classStart: new Date(m.classStart), at: new Date(m.at) }));
  } catch { return []; }
}

/** « Repère » : un toucher quand on décroche ; le soir, l'enregistrement s'ouvre à cette minute. */
function RepereCard({ course, classStart, now }: { course: Course; classStart: Date; now: Date }) {
  const [marks, setMarks] = useState<LectureMark[]>(readMarks);
  const mine = LectureMarks.of(course.id, classStart, marks);
  const add = () => {
    const next = LectureMarks.adding(LectureMark.make(course.id, classStart, new Date()), marks);
    setMarks(next);
    try { localStorage.setItem(MARKS_KEY, JSON.stringify(next)); } catch { /* pour la session */ }
  };
  void now;
  return (
    <GlassCard>
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <Kicker>Repère</Kicker>
        <button type="button" className="btn btn-primary" onClick={add}>Je décroche ici</button>
        {mine.length > 0 && (
          <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
            {mine.map((m) => LectureMark.offsetLabel(m)).join(" · ")} — à revoir dans l'enregistrement
          </span>
        )}
      </div>
    </GlassCard>
  );
}

/** Les annales, dans l'ordre où les travailler (RevisionFocus.pastExamOrder). */
function PastExamsCard({ course }: { course: Course }) {
  const exams = course.pastExams;
  if (exams.length === 0) return null;
  const order = RevisionFocus.pastExamOrder(exams.map((exam) => ({
    id: exam.id, year: exam.year, worked: exam.workedAt !== null, confidence: (exam.confidenceRaw as "red" | "orange" | "green" | null) ?? null,
  })));
  const sorted = order.map((id) => exams.find((exam) => exam.id === id)).filter((exam): exam is NonNullable<typeof exam> => exam !== undefined);
  return (
    <GlassCard>
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <Kicker>Annales</Kicker>
        {sorted.slice(0, 5).map((exam) => (
          <div key={exam.id} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 14 }}>
            <span style={{ flex: 1, color: "var(--ink)" }}>{exam.title || `${exam.year}`}</span>
            <span style={{ fontSize: 12, color: exam.workedAt ? "var(--ink-secondary)" : "var(--review)" }}>{exam.workedAt ? "faite" : "jamais faite"}</span>
            {exam.urlString && <button type="button" className="btn btn-sm" onClick={() => { void openInApp(exam.urlString, exam.title || "Annale"); }}>Sujet</button>}
            {exam.solutionURLString && <button type="button" className="btn btn-sm" onClick={() => { void openInApp(exam.solutionURLString, "Corrigé"); }}>Corrigé</button>}
          </div>
        ))}
      </div>
    </GlassCard>
  );
}

/** La théorie pas encore vue, jusqu'à cette semaine. */
function UnseenTheoryCard({ course, save }: { course: Course; save?: (instance: object) => Promise<void> }) {
  const [, bump] = useState(0);
  const week = course.currentWeek;
  const unseen = course.theoryItems.filter((item) => !item.isWatched && item.plannedWeek <= Math.max(week, 1))
    .sort((a, b) => a.plannedWeek - b.plannedWeek);
  if (unseen.length === 0) return null;
  return (
    <GlassCard>
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <Kicker>{`Théorie pas encore vue · ${unseen.length}`}</Kicker>
        {unseen.slice(0, 6).map((item) => (
          <TheoryTick key={item.id} item={item} onToggle={() => { item.watchedAt = new Date(); void save?.(item); bump((n) => n + 1); }} />
        ))}
      </div>
    </GlassCard>
  );
}

export function DeskHome({ course, courses, classes, timer, save, onOpenPane }: {
  course: Course | null;
  /** Tous les cours suivis (les échéances). */
  courses: Course[];
  classes: ScheduledClass[];
  timer: StudyTimerApi;
  save: (instance: object) => Promise<void>;
  onOpenPane: (pane: StudyPane) => void;
}) {
  const tint = tintOfCourse(course);
  const moment: DeskMomentValue = DeskSchedule.moment(timer.taskType, timer.state?.groupSession != null, course);
  const state = timer.state;

  const persist = (objects: object[]) => {
    void (async () => {
      for (const object of [...new Set(objects)]) await save(object);
    })();
  };

  // L'exercice visé, et la suite (le temps déjà compté reste à la cible précédente).
  const exercise = course?.allExercises.find((item) => item.id === timer.targetID) ?? null;
  const upNext = course ? upNextOf(course, timer.taskType, timer.targetID, 3) : [];
  const passTo = (taskTypeValue: TaskType, id: string) => {
    if (course) timerController.retarget(course.id, taskTypeValue, id);
    onOpenPane("exercise");
  };

  const grid = (cards: ReactNode) => (
    <div style={{
      display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(340px, 1fr))",
      gap: 18, alignItems: "start", width: "100%",
    }}>{cards}</div>
  );

  const header = (
    <h1 className="serif" style={{ fontSize: 28, margin: 0, color: "var(--ink)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
      {course?.name ?? "Ta session"}
    </h1>
  );

  // MARK: L'accueil des séries

  const seriesHome = (
    <>
      {header}
      {grid(
        <>
          <GlassCard>
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  {course && <CourseTag code={course.displayCode} tint={tint} />}
                  <Kicker>{DeskMoment.title(moment)}</Kicker>
                </div>
                {exercise ? (
                  <>
                    <div>
                      <div className="serif" style={{ fontSize: 34, lineHeight: 1.1, color: "var(--ink)" }}>
                        {exercise.displayNumber}
                      </div>
                      {exercise.title !== "" && exercise.title !== exercise.displayNumber && (
                        <div style={{ marginTop: 2, fontSize: 15, color: "var(--ink-secondary)" }}>
                          <MathText text={exercise.title} />
                        </div>
                      )}
                      {exercise.statement !== "" && (
                        <div style={{ marginTop: 6, fontSize: 13.5, color: "var(--ink-secondary)",
                          display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden" }}>
                          <MathText text={exercise.statement} />
                        </div>
                      )}
                    </div>
                    {exercise.hasSubQuestions && (
                      <div style={{ padding: 12, borderRadius: 12, background: "var(--sheet-raised)" }}>
                        <SubQuestionChecklist
                          exercise={exercise}
                          tint={tint}
                          onToggle={(question) => {
                            // `toggle()` met à jour l'exercice et les questions parentes.
                            question.toggle();
                            persist([exercise, ...exercise.subQuestions]);
                          }}
                        />
                      </div>
                    )}
                    <ExerciseQuickMark
                      exercise={exercise}
                      onToggleDone={(target) => { target.setDone(!target.isDone); persist([target, ...target.subQuestions]); }}
                      onCorrect={(target, result) => {
                        if (result === null) target.clearCorrection();
                        else target.correct(result);
                        persist([target, ...target.subQuestions]);
                      }}
                    />
                    <InkButton wide onClick={() => onOpenPane("exercise")}>
                      <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
                        Ouvrir l'exercice <Glyph name="arrow.right" />
                      </span>
                    </InkButton>
                  </>
                ) : (
                  <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                    <span className="serif" style={{ fontSize: 26, color: "var(--ink)" }}>
                      {headlineOf(course, timer.taskType, timer.targetID)}
                    </span>
                    <span style={{ fontSize: 13, color: "var(--ink-secondary)" }}>
                      Choisis un exercice : le chrono y passera, sans couper.
                    </span>
                  </div>
                )}
              </div>
          </GlassCard>

          <GlassCard>
            <Kicker>Ensuite</Kicker>
            {upNext.length === 0 ? (
              <p style={{ margin: "8px 0 0", fontSize: 14, color: "var(--ink-secondary)" }}>Rien d'autre à faire pour l'instant.</p>
            ) : (
              <div style={{ display: "flex", flexDirection: "column", gap: 2, marginTop: 6 }}>
                {upNext.map((item) => (
                  <UpNextRow key={item.id} title={item.title} tint={tint} onPick={() => passTo(item.taskType, item.id)} />
                ))}
              </div>
            )}
          </GlassCard>

          <TodayCard classes={classes} now={timer.now} />
          <DeadlinesCard courses={courses} now={timer.now} />
          <DialCard timer={timer} tint={tint} />
        </>,
      )}
    </>
  );

  // MARK: L'accueil en cours

  const klass = DeskSchedule.latest(course?.id ?? null, classes, timer.now);
  const next = DeskSchedule.next(classes, timer.now);
  const phase = klass ? LectureClock.phase(klass.slot, timer.now) : null;
  // « Suivre le cours » : la session dure jusqu'à la fin du créneau — prolongée
  // si elle devait finir avant (le geste du choix, au milieu de la session).
  const followClass = () => {
    if (!course || !klass || !state) return;
    timerController.retarget(course.id, "lecture", undefined);
    const until = state.studyUntil;
    if (!until || StudyMode.isOpenEnded(state)) return;
    const left = (klass.slot.end.getTime() - until.getTime()) / 60_000;
    if (left > 0) timerController.extendStudy(Math.ceil(left));
  };
  const followsToTheEnd = state?.studyUntil !== undefined
    && klass !== null && state.studyUntil.getTime() >= klass.slot.end.getTime();
  const theory = course
    ? course.sortedTheoryItems.filter((item) => item.plannedWeek === course.currentWeek)
    : [];

  const lectureHome = (
    <>
      {header}
      {grid(
        <>
          {course && klass && <RepereCard course={course} classStart={klass.slot.start} now={timer.now} />}
          <GlassCard>
            <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
              {course && <CourseTag code={course.displayCode} tint={tint} />}
              {klass && <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>{kindLabelOf(klass.slot)}</span>}
              {klass && klass.location !== "" && (
                <span style={{ fontSize: 12, color: "var(--ink-secondary)", display: "inline-flex", gap: 4 }}>
                  <Glyph name="mappin" /> {klass.location}
                </span>
              )}
            </div>
            <span className="serif" style={{ fontSize: 26, lineHeight: 1.15, color: "var(--ink)" }}>
              {course?.name ?? ""}
            </span>
            {klass ? (
              <>
                <span style={{ fontSize: 17, fontWeight: 500, color: "var(--ink)" }}>
                  {lecturePhaseLabel(klass.slot, timer.now)}
                </span>
                <div aria-hidden style={{ position: "relative", height: 6, borderRadius: 3, background: "var(--sheet-raised)" }}>
                  <div style={{
                    position: "absolute", inset: 0, width: `${Math.min(1, Math.max(0.02, LectureClock.progress(klass.slot, timer.now))) * 100}%`,
                    borderRadius: 3, background: tint,
                  }} />
                  {(() => {
                    // La pause de l'EPFL, marquée sur la barre.
                    const pause = LectureClock.breakWindow(klass.slot);
                    if (!pause) return null;
                    const total = klass.slot.end.getTime() - klass.slot.start.getTime();
                    const start = ((pause.start.getTime() - klass.slot.start.getTime()) / total) * 100;
                    const width = ((pause.end.getTime() - pause.start.getTime()) / total) * 100;
                    return (
                      <div style={{
                        position: "absolute", top: 0, bottom: 0, left: `${start}%`, width: `${width}%`,
                        background: "var(--ground)", opacity: 0.85, borderRadius: 3,
                      }} />
                    );
                  })()}
                </div>
                <div className="mono" style={{ display: "flex", justifyContent: "space-between", fontSize: 11, color: "var(--ink-tertiary)" }}>
                  <span>{DateUtils.time(klass.slot.start)}</span>
                  <span>{DateUtils.time(klass.slot.end)}</span>
                </div>
                {next && (
                  <div style={{ borderTop: "1px solid var(--rule)", paddingTop: 10, display: "flex", gap: 8 }}>
                    <span aria-hidden style={{ width: 3, height: 28, borderRadius: 2, background: next.colorHex }} />
                    <span>
                      <span style={{ display: "block", fontSize: 11, fontWeight: 600, color: "var(--ink-secondary)" }}>
                        {`Ensuite · ${DateUtils.time(next.slot.start)}`}
                      </span>
                      <span style={{ display: "block", fontSize: 14, color: "var(--ink)" }}>
                        {[next.slot.courseCode, kindLabelOf(next.slot), next.location === "" ? null : next.location]
                          .filter((part): part is string => part !== null).join(" · ")}
                      </span>
                    </span>
                  </div>
                )}
                {klass && phase?.kind !== "over" && !followsToTheEnd && (
                  <InkButton wide tint={tint} onClick={followClass}>
                    <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
                      <Glyph name="person.wave.2" /> Suivre le cours · jusqu'à {DateUtils.time(klass.slot.end)}
                    </span>
                  </InkButton>
                )}
              </>
            ) : (
              <p style={{ margin: 0, fontSize: 14, color: "var(--ink-secondary)" }}>
                Pas de créneau à l'horaire maintenant.
              </p>
            )}
            </div>
          </GlassCard>

          {theory.length > 0 && (
            <GlassCard>
              <h3 className="serif" style={{ fontSize: 20, margin: "0 0 8px", color: "var(--ink)" }}>Vu en cours</h3>
              {theory.map((item) => (
                <TheoryTick
                  key={item.id}
                  item={item}
                  onToggle={() => {
                    item.watchedAt = item.isWatched ? null : new Date();
                    persist([item]);
                  }}
                />
              ))}
            </GlassCard>
          )}

          <TodayCard classes={classes} now={timer.now} />
          <DeadlinesCard courses={courses} now={timer.now} />
          <DialCard timer={timer} tint={tint} />
        </>,
      )}
    </>
  );

  // MARK: L'accueil en révision

  const due = course
    ? SeriesReview.redoQueue([course]).filter((item) => (item.redoDueAt?.getTime() ?? Number.POSITIVE_INFINITY) <= timer.now.getTime())
    : [];
  const exam = course?.nextSitting ?? null;
  const sheet = course ? RevisionSheet.decode(course.revisionSheetRaw) : null;

  const revisionHome = (
    <>
      {header}
      {grid(
        <>
          {exam && (
            <GlassCard>
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                <Kicker>Examen</Kicker>
                <span className="serif" style={{ fontSize: 26, color: "var(--ink)" }}>
                  {exam.title === "" ? "Examen" : exam.title}
                </span>
                <span style={{ fontSize: 17, fontWeight: 500, color: exam.daysUntil <= 3 ? "var(--wrong)" : "var(--ink)" }}>
                  {exam.daysUntil === 0 ? "Aujourd'hui" : exam.daysUntil === 1 ? "Demain" : `Dans ${exam.daysUntil} jours`}
                </span>
                <span style={{ fontSize: 13, color: "var(--ink-secondary)" }}>
                  {[DateUtils.fullDayLabel(exam.date), exam.location === "" ? null : exam.location]
                    .filter((part): part is string => part !== null).join(" · ")}
                </span>
              </div>
            </GlassCard>
          )}

          {course && <PastExamsCard course={course} />}
          {course && <UnseenTheoryCard course={course} save={save} />}
          {due.length > 0 ? (
            <button
              type="button"
              onClick={() => {
                if (course) timerController.retarget(course.id, "exercise", due[0].id);
                onOpenPane("exercise");
              }}
              style={{
                display: "flex", alignItems: "center", gap: 12, width: "100%", textAlign: "left",
                padding: 16, borderRadius: 20, border: "1px solid color-mix(in srgb, var(--review) 35%, transparent)",
                background: "color-mix(in srgb, var(--review) 10%, transparent)", cursor: "pointer",
              }}
            >
              <Glyph name="arrow.counterclockwise" />
              <span style={{ flex: 1, minWidth: 0 }}>
                <span style={{ display: "block", fontSize: 14, fontWeight: 600, color: "var(--ink)" }}>
                  {due.length === 1 ? `Une reprise due : ${due[0].displayNumber}` : `${due.length} reprises dues`}
                </span>
                <span style={{ display: "block", fontSize: 12, color: "var(--ink-secondary)" }}>
                  Sur papier, l'énoncé seul, sans tes notes — 15 min chacune
                </span>
              </span>
              <Glyph name="arrow.right" />
            </button>
          ) : (
            <GlassCard>
              <span style={{ display: "inline-flex", gap: 8, alignItems: "center", fontSize: 14, color: "var(--ink-secondary)" }}>
                <Glyph name="checkmark" /> Aucune reprise due
              </span>
            </GlassCard>
          )}

          <GlassCard>
            <button
              type="button"
              onClick={() => onOpenPane("sheet")}
              style={{
                display: "flex", alignItems: "center", gap: 14, width: "100%", textAlign: "left",
                padding: 0, border: "none", background: "transparent", cursor: "pointer", color: "var(--ink)",
              }}
            >
              <Glyph name="list.bullet.rectangle" />
              <span style={{ flex: 1, minWidth: 0 }}>
                <span style={{ display: "block", fontWeight: 600 }}>Fiche de révision</span>
                <span style={{ display: "block", fontSize: 12, color: "var(--ink-secondary)" }}>
                  {sheet !== null
                    ? `${sheet.entries.length} entrées : définitions, théorèmes, méthodes, pièges`
                    : "Tout le cours sur une page — à faire une fois"}
                </span>
              </span>
              <Glyph name="arrow.right" />
            </button>
          </GlassCard>

          <TodayCard classes={classes} now={timer.now} />
          <DeadlinesCard courses={courses} now={timer.now} />
          <DialCard timer={timer} tint={tint} />
        </>,
      )}
    </>
  );

  const home = course === null
    ? seriesHome
    : moment === "lecture"
      ? lectureHome
      : moment === "revision"
        ? revisionHome
        : seriesHome;

  return (
    <div style={{ padding: 28, overflowY: "auto", height: "100%", display: "flex", flexDirection: "column", gap: 18 }}>
      {home}
    </div>
  );
}
