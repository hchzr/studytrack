import { DateUtils } from "../domain/dateUtils.ts";
import { ConfidenceLevel, ExamKind } from "./enums.ts";
import { defineToOne, newId } from "./relations.ts";
import { makeURL, trimAll } from "./util.ts";
import type { Course } from "./course.ts";

export interface PastExamInit {
  id?: string;
  course?: Course | null;
  title?: string;
  year?: number;
  kind?: ExamKind;
  urlString?: string;
  solutionURLString?: string;
  confidence?: ConfidenceLevel | null;
  workedAt?: Date | null;
  notes?: string;
}

/**
 * Un sujet d'examen passé : l'annale. Une évaluation se prépare, une annale se travaille.
 * Pas de note : ce qui est consigné, c'est **quand** le sujet a été travaillé, avec quelle
 * sureté, et ce qu'on en retient.
 */
export class PastExam {
  static readonly modelName = "PastExam";

  id: string;
  declare course: Course | null;
  title: string;
  /** Année de la session. */
  year: number;
  /** `ExamKind.rawValue` — examen, midterm, quiz… */
  kindRaw: string;
  urlString: string;
  solutionURLString: string;
  /** `ConfidenceLevel.rawValue` — vert / orange / rouge, comme partout ailleurs. */
  confidenceRaw: string | null;
  /** Date à laquelle le sujet a été travaillé. `null` = pas encore fait. */
  workedAt: Date | null;
  notes: string;
  addedAt: Date;

  constructor(o: PastExamInit = {}) {
    const kind = o.kind ?? "exam";
    const year = o.year ?? new Date().getFullYear();
    this.id = o.id ?? newId();
    this.course = o.course ?? null;
    this.title = (o.title ?? "") === "" ? `${ExamKind.label(kind)} ${year}` : o.title!;
    this.year = year;
    this.kindRaw = kind;
    this.urlString = o.urlString ?? "";
    this.solutionURLString = o.solutionURLString ?? "";
    this.confidenceRaw = o.confidence ?? null;
    this.workedAt = o.workedAt ?? null;
    this.notes = o.notes ?? "";
    this.addedAt = new Date();
  }

  get kind(): ExamKind {
    return ExamKind.fromRaw(this.kindRaw) ?? "exam";
  }
  set kind(value: ExamKind) {
    this.kindRaw = value;
  }

  get confidence(): ConfidenceLevel | null {
    return (this.confidenceRaw !== null ? ConfidenceLevel.fromRaw(this.confidenceRaw) : undefined) ?? null;
  }
  set confidence(value: ConfidenceLevel | null) {
    this.confidenceRaw = value;
  }

  get isWorked(): boolean { return this.workedAt !== null; }

  /** Raccourci pour ouvrir le sujet, s'il y en a un. */
  get url(): URL | null {
    const trimmed = trimAll(this.urlString);
    return trimmed === "" ? null : makeURL(trimmed);
  }

  get solutionURL(): URL | null {
    const trimmed = trimAll(this.solutionURLString);
    return trimmed === "" ? null : makeURL(trimmed);
  }

  /** « Travaillé le 12 mars · vert ». */
  get statusLabel(): string {
    if (this.workedAt === null) return "Pas encore travaillé";
    const parts = [`Travaillé le ${DateUtils.shortDay(this.workedAt)}`];
    const confidence = this.confidence;
    if (confidence) parts.push(ConfidenceLevel.label(confidence));
    return parts.join(" · ");
  }
}

defineToOne(PastExam, "course", "pastExams");

/**
 * Ce que les annales d'un cours disent de la préparation. Fonction **pure** sur des
 * valeurs : la règle « reste-t-il des sujets à travailler, et lesquels » se teste sans base.
 */
export interface PastExamEntry {
  year: number;
  worked: boolean;
}

export interface PastExamSummary {
  total: number;
  worked: number;
  /** Les sujets jamais travaillés, du plus récent au plus ancien. */
  pendingYears: number[];
  readonly isComplete: boolean;
  readonly ratio: number;
  readonly label: string;
}

export const PastExamProgress = {
  /** Le bilan, à partir des couples (année, travaillée). */
  summary(entries: PastExamEntry[]): PastExamSummary {
    const worked = entries.filter((e) => e.worked).length;
    const pending = entries.filter((e) => !e.worked).map((e) => e.year).sort((a, b) => b - a);
    return {
      total: entries.length,
      worked,
      pendingYears: pending,
      get isComplete() { return this.total > 0 && this.worked === this.total; },
      get ratio() { return this.total === 0 ? 0 : this.worked / this.total; },
      get label() {
        if (this.total <= 0) return "Aucune annale";
        if (this.isComplete) return `${this.total}/${this.total} travaillées`;
        return `${this.worked}/${this.total} travaillées`;
      },
    };
  },

  /**
   * Les sujets à travailler en priorité : les plus **récents** d'abord (le programme
   * change peu d'une année à l'autre, mais il change).
   */
  priority(entries: PastExamEntry[], limit = 3): number[] {
    return entries.filter((e) => !e.worked).map((e) => e.year).sort((a, b) => b - a).slice(0, limit);
  },
};
