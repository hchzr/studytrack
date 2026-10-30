// Le plan d'un cours, lu **sans modèle** quand sa forme le permet
// (StudyTrack/Domain/CoursePlanParser.swift).
//
// Les plans de l'EPFL sont souvent des tableaux : une ligne par semaine, puis ce
// qu'il y a à faire. Ici, la semaine courante est suivie ligne par ligne.

import type { ScrapedCourse } from "./courseContentImport.ts";
import { MoodleCourseAI } from "./moodleAIHint.ts";
import { icuRegExp } from "./icuRegExp.ts";

export interface MoocAssignment {
  mooc: number;
  module: number;
  week: number;
}

export const MoocAssignment = {
  make(mooc: number, module: number, week: number): MoocAssignment { return { mooc, module, week }; },
  equals(a: MoocAssignment, b: MoocAssignment): boolean {
    return a.mooc === b.mooc && a.module === b.module && a.week === b.week;
  },
};

export const CoursePlanParser = {
  /** Une demande du plan : regarder les vidéos du module `module` du MOOC `mooc` en semaine `week`. */
  moocAssignments(inPlan: string, totalWeeks: number): MoocAssignment[] {
    const result: MoocAssignment[] = [];
    let week: number | null = null;
    const header = icuRegExp(String.raw`^(?:semaine|week|sem\.?)?\s*(\d{1,2})(?:\s+\d{1,2}[./]\d{1,2}[./]\d{2,4}.*)?$`, "i");
    const video = icuRegExp(String.raw`mooc\s*(\d)?\s*:\s*(?:les\s+)?vid[ée]os?\s+(?:du\s+)?modules?\s+(\d{1,2})((?:\s*(?:,|et|&|à|-)\s*\d{1,2})*)`, "i");
    for (const raw of inPlan.split("\n")) {
      const line = raw.trim();
      if (line === "") continue;
      // Une ligne qui ouvre une semaine : « 3 », « 3 23/09/2026 25/09/2026 », « Semaine 3 ».
      const headerMatch = header.exec(line);
      if (headerMatch !== null) {
        const value = Number(headerMatch[1]);
        if (Number.isInteger(value) && value >= 1 && value <= totalWeeks) {
          week = value;
          continue;
        }
      }
      if (week === null) continue;
      for (const match of line.matchAll(new RegExp(video.source, "giu"))) {
        const mooc = match[1] !== undefined ? Number(match[1]) : 1;
        const first = Number(match[2]);
        if (!Number.isInteger(first)) continue;
        const modules = [first];
        if (match[3] !== undefined) {
          for (const part of match[3].split(/[^\d]+/u)) {
            const value = Number(part);
            if (part !== "" && Number.isInteger(value)) modules.push(value);
          }
        }
        for (const module of modules) {
          if (!result.some((assignment) => assignment.mooc === mooc && assignment.module === module)) {
            result.push(MoocAssignment.make(mooc, module, week));
          }
        }
      }
    }
    return result;
  },

  /** Les semaines des chapitres, par identifiant. */
  chapterWeeks(assignments: MoocAssignment[], moocs: ScrapedCourse[]): Record<string, number> {
    const result: Record<string, number> = {};
    for (const assignment of assignments) {
      const mooc = moocs[assignment.mooc - 1];
      if (mooc === undefined) continue;
      const modules = mooc.sections.filter((section) => section.id !== undefined && !MoodleCourseAI.isFrontMatter(section));
      const chapter = modules[assignment.module - 1];
      if (chapter === undefined || chapter.id === undefined) continue;
      result[chapter.id] = Math.min(result[chapter.id] ?? assignment.week, assignment.week);
    }
    return result;
  },
};
