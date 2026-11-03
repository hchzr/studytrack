// Les sites d'un cours, d'après ses sources (`contentSources`, le lien Moodle) : ce que le
// volet « Le cours » sait lire dans l'app (CoursePane.Source du Mac).

import type { Course } from "../../models/course.ts";
import { MoodleCourseMatcher } from "../../domain/moodleImport.ts";
import { isBotafogo } from "../../services/botafogoBook.ts";
import { Institution } from "../../domain/institution.ts";
import { MoocReference } from "../../domain/moodleCourseAnalyzer.ts";
import { EdDiscussion } from "../../domain/siteContent.ts";
import { knownEdCourses } from "../../services/edClient.ts";

export type CourseSource = "botafogo" | "moodle" | "videos" | "courseware" | "ed";

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

function mentionsVideos(course: Course): boolean {
  const all = [...course.contentSources, ...course.theoryItems.flatMap((item) => [item.urlString, ...item.links.map((link) => link.url)])];
  return all.some((url) => /mediaspace|kaltura/i.test(url));
}

/** Les sources que l'app sait lire pour ce cours, dans l'ordre du Mac. */
export function courseSources(course: Course | null): CourseSource[] {
  const out: CourseSource[] = [];
  if (botafogoSite(course)) out.push("botafogo");
  if (moodleCourseID(course) !== null) out.push("moodle");
  // Les cours filmés : dès qu'il y a de quoi les chercher (Moodle, ou un lien MediaSpace).
  if (course && Institution.current.video && (moodleCourseID(course) !== null || mentionsVideos(course))) out.push("videos");
  if (coursewareKey(course) !== null) out.push("courseware");
  // Ed : retrouvé par le code du cours une fois connecté·e (l'école doit avoir Ed).
  // Une fois connecté·e, seulement si le cours a vraiment son espace sur Ed.
  if (course && course.code.trim() !== "" && Institution.current.ed) {
    const known = knownEdCourses();
    if (known === null || EdDiscussion.match(course.code, known) !== null) out.push("ed");
  }
  return out;
}

/** Le cours a-t-il un site que l'app lit ? */
export function hasCourseSite(course: Course | null): boolean {
  return courseSources(course).length > 0;
}
