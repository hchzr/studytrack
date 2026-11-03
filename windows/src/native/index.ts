// Branche la couche native sur le chrono de l'app : veille, blocage d'étude,
// chrono flottant. Hors Tauri (navigateur, tests) : rien ne se passe.

import type { Course } from "../models/course.ts";
import { StudyMode } from "../domain/studyMode.ts";
import { timerController } from "../ui/timerController.ts";
import { startKeepAwake } from "./keepAwake.ts";
import { startMiniBridge } from "./miniBridge.ts";
import { readKeepAwakeMode } from "./settings.ts";
import { startStudyLock } from "./studyLock.ts";
import { inNative } from "./tauri.ts";

/** Montre la fenêtre principale (clic « ouvrir » du chrono flottant). */
async function openMain(): Promise<void> {
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  const win = getCurrentWindow();
  await win.show();
  await win.unminimize();
  await win.setFocus();
}

export async function startNative(courseOf: (id: string | undefined) => Course | null): Promise<() => void> {
  if (!inNative()) return () => {};
  const ctl = timerController;
  const stops: Array<() => void> = [];

  stops.push(startKeepAwake(
    {
      subscribe: ctl.subscribe,
      source: () => {
        const phase = ctl.phase();
        const state = ctl.snapshot().state;
        return {
          studying: ctl.isStudying,
          running: phase.type === "working",
          onBreak: phase.type === "onBreak",
          until: state && !StudyMode.isOpenEnded(state) ? state.studyUntil ?? null : null,
        };
      },
    },
    readKeepAwakeMode,
  ));

  stops.push(startStudyLock(
    {
      subscribe: ctl.subscribe,
      blocks: () => ctl.studyLocks,
      until: () => {
        const state = ctl.snapshot().state;
        return state && !StudyMode.isOpenEnded(state) ? state.studyUntil ?? null : null;
      },
    },
  ));

  stops.push(await startMiniBridge({
    timer: ctl,
    courseOf,
    openMain: () => void openMain(),
  }));

  return () => stops.forEach((stop) => stop());
}
