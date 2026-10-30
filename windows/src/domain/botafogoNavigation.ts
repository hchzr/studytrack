// Se déplacer dans un cours Botafogo comme sur le site
// (StudyTrack/Domain/BotafogoNavigation.swift).
//
// Le plan d'une page (« Sur cette page »), la section précédente et suivante, le
// chemin (« Polycopié › 5 Séries numériques › 5.1 Définitions »), ce qu'on a lu.
// Pur, testé.

import { MathMarkup } from "./mathMarkup.ts";
import type { BotafogoBlock } from "./botafogoPage.ts";
import type { Chapter, ChapterSection } from "./botafogoProgram.ts";

export type OutlineKind = "heading" | "statement" | "example" | "exercise" | "quiz" | "video";

export interface OutlineItem {
  /** La place du bloc dans la page (son ancre : `block-<index>`). */
  index: number;
  title: string;
  kind: OutlineKind;
}

export const OutlineItem = {
  make(index: number, title: string, kind: OutlineKind): OutlineItem { return { index, title, kind }; },
};

export const BotafogoNavigation = {
  // MARK: Le plan d'une page

  /** Les repères d'une page : titres, énoncés encadrés, exemples, exercices, quiz et vidéos. */
  outline(blocks: BotafogoBlock[]): OutlineItem[] {
    const result: OutlineItem[] = [];
    blocks.forEach((block, index) => {
      switch (block.type) {
        case "heading":
          result.push(OutlineItem.make(index, block.text, "heading"));
          break;
        case "theorem": {
          if (block.title === "") break;
          const example = block.kind === "example" || block.title.toLowerCase().startsWith("exemple");
          result.push(OutlineItem.make(index, block.title, example ? "example" : "statement"));
          break;
        }
        case "aside":
          if (block.title !== "") result.push(OutlineItem.make(index, block.title, "statement"));
          break;
        case "exercise":
          result.push(OutlineItem.make(index, block.label, "exercise"));
          break;
        case "quiz":
          result.push(OutlineItem.make(index, block.title === "" ? "Quiz" : block.title, "quiz"));
          break;
        case "video":
        case "kaltura":
          result.push(OutlineItem.make(index, block.title, "video"));
          break;
        default:
          break;
      }
    });
    return result;
  },

  /** Le repère où l'on est : le dernier dont le haut est passé sous la ligne de lecture. */
  current(outline: OutlineItem[], tops: Map<number, number>, threshold = 90): number | null {
    let current: number | null = null;
    for (const item of outline) {
      const top = tops.get(item.index);
      if (top === undefined) continue;
      if (top <= threshold) current = item.index;
      else break;
    }
    return current ?? outline[0]?.index ?? null;
  },

  // MARK: L'ordre de lecture

  /** Le polycopié dans l'ordre, section après section. */
  order(chapters: Chapter[]): ChapterSection[] {
    return chapters.flatMap((chapter) => chapter.sections);
  },

  neighbours(path: string, chapters: Chapter[]): { previous: ChapterSection | null; next: ChapterSection | null } {
    const all = BotafogoNavigation.order(chapters);
    const index = all.findIndex((section) => section.path === path);
    if (index < 0) return { previous: null, next: null };
    return {
      previous: index > 0 ? all[index - 1] : null,
      next: index + 1 < all.length ? all[index + 1] : null,
    };
  },

  /** La première section pas encore lue, à partir de `start` (ou du début). */
  nextUnread(sections: ChapterSection[], read: Set<string>): ChapterSection | null {
    return sections.find((section) => !read.has(section.path)) ?? null;
  },

  /** « 3/9 » lues dans un chapitre. */
  progress(chapter: Chapter, read: Set<string>): { read: number; total: number } {
    return {
      read: chapter.sections.filter((section) => read.has(section.path)).length,
      total: chapter.sections.length,
    };
  },

  // MARK: Ce qu'on a lu

  /** La clé où ranger les sections lues d'un site (une par site, pas par cours). */
  readKey(site: URL): string {
    return "botafogo.read." + (site.hostname ?? "") + site.pathname;
  },

  /** Le titre d'un chapitre ou d'une semaine sans son TeX. */
  plainTitle(title: string): string {
    return MathMarkup.plain(title);
  },
};
