// Ce qui est nouveau sur Moodle (MoodleWatcher du iPhone) : une série, un corrigé, un rendu
// publiés depuis le dernier relevé. Sous Windows, pas de réveil en arrière-plan : un relevé au
// lancement et quand on revient sur l'app, toutes les deux heures au plus — une requête légère
// par cours (`core_courseformat_get_state`), rien entre deux. Les nouveautés s'affichent sur
// l'accueil jusqu'à ce qu'on les voie.

import type { Course } from "../models/course.ts";
import { MoodleCourseMatcher } from "../domain/moodleImport.ts";
import { MoodleNews, type MoodleNewsItem } from "../domain/moodleNews.ts";
import { MoodleClient } from "./moodleClient.ts";
import { siteAvailable } from "./siteSession.ts";

const KNOWN = "moodleWatch.known";
const NEWS = "moodleWatch.news";
const LAST = "moodleWatch.lastCheck";
const INTERVAL_MS = 2 * 3600 * 1000;

export interface CourseNews { courseID: string; code: string; items: MoodleNewsItem[]; at: string }

const listeners = new Set<() => void>();
export function onMoodleNews(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function read<T>(key: string, fallback: T): T {
  try { return JSON.parse(localStorage.getItem(key) ?? "null") as T ?? fallback; } catch { return fallback; }
}
function write(key: string, value: unknown): void {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* pour la session */ }
}

export function moodleNews(): CourseNews[] { return read<CourseNews[]>(NEWS, []); }

/** Vu : la nouveauté quitte l'accueil (l'activité reste connue). */
export function dismissMoodleNews(courseID: string): void {
  write(NEWS, moodleNews().filter((news) => news.courseID !== courseID));
  for (const listener of listeners) listener();
}

let running: Promise<void> | null = null;

/** Un relevé si le dernier date de plus de deux heures (`force` : tout de suite). */
export function checkMoodleNews(courses: Course[], force = false): Promise<void> {
  if (!siteAvailable()) return Promise.resolve();
  const last = Number(read<number>(LAST, 0));
  if (!force && Date.now() - last < INTERVAL_MS) return Promise.resolve();
  running ??= run(courses).finally(() => { running = null; });
  return running;
}

async function run(courses: Course[]): Promise<void> {
  const client = MoodleClient.background;
  if (!(await client.isSignedIn())) return;
  write(LAST, Date.now());
  const known = read<Record<string, string[]>>(KNOWN, {});
  const news = moodleNews();
  for (const course of courses.filter((c) => c.isTracked)) {
    const id = MoodleCourseMatcher.linkedID([course.moodleURLString, ...course.contentSources].filter(Boolean));
    if (id === null) continue;
    try {
      const snapshot = await client.outline(id, course.name);
      const diff = MoodleNews.diff(snapshot, known[String(id)] ? new Set(known[String(id)]) : null);
      known[String(id)] = [...diff.seen].sort();
      if (diff.new.length > 0) {
        const existing = news.find((item) => item.courseID === course.id);
        if (existing) existing.items.push(...diff.new.filter((item) => !existing.items.some((other) => other.id === item.id)));
        else news.push({ courseID: course.id, code: course.displayCode, items: diff.new, at: new Date().toISOString() });
      }
    } catch {
      // Un cours illisible n'empêche pas les autres.
    }
  }
  write(KNOWN, known);
  write(NEWS, news);
  for (const listener of listeners) listener();
}
