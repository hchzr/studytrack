// Ce que « se connecter » déclenche : importer l'horaire (`.ics`), relire le calendrier
// académique, synchroniser les tâches — et ranger le résultat dans la base.
//
// Les services travaillent sur le graphe en mémoire (comme SwiftData côté Mac) ; ici on
// compare le graphe avant/après pour savoir quoi enregistrer et quoi supprimer.
// Rien ne tourne en arrière-plan : tout part d'un geste, ou **une fois** au lancement
// (`launchSync`), jamais par minuteur.

import { AcademicMilestone } from "../models/academicMilestone.ts";
import { AcademicTerm } from "../models/academicTerm.ts";
import { Course } from "../models/course.ts";
import { LinkedCalendarEvent } from "../models/linkedCalendarEvent.ts";
import { LinkedTask } from "../models/linkedTask.ts";
import { TaskProvider } from "../models/enums.ts";
import type { ModelStore } from "../models/store.ts";
import { readConnection } from "../native/settings.ts";
import { AcademicCalendarService, refreshMessage } from "./academicCalendarService.ts";
import { CalendarSync } from "./calendarService.ts";
import { TimetableImport, resultMessage } from "./timetableImport.ts";
import { AnkiReviewSync } from "./ankiReviewSync.ts";
import { ankiWebSync } from "./ankiWebSync.ts";
import { readableServices, syncTasks, autoLink } from "./taskService.ts";

export interface Persistence {
  store: ModelStore;
  commit(changes: { save: readonly object[]; remove: readonly object[] }): Promise<void>;
}

const tracked = [Course, AcademicTerm, LinkedCalendarEvent, LinkedTask, AcademicMilestone] as const;

function everything(store: ModelStore): Set<object> {
  const all = new Set<object>();
  for (const type of tracked) for (const object of store.fetch(type as never) as object[]) all.add(object);
  return all;
}

/** Fait `work`, puis enregistre ce qui existe maintenant et supprime ce qui a disparu. */
export async function persisting<T>(p: Persistence, work: () => T | Promise<T>): Promise<T> {
  const before = everything(p.store);
  const result = await work();
  const after = everything(p.store);
  await p.commit({ save: [...after], remove: [...before].filter((o) => !after.has(o)) });
  return result;
}

/** Importe le texte d'un `.ics` (fichier ou collage). */
export function importTimetableText(p: Persistence, text: string, sectionCode = ""): Promise<string> {
  return persisting(p, () => {
    const result = TimetableImport.import(text, p.store, sectionCode);
    CalendarSync.repair(p.store);
    return resultMessage(result);
  });
}

/** Relit l'abonnement `.ics` configuré. */
export async function refreshTimetableFeed(p: Persistence, url = readConnection("timetableURLString")): Promise<string> {
  const text = await TimetableImport.fetch(url);
  return importTimetableText(p, text);
}

/** Relève le temps passé dans Anki (révisions depuis AnkiWeb) en sessions « Anki ». */
export async function syncAnki(p: Persistence, force = true): Promise<string> {
  const outcome = await AnkiReviewSync.syncIfDue(p.store, { force });
  if (outcome === null) return ankiWebSync.lastError ?? "Rien à relever.";
  await p.commit({ save: outcome.sessions, remove: [] });
  const minutes = Math.round(outcome.seconds / 60);
  return outcome.sessionsAdded === 0 ? "Aucune nouvelle révision." : `${outcome.sessionsAdded} session(s) relevée(s) · ${minutes} min.`;
}

/** Relit la page publique du calendrier académique. */
export function refreshAcademicCalendar(p: Persistence): Promise<string> {
  return persisting(p, async () => refreshMessage(await AcademicCalendarService.refresh(p.store)));
}

/** Synchronise les tâches de chaque fournisseur configuré (Todoist, Notion…). */
export function syncAllTasks(p: Persistence): Promise<string> {
  return persisting(p, async () => {
    const result = await syncTasks(p.store, readableServices(), (provider) => TaskProvider.label(provider));
    autoLink(p.store.fetch(LinkedTask), p.store.fetch(Course));
    if (result.providers.length === 0) return "Aucune tâche lue (aucun fournisseur ne répond, ou aucun n'est configuré).";
    return `${result.providers.join(", ")} : ${result.created} nouvelle(s), ${result.updated} à jour, ${result.removed} retirée(s).`;
  });
}

const LAST = "win.lastConnectionsSync";
const HALF_DAY = 12 * 3600_000;

/**
 * Au lancement, **une fois** : l'abonnement `.ics` et les tâches, s'ils sont configurés et
 * pas relus depuis douze heures. Aucun minuteur : si l'app reste ouverte, elle ne relit rien.
 */
export async function launchSync(p: Persistence, now = new Date()): Promise<void> {
  let last = 0;
  try { last = Number(globalThis.localStorage?.getItem(LAST) ?? 0); } catch { /* stockage refusé */ }
  if (now.getTime() - last < HALF_DAY) return;
  const feed = readConnection("timetableURLString");
  const hasTasks = readableServices().length > 0;
  const hasAnki = ankiWebSync.isSignedIn;
  if (feed === "" && !hasTasks && !hasAnki) return;
  try { globalThis.localStorage?.setItem(LAST, String(now.getTime())); } catch { /* stockage refusé */ }
  if (feed !== "") await refreshTimetableFeed(p, feed).catch(() => undefined);
  if (hasTasks) await syncAllTasks(p).catch(() => undefined);
  if (hasAnki) await syncAnki(p, false).catch(() => undefined);
}
