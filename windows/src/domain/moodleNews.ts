// Ce qui est apparu sur Moodle depuis la dernière vérification
// (StudyTrack/Domain/MoodleNews.swift).
//
// Pur, donc testé : la surveillance en arrière-plan lit le plan du cours, et
// c'est ici qu'on décide ce qui est **nouveau**, ce qui mérite d'être dit, et
// comment le dire.

import type { ActivityKind } from "./moodleCourseAnalyzer.ts";
import { MoodleCourseAnalyzer } from "./moodleCourseAnalyzer.ts";
import type { MoodleCourseSnapshot } from "./moodleCourseAnalyzer.ts";

export type MoodleNewsKind = "series" | "solution" | "deadline" | "lecture" | "document";

export const MoodleNewsKind = {
  allCases: ["series", "solution", "deadline", "lecture", "document"] as readonly MoodleNewsKind[],

  /** Ce qu'on annonce si l'étudiant·e n'a rien choisi : ce qui se fait. */
  defaults: new Set<MoodleNewsKind>(["series", "solution", "deadline"]),

  label(kind: MoodleNewsKind): string {
    switch (kind) {
      case "series": return "Séries";
      case "solution": return "Corrigés";
      case "deadline": return "Rendus";
      case "lecture": return "Cours et vidéos";
      case "document": return "Autres documents";
    }
  },

  icon(kind: MoodleNewsKind): string {
    switch (kind) {
      case "series": return "doc.text";
      case "solution": return "checkmark.seal";
      case "deadline": return "tray.and.arrow.up";
      case "lecture": return "play.rectangle";
      case "document": return "folder";
    }
  },

  /** « Nouvelle série », en tête d'une notification d'un seul élément. */
  newLabel(kind: MoodleNewsKind): string {
    switch (kind) {
      case "series": return "Nouvelle série";
      case "solution": return "Nouveau corrigé";
      case "deadline": return "Nouveau rendu";
      case "lecture": return "Nouveau cours";
      case "document": return "Nouveau document";
    }
  },

  /** `init?(_ kind: MoodleCourseAnalyzer.ActivityKind)`. */
  fromActivity(kind: ActivityKind): MoodleNewsKind | null {
    switch (kind) {
      case "series": return "series";
      case "solution": return "solution";
      case "deadline": return "deadline";
      case "lecture": return "lecture";
      case "document": return "document";
      case "ignore": return null;
    }
  },

  /** `series,solution` ⇄ l'ensemble : un réglage en une chaîne. */
  decode(raw: string | null | undefined): Set<MoodleNewsKind> {
    if (raw === null || raw === undefined) return new Set(MoodleNewsKind.defaults);
    const result = new Set<MoodleNewsKind>();
    for (const part of raw.split(",")) {
      const kind = MoodleNewsKind.allCases.find((k) => k === part);
      if (kind !== undefined) result.add(kind);
    }
    return result;
  },

  encode(kinds: Set<MoodleNewsKind>): string {
    return MoodleNewsKind.allCases.filter((kind) => kinds.has(kind)).join(",");
  },
};

export interface MoodleNewsItem {
  id: string;
  name: string;
  kind: MoodleNewsKind;
}

export const MoodleNews = {
  /** `MoodleNews.Kind` (Validation/main.swift). */
  Kind: MoodleNewsKind,

  /** Les activités **visibles** d'un cours, rangées. */
  visibleItems(snapshot: MoodleCourseSnapshot): MoodleNewsItem[] {
    const result: MoodleNewsItem[] = [];
    for (const section of snapshot.sections) {
      for (const activity of section.activities) {
        if (!activity.isVisible) continue;
        const kind = MoodleNewsKind.fromActivity(MoodleCourseAnalyzer.classify(activity, section.number > 0));
        if (kind === null) continue;
        result.push({ id: activity.id, name: activity.name, kind });
      }
    }
    return result;
  },

  /** Ce qui n'était pas là, et l'ensemble vu à retenir. */
  diff(snapshot: MoodleCourseSnapshot, known: Set<string> | null): { new: MoodleNewsItem[]; seen: Set<string> } {
    const items = MoodleNews.visibleItems(snapshot);
    const seen = new Set(items.map((item) => item.id));
    if (known === null) return { new: [], seen };
    // Une activité disparue puis revenue reste connue.
    return { new: items.filter((item) => !known.has(item.id)), seen: new Set([...seen, ...known]) };
  },

  /** Le texte d'une notification : une par cours et par relevé. */
  message(courseCode: string, items: MoodleNewsItem[]): { title: string; body: string } | null {
    const first = items[0];
    if (first === undefined) return null;
    if (items.length === 1) {
      return { title: `${MoodleNewsKind.newLabel(first.kind)} · ${courseCode}`, body: first.name };
    }
    const shown = items.slice(0, 3).map((item) => item.name);
    const rest = items.length - shown.length;
    const body = shown.join(" · ") + (rest > 0 ? ` · +${rest}` : "");
    return { title: `${items.length} nouveautés · ${courseCode}`, body };
  },

  /** Quand dire la nouvelle : maintenant (`null`), ou à la fin des heures calmes. */
  deliveryDate(now: Date, quietStart: number, quietEnd: number): Date | null {
    if (quietStart === quietEnd) return null;
    const hour = now.getHours();
    const inside = quietStart < quietEnd
      ? (hour >= quietStart && hour < quietEnd)
      : (hour >= quietStart || hour < quietEnd);
    if (!inside) return null;
    const today = new Date(now.getTime());
    today.setHours(quietEnd, 0, 0, 0);
    if (today.getTime() > now.getTime()) return today;
    const next = new Date(today.getTime());
    next.setDate(next.getDate() + 1);
    return next;
  },
};
