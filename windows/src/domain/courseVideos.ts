// Les vidéos d'un cours (Explique, listes de lecture MediaSpace), rangées dans
// ses semaines (Polymestre/Domain/CourseVideos.swift) : chaque semaine a un
// élément de théorie, et ses vidéos en sont les liens.

import { DateUtils } from "./dateUtils.ts";
import type { ContentLinkKind } from "./moodleCourseAnalyzer.ts";
import {
  ContentDraft, ContentDraftItem, ContentDraftSection,
} from "./courseContentImport.ts";
import { icuRegExp } from "./icuRegExp.ts";

export interface CourseVideo {
  title: string;
  url: string;
  /** La semaine, quand la source la donne ; sinon déduite du titre. */
  week: number | null;
  /** Une leçon de MOOC sans vidéo est une page à lire. */
  kind: ContentLinkKind;
  /** L'ordre de la source, gardé quand rien d'autre ne départage. */
  order: number;
}

export const CourseVideo = {
  make(title: string, url: string, o: Partial<Omit<CourseVideo, "title" | "url">> = {}): CourseVideo {
    return { title, url, week: o.week ?? null, kind: o.kind ?? "video", order: o.order ?? 0 };
  },
};

export const CourseVideos = {
  /** La semaine d'une vidéo d'après son titre, quand la source ne la donne pas. */
  week(of: string, termStart: Date | null, totalWeeks: number, lecturesPerWeek: number): number | null {
    const folded = of.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
    const explicit = number(folded, String.raw`\b(?:semaine|week|sem\.?|s)\s*0*(\d{1,2})\b`);
    if (explicit !== null && explicit >= 1 && explicit <= totalWeeks) return explicit;
    const lecture = number(folded, String.raw`\b(?:lecture|cours|lesson|lecon)\s*0*(\d{1,2})[a-z]?\b`);
    if (lecture !== null && lecture > 0) {
      const week = Math.ceil(lecture / Math.max(lecturesPerWeek, 1));
      if (week >= 1 && week <= totalWeeks) return week;
    }
    if (termStart !== null) {
      const date = parseDate(folded);
      if (date !== null) {
        // Même jour de l'année du semestre : l'enregistrement de l'an passé tombe la même semaine.
        const years = termStart.getFullYear() - date.getFullYear();
        const shifted = new Date(date.getTime());
        shifted.setFullYear(shifted.getFullYear() + years);
        const startOfDay = new Date(termStart.getFullYear(), termStart.getMonth(), termStart.getDate());
        const days = DateUtils.daysBetween(startOfDay, shifted);
        const week = Math.trunc(days / 7) + 1;
        if (days >= 0 && week >= 1 && week <= totalWeeks) return week;
      }
    }
    return null;
  },

  /** Deux cours par semaine quand les numéros dépassent le nombre de semaines. */
  lecturesPerWeek(titles: string[], totalWeeks: number): number {
    const numbers = titles.map((title) => number(title.toLowerCase(), String.raw`\b(?:lecture|cours)\s*0*(\d{1,2})\b`))
      .filter((n): n is number => n !== null);
    if (numbers.length === 0) return 1;
    const maximum = Math.max(...numbers);
    return maximum > totalWeeks ? Math.ceil(maximum / totalWeeks) : 1;
  },

  /** Ajoute les vidéos au brouillon : à l'élément de théorie de leur semaine, ou dans « Vidéos du cours ». */
  merge(videos: CourseVideo[], into: ContentDraft, totalWeeks: number,
        sourceLabel: string, preferredYear: string | null = null): { draft: ContentDraft; added: number } {
    const result = into.clone();
    const known = new Set(result.sections.flatMap((section) =>
      section.items.flatMap((item) => [item.url, ...item.links.map((link) => link.url)])).filter((url) => url !== ""));
    let added = 0;
    const byWeek = new Map<number, CourseVideo[]>();
    for (const video of videos) {
      if (video.week === null) continue;
      const week = Math.min(video.week, Math.max(totalWeeks, 1));
      const list = byWeek.get(week) ?? [];
      list.push(video);
      byWeek.set(week, list);
    }
    for (const week of [...byWeek.keys()].sort((a, b) => a - b)) {
      if (week <= 0) continue;
      const ordered = byWeek.get(week)!
        .sort((lhs, rhs) => {
          const ln = CourseVideos.lectureNumber(lhs.title) ?? Number.POSITIVE_INFINITY;
          const rn = CourseVideos.lectureNumber(rhs.title) ?? Number.POSITIVE_INFINITY;
          if (ln !== rn) return ln - rn;
          if (preferredYear !== null) {
            const l = lhs.title.includes(preferredYear);
            const r = rhs.title.includes(preferredYear);
            if (l !== r) return l ? -1 : 1;
          }
          return lhs.order - rhs.order;
        })
        .filter((video) => {
          if (known.has(video.url)) return false;
          known.add(video.url);
          return true;
        });
      if (ordered.length === 0) continue;
      const links = ordered.map((video) => ({ title: video.title, url: video.url, kind: video.kind }));
      const position = CourseVideos.weekItem(week, result);
      if (position !== null) {
        const item = result.sections[position.section].items[position.item];
        if (item.links.length === 0 && item.url !== "") {
          item.links = [{ title: item.title, url: item.url, kind: "page" }];
        }
        item.links.push(...links);
        item.videoCount = item.links.filter((link) => link.kind === "video").length;
        if (item.videoCount > 0) item.theoryKind = "video";
      } else {
        const topics: string[] = [];
        for (const video of ordered) {
          const topic = CourseVideos.cleanTopic(video.title);
          if (topic !== "" && !topics.includes(topic)) topics.push(topic);
        }
        const item = new ContentDraftItem({
          kind: "theory", number: `${week}`,
          title: topics.length === 0 ? `Cours de la semaine ${week}` : topics.slice(0, 3).join(" · "),
          url: ordered[0].url, videoCount: links.filter((link) => link.kind === "video").length,
          seriesNumber: null,
          theoryKind: links.some((link) => link.kind === "video") ? "video" : "reading",
        });
        item.links = links;
        CourseVideos.append(item, week, sourceLabel, result);
      }
      added += ordered.length;
    }
    // Sans semaine : gardées, dans les documents du cours.
    const loose: CourseVideo[] = [];
    for (const video of videos) {
      if (video.week !== null || known.has(video.url)) continue;
      known.add(video.url);
      loose.push(video);
    }
    if (loose.length > 0) {
      const items = loose.map((video) => {
        const item = new ContentDraftItem({
          kind: "resource", number: "", title: video.title, url: video.url,
          videoCount: 1, seriesNumber: null, theoryKind: "video",
        });
        item.links = [{ title: video.title, url: video.url, kind: video.kind }];
        item.group = `Vidéos du cours (${sourceLabel})`;
        return item;
      });
      const index = result.sections.findIndex((section) => section.title.startsWith("Documents"));
      if (index >= 0) result.sections[index].items.push(...items);
      else {
        result.sections.push(new ContentDraftSection({
          title: "Documents du cours (non suivis)", week: 0, weekIsInferred: false, isIncluded: true, items,
        }));
      }
      added += loose.length;
    }
    return { draft: result, added };
  },

  // MARK: Utilitaires

  lectureNumber(title: string): number | null {
    return number(title.toLowerCase(), String.raw`\blecture\s*(\d+)`);
  },

  /** « Lecture 5: Proofs (2026) » → « Proofs ». */
  cleanTopic(title: string): string {
    return title
      .replace(/\s*\((?:\d{4}|view on speaker|speaker view)\)/gi, "")
      .replace(/^lecture\s*\d+[a-z]?\s*[:–-]\s*/gi, "")
      .replace(/\s*-\s*\d+$/, "")
      .trim();
  },

  weekItem(week: number, draft: ContentDraft): { section: number; item: number } | null {
    for (let s = 0; s < draft.sections.length; s += 1) {
      for (let i = 0; i < draft.sections[s].items.length; i += 1) {
        const item = draft.sections[s].items[i];
        if (item.kind === "theory" && item.plannedWeek(draft.sections[s]) === week) return { section: s, item: i };
      }
    }
    return null;
  },

  append(item: ContentDraftItem, week: number, label: string, draft: ContentDraft): void {
    const index = draft.sections.findIndex((section) => section.week === week && !section.title.startsWith("Échéances"));
    if (index >= 0) draft.sections[index].items.push(item);
    else {
      draft.sections.push(new ContentDraftSection({
        title: `Semaine ${week} · ${label}`, week, weekIsInferred: false, isIncluded: true, items: [item],
      }));
      draft.sections.sort((lhs, rhs) => {
        if (lhs.week === 0 || rhs.week === 0) return lhs.week !== 0 && rhs.week === 0 ? -1 : 0;
        return lhs.week - rhs.week;
      });
    }
  },
};

function number(text: string, pattern: string): number | null {
  const match = icuRegExp(pattern, "i").exec(text);
  if (match === null || match[1] === undefined) return null;
  const value = Number(match[1]);
  return Number.isInteger(value) ? value : null;
}

function parseDate(text: string): Date | null {
  const match = icuRegExp(String.raw`\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b`).exec(text);
  if (match === null) return null;
  const day = Number(match[1]);
  const month = Number(match[2]);
  const year = Number(match[3]);
  if (!(month >= 1 && month <= 12) || !(day >= 1 && day <= 31)) return null;
  return new Date(year, month - 1, day, 12);
}
