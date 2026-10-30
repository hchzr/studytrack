// Les énumérations de StudyTrack/Models/Enums.swift (et celles déclarées à côté
// des modèles : SubQuestionKind, GroupRole, RSVPStatus…).
//
// Un type est une union de littéraux — les `rawValue` Swift, à l'identique, parce
// que ce sont eux que la base et le serveur stockent — et une constante de même
// nom porte `allCases`, `fromRaw` (le `init(rawValue:)` Swift, `undefined` si la
// valeur est inconnue) et les propriétés calculées (`label`, `icon`…) sous forme de
// fonctions : `TaskType.label(t)`.
//
// Les couleurs (`tint`, `color`) sont des **noms** de teinte, pas des valeurs : la
// couche d'affichage les traduit.

import { TaskProviderGuide } from "./taskProviderGuide.ts";

export type Tint =
  | "gray" | "blue" | "purple" | "pink" | "teal" | "green" | "orange" | "red"
  | "yellow" | "brown" | "indigo";

function rawEnum<T extends string>(allCases: readonly T[]) {
  const set = new Set<string>(allCases);
  return {
    allCases,
    /** `init(rawValue:)` : `undefined` pour une valeur inconnue. */
    fromRaw: (raw: string | null | undefined): T | undefined =>
      raw != null && set.has(raw) ? (raw as T) : undefined,
  };
}

// MARK: - Type de tâche

/**
 * Ce sur quoi une session a porté. Trois catégories seulement sont choisies à la
 * main (`choices`) ; les anciennes valeurs restent décodables et `canonical` les
 * replie sur la catégorie qui compte.
 */
export type TaskType =
  "lecture" | "video" | "exercise" | "theory" | "flashcards" | "summary" | "correction" | "project" | "other";

export const TaskType = {
  ...rawEnum<TaskType>(["lecture", "video", "exercise", "theory", "flashcards", "summary", "correction", "project", "other"]),

  /** Les seules catégories proposées dans un sélecteur. */
  choices: ["theory", "exercise", "correction", "other"] as readonly TaskType[],

  /** Les catégories d'un bilan, dans l'ordre d'affichage. */
  reportCategories: ["theory", "exercise", "correction", "flashcards", "lecture", "other"] as readonly TaskType[],

  /** La catégorie qui compte : une vidéo ou un résumé, c'est de la théorie. */
  canonical(t: TaskType): TaskType {
    switch (t) {
      case "video": case "summary": case "theory": return "theory";
      case "project": return "other";
      default: return t;
    }
  },

  label(t: TaskType): string {
    switch (TaskType.canonical(t)) {
      case "lecture": return "Cours en amphi";
      case "exercise": return "Séries";
      case "theory": return "Théorie";
      case "flashcards": return "Anki";
      case "correction": return "Correction";
      default: return "Autre";
    }
  },

  shortLabel(t: TaskType): string {
    switch (TaskType.canonical(t)) {
      case "lecture": return "Amphi";
      case "exercise": return "Séries";
      case "theory": return "Théorie";
      case "flashcards": return "Anki";
      case "correction": return "Corr.";
      default: return "Autre";
    }
  },

  icon(t: TaskType): string {
    switch (TaskType.canonical(t)) {
      case "lecture": return "building.columns.fill";
      case "exercise": return "list.number";
      case "theory": return "book.fill";
      case "flashcards": return "rectangle.stack.fill";
      case "correction": return "checkmark.seal.fill";
      default: return "ellipsis.circle.fill";
    }
  },

  /** Une teinte par catégorie, jamais vert / orange / rouge (ils portent un verdict). */
  tint(t: TaskType): Tint {
    switch (TaskType.canonical(t)) {
      case "lecture": return "gray";
      case "exercise": return "blue";
      case "theory": return "purple";
      case "flashcards": return "pink";
      case "correction": return "teal";
      default: return "gray";
    }
  },
};

// MARK: - Niveau de confiance

export type ConfidenceLevel = "green" | "orange" | "red";

/** `high` = "green", `medium` = "orange", `low` = "red" : les noms Swift des cas. */
export const ConfidenceLevel = {
  ...rawEnum<ConfidenceLevel>(["green", "orange", "red"]),
  high: "green" as ConfidenceLevel,
  medium: "orange" as ConfidenceLevel,
  low: "red" as ConfidenceLevel,

  label(c: ConfidenceLevel): string {
    switch (c) {
      case "green": return "Sûr·e";
      case "orange": return "Moyennement sûr·e";
      case "red": return "Pas sûr·e";
    }
  },

  shortLabel(c: ConfidenceLevel): string {
    switch (c) {
      case "green": return "Vert";
      case "orange": return "Orange";
      case "red": return "Rouge";
    }
  },

  color(c: ConfidenceLevel): Tint {
    switch (c) {
      case "green": return "green";
      case "orange": return "orange";
      case "red": return "red";
    }
  },

  icon(_c: ConfidenceLevel): string { return "circle.fill"; },

  /** Glyphe porté par la pastille : la sûreté n'est pas encodée par la couleur seule. */
  glyph(c: ConfidenceLevel): string {
    switch (c) {
      case "green": return "checkmark";
      case "orange": return "equal";
      case "red": return "questionmark";
    }
  },
};

// MARK: - Résultat de correction

export type Correctness = "correct" | "partial" | "wrong";

export const Correctness = {
  ...rawEnum<Correctness>(["correct", "partial", "wrong"]),

  label(c: Correctness): string {
    switch (c) {
      case "correct": return "Juste";
      case "partial": return "Moyennement juste";
      case "wrong": return "Faux";
    }
  },

  shortLabel(c: Correctness): string {
    switch (c) {
      case "correct": return "Juste";
      case "partial": return "Moyen";
      case "wrong": return "Faux";
    }
  },

  color(c: Correctness): Tint {
    switch (c) {
      case "correct": return "green";
      case "partial": return "orange";
      case "wrong": return "red";
    }
  },

  icon(c: Correctness): string {
    switch (c) {
      case "correct": return "checkmark.circle.fill";
      case "partial": return "minus.circle.fill";
      case "wrong": return "xmark.circle.fill";
    }
  },
};

// MARK: - Type d'évaluation

export type ExamKind = "midterm" | "exam" | "quiz" | "project" | "assignment" | "other";

export const ExamKind = {
  ...rawEnum<ExamKind>(["midterm", "exam", "quiz", "project", "assignment", "other"]),

  /**
   * Une vraie épreuve (midterm, examen) : ce qui fait passer le bureau en révision.
   * Un quiz, un devoir ou une échéance importée n'en est pas une.
   */
  isSitting(k: ExamKind): boolean { return k === "midterm" || k === "exam"; },

  label(k: ExamKind): string {
    switch (k) {
      case "midterm": return "Midterm";
      case "exam": return "Examen";
      case "quiz": return "Quiz";
      case "project": return "Projet";
      case "assignment": return "Devoir";
      case "other": return "Autre";
    }
  },

  icon(k: ExamKind): string {
    switch (k) {
      case "midterm": return "clock.badge.exclamationmark.fill";
      case "exam": return "graduationcap.fill";
      case "quiz": return "questionmark.circle.fill";
      case "project": return "hammer.fill";
      case "assignment": return "doc.text.fill";
      case "other": return "calendar.badge.clock";
    }
  },

  color(k: ExamKind): Tint {
    switch (k) {
      case "midterm": return "orange";
      case "exam": return "red";
      case "quiz": return "yellow";
      case "project": return "brown";
      case "assignment": return "blue";
      case "other": return "gray";
    }
  },
};

// MARK: - Semestre

export type TermSeason = "autumn" | "spring";

export const TermSeason = {
  ...rawEnum<TermSeason>(["autumn", "spring"]),

  label(s: TermSeason): string {
    return s === "autumn" ? "Automne" : "Printemps";
  },
};

// MARK: - Support d'un élément de théorie

/**
 * Certains cours EPFL n'ont aucune vidéo, d'autres mélangent vidéos et supports
 * écrits : le support appartient à l'élément, jamais au cours.
 */
export type TheoryKind = "video" | "reading" | "chapter" | "slides";

export const TheoryKind = {
  ...rawEnum<TheoryKind>(["video", "reading", "chapter", "slides"]),

  label(k: TheoryKind): string {
    switch (k) {
      case "video": return "Vidéo";
      case "reading": return "Lecture";
      case "chapter": return "Chapitre";
      case "slides": return "Diapositives";
    }
  },

  /** Au pluriel, pour les en-têtes de section. */
  pluralLabel(k: TheoryKind): string {
    switch (k) {
      case "video": return "Vidéos";
      case "reading": return "Lectures";
      case "chapter": return "Chapitres";
      case "slides": return "Diapositives";
    }
  },

  icon(k: TheoryKind): string {
    switch (k) {
      case "video": return "play.rectangle.fill";
      case "reading": return "book.fill";
      case "chapter": return "doc.text.fill";
      case "slides": return "rectangle.on.rectangle";
    }
  },

  /** Tous les supports sont de la théorie : une seule teinte. */
  tint(_k: TheoryKind): Tint { return TaskType.tint("theory"); },

  /** Une durée a-t-elle un sens pour ce support ? (Un chapitre n'affiche pas « 0 min ».) */
  hasDuration(k: TheoryKind): boolean {
    return k === "video" || k === "slides";
  },
};

// MARK: - Fournisseur de tâches

export type TaskProvider =
  "reminders" | "todoist" | "things" | "notion" | "webhook" | "googleTasks" | "tickTick";

export const TaskProvider = {
  ...rawEnum<TaskProvider>(["reminders", "todoist", "things", "notion", "webhook", "googleTasks", "tickTick"]),
  // Les notices de configuration (extension `TaskProvider` de TaskProviderGuide.swift).
  ...TaskProviderGuide,

  label(p: TaskProvider): string {
    switch (p) {
      case "reminders": return "Rappels";
      case "todoist": return "Todoist";
      case "things": return "Things 3";
      case "notion": return "Notion";
      case "webhook": return "Webhook";
      case "googleTasks": return "Google Tasks";
      case "tickTick": return "TickTick";
    }
  },

  icon(p: TaskProvider): string {
    switch (p) {
      case "reminders": return "checklist";
      case "todoist": return "checkmark.square.fill";
      case "things": return "checkmark.circle";
      case "notion": return "doc.richtext";
      case "webhook": return "bolt.horizontal.circle.fill";
      case "googleTasks": return "checkmark.circle.fill";
      case "tickTick": return "checkmark.seal.fill";
    }
  },

  /**
   * Ce fournisseur permet-il de lire les tâches existantes ? Things 3 n'expose pas
   * d'API de lecture ; le webhook est en écriture seule par construction.
   */
  supportsReading(p: TaskProvider): boolean {
    switch (p) {
      case "reminders": case "todoist": case "notion": case "googleTasks": case "tickTick": return true;
      case "things": case "webhook": return false;
    }
  },

  /** Clé de réglage associée (jeton, URL…). */
  credentialLabel(p: TaskProvider): string | null {
    switch (p) {
      case "reminders": return null;
      case "todoist": return "Jeton API Todoist";
      case "things": return null;
      case "notion": return "Jeton d'intégration Notion";
      case "webhook": return "URL du webhook";
      case "googleTasks": return "Refresh token OAuth Google";
      case "tickTick": return "Jeton d'accès TickTick";
    }
  },

  helpText(p: TaskProvider): string {
    switch (p) {
      case "reminders":
        return "Synchronisation native avec l'app Rappels. Aucun réglage nécessaire.";
      case "todoist":
        return "Créez un jeton dans Todoist › Paramètres › Intégrations › Développeur.";
      case "things":
        return "Things 3 est en écriture seule : l'app peut y envoyer des tâches, mais pas les relire.";
      case "notion":
        return "Créez une intégration Notion, partagez-lui une base de données, puis collez le jeton et l'ID de la base.";
      case "webhook":
        return "StudyTrack envoie un JSON à cette URL (compatible Shortcuts, Home Assistant, Zapier, n8n).";
      case "googleTasks":
        return "Identifiant client, secret et refresh token OAuth : l'app renouvelle ensuite l'accès toute seule.";
      case "tickTick":
        return "Jeton d'accès de l'API ouverte TickTick (OAuth2).";
    }
  },
};

// MARK: - Type d'événement d'agenda

export type CalendarEventKind =
  "lecture" | "exerciseSession" | "midterm" | "exam" | "study" | "personal" | "task" | "other";

export const CalendarEventKind = {
  ...rawEnum<CalendarEventKind>(["lecture", "exerciseSession", "midterm", "exam", "study", "personal", "task", "other"]),

  label(k: CalendarEventKind): string {
    switch (k) {
      case "lecture": return "Cours";
      case "exerciseSession": return "Séance d'exercices";
      case "midterm": return "Midterm";
      case "exam": return "Examen";
      case "study": return "Session d'étude";
      case "personal": return "Personnel";
      case "task": return "Tâche";
      case "other": return "Autre";
    }
  },

  icon(k: CalendarEventKind): string {
    switch (k) {
      case "lecture": return "building.columns.fill";
      case "exerciseSession": return "pencil.and.list.clipboard";
      case "midterm": return "clock.badge.exclamationmark.fill";
      case "exam": return "graduationcap.fill";
      case "study": return "timer";
      case "personal": return "person.fill";
      case "task": return "checklist";
      case "other": return "calendar";
    }
  },

  color(k: CalendarEventKind): Tint {
    switch (k) {
      case "lecture": return "blue";
      case "exerciseSession": return "teal";
      case "midterm": return "orange";
      case "exam": return "red";
      case "study": return "indigo";
      case "personal": return "gray";
      case "task": return "teal";
      case "other": return "gray";
    }
  },
};

// MARK: - Événement d'agenda unifié (calendrier + examens + sessions)

export type AgendaItemKind = "exam" | "calendar" | "planned" | "task" | "milestone";

export const AgendaItemKind = {
  ...rawEnum<AgendaItemKind>(["exam", "calendar", "planned", "task", "milestone"]),

  label(k: AgendaItemKind): string {
    switch (k) {
      case "milestone": return "Calendrier EPFL";
      case "exam": return "Évaluation";
      case "calendar": return "Calendrier";
      case "planned": return "Session planifiée";
      case "task": return "Tâche";
    }
  },
};

// MARK: - Énumérations déclarées à côté des modèles

/** Une question étiquetée (« 1) », « (a) »), ou un travail demandé sans étiquette. */
export type SubQuestionKind = "question" | "part";
export const SubQuestionKind = rawEnum<SubQuestionKind>(["question", "part"]);

/** Nature d'un élément partagé dans un groupe. */
export type GroupItemKind = "exercise" | "theory";
export const GroupItemKind = {
  ...rawEnum<GroupItemKind>(["exercise", "theory"]),
  label(k: GroupItemKind): string { return k === "exercise" ? "exercices" : "théorie"; },
};

/** Rôle d'un membre : les politiques RLS de Supabase utilisent ces deux chaînes. */
export type GroupRole = "admin" | "member";
export const GroupRole = {
  ...rawEnum<GroupRole>(["admin", "member"]),
  label(r: GroupRole): string { return r === "admin" ? "Admin" : "Membre"; },
  icon(r: GroupRole): string { return r === "admin" ? "crown.fill" : "person.fill"; },
};

export type RSVPStatus = "going" | "maybe" | "declined";
export const RSVPStatus = {
  ...rawEnum<RSVPStatus>(["going", "maybe", "declined"]),

  label(s: RSVPStatus): string {
    switch (s) {
      case "going": return "Je participe";
      case "maybe": return "Peut-être";
      case "declined": return "Je ne peux pas";
    }
  },

  icon(s: RSVPStatus): string {
    switch (s) {
      case "going": return "checkmark.circle.fill";
      case "maybe": return "questionmark.circle.fill";
      case "declined": return "xmark.circle.fill";
    }
  },
};

/** `SavedResource.Kind`. */
export type SavedResourceKind = "pdf" | "web" | "poly" | "video" | "file" | "image";
export const SavedResourceKind = {
  ...rawEnum<SavedResourceKind>(["pdf", "web", "poly", "video", "file", "image"]),

  icon(k: SavedResourceKind): string {
    switch (k) {
      case "pdf": return "doc.richtext";
      case "web": return "safari";
      case "poly": return "text.book.closed";
      case "video": return "play.rectangle";
      case "file": return "doc";
      case "image": return "photo";
    }
  },
};

/** `SeriesReview.MistakeKind` (Domain/SeriesReview.swift) : seules les valeurs brutes servent aux modèles. */
export type MistakeKind = "calculation" | "method" | "understanding" | "slip" | "gap" | "time" | "reading";
export const MistakeKind = rawEnum<MistakeKind>(["calculation", "method", "understanding", "slip", "gap", "time", "reading"]);

/** `MilestoneKind` (Domain/AcademicCalendar.swift) : les valeurs brutes, pour `AcademicMilestone.kind`. */
export type MilestoneKind =
  "teachingStart" | "teachingEnd" | "examStart" | "examEnd" | "break" | "holiday"
  | "deadline" | "opening" | "evaluation" | "publication" | "other";
export const MilestoneKind = rawEnum<MilestoneKind>([
  "teachingStart", "teachingEnd", "examStart", "examEnd", "break", "holiday",
  "deadline", "opening", "evaluation", "publication", "other",
]);
