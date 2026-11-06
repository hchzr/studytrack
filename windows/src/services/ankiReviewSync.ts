// Relève le temps passé dans Anki et l'enregistre en sessions étiquetées « Anki »
// (Polymestre/Services/AnkiReviewSync.swift).
//
// L'étudiant·e ne saisit rien : connecté·e à AnkiWeb, l'app rapatrie les révisions faites
// depuis le dernier relevé. Hors réseau n'est pas une erreur — on réessaiera au prochain
// passage, sans bruit. Sur Windows le passage est le **lancement** de l'app et le bouton
// « Relever maintenant » : rien ne tourne en arrière-plan.

import { AnkiReviewImport } from "../domain/ankiReviewImport.ts";
import { AppLog } from "../domain/appLog.ts";
import { Plural } from "../domain/plural.ts";
import { Course } from "../models/course.ts";
import { StudySession } from "../models/studySession.ts";
import type { ModelStore } from "../models/store.ts";
import { ankiWebSync, type AnkiWebSync } from "./ankiWebSync.ts";

/** Pas plus d'un relevé toutes les dix minutes : AnkiWeb n'a rien de nouveau à dire entre deux. */
export const minimumInterval = 10 * 60 * 1000;

export interface AnkiOutcome {
  sessionsAdded: number;
  seconds: number;
  /** Les sessions créées, à enregistrer. */
  sessions: StudySession[];
}

const LAST_SYNC = "settings.ankiLastSync";

function readLast(): number | null {
  try {
    const raw = globalThis.localStorage?.getItem(LAST_SYNC);
    return raw ? Number(raw) : null;
  } catch { return null; }
}

export function ankiLastSync(): Date | null {
  const last = readLast();
  return last === null ? null : new Date(last);
}

/** Relève si le délai est passé ; `null` quand rien n'était dû (ou pas connecté·e, ou en échec). */
export async function syncIfDue(store: ModelStore, o: { force?: boolean; web?: AnkiWebSync; now?: Date } = {}): Promise<AnkiOutcome | null> {
  const web = o.web ?? ankiWebSync;
  if (!web.isSignedIn) return null;
  const now = o.now ?? new Date();
  const last = readLast();
  if (!o.force && last !== null && now.getTime() - last < minimumInterval) return null;
  try {
    return await sync(store, web, now);
  } catch {
    return null;
  }
}

/** Les révisions arrivent d'AnkiWeb (la copie de la collection, relue si le serveur a changé). */
export async function sync(store: ModelStore, web: AnkiWebSync = ankiWebSync, now = new Date()): Promise<AnkiOutcome> {
  await web.refreshMirror();
  const reviews = await web.newReviews(now);

  const drafts = AnkiReviewImport.sessions(reviews);
  const courses = [...store.fetch(Course)];
  const known = new Set(store.fetch(StudySession).filter((s) => s.isFromAnki).map((s) => s.externalKey));
  const keys = courses.map((c) => ({ code: c.code, shortName: c.shortName, name: c.name }));

  const sessions: StudySession[] = [];
  let seconds = 0;
  for (const draft of drafts) {
    if (known.has(draft.key)) continue;
    const index = AnkiReviewImport.courseIndex(draft.deck, keys);
    const session = new StudySession({
      course: index === null ? null : courses[index],
      taskType: "flashcards",
      startedAt: draft.start,
      durationSeconds: draft.seconds,
      isManual: false,
      note: `Anki · ${draft.deck} · ${Plural.count(draft.reviewCount, `${draft.reviewCount} carte`, `${draft.reviewCount} cartes`)}`,
    });
    session.sourceRaw = "anki";
    session.externalKey = draft.key;
    store.insert(session);
    sessions.push(session);
    seconds += draft.seconds;
  }
  try { globalThis.localStorage?.setItem(LAST_SYNC, String(now.getTime())); } catch { /* stockage refusé */ }
  void AppLog.record("info", "anki", `${sessions.length} session(s) Anki relevée(s), ${seconds} s`);
  return { sessionsAdded: sessions.length, seconds, sessions };
}

export const AnkiReviewSync = { minimumInterval, syncIfDue, sync };
