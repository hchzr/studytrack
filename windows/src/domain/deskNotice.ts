// Les notifications du bureau d'étude (StudyTrack/Domain/DeskNotice.swift) :
// une file, pas des bulles qui se marchent dessus.
//
// Pur et testé : les règles de la file ; l'affichage est dans l'app.

import { newId } from "../models/relations.ts";

export type DeskNoticeKind =
  | "blockedApp" | "iPhone" | "claude" | "classSoon" | "solution" | "breakSoon" | "info";

export const DeskNoticeKind = {
  allCases: ["blockedApp", "iPhone", "claude", "classSoon", "solution", "breakSoon", "info"] as readonly DeskNoticeKind[],
};

/** Trois au plus à l'écran. */
export const maxVisible = 3;
/** Deux du même genre à moins de 4 s n'en font qu'une. */
export const coalesce = 4;
/** L'historique : vingt au plus. */
export const historyLimit = 20;

export interface DeskNoticeItemInit {
  id?: string;
  kind: DeskNoticeKind;
  text: string;
  icon: string;
  at: Date;
}

export class DeskNoticeItem {
  id: string;
  kind: DeskNoticeKind;
  text: string;
  icon: string;
  at: Date;

  constructor(o: DeskNoticeItemInit) {
    this.id = o.id ?? newId();
    this.kind = o.kind;
    this.text = o.text;
    this.icon = o.icon;
    this.at = o.at;
  }
}

/** Combien de temps une notification reste. */
export function duration(kind: DeskNoticeKind): number {
  switch (kind) {
    case "blockedApp": return 4;
    case "iPhone": return 4;
    case "claude": return 6;
    case "classSoon": return 10;
    case "solution": return 6;
    case "breakSoon": return 6;
    case "info": return 5;
  }
}

const secondsBetween = (later: Date, earlier: Date) => (later.getTime() - earlier.getTime()) / 1000;

/**
 * Ajoute `item` : le même genre à moins de `coalesce` secondes le remplace
 * (même place, texte et heure frais) ; au-delà de `maxVisible`, la plus
 * ancienne part.
 */
export function adding(item: DeskNoticeItem, to: DeskNoticeItem[]): DeskNoticeItem[] {
  const result = [...to];
  let index = -1;
  for (let i = result.length - 1; i >= 0; i--) {
    if (result[i].kind === item.kind && secondsBetween(item.at, result[i].at) < coalesce) {
      index = i;
      break;
    }
  }
  if (index >= 0) {
    result[index] = new DeskNoticeItem({ ...item, id: result[index].id });
  } else {
    result.push(item);
  }
  if (result.length > maxVisible) result.splice(0, result.length - maxVisible);
  return result;
}

/** L'historique : du plus récent au plus ancien. Une notification fusionnée n'y est qu'une fois. */
export function remembering(item: DeskNoticeItem, inHistory: DeskNoticeItem[]): DeskNoticeItem[] {
  const result = [...inHistory];
  const index = result.findIndex((entry) => entry.id === item.id);
  if (index >= 0) result.splice(index, 1);
  result.unshift(item);
  return result.slice(0, historyLimit);
}

/** Ce qui est encore à l'écran à `now`. */
export function visible(items: DeskNoticeItem[], at: Date): DeskNoticeItem[] {
  return items.filter((item) => secondsBetween(at, item.at) < duration(item.kind));
}

export const DeskNotice = {
  Kind: DeskNoticeKind,
  Item: DeskNoticeItem,
  maxVisible,
  coalesce,
  historyLimit,
  duration,
  adding,
  remembering,
  visible,
};
