// Les parties pures de la palette Ctrl+K (CommandPalette.swift / PaletteList.swift) :
// résolution d'un résultat de recherche vers un cours et un élément, correspondance
// des actions, déplacement de la sélection, regroupement par section.

import type { SearchHit, SearchKind } from "../../domain/searchEngine.ts";
import { localizedStandardCompare } from "../../models/util.ts";
import type { IconName } from "../icons.tsx";

/** Une ligne de la palette (PaletteItem). `run` ouvre, `time` chronomètre (Ctrl+↩). */
export interface PaletteItem {
  id: string;
  title: string;
  subtitle: string;
  icon: IconName;
  /** Couleur de l'icône ; absente = encre secondaire. */
  tint?: string;
  section: string;
  shortcut?: string;
  run: () => void;
  time?: () => void;
}

/** Les types que la palette cherche (ni sessions, ni tâches, ni groupes). */
export const PALETTE_KINDS: readonly SearchKind[] = ["course", "series", "exercise", "theory", "exam"];

/** Les icônes SF du moteur de recherche n'existent pas toutes dans le kit : leur équivalent. */
const KIND_ICON: Record<SearchKind, IconName> = {
  course: "books.vertical",
  series: "list.bullet",
  exercise: "checkmark.square",
  theory: "play.fill",
  exam: "graduationcap",
  session: "timer",
  task: "checkmark.circle",
  milestone: "graduationcap",
  group: "person.2",
};

export function iconForKind(kind: SearchKind): IconName {
  return KIND_ICON[kind];
}

/** Sans accents ni casse (`caseInsensitive, diacriticInsensitive`). */
export function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}

export function matches(text: string, needle: string): boolean {
  return fold(text).includes(fold(needle));
}

/** Le strict nécessaire d'un cours pour résoudre un résultat. */
export interface ResolvableCourse {
  id: string;
  series: { id: string; sortedExercises: { id: string }[] }[];
  allExercises: { id: string }[];
  theoryItems: { id: string }[];
  exams: { id: string }[];
}

export interface PaletteTarget {
  course: string;
  item: string | null;
  /** Ce que Ctrl+↩ chronomètre quand `item` est défini. */
  type: "theory" | "exercise";
}

/** `exercise.<uuid>` → le cours et l'élément (CommandPalette.resolve). */
export function resolveHit(courses: ResolvableCourse[], hit: Pick<SearchHit, "kind" | "document">): PaletteTarget | null {
  const dot = hit.document.id.indexOf(".");
  if (dot < 0) return null;
  const id = hit.document.id.slice(dot + 1);
  if (id === "") return null;
  switch (hit.kind) {
    case "course":
      return { course: id, item: null, type: "exercise" };
    case "series": {
      const course = courses.find((c) => c.series.some((s) => s.id === id));
      if (!course) return null;
      const first = course.series.find((s) => s.id === id)?.sortedExercises[0]?.id ?? null;
      return { course: course.id, item: first, type: "exercise" };
    }
    case "exercise": {
      const course = courses.find((c) => c.allExercises.some((e) => e.id === id));
      return course ? { course: course.id, item: id, type: "exercise" } : null;
    }
    case "theory": {
      const course = courses.find((c) => c.theoryItems.some((t) => t.id === id));
      return course ? { course: course.id, item: id, type: "theory" } : null;
    }
    case "exam": {
      const course = courses.find((c) => c.exams.some((e) => e.id === id));
      return course ? { course: course.id, item: null, type: "exercise" } : null;
    }
    default:
      return null;
  }
}

/** Sélection circulaire (↑↓). */
export function moveSelection(selected: number, delta: number, count: number): number {
  if (count === 0) return 0;
  return (((selected + delta) % count) + count) % count;
}

/** Les résultats trouvés se rangent par section, comme le Mac (`sorted { $0.section < $1.section }`), à ordre stable. */
export function sortBySection<T extends { section: string }>(items: T[]): T[] {
  return items
    .map((item, index) => ({ item, index }))
    .sort((a, b) => localizedStandardCompare(a.item.section, b.item.section) || a.index - b.index)
    .map(({ item }) => item);
}

/** Un titre de section s'affiche quand la section change. */
export function startsSection(items: { section: string }[], index: number): boolean {
  return index === 0 || items[index - 1]!.section !== items[index]!.section;
}
