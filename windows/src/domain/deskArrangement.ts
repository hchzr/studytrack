// Comment le bureau s'arrange selon le moment
// (Polymestre/Domain/DeskArrangement.swift).
//
// `DeskMoment` ne choisissait que l'accueil. Ici : l'outil du centre, ce qu'on
// garde à côté, et ce qui prend l'écran un instant (la pause, la fin qui
// approche). Une décision pure et testée ; l'appliquer est dans le Mac.
//
// **Règle d'or : le bureau ne bouge jamais sous les mains.** Il ne se réarrange
// qu'à un changement de moment (`signature`) ; un geste de l'étudiant·e épingle
// la partie touchée jusqu'au changement suivant.

import type { DeskMoment } from "./deskMoment.ts";

/** Où en est la session : au travail, en pause du rythme, en pause, finie. */
export type DeskPhase = "running" | "onBreak" | "paused" | "ended";

/** Ce que le bureau sait de la situation. */
export interface DeskArrangementContextInit {
  moment: DeskMoment;
  /** Le travail est de la théorie (lire, regarder), pas des exercices. */
  isTheory?: boolean;
  phase?: DeskPhase;
  /** Un exercice est visé. */
  hasTarget?: boolean;
  /** L'exercice visé est fait (à corriger). */
  targetDone?: boolean;
  seriesComplete?: boolean;
  solutionAvailable?: boolean;
  hasCopy?: boolean;
  hasCourseNotes?: boolean;
  /** Minutes restantes (`null` : session sans fin). */
  minutesLeft?: number | null;
  /** La pause du cours (à +45 min) est en cours. */
  classBreak?: boolean;
  /** Une app d'écriture (GoodNotes) occupe le centre. */
  writingApp?: boolean;
}

export class DeskArrangementContext {
  moment: DeskMoment;
  isTheory: boolean;
  phase: DeskPhase;
  hasTarget: boolean;
  targetDone: boolean;
  seriesComplete: boolean;
  solutionAvailable: boolean;
  hasCopy: boolean;
  hasCourseNotes: boolean;
  minutesLeft: number | null;
  classBreak: boolean;
  writingApp: boolean;

  constructor(o: DeskArrangementContextInit) {
    this.moment = o.moment;
    this.isTheory = o.isTheory ?? false;
    this.phase = o.phase ?? "running";
    this.hasTarget = o.hasTarget ?? false;
    this.targetDone = o.targetDone ?? false;
    this.seriesComplete = o.seriesComplete ?? false;
    this.solutionAvailable = o.solutionAvailable ?? false;
    this.hasCopy = o.hasCopy ?? false;
    this.hasCourseNotes = o.hasCourseNotes ?? false;
    this.minutesLeft = o.minutesLeft ?? null;
    this.classBreak = o.classBreak ?? false;
    this.writingApp = o.writingApp ?? false;
  }
}

/** Les outils du centre (les mêmes valeurs que `StudyDesk.Pane`). */
export type DeskCenter = "desk" | "exercise" | "course" | "notes" | "calc" | "web" | "music";
export const DeskCenter = {
  allCases: ["desk", "exercise", "course", "notes", "calc", "web", "music"] as readonly DeskCenter[],
};

/** Ce qu'on peut garder à côté. */
export type DeskSide = "series" | "copy" | "solution" | "courseNotes" | "sheet";
export const DeskSide = {
  allCases: ["series", "copy", "solution", "courseNotes", "sheet"] as readonly DeskSide[],
};

export type DeskTakeover = "none" | "onBreak" | "paused" | "wrapUp" | "classBreak";
export const DeskTakeover = {
  allCases: ["none", "onBreak", "paused", "wrapUp", "classBreak"] as readonly DeskTakeover[],
};

export interface DeskLayout {
  center: DeskCenter;
  /** Le premier est ouvert ; les autres sont proposés. */
  side: DeskSide[];
  sideOpen: boolean;
  takeover: DeskTakeover;
  /** Clore la série avec Claude (la série est finie). */
  openClaude: boolean;
}

/** Cinq minutes avant la fin : le bilan. */
export const wrapUpMinutes = 5;

type ContextInput = DeskArrangementContext | DeskArrangementContextInit;

/** Un `Context` à partir de l'objet de test ou de la classe (les champs absents prennent leur défaut). */
function asContext(input: ContextInput): DeskArrangementContext {
  return input instanceof DeskArrangementContext ? input : new DeskArrangementContext(input);
}

export function layout(input: ContextInput): DeskLayout {
  const c = asContext(input);
  const takeover = takeoverFor(c);
  const result: DeskLayout = { center: "desk", side: [], sideOpen: false, takeover, openClaude: false };
  switch (c.moment) {
    case "lecture":
      // En cours : l'accueil du cours. Rien à côté.
      break;
    case "revision":
      result.side = ["sheet"];
      result.sideOpen = true;
      break;
    case "series":
    case "together":
      if (c.isTheory) {
        result.center = "course";
        if (c.hasCourseNotes) {
          result.side = ["courseNotes"];
          result.sideOpen = true;
        }
      } else if (c.hasTarget) {
        result.center = "exercise";
        if (c.writingApp) {
          // Le centre est à l'app d'écriture : l'énoncé passe à côté.
          result.side = ["series"];
        } else if (c.targetDone && c.solutionAvailable) {
          // Faire → corriger : le corrigé vient à côté de l'énoncé.
          result.side = ["solution"];
        } else if (c.hasCopy) {
          result.side = ["copy"];
        } else if (c.hasCourseNotes) {
          result.side = ["courseNotes"];
        }
        result.sideOpen = result.side.length > 0;
        result.openClaude = c.seriesComplete;
      }
      break;
  }
  return result;
}

export function takeoverFor(input: ContextInput): DeskTakeover {
  const c = asContext(input);
  if (c.classBreak) return "classBreak";
  switch (c.phase) {
    case "onBreak": return "onBreak";
    case "paused": return "paused";
    case "ended": return "none";
    case "running":
      if (c.minutesLeft !== null && c.minutesLeft <= wrapUpMinutes) return "wrapUp";
      return "none";
  }
}

/** La clé d'un moment : quand elle change, le bureau se réarrange. */
export function signature(input: ContextInput): string {
  const c = asContext(input);
  return [
    c.moment,
    c.isTheory ? "t" : "e",
    c.hasTarget ? "cible" : "-",
    c.targetDone ? "fait" : "-",
    c.seriesComplete ? "série" : "-",
    c.solutionAvailable ? "corrigé" : "-",
    c.hasCopy ? "copie" : "-",
    c.writingApp ? "écrit" : "-",
  ].join("|");
}

/** Les parties du bureau qu'un geste a épinglées. */
export interface PinsInit {
  center?: boolean;
  side?: boolean;
  claude?: boolean;
}

export class Pins {
  center: boolean;
  side: boolean;
  claude: boolean;

  constructor(o: PinsInit = {}) {
    this.center = o.center ?? false;
    this.side = o.side ?? false;
    this.claude = o.claude ?? false;
  }

  get isEmpty(): boolean { return !this.center && !this.side && !this.claude; }
}

/** À un changement de moment les épingles tombent, sinon elles restent. */
export function pins(current: Pins | PinsInit, previous: string | null, next: string): Pins {
  if (previous !== next) return new Pins();
  return current instanceof Pins ? current : new Pins(current);
}

/** `takeover(for:)` : ce qui prend l'écran un instant. */
export const takeover = takeoverFor;

/** Ce qu'on peut appliquer : la mise en page, privée de ce que l'étudiant·e a épinglé. */
export function applicable(
  value: DeskLayout,
  pinned: Pins | PinsInit,
): { center: DeskCenter | null; side: DeskSide[] | null; claude: boolean } {
  return {
    center: pinned.center ? null : value.center,
    side: pinned.side ? null : value.side,
    claude: !pinned.claude && value.openClaude,
  };
}

export const DeskArrangement = {
  Context: DeskArrangementContext,
  Center: DeskCenter,
  Side: DeskSide,
  Takeover: DeskTakeover,
  Pins,
  wrapUpMinutes,
  layout,
  takeover,
  signature,
  pins,
  applicable,
};
