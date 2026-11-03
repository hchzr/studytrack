// Les enregistrements d'un cours, tous, rangés par semaine : les listes MediaSpace que le cours
// cite (sur Moodle, dans ses sources, ses éléments de théorie) déroulées vidéo par vidéo, et
// les vidéos citées une à une (MediaSpaceSupplement du Mac, étendu à l'écran du cours).
// Gardés sur l'appareil par cours : la liste s'affiche tout de suite, puis se met à jour.

import type { Course } from "../models/course.ts";
import { CourseVideos } from "../domain/courseVideos.ts";
import { DateUtils } from "../domain/dateUtils.ts";
import { MoodleCourseMatcher } from "../domain/moodleImport.ts";
import { collectionVideos, entryID, isCollection, type MediaSpaceVideo } from "./mediaspace.ts";
import { moodleCoursePage } from "./moodleReader.ts";
import { SiteError, parseHTML } from "./siteSession.ts";

export interface Recording extends MediaSpaceVideo {
  week: number | null;
}

export interface RecordingsResult {
  recordings: Recording[];
  /** Une liste citée demande la connexion à MediaSpace (SWITCH edu-ID). */
  needsLogin: boolean;
  /** Les listes citées (même illisibles) : il y a quelque chose à chercher. */
  collections: number;
}

interface Found { url: string; title: string }

/** Les liens MediaSpace qu'un cours cite : sa page Moodle, ses sources, sa théorie. */
async function links(course: Course): Promise<Found[]> {
  const found: Found[] = [];
  const add = (url: string, title = "") => { if (/mediaspace|kaltura/i.test(url)) found.push({ url, title }); };
  for (const source of course.contentSources) add(source);
  for (const item of course.theoryItems) {
    add(item.urlString, item.title);
    for (const link of item.links) add(link.url, link.title || item.title);
  }
  const moodle = MoodleCourseMatcher.linkedID([course.moodleURLString, ...course.contentSources].filter(Boolean));
  if (moodle !== null) {
    try {
      const page = await moodleCoursePage(moodle);
      for (const section of page.sections) {
        const html = [section.summary, ...section.activities.map((activity) => activity.html)].join("\n");
        for (const anchor of parseHTML(html).querySelectorAll("a[href]")) add(anchor.getAttribute("href") ?? "", anchor.textContent?.trim() ?? "");
        for (const activity of section.activities) add(activity.url, activity.name);
      }
    } catch {
      // Moodle pas lisible maintenant : les autres sources suffisent.
    }
  }
  return found;
}

/** La semaine d'une vidéo : son titre d'abord, sinon sa date de mise en ligne (ramenée à l'année du semestre). */
function weekOf(video: MediaSpaceVideo, termStart: Date | null, totalWeeks: number, perWeek: number): number | null {
  const fromTitle = CourseVideos.week(video.title, termStart, totalWeeks, perWeek);
  if (fromTitle !== null || termStart === null || video.createdAt === null) return fromTitle;
  const shifted = new Date(video.createdAt.getTime());
  shifted.setFullYear(shifted.getFullYear() + (termStart.getFullYear() - shifted.getFullYear()));
  const start = new Date(termStart.getFullYear(), termStart.getMonth(), termStart.getDate());
  const days = DateUtils.daysBetween(start, shifted);
  const week = Math.trunc(days / 7) + 1;
  return days >= 0 && week <= totalWeeks ? week : null;
}

const KEY = (course: Course) => `recordings.${course.id}`;

export function cachedRecordings(course: Course): Recording[] | null {
  try {
    const raw = localStorage.getItem(KEY(course));
    if (!raw) return null;
    return (JSON.parse(raw) as (Recording & { createdAt: string | null })[]).map((r) => ({ ...r, createdAt: r.createdAt ? new Date(r.createdAt) : null }));
  } catch {
    return null;
  }
}

export async function loadRecordings(course: Course): Promise<RecordingsResult> {
  const found = await links(course);
  const collections = [...new Set(found.map((f) => f.url).filter(isCollection))];
  const videos = new Map<string, MediaSpaceVideo>();
  let needsLogin = false;
  for (const collection of collections.slice(0, 8)) {
    try {
      for (const video of await collectionVideos(collection)) if (!videos.has(video.entryID)) videos.set(video.entryID, video);
    } catch (error) {
      if (error instanceof SiteError && error.kind === "notSignedIn") needsLogin = true;
    }
  }
  for (const link of found) {
    if (isCollection(link.url)) continue;
    const id = entryID(link.url);
    if (!id || videos.has(id)) continue;
    videos.set(id, { entryID: id, title: link.title || "Vidéo du cours", url: link.url, createdAt: null, durationSeconds: 0 });
  }
  const termStart = course.term?.startDate ?? null;
  const totalWeeks = course.term?.totalWeeks ?? 14;
  const list = [...videos.values()];
  const perWeek = CourseVideos.lecturesPerWeek(list.map((video) => video.title), totalWeeks);
  const recordings = list.map((video) => ({ ...video, week: weekOf(video, termStart, totalWeeks, perWeek) }))
    .sort((a, b) => (a.week ?? 99) - (b.week ?? 99) || (a.createdAt?.getTime() ?? 0) - (b.createdAt?.getTime() ?? 0) || a.title.localeCompare(b.title, "fr"));
  if (recordings.length > 0) {
    try { localStorage.setItem(KEY(course), JSON.stringify(recordings)); } catch { /* sans cache */ }
  }
  return { recordings, needsLogin, collections: collections.length };
}
