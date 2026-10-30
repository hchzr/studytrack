import type { KeyValueStore } from "./focusTimerState.ts";

/** « Ta session » : les étapes que le bureau propose, dans l'ordre de
 * l'étudiant·e. Par défaut les quatre : revoir le cours, faire la série,
 * bloqué ?, débriefer. Une étape retirée disparaît de tous les appareils.
 */
export type SessionStep = "course" | "series" | "help" | "debrief";

/** Dans l'ordre d'origine (`CaseIterable`). */
export const sessionSteps: SessionStep[] = ["course", "series", "help", "debrief"];

export function stepTitle(step: SessionStep): string {
  switch (step) {
    case "course": return "Revoir le cours";
    case "series": return "Faire la série";
    case "help": return "Bloqué ?";
    case "debrief": return "Débriefer";
  }
}

export interface SessionFlow {
  steps: SessionStep[];
}

export const storageKey = "studyFlow";

/** `SessionFlow.standard` : les quatre étapes. */
export function standardSessionFlow(): SessionFlow {
  return { steps: [...sessionSteps] };
}

export function loadSessionFlow(store: KeyValueStore): SessionFlow {
  const text = store.get(storageKey);
  if (!text) return standardSessionFlow();
  try {
    const data = JSON.parse(text) as { steps?: unknown };
    if (!Array.isArray(data.steps) || data.steps.length === 0
      || !data.steps.every((step) => sessionSteps.includes(step as SessionStep))) {
      return standardSessionFlow();
    }
    return { steps: data.steps as SessionStep[] };
  } catch {
    return standardSessionFlow();
  }
}

export function saveSessionFlow(flow: SessionFlow, store: KeyValueStore): void {
  store.set(storageKey, JSON.stringify(flow));
}

export function flowContains(flow: SessionFlow, step: SessionStep): boolean {
  return flow.steps.includes(step);
}

export function toggleStep(flow: SessionFlow, step: SessionStep): void {
  const index = flow.steps.indexOf(step);
  if (index >= 0) {
    if (flow.steps.length <= 1) return;
    flow.steps.splice(index, 1);
  } else {
    // Remise à sa place d'origine.
    const found = flow.steps.findIndex((other) => sessionSteps.indexOf(other) > sessionSteps.indexOf(step));
    flow.steps.splice(found >= 0 ? found : flow.steps.length, 0, step);
  }
}

export function moveStep(flow: SessionFlow, step: SessionStep, offset: number): void {
  const index = flow.steps.indexOf(step);
  if (index < 0) return;
  const target = Math.min(Math.max(index + offset, 0), flow.steps.length - 1);
  flow.steps.splice(index, 1);
  flow.steps.splice(target, 0, step);
}

// MARK: - Raccourcis du chrono (StudyTrack/Domain/FocusShortcut.swift)

/** Un raccourci du chrono : « CS-250 · Exercices », lancé d'un tap.
 *
 * Les raccourcis étaient une grille fixe de **tous** les cours suivis croisés avec
 * trois types de travail. Ils deviennent une liste que l'étudiant·e compose.
 * `taskTypeRaw` est la valeur brute du `TaskType` (« video », « exercise »…).
 */
export interface FocusShortcut {
  courseCode: string;
  taskTypeRaw: string;
}

export function focusShortcutId(shortcut: FocusShortcut): string {
  return `${shortcut.courseCode}|${shortcut.taskTypeRaw}`;
}

export const FocusShortcutDefaults = {
  maxDefaults: 6,

  /** Une liste par défaut à partir des codes de cours suivis.
   *
   * Les types sont choisis dans l'ordre où ils servent réellement : on regarde
   * une vidéo, puis on fait les exercices, puis on les corrige.
   */
  make(courseCodes: string[], types: string[] = ["video", "exercise"]): FocusShortcut[] {
    const result: FocusShortcut[] = [];
    for (const code of courseCodes) {
      for (const type of types) {
        result.push({ courseCode: code, taskTypeRaw: type });
        if (result.length >= FocusShortcutDefaults.maxDefaults) return result;
      }
    }
    return result;
  },

  /** Nettoie une liste : sans doublon, sans cours disparu, dans l'ordre donné.
   *
   * Un cours supprimé ne doit pas laisser une tuile qui ne mène nulle part.
   */
  sanitize(shortcuts: FocusShortcut[], knownCourses: Set<string>): FocusShortcut[] {
    const seen = new Set<string>();
    return shortcuts.filter((shortcut) => {
      if (!knownCourses.has(shortcut.courseCode)) return false;
      const id = focusShortcutId(shortcut);
      if (seen.has(id)) return false;
      seen.add(id);
      return true;
    });
  },

  decode(raw: string): FocusShortcut[] {
    try {
      const data = JSON.parse(raw);
      if (!Array.isArray(data)) return [];
      if (!data.every((item) => typeof item?.courseCode === "string" && typeof item?.taskTypeRaw === "string")) return [];
      return data.map((item) => ({ courseCode: item.courseCode, taskTypeRaw: item.taskTypeRaw }));
    } catch {
      return [];
    }
  },

  encode(shortcuts: FocusShortcut[]): string {
    return JSON.stringify(shortcuts);
  },
};
