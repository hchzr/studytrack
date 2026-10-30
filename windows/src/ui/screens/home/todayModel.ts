// Tout ce qu'« Aujourd'hui » dérive de l'état persisté, calculé une fois par
// rendu (StudyTrack/Views/Home/TodayView.swift, `TodayState`). Les écrans ne
// font plus que dessiner : planning du jour, semaine, sessions et prochain geste.

import type { ModelStore } from "../../../models/store.ts";
import type { Course } from "../../../models/course.ts";
import { StudySession } from "../../../models/studySession.ts";
import { PlannedSession } from "../../../models/plannedSession.ts";
import { LinkedCalendarEvent } from "../../../models/linkedCalendarEvent.ts";
import { AcademicTerm } from "../../../models/academicTerm.ts";
import { ExamKind } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { StudyTime } from "../../../domain/studyTime.ts";
import { StudyGoal } from "../../../domain/studyGoal.ts";
import { Deadline } from "../../../domain/deadline.ts";
import { WeekCourseSummary } from "../../../domain/progressEngine.ts";

/**
 * Défaut de `SettingsStore.swift` : 30 h de travail par crédit ECTS. Les réglages
 * ne sont pas encore portés côté Windows ; l'objectif se déduit donc de la charge
 * EPFL, exactement comme `StudyGoal.weeklySeconds(goalMinutes: 0…)`.
 */
const HOURS_PER_CREDIT = 30;

export interface TodayItem {
  id: string;
  start: Date;
  end: Date | null;
  title: string;
  subtitle: string;
  /** Couleur du cours, ou une variable CSS pour ce qui n'en a pas. */
  color: string;
  courseId: string | null;
}

export interface NextAction {
  title: string;
  subtitle: string;
  courseId: string | null;
  color: string;
  badge: string | null;
}

interface AxisValue { done: number; total: number }

export interface HomeData {
  tracked: Course[];
  term: AcademicTerm | null;
  summaries: WeekCourseSummary[];
  weekStart: Date;
  days: number[];
  weekTotal: number;
  theory: AxisValue;
  series: AxisValue;
  corrections: AxisValue;
  late: number;
  weeklyGoal: number;
  dailyGoal: number;
  todayTotal: number;
  todaySessions: StudySession[];
  todayItems: TodayItem[];
  deadlines: ReturnType<typeof Deadline.upcoming>;
  nextAction: NextAction | null;
}

const join = (parts: (string | null | undefined)[]): string =>
  parts.filter((part): part is string => part !== null && part !== undefined && part.trim() !== "").join(" · ");

function eventsToday(store: ModelStore, now: Date): LinkedCalendarEvent[] {
  return store.fetch(LinkedCalendarEvent)
    .filter((event) => event.isAcademic && !event.isSkipped && DateUtils.isSameDay(event.startsAt, now));
}

function plannedToday(store: ModelStore, now: Date): PlannedSession[] {
  return store.fetch(PlannedSession).filter((session) => DateUtils.isSameDay(session.startsAt, now));
}

/** Ce qui a une heure aujourd'hui : cours de l'horaire, sessions planifiées, évaluations. */
export function collectTodayItems(store: ModelStore, courses: Course[], now: Date): TodayItem[] {
  const items: TodayItem[] = [];
  for (const event of eventsToday(store, now)) {
    items.push({
      id: `event-${event.id}`,
      start: event.startsAt,
      end: event.endsAt,
      title: event.title,
      subtitle: join([event.course?.displayCode, event.location]),
      color: event.course?.colorHex ?? "var(--ink-tertiary)",
      courseId: event.course?.id ?? null,
    });
  }
  for (const session of plannedToday(store, now)) {
    items.push({
      id: `planned-${session.id}`,
      start: session.startsAt,
      end: session.endsAt,
      title: session.title,
      subtitle: join([
        session.course?.displayCode,
        session.location,
        session.isGroupSession ? session.groupName : null,
      ]),
      color: session.course?.colorHex ?? "var(--selection)",
      courseId: session.course?.id ?? null,
    });
  }
  for (const course of courses) {
    for (const exam of course.exams) {
      if (!DateUtils.isSameDay(exam.date, now)) continue;
      items.push({
        id: `exam-${exam.id}`,
        start: exam.date,
        end: null,
        title: exam.title,
        subtitle: join([course.displayCode, ExamKind.label(exam.kind), exam.location]),
        color: course.colorHex,
        courseId: course.id,
      });
    }
  }
  return items.sort((a, b) => a.start.getTime() - b.start.getTime());
}

/** Les sessions enregistrées aujourd'hui, la plus récente d'abord (`SessionRow`). */
export function sessionsToday(store: ModelStore, now: Date): StudySession[] {
  return store.fetch(StudySession)
    .filter((session) => DateUtils.isSameDay(session.startedAt, now))
    .sort((a, b) => b.startedAt.getTime() - a.startedAt.getTime());
}

/**
 * Le temps de la semaine, compté comme partout (`StudyTime` : sessions et cours
 * suivis), et l'avancement de chaque cours dans sa semaine.
 */
function weekData(store: ModelStore, tracked: Course[], now: Date, weekStart: Date) {
  const weekEnd = DateUtils.addDays(7, weekStart);
  const sessions = store.fetch(StudySession)
    .filter((session) => session.startedAt >= weekStart && session.startedAt < weekEnd);
  const events = store.fetch(LinkedCalendarEvent)
    .filter((event) => event.startsAt >= weekStart && event.startsAt < weekEnd);
  const days = StudyTime.days(StudyTime.blocks(events, sessions), weekStart);
  const summaries = tracked.map((course) => new WeekCourseSummary(course, now));
  const weeks = summaries.map((summary) => summary.week);
  return {
    days,
    summaries,
    theory: {
      done: weeks.reduce((sum, week) => sum + week.watchedCount, 0),
      total: weeks.reduce((sum, week) => sum + week.videoCount, 0),
    },
    series: {
      done: weeks.reduce((sum, week) => sum + week.doneCount, 0),
      total: weeks.reduce((sum, week) => sum + week.exerciseCount, 0),
    },
    corrections: {
      done: weeks.reduce((sum, week) => sum + week.correctedCount, 0),
      total: weeks.reduce((sum, week) => sum + week.doneCount, 0),
    },
    late: summaries.reduce((sum, summary) => sum + summary.late, 0),
  };
}

/** Le prochain geste : l'élément du jour en cours ou à venir, sinon l'échéance, sinon le cours en retard. */
export function chooseNextAction(
  items: TodayItem[],
  deadlines: ReturnType<typeof Deadline.upcoming>,
  summaries: WeekCourseSummary[],
  now: Date,
): NextAction | null {
  const nextItem = items.find((item) => (item.end ?? item.start).getTime() >= now.getTime());
  if (nextItem) {
    const ongoing = nextItem.start.getTime() <= now.getTime()
      && (nextItem.end === null || nextItem.end.getTime() >= now.getTime());
    return {
      title: nextItem.title,
      subtitle: nextItem.subtitle,
      courseId: nextItem.courseId,
      color: nextItem.color,
      badge: ongoing ? "En cours" : DateUtils.time(nextItem.start),
    };
  }

  const deadline = deadlines.find((item) => item.date.getTime() >= now.getTime());
  if (deadline) {
    return {
      title: deadline.title,
      subtitle: join([deadline.courseCode, DateUtils.countdownLabel(deadline.date)]),
      courseId: deadline.courseID,
      color: deadline.kind === "exam" ? "var(--wrong)" : deadline.colorHex,
      badge: DateUtils.countdownLabel(deadline.date),
    };
  }

  const late = summaries.find((summary) => summary.late > 0);
  const unfinished = summaries.find((summary) => summary.week.hasItems && !summary.week.isComplete);
  const summary = late ?? unfinished;
  if (!summary) return null;
  return {
    title: summary.course.name === "" ? summary.course.displayCode : summary.course.name,
    subtitle: summary.late > 0
      ? `${summary.late} en retard`
      : `${summary.week.doneCount}/${summary.week.exerciseCount} exercices cette semaine`,
    courseId: summary.course.id,
    color: summary.course.colorHex,
    badge: summary.late > 0 ? "À rattraper" : "À faire",
  };
}

/** Une seule passe de dérivation, réutilisée par toutes les sections du rendu. */
export function buildHomeData(store: ModelStore, courses: Course[], now: Date): HomeData {
  const tracked = courses.filter((course) => course.isTracked);
  const terms = new Map<string, AcademicTerm>();
  for (const course of tracked) {
    if (course.term) terms.set(course.term.id, course.term);
  }
  const term = AcademicTerm.resolve([...terms.values()], now);
  const weekStart = DateUtils.startOfWeek(now);
  const week = weekData(store, tracked, now, weekStart);
  const weeklyGoal = StudyGoal.weeklySeconds(0, tracked, HOURS_PER_CREDIT, now);
  const todayItems = collectTodayItems(store, courses, now);
  const deadlines = Deadline.upcoming(tracked, 14, DateUtils.startOfDay(now))
    .filter((item) => item.date.getTime() >= now.getTime())
    .slice(0, 6);

  return {
    tracked,
    term,
    summaries: week.summaries,
    weekStart,
    days: week.days,
    weekTotal: week.days.reduce((sum, value) => sum + value, 0),
    theory: week.theory,
    series: week.series,
    corrections: week.corrections,
    late: week.late,
    weeklyGoal,
    dailyGoal: StudyGoal.dailySeconds(weeklyGoal),
    todayTotal: StudyTime.today(store, now),
    todaySessions: sessionsToday(store, now),
    todayItems,
    deadlines,
    nextAction: chooseNextAction(todayItems, deadlines, week.summaries, now),
  };
}
