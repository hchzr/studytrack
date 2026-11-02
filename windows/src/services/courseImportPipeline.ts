// L'import d'un cours Moodle, de bout en bout (StudyTrack/Services/CourseSiteClients.swift
// › CourseImportPipeline).
//
// 1. Moodle (le plan du cours, les cibles des liens) — `MoodleClient.snapshot` ;
// 2. le modèle range ce que les règles ne savent pas lire (activités aux noms
//    inattendus, consigne de chaque semaine) — `MoodleCourseAIService` ;
// 3. les règles construisent le brouillon (un élément de théorie par semaine).
//
// Pas porté : Botafogo, les MOOC Courseware, Explique, les listes MediaSpace et la
// lecture du plan du cours (`CoursePlanReader`). Un cours qui en dépend le dit dans les
// notes plutôt que de l'importer à moitié.

import type { MoodleCourseSnapshot } from "../domain/moodleCourseAnalyzer.ts";
import { MoodleCourseAnalyzer } from "../domain/moodleCourseAnalyzer.ts";
import type { ContentDraft } from "../domain/courseContentImport.ts";
import { MoodleCourseAIService } from "./moodleCourseAIService.ts";

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
  return { draft, notes };
}

export const CourseImportPipeline = { draft: draftFrom };
