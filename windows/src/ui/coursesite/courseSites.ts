// Les sites d'un cours, d'après ses sources (`contentSources`, le lien Moodle) : ce que le
// volet « Le cours » sait lire dans l'app (CoursePane.Source du Mac).

import type { Course } from "../../models/course.ts";
import { isBotafogo } from "../../services/botafogoBook.ts";

/** Le site Botafogo du cours, s'il en a un. */
export function botafogoSite(course: Course | null): string | null {
  if (!course) return null;
  return course.contentSources.find((address) => isBotafogo(address)) ?? null;
}

/** Le cours a-t-il un site que l'app lit ? */
export function hasCourseSite(course: Course | null): boolean {
  return botafogoSite(course) !== null;
}
