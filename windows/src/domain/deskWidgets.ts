// Les cartes du bureau d'étude (StudyTrack/Domain/DeskWidgets.swift) : ce qu'on
// pose sur la table selon le moment, rangé par l'étudiant·e — masquer, agrandir,
// déplacer — et retenu **par moment**.
//
// Pur et testé ; les cartes elles-mêmes sont dans l'interface.

import type { DeskMoment } from "./deskMoment.ts";

export type DeskWidgetKind =
  | "session" | "target" | "upNext" | "steps" | "redo" | "exam" | "music" | "today"
  | "claude" | "courses" | "accounts" | "deadlines" | "group"
  | "lectureClock" | "lectureMarks" | "lectureTools" | "lectureWeek" | "lectureTheory"
  | "revisionExam" | "revisionSheet" | "revisionPast" | "revisionRedo" | "revisionTheory";

export const DeskWidgetKind = {
  allCases: [
    "session", "target", "upNext", "steps", "redo", "exam", "music", "today", "claude",
    "courses", "accounts", "deadlines", "group",
    "lectureClock", "lectureMarks", "lectureTools", "lectureWeek", "lectureTheory",
    "revisionExam", "revisionSheet", "revisionPast", "revisionRedo", "revisionTheory",
  ] as readonly DeskWidgetKind[],
};

export type DeskWidgetSize = "small" | "medium" | "large";

export const DeskWidgetSize = {
  allCases: ["small", "medium", "large"] as readonly DeskWidgetSize[],

  next(size: DeskWidgetSize): DeskWidgetSize {
    switch (size) {
      case "small": return "medium";
      case "medium": return "large";
      case "large": return "small";
    }
  },

  /** Le nombre de colonnes qu'une carte occupe (la hauteur suit son contenu). */
  span(size: DeskWidgetSize): number {
    switch (size) {
      case "small": return 1;
      case "medium": return 2;
      case "large": return 3;
    }
  },
};

export interface DeskWidgetPlacementInit {
  kind: DeskWidgetKind;
  size: DeskWidgetSize;
  hidden?: boolean;
}

export class DeskWidgetPlacement {
  kind: DeskWidgetKind;
  size: DeskWidgetSize;
  hidden: boolean;

  constructor(o: DeskWidgetPlacementInit) {
    this.kind = o.kind;
    this.size = o.size;
    this.hidden = o.hidden ?? false;
  }

  get id(): string { return this.kind; }
}

/** Ce que le bureau sait pour choisir ses cartes. */
export interface DeskWidgetsContextInit {
  moment: DeskMoment;
  hasCourse: boolean;
  hasSeries?: boolean;
  /** La session est commune à un groupe. */
  inGroup?: boolean;
  /** Un exercice est visé (sa carte montre déjà la suite de la série). */
  hasTarget?: boolean;
  redosDue?: number;
  /** Jours avant le prochain examen (`null` : aucun). */
  daysToExam?: number | null;
}

export class DeskWidgetsContext {
  moment: DeskMoment;
  hasCourse: boolean;
  hasSeries: boolean;
  inGroup: boolean;
  hasTarget: boolean;
  redosDue: number;
  daysToExam: number | null;

  constructor(o: DeskWidgetsContextInit) {
    this.moment = o.moment;
    this.hasCourse = o.hasCourse;
    this.hasSeries = o.hasSeries ?? false;
    this.inGroup = o.inGroup ?? false;
    this.hasTarget = o.hasTarget ?? false;
    this.redosDue = o.redosDue ?? 0;
    this.daysToExam = o.daysToExam ?? null;
  }
}

/** Les examens à moins de trois semaines méritent leur carte. */
export const examHorizonDays = 21;

const p = (kind: DeskWidgetKind, size: DeskWidgetSize): DeskWidgetPlacement =>
  new DeskWidgetPlacement({ kind, size });

type ContextInput = DeskWidgetsContext | DeskWidgetsContextInit;

function asContext(input: ContextInput): DeskWidgetsContext {
  return input instanceof DeskWidgetsContext ? input : new DeskWidgetsContext(input);
}

/** Les cartes d'un moment, dans l'ordre où elles servent. */
export function defaults(input: ContextInput): DeskWidgetPlacement[] {
  const c = asContext(input);
  if (c.hasCourse && c.moment === "lecture") {
    return [p("lectureClock", "medium"), p("lectureMarks", "small"), p("lectureTools", "small"), p("lectureWeek", "large"),
      p("lectureTheory", "small"), p("session", "small"), p("music", "small")];
  }
  if (c.hasCourse && c.moment === "revision") {
    return [p("revisionExam", "small"), p("revisionSheet", "small"), p("revisionRedo", "small"), p("revisionPast", "large"),
      p("revisionTheory", "small"), p("session", "small"), p("music", "small")];
  }
  if (!c.hasCourse) {
    // Session libre : choisir, puis ce que la journée réserve.
    return [p("courses", "medium"), p("session", "small"), p("today", "small"), p("deadlines", "small"),
      p("music", "small"), p("claude", "small"), p("accounts", "small")];
  }
  // L'exercice visé montre déjà ce qui vient ensuite : pas de seconde liste.
  const list: DeskWidgetPlacement[] = [p("session", "small")];
  if (c.hasTarget) list.push(p("target", "medium"));
  if (c.redosDue > 0) list.push(p("redo", "medium"));
  if (c.moment === "revision" || (c.daysToExam !== null && c.daysToExam >= 0 && c.daysToExam <= examHorizonDays)) {
    list.push(p("exam", "small"));
  }
  list.push(p("steps", "small"));
  if (c.hasSeries && !c.hasTarget) list.push(p("upNext", "small"));
  if (c.inGroup) list.push(p("group", "small"));
  list.push(p("music", "small"), p("claude", "small"), p("today", "small"), p("deadlines", "small"), p("accounts", "small"));
  return list;
}

/**
 * Les cartes montrées : ce que l'étudiant·e a rangé, puis les cartes que le
 * moment propose et qu'elle n'a jamais vues. Une carte que le moment ne propose
 * plus disparaît, même rangée.
 */
export function merged(
  defaultsList: DeskWidgetPlacement[],
  stored: DeskWidgetPlacement[] | null | undefined,
): DeskWidgetPlacement[] {
  if (!stored) return defaultsList;
  const offered = new Set(defaultsList.map((placement) => placement.kind));
  const result = stored.filter((placement) => offered.has(placement.kind));
  for (const placement of defaultsList) {
    if (!result.some((entry) => entry.kind === placement.kind) && !stored.some((entry) => entry.kind === placement.kind)) {
      result.push(placement);
    }
  }
  return result;
}

/** Déplace la carte `kind` d'un cran (`-1` : avant, `+1` : après), parmi les cartes montrées. */
export function moved(kind: DeskWidgetKind, by: number, list: DeskWidgetPlacement[]): DeskWidgetPlacement[] {
  const index = list.findIndex((placement) => placement.kind === kind);
  if (index < 0) return list;
  const visible = list.map((_, i) => i).filter((i) => !list[i].hidden);
  const position = visible.indexOf(index);
  if (position < 0) return list;
  const target = position + by;
  if (target < 0 || target >= visible.length) return list;
  const result = [...list];
  const other = visible[target];
  [result[index], result[other]] = [result[other], result[index]];
  return result;
}

/** La grille : des colonnes égales, au moins 300 pt chacune, quatre au plus. */
export const minimumColumn = 300;
export const gap = 16;
export const maximumColumns = 4;

export function columnCount(available: number): number {
  const fit = Math.floor((available + gap) / (minimumColumn + gap));
  return Math.min(maximumColumns, Math.max(1, fit));
}

/** Les colonnes d'une carte : sa taille, sans dépasser la grille. */
export function span(size: DeskWidgetSize, columns: number): number {
  return Math.min(DeskWidgetSize.span(size), Math.max(1, columns));
}

export function resized(kind: DeskWidgetKind, list: DeskWidgetPlacement[]): DeskWidgetPlacement[] {
  return list.map((placement) => placement.kind === kind
    ? new DeskWidgetPlacement({ kind, size: DeskWidgetSize.next(placement.size), hidden: placement.hidden })
    : placement);
}

export function toggled(kind: DeskWidgetKind, list: DeskWidgetPlacement[]): DeskWidgetPlacement[] {
  return list.map((placement) => placement.kind === kind
    ? new DeskWidgetPlacement({ kind, size: placement.size, hidden: !placement.hidden })
    : placement);
}

export function encode(list: DeskWidgetPlacement[]): string {
  return JSON.stringify(list.map((placement) => ({
    kind: placement.kind,
    size: placement.size,
    hidden: placement.hidden,
  })));
}

export function decode(data: string | null | undefined): DeskWidgetPlacement[] | null {
  if (data === null || data === undefined) return null;
  let raw: unknown;
  try {
    raw = JSON.parse(data);
  } catch {
    return null;
  }
  if (!Array.isArray(raw)) return null;
  const result: DeskWidgetPlacement[] = [];
  for (const entry of raw) {
    if (entry === null || typeof entry !== "object") return null;
    const object = entry as Record<string, unknown>;
    if (typeof object.kind !== "string" || !DeskWidgetKind.allCases.includes(object.kind as DeskWidgetKind)) return null;
    if (typeof object.size !== "string" || !DeskWidgetSize.allCases.includes(object.size as DeskWidgetSize)) return null;
    if (typeof object.hidden !== "boolean") return null;
    result.push(new DeskWidgetPlacement({
      kind: object.kind as DeskWidgetKind,
      size: object.size as DeskWidgetSize,
      hidden: object.hidden,
    }));
  }
  return result;
}

/** La clé de rangement : un bureau par moment. */
export function storageKey(moment: DeskMoment): string {
  return `desk.widgets.${moment}`;
}

export const DeskWidgets = {
  Kind: DeskWidgetKind,
  Size: DeskWidgetSize,
  Placement: DeskWidgetPlacement,
  Context: DeskWidgetsContext,
  examHorizonDays,
  defaults,
  merged,
  moved,
  minimumColumn,
  gap,
  maximumColumns,
  columnCount,
  span,
  resized,
  toggled,
  encode,
  decode,
  storageKey,
};
