// Explique (explique.epfl.ch) : l'outil d'AICC (CS-101) où vivent les cours en
// replay, semaine par semaine, et les « exercices d'explication » à rendre
// (StudyTrack/Domain/ExpliqueImport.swift).

import { Institution } from "./institution.ts";
import { CourseVideos, type CourseVideo } from "./courseVideos.ts";
import {
  ContentDraft, ContentDraftItem, ContentDraftSection,
} from "./courseContentImport.ts";
import { icuRegExp } from "./icuRegExp.ts";

export interface ExpliqueLecture {
  week: number;
  title: string;
  url: string;
}

export interface ExpliqueExercise {
  week: number;
  title: string;
  url: string;
  due: string;
  done: boolean;
}

export const ExpliqueImport = {
  get host(): string {
    return Institution.current.extras["explique"]
      ? (safeURL(Institution.current.extras["explique"])?.hostname ?? "explique.epfl.ch")
      : "explique.epfl.ch";
  },

  /** `slug(in:)` : `https://explique.epfl.ch/cs101/exercises` → `cs101` ; `slug(courseCode:)` : CS-101 → `cs101`. */
  slug(value: string | string[]): string | null {
    if (typeof value === "string") {
      return value.toLowerCase().split("").filter((c) => /\p{L}|\p{N}/u.test(c)).join("");
    }
    for (const link of value) {
      const url = safeURL(link);
      if (url === null || url.hostname !== ExpliqueImport.host) continue;
      const first = url.pathname.split("/").filter((p) => p !== "")[0];
      if (first === undefined || ["login", "api", "_next"].includes(first)) continue;
      return first;
    }
    return null;
  },

  // MARK: Échéances

  /** « Tuesday 29 September at 17:00 » → la date, à l'année du semestre. */
  dueDate(text: string, termStart: Date | null): Date | null {
    const lower = text.toLowerCase();
    const match = icuRegExp(String.raw`(\d{1,2})\s+([a-zéû]+)(?:\s+(\d{4}))?(?:\s+(?:at|à)\s+(\d{1,2})[:h](\d{2}))?`).exec(lower);
    if (match === null) return null;
    const months = new Map<string, number>(Object.entries({
      january: 1, february: 2, march: 3, april: 4, may: 5, june: 6, july: 7, august: 8,
      september: 9, october: 10, november: 11, december: 12,
      janvier: 1, "février": 2, mars: 3, avril: 4, mai: 5, juin: 6, juillet: 7, "août": 8,
      septembre: 9, octobre: 10, novembre: 11, "décembre": 12,
    }));
    const day = Number(match[1]);
    const month = months.get(match[2]);
    if (!Number.isInteger(day) || month === undefined) return null;
    const base = termStart ?? new Date();
    let year = match[3] !== undefined ? Number(match[3]) : base.getFullYear();
    if (match[3] === undefined && termStart !== null && month < termStart.getMonth() + 1 - 2) year += 1;
    return new Date(year, month - 1, day,
      match[4] !== undefined ? Number(match[4]) : 23,
      match[5] !== undefined ? Number(match[5]) : 59);
  },

  // MARK: Rangement

  /** « Lecture 5: Proofs (2026) » → 5 ; `null` pour « Proofs - 1 ». */
  lectureNumber(title: string): number | null {
    const match = icuRegExp(String.raw`\blecture\s*(\d+)`, "i").exec(title);
    return match === null ? null : Number(match[1]);
  },

  /** Ajoute les cours (en replay) et les exercices d'Explique au brouillon Moodle, dans leurs semaines. */
  merge(lectures: ExpliqueLecture[], exercises: ExpliqueExercise[], into: ContentDraft,
        termStart: Date | null, totalWeeks = 14): { draft: ContentDraft; added: number } {
    let result = into.clone();
    let added = 0;
    const currentYear = String((termStart ?? new Date()).getFullYear());

    const videos = CourseVideos.merge(lectures.map((lecture, index): CourseVideo => ({
      title: lecture.title, url: lecture.url,
      week: lecture.week > 0 ? lecture.week : null,
      kind: "video", order: index,
    })), result, totalWeeks, "Explique", currentYear);
    result = videos.draft;
    added += videos.added;

    const known = new Set(result.sections.flatMap((section) => section.items.map((item) => item.url)));
    for (const exercise of exercises) {
      if (known.has(exercise.url)) continue;
      const title = exercise.title
        .replace(/\s*explanation exercise$/gi, "")
        .trim();
      const item = new ContentDraftItem({
        kind: "deadline", number: "", title: `Explique · ${title}`,
        url: exercise.url, videoCount: 0, seriesNumber: null, theoryKind: "reading",
      });
      item.date = ExpliqueImport.dueDate(exercise.due, termStart);
      item.examKind = "assignment";
      ExpliqueImport.appendDeadline(item, result);
      added += 1;
    }
    return { draft: result, added };
  },

  deadlinesTitle: "Échéances : rendus, projet, examen",

  appendDeadline(item: ContentDraftItem, draft: ContentDraft): void {
    const index = draft.sections.findIndex((section) => section.title === ExpliqueImport.deadlinesTitle);
    if (index >= 0) {
      draft.sections[index].items.push(item);
      draft.sections[index].items.sort((a, b) =>
        (a.date?.getTime() ?? Number.POSITIVE_INFINITY) - (b.date?.getTime() ?? Number.POSITIVE_INFINITY));
    } else {
      draft.sections.push(new ContentDraftSection({
        title: ExpliqueImport.deadlinesTitle, week: 0, weekIsInferred: false, isIncluded: true, items: [item],
      }));
    }
  },
};

function safeURL(text: string): URL | null {
  try {
    return new URL(text);
  } catch {
    return null;
  }
}
