// Les sites d'un cours, d'après ses sources (`contentSources`, le lien Moodle) : ce que le
// volet « Le cours » sait lire dans l'app (CoursePane.Source du Mac).

import type { Course } from "../../models/course.ts";
import { MoodleCourseMatcher } from "../../domain/moodleImport.ts";
import { isBotafogo } from "../../services/botafogoBook.ts";
import { Institution } from "../../domain/institution.ts";
import { MoocReference } from "../../domain/moodleCourseAnalyzer.ts";

export type CourseSource = "botafogo" | "moodle" | "courseware" | "ed";

/** Le site Botafogo du cours, s'il en a un. */
export function botafogoSite(course: Course | null): string | null {
  if (!course) return null;
  return course.contentSources.find((address) => isBotafogo(address)) ?? null;
}

/** L'identifiant du cours Moodle lié (son lien, ou une source Moodle). */
export function moodleCourseID(course: Course | null): number | null {
  if (!course) return null;
  return MoodleCourseMatcher.linkedID([course.moodleURLString, ...course.contentSources].filter(Boolean));
}

/** Le cours Courseware (« course-v1:EPFL+… ») cité par les sources du cours. */
export function coursewareKey(course: Course | null): string | null {
  if (!course) return null;
  for (const address of course.contentSources) {
    const key = MoocReference.courseKey(address);
    if (key) return key;
  }
  return null;
}

/** Les sources que l'app sait lire pour ce cours, dans l'ordre du Mac. */
export function courseSources(course: Course | null): CourseSource[] {
  const out: CourseSource[] = [];
  if (botafogoSite(course)) out.push("botafogo");
  if (moodleCourseID(course) !== null) out.push("moodle");
  if (coursewareKey(course) !== null) out.push("courseware");
  // Ed : retrouvé par le code du cours une fois connecté·e (l'école doit avoir Ed).
  if (course && course.code.trim() !== "" && Institution.current.ed) out.push("ed");
  return out;
}

/** Le cours a-t-il un site que l'app lit ? */
export function hasCourseSite(course: Course | null): boolean {
  return courseSources(course).length > 0;
}
