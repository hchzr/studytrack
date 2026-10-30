// La géométrie du bureau d'étude (StudyTrack/Domain/DeskGeometry.swift) : où
// poser la fenêtre d'une app permise pour qu'elle remplisse le centre du bureau.
//
// Deux repères se croisent : AppKit mesure depuis le **bas** de l'écran
// principal, l'Accessibilité depuis son **haut**. Tout est pur et testé ici.

/** Ce qu'un rectangle doit offrir (un `Rect` ou un objet littéral). */
export interface RectLike {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** Un rectangle en points. */
export class Rect implements RectLike {
  x: number;
  y: number;
  width: number;
  height: number;

  constructor(xOrInit: number | RectLike, y = 0, width = 0, height = 0) {
    if (typeof xOrInit === "number") {
      this.x = xOrInit;
      this.y = y;
      this.width = width;
      this.height = height;
    } else {
      this.x = xOrInit.x;
      this.y = xOrInit.y;
      this.width = xOrInit.width;
      this.height = xOrInit.height;
    }
  }

  get maxX(): number { return this.x + this.width; }
  get maxY(): number { return this.y + this.height; }

  contains(other: RectLike, tolerance = 2): boolean {
    return other.x >= this.x - tolerance && other.y >= this.y - tolerance
      && other.x + other.width <= this.maxX + tolerance && other.y + other.height <= this.maxY + tolerance;
  }
}

/**
 * Le centre du bureau en repère de l'Accessibilité (origine en haut à gauche) :
 * `window` est la fenêtre du bureau en repère AppKit (origine en bas), `local`
 * le centre mesuré depuis son coin supérieur gauche.
 */
export function accessibilityRect(window: RectLike, local: RectLike, primaryHeight: number): Rect {
  const windowTop = primaryHeight - (window.y + window.height);
  return new Rect(window.x + local.x, windowTop + local.y, local.width, local.height);
}

/**
 * Où poser une fenêtre dans `hole`.
 *
 * - Redimensionnable : elle remplit le trou.
 * - Sinon, ou si l'app refuse d'être aussi petite (`minimum`) : sa taille,
 *   ramenée dans le trou si elle y tient, centrée dedans.
 */
export function placement(
  current: RectLike,
  minimum: { width: number; height: number } | null,
  resizable: boolean,
  inHole: RectLike,
): Rect {
  if (resizable) {
    const width = Math.max(inHole.width, minimum?.width ?? 0);
    const height = Math.max(inHole.height, minimum?.height ?? 0);
    return centred(width, height, inHole);
  }
  return centred(current.width, current.height, inHole);
}

/** Une fenêtre de cette taille, au centre du trou ; trop grande, du coin haut-gauche. */
export function centred(width: number, height: number, hole: RectLike): Rect {
  const x = width >= hole.width ? hole.x : hole.x + (hole.width - width) / 2;
  const y = height >= hole.height ? hole.y : hole.y + (hole.height - height) / 2;
  return new Rect(x, y, width, height);
}

export const DeskGeometry = { Rect, accessibilityRect, placement, centred };

// MARK: - Fenêtres du bureau

export interface PanelFrames {
  bar: Rect;
  rail: Rect;
  desk: Rect;
  side: Rect | null;
}

/**
 * Où vont les fenêtres du bureau sur un écran (repère AppKit) : la barre du
 * haut, la colonne d'outils, le centre et, à part, le volet d'à côté.
 *
 * - `sideWidth` : la largeur du volet quand il est ouvert (`null` : fermé).
 * - `secondScreen` : le volet occupe tout cet autre écran.
 */
export function frames(
  screen: RectLike,
  visible: RectLike,
  bar: number,
  rail: number,
  sideWidth: number | null,
  secondScreen: RectLike | null,
): PanelFrames {
  const screenMaxX = screen.x + screen.width;
  const screenMaxY = screen.y + screen.height;
  const visibleMaxX = visible.x + visible.width;
  const left = Math.max(0, visible.x - screen.x);
  const right = Math.max(0, screenMaxX - visibleMaxX);
  const bottom = Math.max(0, visible.y - screen.y);
  const y0 = screen.y + bottom;
  const height = screen.height - bar - bottom;
  const contentLeft = screen.x + left + rail - 1;
  const contentRight = screenMaxX - right;
  const onThisScreen = secondScreen === null ? sideWidth : null;
  const desk = new Rect(contentLeft, y0, contentRight - contentLeft - (onThisScreen ?? 0), height + 1);
  let side: Rect | null = null;
  if (sideWidth !== null) {
    side = secondScreen === null
      ? new Rect(contentRight - sideWidth, y0, sideWidth, height)
      : new Rect(secondScreen.x, secondScreen.y, secondScreen.width, secondScreen.height);
  }
  return {
    bar: new Rect(screen.x, screenMaxY - bar, screen.width, bar),
    rail: new Rect(screen.x + left, y0, rail, height),
    desk,
    side,
  };
}

export const PanelLayout = { frames };

// MARK: - Ce qu'il manque avant de commencer un blocage

export type StudyMissing = "accessibility" | "systemEvents";

export function missing(
  blocking: boolean,
  placeApps: boolean,
  trusted: boolean,
  hideChrome: boolean,
  automationGranted: boolean,
): StudyMissing[] {
  if (!blocking) return [];
  const result: StudyMissing[] = [];
  if (placeApps && !trusted) result.push("accessibility");
  if (hideChrome && !automationGranted) result.push("systemEvents");
  return result;
}

export const StudyReadiness = { missing };
