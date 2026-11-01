// Le chrono tel que l'écran Focus le lit : une vue sur le contrôleur partagé
// (`timerController`), un battement d'horloge pour l'affichage, et l'écriture
// des sessions branchée dès que les données sont ouvertes.
//
// Toute la logique vit dans src/ui/timerController.ts — un seul chrono pour
// l'écran Chrono, le mode étude et les sorties.

import { useEffect, useState, useSyncExternalStore } from "react";
import { useData } from "../../../data/dataContext.tsx";
import type { TaskType } from "../../../models/enums.ts";
import { cycleOr, elapsed, taskType as stateTaskType, type FocusTimerState } from "../../../domain/focusTimerState.ts";
import type { FocusPhase, PomodoroSettings } from "../../../domain/pomodoroEngine.ts";
import { phaseOf } from "./timerView.ts";
import {
  timerController,
  type FocusDraft,
  type FocusRecap,
} from "../../timerController.ts";

export type { FocusDraft, FocusRecap, FocusRecapPart } from "../../timerController.ts";

export interface FocusTimerApi {
  state: FocusTimerState | null;
  now: Date;
  settings: typeof timerController.settings;
  phase: FocusPhase;
  /** Les durées du cycle en vigueur : celles de la session ouverte, sinon du poste. */
  cycle: PomodoroSettings;
  draft: FocusDraft;
  courseID?: string;
  taskType: TaskType;
  targetID?: string;
  pomodoro: boolean;
  recap: FocusRecap | null;
  /** Secondes comptées à l'instant affiché. */
  elapsedNow: number;
  chooseCourse(courseID: string | undefined): void;
  chooseTaskType(taskType: TaskType): void;
  chooseTarget(targetID: string | undefined): void;
  setPomodoro(enabled: boolean): void;
  start(): void;
  toggle(): void;
  pause(): void;
  resume(): void;
  skipBreak(): void;
  finish(): Promise<void>;
  discard(): void;
  retarget(courseID: string | undefined, taskType: TaskType, targetID?: string): void;
  dismissRecap(): void;
  undoRecap(): Promise<void>;
}

export function useFocusTimer(): FocusTimerApi {
  const { store, save, remove } = useData();
  const snap = useSyncExternalStore(timerController.subscribe, timerController.snapshot);

  // L'horloge d'affichage : un peu plus fine que la seconde, pour qu'elle
  // change à la seconde et non jusqu'à une seconde en retard.
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const id = window.setInterval(() => setNow(new Date()), 250);
    return () => window.clearInterval(id);
  }, []);

  // Les sessions s'écrivent par la source de données de l'app, dès qu'elle existe.
  useEffect(() => {
    if (store) timerController.attach({ store, save, remove });
  }, [store, save, remove]);

  const state = snap.state;
  const draft = snap.draft;
  return {
    state,
    now,
    settings: snap.settings,
    phase: state ? phaseOf(state, snap.settings.cycle, now) : { type: "idle" },
    cycle: state ? cycleOr(state, snap.settings.cycle) : snap.settings.cycle,
    draft,
    courseID: state ? state.courseID : draft.courseID,
    taskType: state ? stateTaskType(state) : draft.taskType,
    targetID: state ? state.targetID : draft.targetID,
    pomodoro: state ? state.pomodoro : draft.pomodoro,
    recap: snap.recap,
    elapsedNow: state ? elapsed(state, now) : 0,
    chooseCourse: (courseID) => timerController.chooseCourse(courseID),
    chooseTaskType: (taskType) => timerController.chooseTaskType(taskType),
    chooseTarget: (targetID) => timerController.chooseTarget(targetID),
    setPomodoro: (enabled) => timerController.setPomodoro(enabled),
    start: () => timerController.start(),
    toggle: () => timerController.toggle(),
    pause: () => timerController.pause(),
    resume: () => timerController.resume(),
    skipBreak: () => timerController.skipBreak(),
    finish: () => timerController.finish(),
    discard: () => timerController.discard(),
    retarget: (courseID, taskType, targetID) => timerController.retarget(courseID, taskType, targetID),
    dismissRecap: () => timerController.dismissRecap(),
    undoRecap: () => timerController.undoRecap(),
  };
}
