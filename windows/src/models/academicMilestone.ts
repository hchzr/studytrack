import { DateUtils } from "../domain/dateUtils.ts";
import { EPFLCalendarSnapshot } from "../domain/epflCalendarSnapshot.ts";
import { MilestoneKind } from "./enums.ts";
import { newId } from "./relations.ts";
import type { ModelStore } from "./store.ts";

/** `Institution.epfl.calendarURL`, la source par défaut d'une échéance. */
export const epflCalendarURL = "https://www.epfl.ch/education/studies/reglement-et-procedure/calendrier-academique/";

/** Une échéance du calendrier académique, indépendante de la persistance (`AcademicMilestoneValue`). */
export interface AcademicMilestoneValue {
  id: string;
  title: string;
  date: Date;
  kind: MilestoneKind;
  /** Mise en évidence par l'EPFL lui-même. */
  isImportant: boolean;
  /** Date approximative : « Fin décembre », « Mi-novembre ». */
  isApproximate: boolean;
  termLabel: string;
  sourceURL: string;
}

/** « dans 12 j », « aujourd'hui », « il y a 3 j » (`AcademicMilestoneValue.countdown`). */
export function milestoneCountdown(date: Date, reference: Date = new Date()): string {
  const days = DateUtils.daysBetween(reference, date);
  if (days === 0) return "aujourd'hui";
  if (days === 1) return "demain";
  if (days > 1) return `dans ${days} j`;
  if (days === -1) return "hier";
  return `il y a ${-days} j`;
}

export interface AcademicMilestoneInit {
  id?: string;
  externalID: string;
  title: string;
  date: Date;
  kind: MilestoneKind;
  isImportant?: boolean;
  isApproximate?: boolean;
  termLabel?: string;
  isOfficial?: boolean;
  notes?: string;
  confirmedAt?: Date;
}

/**
 * Une échéance de la vie de l'EPFL : borne de semestre, vacances, délai administratif,
 * session d'examens, publication officielle. Les cours disent ce qu'on étudie ; ceci dit
 * **quand** l'école vit.
 */
export class AcademicMilestone {
  static readonly modelName = "AcademicMilestone";

  id: string;
  /**
   * Clé stable : celle du parseur pour une échéance officielle, un identifiant local pour
   * une échéance ajoutée à la main. Elle permet de **mettre à jour** au lieu de dupliquer.
   */
  externalID: string;
  title: string;
  date: Date;
  kindRaw: string;
  isImportant: boolean;
  /** Date approximative : l'app le dit à l'écran au lieu de la faire passer pour exacte. */
  isApproximate: boolean;
  termLabel: string;
  /** Vrai si l'échéance vient de l'EPFL, faux si l'étudiant·e l'a ajoutée. */
  isOfficial: boolean;
  notes: string;
  addedAt: Date;
  /** Date de dernière confirmation par la source. */
  confirmedAt: Date;

  constructor(o: AcademicMilestoneInit) {
    this.id = o.id ?? newId();
    this.externalID = o.externalID;
    this.title = o.title;
    this.date = o.date;
    this.kindRaw = o.kind;
    this.isImportant = o.isImportant ?? false;
    this.isApproximate = o.isApproximate ?? false;
    this.termLabel = o.termLabel ?? "";
    this.isOfficial = o.isOfficial ?? true;
    this.notes = o.notes ?? "";
    this.addedAt = new Date();
    this.confirmedAt = o.confirmedAt ?? new Date();
  }

  get kind(): MilestoneKind {
    return MilestoneKind.fromRaw(this.kindRaw) ?? "other";
  }
  set kind(value: MilestoneKind) {
    this.kindRaw = value;
  }

  get value(): AcademicMilestoneValue {
    return {
      id: this.externalID,
      title: this.title,
      date: this.date,
      kind: this.kind,
      isImportant: this.isImportant,
      isApproximate: this.isApproximate,
      termLabel: this.termLabel,
      sourceURL: epflCalendarURL,
    };
  }

  get isPast(): boolean { return this.date.getTime() < Date.now(); }

  /** « dans 12 j », « aujourd'hui » — avec la mention d'approximation. */
  countdown(reference: Date = new Date()): string {
    const base = milestoneCountdown(this.date, reference);
    return this.isApproximate ? `vers le ${DateUtils.shortDay(this.date)}` : base;
  }

  /**
   * Installe l'instantané embarqué si l'app ne connaît encore aucune échéance. Au niveau
   * du modèle et non du service : la réparation de données doit pouvoir l'appeler sans
   * dépendre du réseau.
   */
  static installSnapshotIfNeeded(store: ModelStore): number {
    if (store.fetchCount(AcademicMilestone) !== 0) return 0;
    const values = EPFLCalendarSnapshot.milestones();
    AcademicMilestone.upsert(values, store);
    return values.length;
  }

  static upsert(
    values: AcademicMilestoneValue[],
    store: ModelStore,
    official = true,
  ): { added: number; updated: number; removed: number } {
    const existing = store.fetch(AcademicMilestone);
    const byKey = new Map<string, AcademicMilestone>();
    for (const m of existing) if (!byKey.has(m.externalID)) byKey.set(m.externalID, m);
    let added = 0;
    let updated = 0;
    const now = new Date();

    for (const value of values) {
      const match = byKey.get(value.id);
      if (match) {
        if (match.date.getTime() !== value.date.getTime()
          || match.title !== value.title
          || match.kindRaw !== value.kind
          || match.isImportant !== value.isImportant) {
          updated += 1;
        }
        match.title = value.title;
        match.date = value.date;
        match.kind = value.kind;
        match.isImportant = value.isImportant;
        match.isApproximate = value.isApproximate;
        match.termLabel = value.termLabel;
        match.confirmedAt = now;
        match.isOfficial = official;
      } else {
        const created = new AcademicMilestone({
          externalID: value.id,
          title: value.title,
          date: value.date,
          kind: value.kind,
          isImportant: value.isImportant,
          isApproximate: value.isApproximate,
          termLabel: value.termLabel,
          isOfficial: official,
          confirmedAt: now,
        });
        store.insert(created);
        byKey.set(value.id, created);
        added += 1;
      }
    }

    // Une échéance officielle **à venir** qui n'est plus publiée a été corrigée ou retirée
    // par l'EPFL. La garder ferait croire à une date qui n'existe plus ; les échéances
    // passées, elles, restent comme historique.
    let removed = 0;
    if (official) {
      const fresh = new Set(values.map((v) => v.id));
      for (const milestone of existing) {
        if (milestone.isOfficial && !fresh.has(milestone.externalID) && milestone.date.getTime() > now.getTime()) {
          store.delete(milestone);
          removed += 1;
        }
      }
    }
    return { added, updated, removed };
  }
}
