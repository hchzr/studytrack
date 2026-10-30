import { MistakeKind } from "./enums.ts";
import { defineToOne, newId } from "./relations.ts";
import type { Exercise } from "./exercise.ts";

export interface MistakeInit {
  exercise: Exercise | null;
  kind: MistakeKind;
  summary: string;
  correction?: string;
  notion?: string;
  source?: string;
  createdAt?: Date;
}

/**
 * Une erreur du carnet : ce qui s'est mal passé sur un exercice, assez précis pour être
 * reconnu la prochaine fois. Toute erreur devient une ligne, même une étourderie : c'est
 * la récurrence des types qui dit quoi travailler.
 */
export class Mistake {
  static readonly modelName = "Mistake";

  id = newId();
  declare exercise: Exercise | null;
  createdAt: Date;
  summary: string;
  /** `SeriesReview.MistakeKind.rawValue`. */
  kindRaw: string;
  /** La bonne démarche, en une ou deux phrases. */
  correction: string;
  /** La notion en jeu (« continuité », « critère de d'Alembert »). */
  notion: string;
  /** « claude » ou « manual ». */
  source: string;

  constructor(o: MistakeInit) {
    this.exercise = o.exercise;
    this.kindRaw = o.kind;
    this.summary = o.summary;
    this.correction = o.correction ?? "";
    this.notion = o.notion ?? "";
    this.source = o.source ?? "manual";
    this.createdAt = o.createdAt ?? new Date();
  }

  get kind(): MistakeKind {
    return MistakeKind.fromRaw(this.kindRaw) ?? "method";
  }
  set kind(value: MistakeKind) {
    this.kindRaw = value;
  }
}

defineToOne(Mistake, "exercise", "mistakesStore");
