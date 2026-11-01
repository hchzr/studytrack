// Les morceaux purs de l'écran du mode étude : formats et lectures que le
// Swift porte dans ses vues, sortis ici pour être testés et partagés entre
// l'accueil, l'écran de lancement et le volet d'à côté.

import { BotafogoLinks } from "../../domain/botafogoProgram.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { LectureClock, type FocusContextSlot } from "../../domain/deskMoment.ts";
import type { ExerciseSeries } from "../../models/exercise.ts";

/** « 25 min », « 1 h 30 », « 2 h » — la pastille d'une durée proposée. */
export function durationChipLabel(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.trunc(minutes / 60);
  const rest = minutes % 60;
  return rest === 0 ? `${hours} h` : `${hours} h ${rest}`;
}

/** « jusqu'à 17 h 50 » / « sans heure de fin » — ce que l'écran de lancement dit de la fin. */
export function endLabel(minutes: number, openEnded: boolean, now: Date): string {
  if (openEnded) return "sans heure de fin";
  return "jusqu'à " + DateUtils.time(new Date(now.getTime() + minutes * 60_000));
}

/** Où en est le créneau, en une ligne (LectureDeskView.phaseLabel) : la pause
 *  de l'EPFL comprise (« Pause · reprise dans 10 min »). */
export function lecturePhaseLabel(slot: FocusContextSlot, now: Date): string {
  const phase = LectureClock.phase(slot, now);
  switch (phase.kind) {
    case "before":
      return `Commence dans ${phase.minutes} min`;
    case "running": {
      const left = Math.ceil((slot.end.getTime() - now.getTime()) / 60_000);
      const pause = LectureClock.breakWindow(slot);
      if (pause && now < pause.start) {
        return `Encore ${left} min · pause à ${DateUtils.time(pause.start)}`;
      }
      return `Encore ${left} min`;
    }
    case "pause":
      return `Pause · reprise dans ${phase.untilMinutes} min`;
    case "over":
      return "Le cours est fini";
  }
}

/** Le PDF du corrigé, une fois publié (ExercisePane.solutionAddress) : pas
 *  celui d'une série lue en natif sur Botafogo, pas avant sa date. */
export function solutionAddress(series: ExerciseSeries, now: Date): string | null {
  const address = series.solutionURLString;
  if (address === "" || BotafogoLinks.isPage(address) || address === series.urlString) return null;
  if (series.solutionsAt !== null && series.solutionsAt > now) return null;
  return address;
}

/** Le nom d'une série : son titre, sinon « Série 3 ». */
export function seriesName(series: ExerciseSeries): string {
  return series.title === "" ? `Série ${series.seriesNumber}` : series.title;
}
