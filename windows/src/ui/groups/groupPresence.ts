// Ma présence dans mes groupes (PresenceService de l'iPhone) : quand mon chrono tourne, mes
// groupes voient « Hugo · MATH-101 · Exercices · 3.2 » ; un battement toutes les cinq minutes
// tant qu'il tourne, effacé dès qu'il s'arrête. Rien sans groupe, ni hors connexion.

import { Groups, PRESENCE_HEARTBEAT_S, type Group } from "../../services/groupsService.ts";
import { TaskType } from "../../models/enums.ts";
import type { FocusTimerState } from "../../domain/focusTimerState.ts";
import { timerController } from "../timerController.ts";

const NAME = "groups.displayName";
const IDS = "groups.ids";

export function readGroupsDisplayName(): string {
  try { return localStorage.getItem(NAME) ?? ""; } catch { return ""; }
}
export function writeGroupsDisplayName(value: string): void {
  try { localStorage.setItem(NAME, value.trim()); } catch { /* pour la session */ }
}

function groupIDs(): string[] {
  try { return JSON.parse(localStorage.getItem(IDS) ?? "[]") as string[]; } catch { return []; }
}

/** Relit mes groupes (et retient leurs identifiants pour la présence). */
export async function refreshMyGroups(): Promise<Group[]> {
  const groups = await Groups.mine();
  try { localStorage.setItem(IDS, JSON.stringify(groups.map((g) => g.id))); } catch { /* idem */ }
  return groups;
}

/**
 * Branche la présence sur le chrono. `courseCode` retrouve le code d'un cours.
 * Rend l'arrêt (efface ma présence s'il y en avait une).
 */
export function startGroupPresence(courseCode: (id: string | undefined) => string, targetLabel: (state: FocusTimerState) => string): () => void {
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let sharing = false;
  let lastKey = "";

  const entry = (state: FocusTimerState) => ({
    courseCode: courseCode(state.courseID), taskLabel: TaskType.label(TaskType.fromRaw(state.taskTypeRaw) ?? "other"),
    target: targetLabel(state), startedAt: state.sessionStartedAt, displayName: readGroupsDisplayName(),
  });

  const update = () => {
    const ids = groupIDs();
    const state = timerController.snapshot().state;
    const running = state !== null && state.runningSince !== undefined;
    if (!running || ids.length === 0) {
      if (heartbeat) clearInterval(heartbeat);
      heartbeat = null;
      lastKey = "";
      if (sharing) { sharing = false; void Groups.publishPresence(null, ids).catch(() => {}); }
      return;
    }
    const current = entry(state);
    const key = [current.courseCode, current.taskLabel, current.target, current.startedAt.getTime()].join("|");
    if (key === lastKey && heartbeat) return;
    lastKey = key;
    sharing = true;
    void Groups.publishPresence(current, ids).catch(() => {});
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = setInterval(() => {
      const now = timerController.snapshot().state;
      if (now) void Groups.publishPresence(entry(now), groupIDs()).catch(() => {});
    }, PRESENCE_HEARTBEAT_S * 1000);
  };

  const off = timerController.subscribe(update);
  update();
  return () => {
    off();
    if (heartbeat) clearInterval(heartbeat);
    if (sharing) void Groups.publishPresence(null, groupIDs()).catch(() => {});
  };
}
