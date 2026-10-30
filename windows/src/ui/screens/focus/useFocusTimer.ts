// Le chrono de l'écran Focus : l'état persisté (`FocusTimerState`), les gestes
// du `TimerEngine` et l'enregistrement des sessions — sans la synchronisation
// entre appareils du Mac (relais iCloud, sessions de groupe).
//
// L'état survit à la fermeture de l'app comme sur le Mac : écrit à chaque geste
// et à chaque frontière du cycle (fin de bloc, fin de pause), relu au montage.
// Le temps écoulé se déduit des dates — jamais d'un compteur qui aurait dû
// tourner pendant que l'app était fermée.

import { useEffect, useRef, useState } from "react";
import { useData } from "../../../data/dataContext.tsx";
import { Course, StudySession } from "../../../models/index.ts";
import { TaskType } from "../../../models/enums.ts";
import {
  FocusTimerStore,
  allocatedSeconds,
  cycleOr,
  elapsed,
  isRestorable,
  maxRestorableAge,
  newFocusTimerState,
  pause,
  segmentTaskType,
  start,
  switchContext,
  taskType as stateTaskType,
  type FocusTimerState,
} from "../../../domain/focusTimerState.ts";
import {
  advance,
  phase as focusPhase,
  setPomodoro as applyPomodoro,
  skipBreak as applySkipBreak,
  type FocusPhase,
  type PomodoroSettings,
} from "../../../domain/pomodoroEngine.ts";
import { focusStore, readFocusSettings, type FocusSettings } from "./focusSettings.ts";
import { phaseOf } from "./timerView.ts";

/** En dessous, une session est un faux départ (`TimerEngine.minimumRecordedSeconds`). */
const minimumRecordedSeconds = 60;

/** Ce qui sera chronométré au prochain démarrage (le brouillon de l'écran). */
export interface FocusDraft {
  courseID?: string;
  taskType: TaskType;
  targetID?: string;
  pomodoro: boolean;
}

/** Un morceau de session réellement enregistré, cible par cible. */
export interface FocusRecapPart {
  courseID?: string;
  taskType: TaskType;
  targetID?: string;
  seconds: number;
  session: StudySession;
}

/** Ce que « Terminer » a enregistré (MacTimer.Recap). */
export interface FocusRecap {
  startedAt: Date;
  endedAt: Date;
  totalSeconds: number;
  /** Vide : moins d'une minute, rien n'a été enregistré. */
  parts: FocusRecapPart[];
  discarded: boolean;
}

export interface FocusTimerApi {
  state: FocusTimerState | null;
  now: Date;
  settings: FocusSettings;
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

const addSeconds = (date: Date, seconds: number) => new Date(Math.round(date.getTime() + seconds * 1000));

/** L'exercice ou l'élément de théorie visé par une session (TimerEngine.target). */
function targetOf(course: Course | null, targetID: string | undefined) {
  if (!course || !targetID) return { exercise: null, theoryItem: null };
  const exercise = course.allExercises.find((candidate) => candidate.id === targetID) ?? null;
  if (exercise) return { exercise, theoryItem: null };
  const theoryItem = course.theoryItems.find((candidate) => candidate.id === targetID) ?? null;
  return { exercise: null, theoryItem };
}

export function useFocusTimer(): FocusTimerApi {
  const { store, save, remove } = useData();
  const [settings] = useState<FocusSettings>(readFocusSettings);
  const [state, setState] = useState<FocusTimerState | null>(null);
  const [draft, setDraft] = useState<FocusDraft>(() => ({
    taskType: "exercise",
    pomodoro: settings.pomodoroDefault,
  }));
  const [recap, setRecap] = useState<FocusRecap | null>(null);
  const [now, setNow] = useState(() => new Date());

  // Le battement : un peu plus fin que la seconde, pour que l'horloge change à
  // la seconde et non jusqu'à une seconde en retard.
  useEffect(() => {
    const id = window.setInterval(() => setNow(new Date()), 250);
    return () => window.clearInterval(id);
  }, []);

  /** Écrit l'état (ou l'efface), et fait suivre la sélection affichée. */
  const persist = (next: FocusTimerState | null) => {
    setState(next);
    FocusTimerStore.save(next, focusStore);
    if (next) {
      setDraft({
        courseID: next.courseID,
        taskType: stateTaskType(next),
        targetID: next.targetID,
        pomodoro: next.pomodoro,
      });
    }
  };

  // Reprise au lancement : une session vivante est reprise ; une session
  // oubliée trop longtemps est enregistrée bornée, avec une note pour qu'on la
  // corrige dans le journal (TimerEngine.reload).
  const loaded = useRef(false);
  useEffect(() => {
    if (loaded.current || !store) return;
    loaded.current = true;
    const saved = FocusTimerStore.load(focusStore);
    if (!saved) return;
    const at = new Date();
    if (isRestorable(saved, at)) {
      setState(saved);
      setDraft({
        courseID: saved.courseID,
        taskType: stateTaskType(saved),
        targetID: saved.targetID,
        pomodoro: saved.pomodoro,
      });
      return;
    }
    FocusTimerStore.save(null, focusStore);
    const seconds = Math.min(Math.trunc(elapsed(saved, at)), maxRestorableAge);
    if (seconds < minimumRecordedSeconds) return;
    const course = saved.courseID ? store.fetch(Course).find((entry) => entry.id === saved.courseID) ?? null : null;
    const target = targetOf(course, saved.targetID);
    const note = saved.note === ""
      ? "Chrono resté ouvert — durée à vérifier"
      : `${saved.note} · chrono resté ouvert`;
    void save(new StudySession({
      course,
      taskType: stateTaskType(saved),
      startedAt: saved.sessionStartedAt,
      durationSeconds: seconds,
      isManual: false,
      note,
      exercise: target.exercise,
      theoryItem: target.theoryItem,
    }));
  }, [store, save]);

  // Les frontières du cycle : une app restée ouverte franchit la fin du bloc à
  // l'instant exact où elle tombe (`advance` déduit tout des dates).
  useEffect(() => {
    if (!state) return;
    const copy = { ...state };
    const events = advance(copy, cycleOr(copy, settings.cycle), now);
    if (events.length === 0) return;
    setState(copy);
    FocusTimerStore.save(copy, focusStore);
  }, [now, state, settings.cycle]);

  const cycle = state ? cycleOr(state, settings.cycle) : settings.cycle;
  const phase: FocusPhase = state ? phaseOf(state, settings.cycle, now) : { type: "idle" };

  const courseID = state ? state.courseID : draft.courseID;
  const taskType = state ? stateTaskType(state) : draft.taskType;
  const targetID = state ? state.targetID : draft.targetID;
  const pomodoro = state ? state.pomodoro : draft.pomodoro;

  const beginFresh = (): FocusTimerState => {
    const at = new Date();
    const fresh = newFocusTimerState({
      sessionStartedAt: at,
      courseID: draft.courseID,
      taskTypeRaw: draft.taskType,
      targetID: draft.targetID,
      pomodoro: draft.pomodoro,
    });
    fresh.cycle = settings.cycle;
    start(fresh, at);
    return fresh;
  };

  const startSession = () => {
    setRecap(null);
    if (state) {
      // Reprendre la session ouverte sur le contexte affiché : le temps déjà
      // compté reste à la cible précédente.
      const copy = { ...state };
      switchContext(copy, { courseID: draft.courseID, taskTypeRaw: draft.taskType, targetID: draft.targetID });
      start(copy);
      persist(copy);
      return;
    }
    persist(beginFresh());
  };

  const pauseSession = () => {
    if (!state || !state.runningSince) return;
    const copy = { ...state };
    pause(copy);
    persist(copy);
  };

  const resumeSession = () => {
    if (!state) return;
    const copy = { ...state };
    start(copy);
    persist(copy);
  };

  const skipBreak = () => {
    if (!state) return;
    const copy = { ...state };
    applySkipBreak(copy);
    persist(copy);
  };

  const toggle = () => {
    if (!state) {
      startSession();
      return;
    }
    const current = focusPhase(state, cycleOr(state, settings.cycle), new Date());
    if (current.type === "onBreak") skipBreak();
    else if (current.type === "working") pauseSession();
    else resumeSession();
  };

  const chooseCourse = (id: string | undefined) => {
    if (state) retarget(id, taskType, undefined);
    else setDraft({ ...draft, courseID: id, targetID: undefined });
  };

  const chooseTaskType = (value: TaskType) => {
    if (state) retarget(state.courseID, value, undefined);
    else setDraft({ ...draft, taskType: value, targetID: undefined });
  };

  const chooseTarget = (id: string | undefined) => {
    if (state) retarget(state.courseID, taskType, id);
    else setDraft({ ...draft, targetID: id });
  };

  const retarget = (id: string | undefined, type: TaskType, target: string | undefined) => {
    setDraft({ courseID: id, taskType: type, targetID: target, pomodoro });
    if (!state) return;
    const copy = { ...state };
    switchContext(copy, { courseID: id, taskTypeRaw: type, targetID: target });
    persist(copy);
  };

  const setPomodoro = (enabled: boolean) => {
    if (!state) {
      setDraft({ ...draft, pomodoro: enabled });
      return;
    }
    const copy = { ...state };
    if (!copy.cycle) copy.cycle = settings.cycle;
    applyPomodoro(copy, enabled);
    advance(copy, cycleOr(copy, settings.cycle), new Date());
    persist(copy);
  };

  const record = async (current: FocusTimerState, endedAt: Date): Promise<FocusRecap> => {
    const allocated = allocatedSeconds(current, endedAt);
    const own = allocated
      .filter((entry) => entry.segment.excluded !== true)
      .reduce((sum, entry) => sum + entry.seconds, 0);
    const result: FocusRecap = {
      startedAt: current.sessionStartedAt,
      endedAt,
      totalSeconds: own,
      parts: [],
      discarded: own < minimumRecordedSeconds || !store,
    };
    if (result.discarded) return result;

    let startAt = current.sessionStartedAt;
    for (const entry of allocated) {
      // Le temps d'avant l'arrivée dans une session de groupe n'est pas le sien.
      if (entry.segment.excluded === true) {
        startAt = addSeconds(startAt, entry.seconds);
        continue;
      }
      const course = entry.segment.courseID
        ? store!.fetch(Course).find((candidate) => candidate.id === entry.segment.courseID) ?? null
        : null;
      const target = targetOf(course, entry.segment.targetID);
      const session = new StudySession({
        course,
        taskType: segmentTaskType(entry.segment),
        startedAt: startAt,
        durationSeconds: entry.seconds,
        isManual: false,
        note: result.parts.length === 0 ? current.note : "",
        exercise: target.exercise,
        theoryItem: target.theoryItem,
      });
      result.parts.push({
        courseID: course?.id,
        taskType: segmentTaskType(entry.segment),
        targetID: entry.segment.targetID,
        seconds: entry.seconds,
        session,
      });
      startAt = addSeconds(startAt, entry.seconds);
    }
    try {
      for (const part of result.parts) await save(part.session);
    } catch {
      // Une écriture refusée laisse le récapitulatif visible : rien n'est perdu
      // de ce qui a été compté, et « Annuler » ne retirera que ce qui existe.
    }
    return result;
  };

  const finish = async () => {
    const current = state;
    if (!current) return;
    const endedAt = new Date();
    const result = await record(current, endedAt);
    setRecap(result);
    persist(null);
  };

  const discard = () => {
    if (!state) return;
    persist(null);
  };

  const dismissRecap = () => setRecap(null);

  const undoRecap = async () => {
    if (!recap) return;
    for (const part of recap.parts) {
      try {
        await remove(part.session);
      } catch {
        // Déjà partie : le récapitulatif se ferme quand même.
      }
    }
    setRecap(null);
  };

  return {
    state,
    now,
    settings,
    phase,
    cycle,
    draft,
    courseID,
    taskType,
    targetID,
    pomodoro,
    recap,
    elapsedNow: state ? elapsed(state, now) : 0,
    chooseCourse,
    chooseTaskType,
    chooseTarget,
    setPomodoro,
    start: startSession,
    toggle,
    pause: pauseSession,
    resume: resumeSession,
    skipBreak,
    finish,
    discard,
    retarget,
    dismissRecap,
    undoRecap,
  };
}
