// Réparations de données, nommées et jouées une seule fois par version
// (`DataRepair`, PolymestreSchema.swift).
//
// Ce ne sont pas des migrations — le schéma est déjà à jour — mais des corrections de
// **contenu** rendues nécessaires par un défaut passé. Les nommer permet de dire ce qui a
// été fait, et de ne pas le refaire.

import { AcademicMilestone } from "./academicMilestone.ts";
import { AcademicTerm } from "./academicTerm.ts";
import { ExerciseSeries } from "./exercise.ts";
import { Plural } from "../domain/plural.ts";
import type { ModelStore } from "./store.ts";

/** Version du schéma (`PolymestreSchema.currentVersion`). */
export const schemaCurrentVersion = 1;
export const schemaVersionKey = "schema.version";

/** Ce que les réglages (`UserDefaults`) doivent offrir aux réparations. */
export interface RepairDefaults {
  integer(key: string): number;
  set(key: string, value: number): void;
}

/** Un `RepairDefaults` en mémoire, pour les tests et l'amorçage. */
export function memoryDefaults(initial: Record<string, number> = {}): RepairDefaults {
  const values = new Map(Object.entries(initial));
  return {
    integer: (key) => values.get(key) ?? 0,
    set: (key, value) => { values.set(key, value); },
  };
}

export interface RepairOutcome {
  coursesAttached: number;
  milestonesInstalled: number;
  bonusCleared: number;
  summary: string;
}

export const DataRepair = {
  /**
   * Augmente quand une réparation s'ajoute : elle est alors jouée une fois.
   */
  repairVersion: 3,
  repairKey: "dataRepair.version",

  outcomeSummary(o: { coursesAttached: number; milestonesInstalled: number; bonusCleared: number }): string {
    const parts: string[] = [];
    if (o.coursesAttached > 0) {
      parts.push(`${Plural.count(o.coursesAttached, `${o.coursesAttached} cours rattaché`, `${o.coursesAttached} cours rattachés`)} à leur semestre`);
    }
    if (o.milestonesInstalled > 0) {
      parts.push(`${o.milestonesInstalled} échéances de l'EPFL installées`);
    }
    if (o.bonusCleared > 0) {
      parts.push(`${o.bonusCleared} exercices remis au programme`);
    }
    return parts.join(" · ");
  },

  /**
   * Applique les réparations connues, puis marque la version comme faite. Idempotent par
   * construction : chaque étape ne touche que ce qui est cassé. Le marqueur évite
   * simplement de relire toute la base à chaque lancement.
   */
  run(store: ModelStore, defaults: RepairDefaults): RepairOutcome {
    const outcome = { coursesAttached: 0, milestonesInstalled: 0, bonusCleared: 0 };
    const finish = (): RepairOutcome => ({ ...outcome, summary: DataRepair.outcomeSummary(outcome) });
    // Le marqueur arrête **vraiment** les réparations.
    if (!(defaults.integer(DataRepair.repairKey) < DataRepair.repairVersion)) return finish();

    // Les cours importés avant la correction n'ont aucun semestre : ils affichaient
    // « semaine 1 » en pleine semaine 2.
    outcome.coursesAttached = AcademicTerm.attachOrphanCourses(store);

    // Le calendrier académique doit être là hors ligne, dès l'installation.
    outcome.milestonesInstalled = AcademicMilestone.installSnapshotIfNeeded(store);

    // Une série lue tout en « bonus » (une note de page prise pour une mention) : la même
    // règle que l'import d'aujourd'hui (`DetectedSeries.withoutBlanketBonus`).
    outcome.bonusCleared = DataRepair.clearBlanketBonus(store);

    defaults.set(schemaVersionKey, schemaCurrentVersion);
    defaults.set(DataRepair.repairKey, DataRepair.repairVersion);
    store.save();
    return finish();
  },

  clearBlanketBonus(store: ModelStore): number {
    let cleared = 0;
    for (const series of store.fetch(ExerciseSeries)) {
      if (series.exercises.length >= 3 && series.exercises.every((e) => e.isBonus)) {
        for (const exercise of series.exercises) exercise.isBonus = false;
        cleared += series.exercises.length;
      }
    }
    return cleared;
  },
};
