// Range le MOOC d'un cours dans les semaines de son Moodle
// (StudyTrack/Domain/MoocMerger.swift).
//
// Chaque leçon du MOOC reçoit la semaine où Moodle la cite : un lien Moodle qui
// pointe dans la leçon, « Semaine 3 » dans le titre du chapitre, le numéro du
// chapitre, ou le plan du cours.

import {
  ContentDraft, ContentDraftBuilder, ContentDraftItem, ContentDraftSection,
  type ScrapedCourse, type ScrapedItem,
} from "./courseContentImport.ts";
import { MoodleCourseAnalyzer, type ContentLink, type MoocReference, type MoodleCourseSnapshot } from "./moodleCourseAnalyzer.ts";
import { icuRegExp } from "./icuRegExp.ts";

export const MoocMerger = {
  merge(o: {
    mooc: ScrapedCourse;
    references: MoocReference[];
    snapshot: MoodleCourseSnapshot;
    into: ContentDraft;
    termStart: Date | null;
    totalWeeks?: number;
    plannedWeeks?: Record<string, number>;
    plannedLessons?: Record<string, number>;
    ordinal?: number;
  }): ContentDraft {
    const totalWeeks = o.totalWeeks ?? 14;
    const plannedWeeks = o.plannedWeeks ?? {};
    const plannedLessons = o.plannedLessons ?? {};
    const ordinal = o.ordinal ?? 1;
    const result = o.into.clone();
    const sectionWeeks = new Map<number, number>();
    for (const section of o.snapshot.sections) {
      const week = MoodleCourseAnalyzer.week(section, o.termStart, totalWeeks);
      if (week !== null && !sectionWeeks.has(section.number)) sectionWeeks.set(section.number, week);
    }

    // La semaine de chaque bloc cité depuis Moodle.
    const blockWeeks = new Map<string, number>();
    for (const reference of o.references) {
      const block = reference.blockID;
      if (block === null || reference.sectionNumber === null) continue;
      const week = sectionWeeks.get(reference.sectionNumber);
      if (week === undefined) continue;
      blockWeeks.set(block, Math.min(blockWeeks.get(block) ?? week, week));
    }

    // Les chapitres que le **plan du cours** demande de regarder.
    for (const [block, week] of Object.entries(plannedWeeks)) {
      blockWeeks.set(block, Math.min(blockWeeks.get(block) ?? week, week));
    }

    // La semaine où Moodle traite chaque chapitre (« 4 · Espaces vectoriels »).
    const chapterWeeks = new Map<number, number>();
    for (const section of o.into.sections) {
      if (section.week <= 0) continue;
      for (const item of section.items) {
        if (item.kind !== "theory") continue;
        const first = item.number.split(".")[0];
        const chapter = Number(first);
        if (!Number.isInteger(chapter)) continue;
        const week = item.week ?? section.week;
        chapterWeeks.set(chapter, Math.min(chapterWeeks.get(chapter) ?? week, week));
      }
    }

    o.mooc.sections.forEach((chapter, chapterIndex) => {
      const title = ContentDraftBuilder.cleanTitle(chapter.title);
      if (title === "" || chapter.items.length === 0) return;
      const chapterCited = chapter.id !== undefined ? blockWeeks.get(chapter.id) : undefined;
      const leading = ContentDraftBuilder.leadingNumber(title);
      const chapterWeek = chapterCited
        ?? MoocMerger.weekInTitle(title)
        ?? (leading !== null && Number.isInteger(Number(leading.number)) ? chapterWeeks.get(Number(leading.number)) : undefined);
      const byWeek = new Map<number, ContentLink[]>();
      const firstURL = new Map<number, string>();
      const videoCounts = new Map<number, number>();
      // **Leçon par leçon**, quand le plan le dit : seules les leçons demandées.
      const lessonPlan = (lesson: ScrapedItem): number | null => {
        const refs = [lesson.id, lesson.url, ...(lesson.blockIDs ?? [])].filter((x): x is string => x !== undefined);
        const weeks = refs.map((ref) => plannedLessons[ref]).filter((w): w is number => w !== undefined);
        return weeks.length === 0 ? null : Math.min(...weeks);
      };
      const byLesson = chapter.items.some((lesson) => lessonPlan(lesson) !== null);
      for (const lesson of chapter.items) {
        // Les exercices du MOOC ne sont pas à faire, sauf ses quiz en ligne.
        if (lesson.url === "") continue;
        if (MoocMerger.isExercise(lesson) && !MoocMerger.isQuiz(lesson) && lessonPlan(lesson) === null) continue;
        const ids = [lesson.id, ...(lesson.blockIDs ?? [])].filter((x): x is string => x !== undefined);
        const planned = byLesson ? lessonPlan(lesson)
          : (ids.map((id) => blockWeeks.get(id)).filter((w): w is number => w !== undefined).sort((a, b) => a - b)[0] ?? chapterWeek ?? null);
        if (planned === null || planned <= 0) continue;
        const week = Math.min(planned, Math.max(totalWeeks, 1));
        const lessonTitle = ContentDraftBuilder.cleanTitle(lesson.title);
        const videoLinks = (lesson.links ?? []).filter((link) => link.kind === "video");
        if (!firstURL.has(week)) firstURL.set(week, lesson.url);
        if (videoLinks.length === 0) {
          const isVideo = (lesson.videoCount ?? 0) > 0;
          const links = byWeek.get(week) ?? [];
          links.push({
            title: lessonTitle === "" ? title : lessonTitle,
            url: lesson.url, kind: isVideo ? "video" : "page",
          });
          byWeek.set(week, links);
          videoCounts.set(week, (videoCounts.get(week) ?? 0) + (lesson.videoCount ?? 0));
        } else {
          const links = byWeek.get(week) ?? [];
          for (const link of videoLinks) {
            const name = ContentDraftBuilder.cleanTitle(link.title);
            links.push({
              title: name === "" || name === lessonTitle ? lessonTitle : `${lessonTitle} — ${name}`,
              url: link.url, kind: "video",
            });
          }
          byWeek.set(week, links);
          videoCounts.set(week, (videoCounts.get(week) ?? 0) + videoLinks.length);
        }
      }
      const split = byWeek.size > 1;
      for (const week of [...byWeek.keys()].sort((a, b) => a - b)) {
        const links = byWeek.get(week) ?? [];
        const url = firstURL.get(week);
        if (links.length === 0 || url === undefined) continue;
        // Un chapitre réparti sur plusieurs semaines : un élément par semaine.
        const item = new ContentDraftItem({
          kind: "theory",
          number: `M${ordinal}-${chapterIndex + 1}` + (split ? `-s${week}` : ""),
          title: `MOOC · ${title}`,
          url,
          videoCount: videoCounts.get(week) ?? 0,
          seriesNumber: null,
          theoryKind: (videoCounts.get(week) ?? 0) > 0 ? "video" : "reading",
          week,
        });
        item.links = links;
        const index = result.sections.findIndex((section) => section.week === week && !section.title.startsWith("Échéances"));
        if (index >= 0) {
          if (!result.sections[index].items.some((existing) => existing.url === url)) {
            result.sections[index].items.push(item);
          }
        } else {
          result.sections.push(new ContentDraftSection({
            title: `Semaine ${week} · MOOC`, week, weekIsInferred: false, isIncluded: true, items: [item],
          }));
        }
      }
    });
    result.sections.sort((lhs, rhs) => {
      if (lhs.week === 0 || rhs.week === 0) return lhs.week !== 0 && rhs.week === 0 ? -1 : 0;
      return lhs.week - rhs.week;
    });
    // Le MOOC lui-même reste à portée, pour le reste (facultatif).
    if (o.mooc.url !== "") {
      const item = new ContentDraftItem({
        kind: "resource", number: "", title: `MOOC · ${o.mooc.title}`, url: o.mooc.url,
        videoCount: 0, seriesNumber: null, theoryKind: "reading",
      });
      item.links = [{ title: o.mooc.title, url: o.mooc.url, kind: "page" }];
      item.group = "Cours en ligne";
      const index = result.sections.findIndex((section) => section.title.startsWith("Documents"));
      if (index >= 0) {
        if (!result.sections[index].items.some((existing) => existing.url === o.mooc.url)) {
          result.sections[index].items.push(item);
        }
      } else {
        result.sections.push(new ContentDraftSection({
          title: "Documents du cours (non suivis)", week: 0, weekIsInferred: false, isIncluded: true, items: [item],
        }));
      }
    }
    return result;
  },

  /** Une leçon d'exercices, de quiz ou d'évaluation du MOOC : pas à faire ici. */
  isExercise(lesson: ScrapedItem): boolean {
    if ((lesson.videoCount ?? 0) !== 0 || (lesson.links ?? []).some((link) => link.kind === "video")) return false;
    const folded = ContentDraftBuilder.fold(lesson.title);
    return icuRegExp(String.raw`\b(exercices?|exercises?|quiz+|quizzes|problemes?|problems?|series?|evaluation|assessment|test|devoir|homework|graded)\b`).test(folded);
  },

  /** Un quiz en ligne du MOOC : « Exercices online (6 Questions) ». */
  isQuiz(lesson: ScrapedItem): boolean {
    return icuRegExp(String.raw`\(\d+ questions?\)|\bquiz`).test(ContentDraftBuilder.fold(lesson.title));
  },

  /** « Semaine 3 — Les boucles » / « Week 3 » → 3. */
  weekInTitle(title: string): number | null {
    const folded = ContentDraftBuilder.fold(title);
    const range = icuRegExp(String.raw`\b(semaine|week|sem\.?)\s*0*(\d{1,2})\b`).exec(folded);
    if (range === null) return null;
    const digits = range[0].split("").filter((c) => /\p{N}/u.test(c)).join("");
    const value = Number(digits);
    return Number.isInteger(value) ? value : null;
  },
};
