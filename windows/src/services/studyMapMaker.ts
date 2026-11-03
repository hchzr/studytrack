// « Comprendre avec Claude » (StudyMapStore.enrich, StudyKit/StudyMapStore.swift) : Claude relit la
// fiche, relie les notions, les explique et dessine les schémas — par Claude Code s'il est
// installé, sinon par le tuteur gratuit (fonction serveur `tutor`, modes `studyMap*`).

import type { Course } from "../models/course.ts";
import { RevisionSheet } from "../domain/revisionSheet.ts";
import { StudyMapAI } from "../domain/studyMapAI.ts";
import { StudyMap } from "../domain/studyMap.ts";
import { askClaude, claudeSetup } from "./claudeConversation.ts";
import { askTutor } from "./freeTutor.ts";

export async function enrichStudyMap(course: Course, chapter: string | null, current: StudyMap, progress: (text: string) => void): Promise<StudyMap> {
  const sheet = RevisionSheet.decode(course.revisionSheetRaw);
  if (!sheet || sheet.entries.length === 0) throw new Error("Fais d'abord la fiche du cours.");
  progress(chapter ? "Claude relit ce chapitre et dessine ses schémas…" : "Claude relie les notions et dessine les schémas…");
  const { text, ids } = StudyMapAI.prompt(course.name, sheet, 220, 400, chapter);
  const instructions = chapter ? StudyMapAI.chapterInstructions : StudyMapAI.instructions;
  const answer = (await claudeSetup())?.found
    ? await askClaude(instructions, text, progress)
    : (await askTutor(chapter ? "studyMapChapter" : "studyMap", [{ role: "user", content: text }])).text;
  const enriched = StudyMapAI.apply(answer, sheet, ids, current, new Date(), chapter);
  if (!enriched) throw new Error("Claude n'a pas rendu de réponse lisible. Réessaie.");
  return enriched;
}
