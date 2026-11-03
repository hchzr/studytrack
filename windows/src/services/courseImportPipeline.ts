// L'import d'un cours Moodle, de bout en bout (StudyTrack/Services/CourseSiteClients.swift
// › CourseImportPipeline).
//
// 1. Moodle (le plan du cours, les cibles des liens) — `MoodleClient.snapshot` ;
// 2. le modèle range ce que les règles ne savent pas lire (activités aux noms
//    inattendus, consigne de chaque semaine) — `MoodleCourseAIService` ;
// 3. les règles construisent le brouillon (un élément de théorie par semaine).
//
// 4. les listes MediaSpace que le cours cite, déroulées vidéo par vidéo, chacune posée dans
//    sa semaine (MediaSpaceSupplement) — connexion SWITCH demandée une fois si besoin.
//
// Pas porté : Botafogo, les MOOC Courseware, Explique et la
// lecture du plan du cours (`CoursePlanReader`). Un cours qui en dépend le dit dans les
// notes plutôt que de l'importer à moitié.

import type { MoodleCourseSnapshot } from "../domain/moodleCourseAnalyzer.ts";
import { MoodleCourseAnalyzer } from "../domain/moodleCourseAnalyzer.ts";
import type { ContentDraft } from "../domain/courseContentImport.ts";
import { MoodleCourseAIService } from "./moodleCourseAIService.ts";
import { CourseVideo, CourseVideos } from "../domain/courseVideos.ts";
import { collectionVideos, entryID, isCollection } from "./mediaspace.ts";
import { SiteError } from "./siteSession.ts";

export interface PipelineOutcome {
  draft: ContentDraft;
  notes: string[];
}

export async function draftFrom(snapshot: MoodleCourseSnapshot, termStart: Date | null, totalWeeks: number,
  progress: (step: string) => void = () => {}, signal?: AbortSignal): Promise<PipelineOutcome> {
  const notes: string[] = [];
  if (snapshot.unopened > 0) notes.push(`${snapshot.unopened} activités non ouvertes (cours très long)`);
  if (snapshot.moocLinks.length > 0) notes.push("MOOC cité : non lu sur Windows (ajoute-le depuis son site)");
  progress("rangement du cours…");
  const answer = await MoodleCourseAIService.analyze(snapshot, { termStart, totalWeeks, signal });
  let draft = MoodleCourseAnalyzer.draft(snapshot, termStart, totalWeeks, answer.hints);
  // Ce que le modèle a compris du cours entier : où sont les énoncés, et la consigne de chaque semaine.
  draft = MoodleCourseAnalyzer.apply(answer, draft, snapshot, totalWeeks);
  progress("vidéos MediaSpace…");
  draft = await withRecordings(snapshot, draft, termStart, totalWeeks, notes);
  return { draft, notes };
}

/** Les listes MediaSpace citées par Moodle, déroulées et posées dans leur semaine. */
async function withRecordings(snapshot: MoodleCourseSnapshot, draft: ContentDraft, termStart: Date | null,
  totalWeeks: number, notes: string[]): Promise<ContentDraft> {
  const links = snapshot.sections.flatMap((section) => [
    ...section.activities.flatMap((activity) => [activity.url, activity.target ?? ""]),
    ...section.links.map((link) => link.url),
  ]).filter((url) => url !== "");
  const collections = [...new Set(links.filter(isCollection))].sort();
  if (collections.length === 0) return draft;
  const seen = new Set(draft.sections.flatMap((section) => section.items.flatMap((item) => [item.url, ...item.links.map((link) => link.url)]))
    .map(entryID).filter((id): id is string => id !== null));
  const videos: { title: string; url: string }[] = [];
  for (const collection of collections.slice(0, 4)) {
    try {
      for (const video of await collectionVideos(collection)) {
        if (seen.has(video.entryID)) continue;
        seen.add(video.entryID);
        videos.push({ title: video.title, url: video.url });
      }
    } catch (error) {
      if (error instanceof SiteError && error.kind === "notSignedIn") {
        notes.push("Liste de vidéos MediaSpace citée — connecte-toi à MediaSpace (« Le cours › Vidéos »), puis relance l'import");
        return draft;
      }
    }
  }
  if (videos.length === 0) return draft;
  const perWeek = CourseVideos.lecturesPerWeek(videos.map((video) => video.title), totalWeeks);
  const placed = videos.map((video, order) => CourseVideo.make(video.title, video.url, {
    week: CourseVideos.week(video.title, termStart, totalWeeks, perWeek), order,
  }));
  const merged = CourseVideos.merge(placed, draft, totalWeeks, "MediaSpace");
  notes.push(`+ MediaSpace (${videos.length} vidéo${videos.length > 1 ? "s" : ""})`);
  return merged.draft;
}

export const CourseImportPipeline = { draft: draftFrom };
