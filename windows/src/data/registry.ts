// Le pont entre une table de synchronisation et sa classe de modèle.
//
// `schema.ts` décrit les colonnes ; `registry` dit quelle classe chaque table
// instancie. Les deux ensemble suffisent à reconstruire le graphe d'objets à
// partir des lignes SQLite, et à resérialiser un objet en ligne.

import {
  AcademicTerm, Course, TheoryItem, ExerciseSeries, Exercise, SubQuestion,
  StudySession, Exam, PlannedSession, LinkedTask, LinkedCalendarEvent,
  AcademicMilestone, PastExam, Mistake, SavedResource,
  type ModelClass,
} from "../models/index.ts";

/** Classe de modèle par nom Swift (`table.model` de schema.ts). */
export const registry: Record<string, ModelClass> = {
  AcademicTerm, Course, TheoryItem, ExerciseSeries, Exercise, SubQuestion,
  StudySession, Exam, PlannedSession, LinkedTask, LinkedCalendarEvent,
  AcademicMilestone, PastExam, Mistake, SavedResource,
};
