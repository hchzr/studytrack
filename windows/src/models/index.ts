// Les modèles de Polymestre (Polymestre/Models/*.swift) en TypeScript.
// Le schéma synchronisé (champs, règles de suppression) est décrit à part par schema.ts.

export * from "./enums.ts";
export * from "./relations.ts";
export * from "./store.ts";
export * from "./jsonTypes.ts";
export * from "./hooks.ts";
export { AcademicTerm, type AcademicTermInit } from "./academicTerm.ts";
export {
  AcademicMilestone, milestoneCountdown, epflCalendarURL,
  type AcademicMilestoneInit, type AcademicMilestoneValue,
} from "./academicMilestone.ts";
export { Course, type CourseInit } from "./course.ts";
export {
  ExerciseSeries, Exercise, SubQuestion,
  type ExerciseSeriesInit, type ExerciseInit, type SubQuestionInit,
  type DetectedSubQuestionData, type HintEntry,
} from "./exercise.ts";
export { Exam, type ExamInit } from "./exam.ts";
export { TheoryItem, type TheoryItemInit } from "./theoryItem.ts";
export { StudySession, type StudySessionInit } from "./studySession.ts";
export { PlannedSession, type PlannedSessionInit } from "./plannedSession.ts";
export { LinkedTask, type LinkedTaskInit } from "./linkedTask.ts";
export { LinkedCalendarEvent, type LinkedCalendarEventInit } from "./linkedCalendarEvent.ts";
export { PastExam, PastExamProgress, type PastExamInit, type PastExamEntry, type PastExamSummary } from "./pastExam.ts";
export { Mistake, type MistakeInit } from "./mistake.ts";
export { SavedResource, type SavedResourceInit } from "./savedResource.ts";
export { RelayBeacon } from "./relayBeacon.ts";
export {
  StudyGroup, GroupMember, GroupSeriesCompletion, GroupDemoData,
  type StudyGroupInit, type GroupMemberInit, type GroupSeriesCompletionInit,
} from "./studyGroup.ts";
export { GroupItemCompletion, type GroupItemCompletionInit } from "./groupItemCompletion.ts";
export { EPFLCatalog, type EPFLSection } from "./epflCatalog.ts";
export { TaskProviderGuide } from "./taskProviderGuide.ts";
export { SeedData, type SeedSettings } from "./seedData.ts";
export {
  DataRepair, memoryDefaults, schemaCurrentVersion, schemaVersionKey,
  type RepairDefaults, type RepairOutcome,
} from "./dataRepair.ts";
