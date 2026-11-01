// Le chrono tel que le mode étude le lit : une vue sur le contrôleur partagé
// (`timerController`), un battement d'horloge de 250 ms pour l'affichage, et
// l'écriture des sessions branchée dès que les données sont ouvertes — comme
// `useFocusTimer` pour l'écran Chrono. Toute la logique vit dans
// src/ui/timerController.ts : un seul chrono pour toute la fenêtre.

import { useEffect, useState, useSyncExternalStore } from "react";
import { useData } from "../../data/dataContext.tsx";
import type { TaskType } from "../../models/enums.ts";
import { taskType as stateTaskType, type FocusTimerState } from "../../domain/focusTimerState.ts";
import type { FocusPhase, PomodoroSettings } from "../../domain/pomodoroEngine.ts";
import { timerController, type TimerSnapshot } from "../timerController.ts";

export interface StudyTimerApi {
  /** L'état publié par le contrôleur, stable entre deux gestes. */
  snap: TimerSnapshot;
  state: FocusTimerState | null;
  /** L'horloge d'affichage : un seul « maintenant » pour tout l'écran. */
  now: Date;
  /** Les réglages du poste (le cycle, en particulier). */
  settings: TimerSnapshot["settings"];
  phase: FocusPhase;
  cycle: PomodoroSettings;
  /** Le contexte courant : celui de la session ouverte, sinon du brouillon. */
  courseID?: string;
  taskType: TaskType;
  targetID?: string;
  pomodoro: boolean;
  isStudying: boolean;
  studyIsOver: boolean;
  isLocked: boolean;
  studyLocks: boolean;
}

export function useStudyTimer(): StudyTimerApi {
  const { store, save, remove } = useData();
  const snap = useSyncExternalStore(timerController.subscribe, timerController.snapshot);

  // L'horloge d'affichage : un peu plus fine que la seconde, pour qu'elle
  // change à la seconde et non jusqu'à une seconde en retard.
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const id = window.setInterval(() => setNow(new Date()), 250);
    return () => window.clearInterval(id);
  }, []);

  // Les sessions s'écrivent par la source de données de l'app, dès qu'elle
  // existe — le mode étude peut être ouvert sans passer par l'écran Chrono.
  useEffect(() => {
    if (store) timerController.attach({ store, save, remove });
  }, [store, save, remove]);

  const state = snap.state;
  return {
    snap,
    state,
    now,
    settings: snap.settings,
    phase: timerController.phase(now),
    cycle: timerController.cycle(),
    courseID: state ? state.courseID : snap.draft.courseID,
    taskType: state ? stateTaskType(state) : snap.draft.taskType,
    targetID: state ? state.targetID : snap.draft.targetID,
    pomodoro: state ? state.pomodoro : snap.draft.pomodoro,
    isStudying: timerController.isStudying,
    studyIsOver: timerController.studyIsOver,
    isLocked: timerController.isLocked,
    studyLocks: timerController.studyLocks,
  };
}
