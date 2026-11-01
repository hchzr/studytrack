// Le chrono de l'app, **un seul pour toute la fenêtre** : ce que `MacTimer`
// est sur le Mac. L'écran Chrono, le mode étude et les sorties (terminer,
// abandonner) parlent au même objet — plus deux états qui divergent.
//
// Comme le `TimerEngine` de StudyKit : l'état **valeur** (`FocusTimerState`)
// survit à la fermeture (écrit à chaque geste, relu au lancement), le temps
// se déduit des dates, les frontières du cycle (fin de bloc, de pause) sont
// rattrapées par un battement — ici un `setInterval` qui n'existe que pendant
// une session. Sans React : la file d'abonnés sert à `useSyncExternalStore`.
//
// Le mode étude vit **dans** l'état du chrono (`studySince` / `studyUntil`),
// jamais à côté (StudyMode.swift) : lancé depuis le bureau, il verrouille
// aussi l'écran Chrono, et terminer la session le lève partout.

import { Course, StudySession, type ModelStore } from "../models/index.ts";
import { TaskType } from "../models/enums.ts";
import {
  FocusTimerStore,
  allocatedSeconds,
  cycleOr,
  elapsed,
  isRestorable,
  maxRestorableAge,
  newFocusTimerState,
  pause as pauseState,
  segmentTaskType,
  start as startState,
  switchContext,
  taskType as stateTaskType,
  type FocusTimerState,
  type KeyValueStore,
} from "../domain/focusTimerState.ts";
import {
  advance,
  phase as focusPhase,
  setPomodoro as applyPomodoro,
  skipBreak as applySkipBreak,
  type FocusPhase,
  type PomodoroSettings,
} from "../domain/pomodoroEngine.ts";
import { StudyMode } from "../domain/studyMode.ts";
import { focusStore, readFocusSettings, type FocusSettings } from "./screens/focus/focusSettings.ts";

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

/** Comment le contrôleur écrit les sessions : la source de données de l'app. */
export interface TimerRecording {
  store: ModelStore;
  save(instance: object): Promise<void>;
  remove(instance: object): Promise<void>;
}

export interface StudyBegin {
  courseID?: string;
  taskType: TaskType;
  targetID?: string;
  label?: string;
  /** Le rythme d'une session qui démarre ; une session ouverte garde le sien. */
  pomodoro?: boolean;
  /** Bloquer le reste (le réglage du bureau). */
  locks?: boolean;
}

/** L'état publié aux vues : stable entre deux gestes. */
export interface TimerSnapshot {
  version: number;
  state: FocusTimerState | null;
  recap: FocusRecap | null;
  draft: FocusDraft;
  settings: FocusSettings;
}

const addSeconds = (date: Date, seconds: number) => new Date(Math.round(date.getTime() + seconds * 1000));

/** L'exercice ou l'élément de théorie visé par une session (TimerEngine.target). */
function targetOf(store: ModelStore | null, course: Course | null, targetID: string | undefined) {
  if (!store || !course || !targetID) return { exercise: null, theoryItem: null };
  const exercise = course.allExercises.find((candidate) => candidate.id === targetID) ?? null;
  if (exercise) return { exercise, theoryItem: null };
  const theoryItem = course.theoryItems.find((candidate) => candidate.id === targetID) ?? null;
  return { exercise, theoryItem };
}

export class FocusTimerController {
  private state: FocusTimerState | null = null;
  private recapValue: FocusRecap | null = null;
  private draftValue: FocusDraft;
  private readonly settingsValue: FocusSettings;
  private recording: TimerRecording | null = null;
  private restored = false;
  private listeners = new Set<() => void>();
  private version = 0;
  private snapshotCache: TimerSnapshot | null = null;
  private ticker: ReturnType<typeof setInterval> | null = null;
  private readonly now: () => Date;
  private readonly ticking: boolean;
  private readonly storage: KeyValueStore;

  constructor(options: { now?: () => Date; ticking?: boolean; storage?: KeyValueStore } = {}) {
    this.now = options.now ?? (() => new Date());
    this.ticking = options.ticking ?? true;
    this.storage = options.storage ?? focusStore;
    this.settingsValue = readFocusSettings();
    this.draftValue = { taskType: "exercise", pomodoro: this.settingsValue.pomodoroDefault };
  }

  // MARK: Abonnés (React et le reste)

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  snapshot = (): TimerSnapshot => {
    if (!this.snapshotCache) {
      this.snapshotCache = {
        version: this.version,
        state: this.state,
        recap: this.recapValue,
        draft: this.draftValue,
        settings: this.settingsValue,
      };
    }
    return this.snapshotCache;
  };

  private changed(): void {
    this.version++;
    this.snapshotCache = null;
    for (const listener of this.listeners) listener();
  }

  /** Branche l'écriture des sessions (une fois les données ouvertes). */
  attach(recording: TimerRecording): void {
    this.recording = recording;
    if (!this.restored) {
      this.restored = true;
      this.restore();
    }
  }

  /**
   * Reprise au lancement : une session vivante est reprise ; une session
   * oubliée trop longtemps est enregistrée bornée, avec une note pour qu'on
   * la corrige dans le journal (TimerEngine.reload).
   */
  private restore(): void {
    const saved = FocusTimerStore.load(this.storage);
    if (!saved) return;
    const at = this.now();
    if (isRestorable(saved, at)) {
      this.state = saved;
      this.draftValue = {
        courseID: saved.courseID,
        taskType: stateTaskType(saved),
        targetID: saved.targetID,
        pomodoro: saved.pomodoro,
      };
      this.startTicking();
      this.changed();
      return;
    }
    FocusTimerStore.save(null, this.storage);
    const seconds = Math.min(Math.trunc(elapsed(saved, at)), maxRestorableAge);
    if (seconds < minimumRecordedSeconds || !this.recording) return;
    const { store } = this.recording;
    const course = saved.courseID ? store.fetch(Course).find((entry) => entry.id === saved.courseID) ?? null : null;
    const target = targetOf(store, course, saved.targetID);
    const note = saved.note === ""
      ? "Chrono resté ouvert — durée à vérifier"
      : `${saved.note} · chrono resté ouvert`;
    void this.recording.save(new StudySession({
      course,
      taskType: stateTaskType(saved),
      startedAt: saved.sessionStartedAt,
      durationSeconds: seconds,
      isManual: false,
      note,
      exercise: target.exercise,
      theoryItem: target.theoryItem,
    }));
  }

  // MARK: Battement

  /** Les frontières du cycle : rattrapées dès qu'elles tombent, chrono au repos compris. */
  private startTicking(): void {
    if (!this.ticking || this.ticker !== null || this.state === null) return;
    this.ticker = setInterval(() => this.tick(), 250);
  }

  private stopTicking(): void {
    if (this.ticker === null) return;
    clearInterval(this.ticker);
    this.ticker = null;
  }

  /** Un pas du battement : les événements de cycle passés sont appliqués. */
  tick(now: Date = this.now()): void {
    if (!this.state) return;
    const copy = { ...this.state };
    const events = advance(copy, cycleOr(copy, this.settingsValue.cycle), now);
    if (events.length === 0) return;
    this.state = copy;
    FocusTimerStore.save(copy, this.storage);
    this.changed();
  }

  // MARK: Lecture

  get settings(): FocusSettings { return this.settingsValue; }
  get studyLocks(): boolean { return StudyMode.blocks(this.state); }
  get isStudying(): boolean { return StudyMode.isActive(this.state, this.now()); }
  get studyIsOver(): boolean { return StudyMode.isOver(this.state, this.now()); }
  /** Le verrou tient : terminer, abandonner et sortir passent par la sortie d'urgence. */
  get isLocked(): boolean { return StudyMode.locks(this.state, this.now()); }
  phase(now: Date = this.now()): FocusPhase {
    return this.state ? focusPhase(this.state, cycleOr(this.state, this.settingsValue.cycle), now) : { type: "idle" };
  }
  cycle(): PomodoroSettings {
    return this.state ? cycleOr(this.state, this.settingsValue.cycle) : this.settingsValue.cycle;
  }

  private persist(next: FocusTimerState | null): void {
    this.state = next;
    FocusTimerStore.save(next, this.storage);
    if (next) {
      this.draftValue = {
        courseID: next.courseID,
        taskType: stateTaskType(next),
        targetID: next.targetID,
        pomodoro: next.pomodoro,
      };
      this.startTicking();
    } else {
      this.stopTicking();
    }
    this.changed();
  }

  // MARK: Gestes

  private beginFresh(): FocusTimerState {
    const at = this.now();
    const fresh = newFocusTimerState({
      sessionStartedAt: at,
      courseID: this.draftValue.courseID,
      taskTypeRaw: this.draftValue.taskType,
      targetID: this.draftValue.targetID,
      pomodoro: this.draftValue.pomodoro,
    });
    fresh.cycle = this.settingsValue.cycle;
    fresh.note = "";
    fresh.contextLabel = "";
    startState(fresh, at);
    return fresh;
  }

  start(): void {
    this.recapValue = null;
    if (this.state) {
      // Reprendre la session ouverte sur le contexte affiché : le temps déjà
      // compté reste à la cible précédente.
      const copy = { ...this.state };
      switchContext(copy, {
        courseID: this.draftValue.courseID,
        taskTypeRaw: this.draftValue.taskType,
        targetID: this.draftValue.targetID,
      }, this.now());
      startState(copy, this.now());
      this.persist(copy);
      return;
    }
    this.persist(this.beginFresh());
  }

  pause(): void {
    if (!this.state?.runningSince) return;
    const copy = { ...this.state };
    pauseState(copy, this.now());
    this.persist(copy);
  }

  resume(): void {
    if (!this.state) return;
    const copy = { ...this.state };
    startState(copy, this.now());
    this.persist(copy);
  }

  skipBreak(): void {
    if (!this.state) return;
    const copy = { ...this.state };
    applySkipBreak(copy);
    this.persist(copy);
  }

  toggle(): void {
    if (!this.state) {
      this.start();
      return;
    }
    const current = this.phase();
    if (current.type === "onBreak") this.skipBreak();
    else if (current.type === "working") this.pause();
    else this.resume();
  }

  retarget(courseID: string | undefined, taskType: TaskType, targetID: string | undefined): void {
    this.draftValue = { courseID, taskType, targetID, pomodoro: this.draftValue.pomodoro };
    if (!this.state) {
      this.changed();
      return;
    }
    const copy = { ...this.state };
    switchContext(copy, { courseID, taskTypeRaw: taskType, targetID }, this.now());
    this.persist(copy);
  }

  chooseCourse(courseID: string | undefined): void {
    this.retarget(courseID, this.draft().taskType, undefined);
  }

  chooseTaskType(value: TaskType): void {
    this.retarget(this.draft().courseID, value, undefined);
  }

  chooseTarget(targetID: string | undefined): void {
    this.retarget(this.draft().courseID, this.draft().taskType, targetID);
  }

  setPomodoro(enabled: boolean): void {
    if (!this.state) {
      this.draftValue = { ...this.draftValue, pomodoro: enabled };
      this.changed();
      return;
    }
    const copy = { ...this.state };
    if (!copy.cycle) copy.cycle = this.settingsValue.cycle;
    applyPomodoro(copy, enabled);
    advance(copy, cycleOr(copy, this.settingsValue.cycle), this.now());
    this.persist(copy);
  }

  /** Le brouillon de l'écran (ce qui sera chronométré au prochain démarrage). */
  draft(): FocusDraft {
    return this.draftValue;
  }

  // MARK: Terminer

  /** Enregistre une session par cible ; `discarded` : trop courte pour être gardée. */
  private async record(current: FocusTimerState, endedAt: Date, emergency: boolean): Promise<FocusRecap> {
    const recording = this.recording;
    if (!recording) {
      return {
        startedAt: current.sessionStartedAt,
        endedAt,
        totalSeconds: 0,
        parts: [],
        discarded: true,
      };
    }
    const allocated = allocatedSeconds(current, endedAt);
    const own = allocated
      .filter((entry) => entry.segment.excluded !== true)
      .reduce((sum, entry) => sum + entry.seconds, 0);
    const note = emergency ? StudyMode.emergencyNote(current.note) : current.note;
    const result: FocusRecap = {
      startedAt: current.sessionStartedAt,
      endedAt,
      totalSeconds: own,
      parts: [],
      discarded: own < minimumRecordedSeconds,
    };
    if (result.discarded) return result;
    const store = recording.store;
    const resolve = (id: string | undefined): Course | null =>
      id ? store.fetch(Course).find((candidate) => candidate.id === id) ?? null : null;

    let startAt = current.sessionStartedAt;
    for (const entry of allocated) {
      // Le temps d'avant l'arrivée dans une session de groupe n'est pas le sien.
      if (entry.segment.excluded === true) {
        startAt = addSeconds(startAt, entry.seconds);
        continue;
      }
      const course = resolve(entry.segment.courseID);
      const target = targetOf(store, course, entry.segment.targetID);
      const session = new StudySession({
        course,
        taskType: segmentTaskType(entry.segment),
        startedAt: startAt,
        durationSeconds: entry.seconds,
        isManual: false,
        note: result.parts.length === 0 ? note : "",
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
      for (const part of result.parts) await recording.save(part.session);
    } catch {
      // Une écriture refusée laisse le récapitulatif visible : rien n'est perdu
      // de ce qui a été compté, et « Annuler » ne retirera que ce qui existe.
    }
    return result;
  }

  /** Terminer : enregistre, montre le récapitulatif. Refusé sous verrou. */
  async finish(options: { emergency?: boolean } = {}): Promise<void> {
    const current = this.state;
    if (!current) return;
    if (this.isLocked && !options.emergency) return;
    const endedAt = this.now();
    this.recapValue = await this.record(current, endedAt, options.emergency === true);
    this.persist(null);
  }

  /** Abandonner : rien n'est enregistré. Refusé sous verrou. */
  discard(): void {
    if (!this.state || this.isLocked) return;
    this.recapValue = null;
    this.persist(null);
  }

  dismissRecap(): void {
    this.recapValue = null;
    this.changed();
  }

  async undoRecap(): Promise<void> {
    const recap = this.recapValue;
    if (!recap || !this.recording) return;
    for (const part of recap.parts) {
      try {
        await this.recording.remove(part.session);
      } catch {
        // Déjà partie : le récapitulatif se ferme quand même.
      }
    }
    this.recapValue = null;
    this.changed();
  }

  // MARK: Mode étude

  /**
   * Entre en mode étude : démarre la session si besoin, sinon la verrouille sur
   * ce contexte (TimerEngine.enterStudy). `minutes` : `null`, sans fin.
   */
  enterStudy(minutes: number | null, begin: StudyBegin): void {
    if (!this.state) {
      this.draftValue = {
        courseID: begin.courseID,
        taskType: begin.taskType,
        targetID: begin.targetID,
        pomodoro: begin.pomodoro ?? this.draftValue.pomodoro,
      };
      this.recapValue = null;
      this.persist(this.beginFresh());
    } else if (begin.courseID !== undefined || begin.targetID !== undefined) {
      const copy = { ...this.state };
      switchContext(copy, {
        courseID: begin.courseID ?? copy.courseID,
        taskTypeRaw: begin.taskType,
        targetID: begin.targetID ?? copy.targetID,
      }, this.now());
      this.state = copy;
    }
    const current = this.state;
    if (!current) return;
    const copy = { ...current };
    StudyMode.enter(copy, minutes, begin.locks ?? true, this.now());
    if (copy.runningSince === undefined && copy.breakEndsAt === undefined) startState(copy, this.now());
    this.persist(copy);
  }

  /** Prolonger : à partir de la fin prévue si elle n'est pas passée, sinon de maintenant. */
  extendStudy(minutes: number): void {
    const current = this.state;
    if (!current) return;
    const copy = { ...current };
    // Prolonger après l'échéance repart d'un anneau vide.
    if (copy.studySince === undefined || StudyMode.isOver(copy, this.now())) copy.studySince = this.now();
    copy.studyUntil = StudyMode.extended(copy.studyUntil, minutes, this.now());
    if (copy.runningSince === undefined && copy.breakEndsAt === undefined) startState(copy, this.now());
    this.persist(copy);
  }

  /** Sortir du mode étude sans terminer la session ; l'urgence passe le verrou. */
  leaveStudy(emergency = false): void {
    const current = this.state;
    if (!current || current.studyUntil === undefined) return;
    if (!emergency && StudyMode.locks(current, this.now())) return;
    const copy = { ...current };
    if (emergency) copy.note = StudyMode.emergencyNote(copy.note);
    StudyMode.leave(copy);
    this.persist(copy);
  }
}

/** Le chrono de l'app (comme `MacTimer.shared`). */
export const timerController = new FocusTimerController();
