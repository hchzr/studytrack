import { DateUtils } from "../domain/dateUtils.ts";
import { TermSeason } from "./enums.ts";
import { defineToMany, newId } from "./relations.ts";
import type { ModelStore } from "./store.ts";
import { Course } from "./course.ts";

export interface AcademicTermInit {
  id?: string;
  year: number;
  season: TermSeason;
  startDate: Date;
  endDate: Date;
  totalWeeks?: number;
  name?: string;
}

/** Semestre académique EPFL (automne / printemps). */
export class AcademicTerm {
  static readonly modelName = "AcademicTerm";

  id: string;
  year: number;
  seasonRaw: string;
  /** Lundi de la semaine 1. */
  startDate: Date;
  endDate: Date;
  totalWeeks: number;
  name: string;

  /** Les cours du semestre. Inverse de `Course.term`. */
  declare courses: Course[];

  constructor(o: AcademicTermInit) {
    this.id = o.id ?? newId();
    this.year = o.year;
    this.seasonRaw = o.season;
    this.startDate = o.startDate;
    this.endDate = o.endDate;
    this.totalWeeks = o.totalWeeks ?? 14;
    this.name = o.name ?? "";
  }

  get season(): TermSeason {
    return TermSeason.fromRaw(this.seasonRaw) ?? "spring";
  }
  set season(value: TermSeason) {
    this.seasonRaw = value;
  }

  /** Libellé court : « Printemps 2025 ». */
  get displayName(): string {
    return this.name === "" ? `${TermSeason.label(this.season)} ${this.year}` : this.name;
  }

  // MARK: État temporel

  get hasStarted(): boolean { return Date.now() >= this.startDate.getTime(); }
  get hasEnded(): boolean { return Date.now() > this.endDate.getTime(); }
  /** Le semestre est en cours aujourd'hui. */
  get isRunning(): boolean { return this.hasStarted && !this.hasEnded; }
  get hasNotStarted(): boolean { return Date.now() < this.startDate.getTime(); }

  /** Progression temporelle du semestre, 0…1. */
  get timeProgress(): number {
    const total = this.endDate.getTime() - this.startDate.getTime();
    if (!(total > 0)) return 0;
    const elapsed = Date.now() - this.startDate.getTime();
    return Math.min(1, Math.max(0, elapsed / total));
  }

  /** Semaine courante bornée à `1...totalWeeks`. */
  get currentWeek(): number {
    return DateUtils.clampedWeek(new Date(), this);
  }

  /** État lisible pour l'interface. */
  get statusLabel(): string {
    if (this.hasEnded) return "Terminé";
    if (this.hasNotStarted) return "À venir";
    return `Semaine ${this.currentWeek} / ${this.totalWeeks}`;
  }

  // MARK: Résolution

  /**
   * Choisit le semestre à afficher : celui qui contient la date du jour, sinon le
   * plus proche (le prochain à venir, ou le dernier terminé).
   */
  static resolve(terms: AcademicTerm[], reference: Date = new Date()): AcademicTerm | null {
    if (terms.length === 0) return null;
    const running = terms.find((t) => t.isRunning);
    if (running) return running;

    const upcoming = terms
      .filter((t) => t.startDate.getTime() > reference.getTime())
      .reduce<AcademicTerm | null>((best, t) => (best === null || t.startDate < best.startDate ? t : best), null);
    if (upcoming) return upcoming;

    return terms.reduce((best, t) => (t.endDate > best.endDate ? t : best));
  }

  /** Semestres triés du plus récent au plus ancien. */
  static sorted(terms: AcademicTerm[]): AcademicTerm[] {
    return [...terms].sort((a, b) => b.startDate.getTime() - a.startDate.getTime());
  }

  // MARK: Rattachement des cours

  /**
   * Le semestre auquel rattacher un cours qui n'en a pas : celui en cours, sinon le
   * plus récent, sinon celui qu'on crée d'après le calendrier EPFL. Un cours sans
   * semestre affiche « semaine 1 » sur tous les écrans — c'est faux, et rien ne le
   * signalait.
   */
  static current(store: ModelStore, reference: Date = new Date()): AcademicTerm {
    const terms = store.fetch(AcademicTerm);
    const running = terms.find((t) => t.isRunning);
    if (running) return running;
    const latest = terms.reduce<AcademicTerm | null>((best, t) => (best === null || t.startDate > best.startDate ? t : best), null);
    if (latest) return latest;

    const start = DateUtils.currentAutumnOrSpringStart(reference);
    const monday = DateUtils.startOfWeek(start.start);
    const term = new AcademicTerm({
      year: monday.getFullYear(),
      season: start.season,
      startDate: monday,
      endDate: DateUtils.addTeachingWeeks(start.weeks, monday),
      totalWeeks: start.weeks,
    });
    store.insert(term);
    return term;
  }

  /**
   * Rattache au semestre courant les cours qui n'en ont aucun, et remet d'aplomb la
   * semaine de leurs séries.
   *
   * Réparation, pas fonctionnalité : les cours créés par l'import d'horaire
   * étaient enregistrés avec `term: nil`, donc affichés en « semaine 1 » quel que
   * soit le jour. L'import PDF d'une série prend `course.currentWeek` comme semaine
   * planifiée — il écrivait « Semaine 1 » pour toutes les séries.
   *
   * La correction des séries reste **bornée** : uniquement les cours réparés ici,
   * uniquement une série encore à la semaine 1, et uniquement si son numéro désigne
   * une autre semaine. Aucune donnée choisie par l'étudiant·e n'est touchée.
   * Idempotent.
   */
  static attachOrphanCourses(store: ModelStore, reference: Date = new Date()): number {
    const orphans = store.fetch(Course).filter((c) => c.term === null);
    if (orphans.length === 0) return 0;
    const term = AcademicTerm.current(store, reference);
    for (const course of orphans) {
      course.term = term;
      for (const series of course.series) {
        if (series.plannedWeek === 1 && series.seriesNumber > 1) series.plannedWeek = series.seriesNumber;
      }
    }
    store.save();
    return orphans.length;
  }
}

defineToMany(AcademicTerm, "courses", "term");
