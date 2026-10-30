import { DateUtils } from "../domain/dateUtils.ts";
import { TheoryKind } from "./enums.ts";
import { decodeList, encodeList, type ContentLink } from "./jsonTypes.ts";
import { defineToMany, defineToOne, newId } from "./relations.ts";
import type { Course } from "./course.ts";
import type { LinkedTask } from "./linkedTask.ts";
import type { StudySession } from "./studySession.ts";

export interface TheoryItemInit {
  id?: string;
  course?: Course | null;
  sectionNumber: number;
  number: string;
  title?: string;
  kind?: TheoryKind;
  durationSeconds?: number;
  plannedWeek?: number;
  sortOrder?: number;
  urlString?: string;
}

/**
 * Élément de théorie : « vidéo 1.1 », « chapitre 2.3 », une lecture, des diapos.
 *
 * Tous les cours EPFL ne sont pas filmés : le type de support appartient à l'**élément**,
 * jamais au cours, et rien ne le suppose.
 */
export class TheoryItem {
  static readonly modelName = "TheoryItem";

  id: string;
  declare course: Course | null;
  /** Section (ex : 1 pour les éléments 1.x). */
  sectionNumber: number;
  /** Numéro affiché : « 1.1 ». */
  number: string;
  title: string;
  /** Durée en secondes. `0` = inconnue (fréquent pour une lecture ou un chapitre). */
  durationSeconds: number;
  /** Semaine à laquelle l'élément doit être travaillé (1-based). */
  plannedWeek: number;
  sortOrder: number;

  kindRaw: string;

  /** Date à laquelle l'élément a été fait — vu, lu, parcouru. */
  watchedAt: Date | null = null;
  /** Date du résumé. */
  summarizedAt: Date | null = null;
  summaryText: string | null = null;
  urlString: string;

  /**
   * Nombre de vidéos **dans** l'élément (une section de polycopié en ligne ou une
   * leçon de MOOC en contient souvent plusieurs : c'est la même théorie à travailler).
   */
  videoCount = 0;
  /** Titre du chapitre auquel l'élément appartient (« Suites réelles »). */
  sectionTitle = "";
  /** D'où vient l'élément (`ContentSource.rawValue`), vide s'il a été saisi. */
  sourceRaw = "";
  /** Tous les liens de l'élément (JSON de `ContentLink`) ; `urlString` reste le lien principal. */
  linksRaw = "";

  /** Les sessions et les tâches qui visent cet élément ; supprimer l'élément les laisse sans cible. */
  declare targetedSessions: StudySession[];
  declare targetedTasks: LinkedTask[];

  constructor(o: TheoryItemInit) {
    this.id = o.id ?? newId();
    this.course = o.course ?? null;
    this.sectionNumber = o.sectionNumber;
    this.number = o.number;
    this.title = o.title ?? "";
    this.kindRaw = o.kind ?? "video";
    this.durationSeconds = o.durationSeconds ?? 0;
    this.plannedWeek = o.plannedWeek ?? 1;
    this.sortOrder = o.sortOrder ?? 0;
    this.urlString = o.urlString ?? "";
  }

  get links(): ContentLink[] {
    return decodeList<ContentLink>(this.linksRaw);
  }
  set links(value: ContentLink[]) {
    this.linksRaw = encodeList(value);
  }

  get kind(): TheoryKind {
    return TheoryKind.fromRaw(this.kindRaw) ?? "video";
  }
  set kind(value: TheoryKind) {
    this.kindRaw = value;
  }

  get isWatched(): boolean { return this.watchedAt !== null; }
  get isSummarized(): boolean { return this.summarizedAt !== null; }

  /** Une durée est-elle connue ? Un chapitre sans durée ne doit pas s'afficher « 0 min ». */
  get hasDuration(): boolean { return this.durationSeconds > 0; }

  get durationLabel(): string { return DateUtils.durationLabel(this.durationSeconds); }
  get durationMinutes(): number { return Math.trunc(this.durationSeconds / 60); }

  /**
   * Libellé : « Théorie 1.1 ». Le support (vidéo, lecture…) est une icône, pas une
   * catégorie : tout élément de théorie se nomme de la même façon.
   */
  get displayNumber(): string { return `Théorie ${this.number}`; }

  /** « 1.1 · Introduction », ou le numéro seul. */
  get numberAndTitle(): string { return this.title === "" ? this.number : `${this.number} · ${this.title}`; }
}

defineToOne(TheoryItem, "course", "theoryItems");
defineToMany(TheoryItem, "targetedSessions", "theoryItem");
defineToMany(TheoryItem, "targetedTasks", "video");
