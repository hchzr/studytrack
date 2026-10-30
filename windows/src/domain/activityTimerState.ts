import { dateFromJSON, encodeJSON, parseJSON } from "./focusTimerState.ts";

/** `date.addingTimeInterval(seconds)`, à la milliseconde. */
const adding = (date: Date, seconds: number) => new Date(Math.round(date.getTime() + seconds * 1000));

/** Un `ClosedRange<Date>` : de `start` à `end`. */
export interface DateInterval {
  start: Date;
  end: Date;
}

/** Ce que la Live Activity doit afficher, et comment le temps s'y écoule.
 *
 * **Type pur, sans ActivityKit** : c'est ce qui permet de le tester sans
 * simulateur ni écran verrouillé — et c'est précisément là que se trouvait
 * le bogue.
 *
 * L'ancienne version portait `accumulated` **et** `runningSince`, et le compteur
 * système n'affichait que le second : après une pause, il repartait de zéro et
 * annonçait « 00:01 » au lieu d'une heure de travail. Ici, `countingSince` est
 * l'instant de départ **reculé du total déjà écoulé** — le compteur affiche
 * donc le total, et continue d'avancer.
 */
export interface ActivityTimerState {
  /** Instant depuis lequel le **total** s'écoule. Absent quand c'est en pause. */
  countingSince?: Date;
  /** Le total, figé, quand le chrono est en pause. */
  frozenTotal: number;
  /** Sous-questions cochées de la cible, et combien il y en a.
   *
   * Optionnels, et pas `0` par défaut : une session sans cible n'a pas
   * « 0/0 » sous-questions, elle n'en a **pas**. C'est aussi ce qui permet à
   * une activité publiée par une version précédente de se décoder. */
  questionsDone?: number;
  questionsTotal?: number;
  /** Le bloc Pomodoro en cours, quand la session est en Pomodoro. */
  pomodoro?: ActivityPomodoro;
  /** Sur quoi porte la session **maintenant** : « MATH-101 », « Exercices · 3.4 ».
   *
   * Ces libellés vivaient dans les attributs de l'activité, qui sont **figés** à
   * sa création. Or une activité est reprise d'une session à l'autre et le cours
   * change en pleine session : l'écran verrouillé affichait donc pour toujours le
   * premier cours démarré. L'état, lui, se met à jour. */
  title?: string;
  subtitle?: string;
  /** La couleur du cours (« #4F46E5 »), pour l'îlot et l'écran verrouillé. */
  colorHex?: string;
  /** Le début de la session affichée : un appareil réveillé avec un état
   * périmé (la session d'avant) ne doit pas écraser l'activité d'une session
   * plus récente. */
  sessionStartedAt?: Date;
}

export const ActivityTimerState = {
  /** Construit l'état à publier.
   *
   * - `elapsed` : le total réel déjà travaillé.
   * - `running` : le chrono continue-t-il de s'écouler ?
   * - `questionsDone` / `questionsTotal` : sous-questions de la cible, s'il y en a.
   * - `pomodoro` : le bloc en cours, si la session est en Pomodoro.
   * - `title` : le cours (« MATH-101 »), republié à chaque changement.
   * - `subtitle` : le type de travail et la cible (« Exercices · 3.4 »).
   * - `now` : l'instant de référence, injectable pour les tests.
   */
  make(args: {
    elapsed: number;
    running: boolean;
    questionsDone?: number;
    questionsTotal?: number;
    pomodoro?: ActivityPomodoro;
    title?: string;
    subtitle?: string;
    now?: Date;
  }): ActivityTimerState {
    const now = args.now ?? new Date();
    const total = Math.max(0, args.elapsed);
    const state: ActivityTimerState = { frozenTotal: total };
    if (args.running) state.countingSince = adding(now, -total);
    if (args.questionsDone !== undefined) state.questionsDone = args.questionsDone;
    if (args.questionsTotal !== undefined) state.questionsTotal = args.questionsTotal;
    if (args.pomodoro !== undefined) state.pomodoro = args.pomodoro;
    if (args.title !== undefined) state.title = args.title;
    if (args.subtitle !== undefined) state.subtitle = args.subtitle;
    return state;
  },

  /** « Exercices · 3.4 » : le type de travail, puis la cible s'il y en a une. */
  subtitle(task: string, target?: string | null): string {
    if (!target) return task;
    return `${task} · ${target}`;
  },

  isRunning(state: ActivityTimerState): boolean {
    return state.countingSince !== undefined;
  },

  /** Total écoulé à cet instant. */
  elapsed(state: ActivityTimerState, now: Date = new Date()): number {
    if (!state.countingSince) return state.frozenTotal;
    return Math.max(state.frozenTotal, (now.getTime() - state.countingSince.getTime()) / 1000);
  },

  // MARK: Sous-questions

  /** « 3/9 », ou `null` quand la cible n'a pas de sous-questions.
   *
   * Une cible qui n'a qu'une seule case n'en affiche pas : « 0/1 » n'apprend
   * rien que le bouton « fait » ne dise déjà. */
  questionsLabel(state: ActivityTimerState): string | null {
    const total = state.questionsTotal;
    if (total === undefined || !(total > 1)) return null;
    return `${Math.min(state.questionsDone ?? 0, total)}/${total}`;
  },

  /** Reste-t-il une sous-question à cocher ? C'est la condition du bouton. */
  hasNextQuestion(state: ActivityTimerState): boolean {
    const total = state.questionsTotal;
    if (total === undefined || !(total > 0)) return false;
    return (state.questionsDone ?? 0) < total;
  },

  /** Part des sous-questions faites, pour la barre de l'écran verrouillé. */
  questionsProgress(state: ActivityTimerState): number | null {
    const total = state.questionsTotal;
    if (total === undefined || !(total > 0)) return null;
    return Math.min(1, Math.max(0, (state.questionsDone ?? 0) / total));
  },

  encode(state: ActivityTimerState): string {
    return encodeJSON(state);
  },

  /** Relit un état, y compris celui d'une version précédente (champs absents). */
  decode(text: string): ActivityTimerState | null {
    const raw = parseJSON(text);
    if (typeof raw !== "object" || raw === null) return null;
    const object = raw as Record<string, unknown>;
    if (typeof object.frozenTotal !== "number") return null;
    for (const key of ["countingSince", "sessionStartedAt"]) {
      if (object[key] === undefined) continue;
      const date = dateFromJSON(object[key]);
      if (!date) return null;
      object[key] = date;
    }
    const pomodoro = object.pomodoro as Record<string, unknown> | undefined;
    if (pomodoro !== undefined) {
      if (typeof pomodoro !== "object" || typeof pomodoro.blockNumber !== "number"
        || typeof pomodoro.completedBlocks !== "number" || typeof pomodoro.frozenProgress !== "number") return null;
      for (const key of ["startedAt", "endsAt", "breakStartedAt", "breakEndsAt"]) {
        if (pomodoro[key] === undefined) continue;
        const date = dateFromJSON(pomodoro[key]);
        if (!date) return null;
        pomodoro[key] = date;
      }
    }
    return object as unknown as ActivityTimerState;
  },
};

/** Le bloc Pomodoro en cours, tel que l'îlot peut le dessiner **seul**.
 *
 * L'anneau ne reçoit pas une fraction rafraîchie chaque seconde : il reçoit les
 * deux bornes du bloc en horloge murale, et se remplit tout seul, comme le
 * compteur avance tout seul. Une mise à jour par seconde coûterait de la
 * batterie pour un résultat identique.
 *
 * Les bornes sont en horloge murale alors que le chrono compte le **travail** :
 * c'est correct tant que le chrono tourne, et c'est précisément pourquoi elles
 * sont absentes en pause — pendant une pause, le bloc n'avance pas, et un anneau
 * qui continuerait de se remplir mentirait. La pause garde donc `frozenProgress`.
 */
export interface ActivityPomodoro {
  /** Bloc en cours, à partir de 1. */
  blockNumber: number;
  /** Blocs entièrement terminés dans la session. */
  completedBlocks: number;
  /** Début du bloc en cours, en horloge murale. Absent en pause. */
  startedAt?: Date;
  /** Fin prévue du bloc, en horloge murale. Absent en pause. */
  endsAt?: Date;
  /** Part du bloc déjà faite, figée — ce qu'on montre en pause. */
  frozenProgress: number;
  /** La pause Pomodoro en cours : son type (`short`, `long`) et ses bornes.
   *
   * Optionnels, pour qu'une activité publiée avant l'ajout des pauses se
   * décode encore. Pendant une pause, le compteur de l'îlot **descend** vers
   * `breakEndsAt`. */
  breakKind?: string;
  breakStartedAt?: Date;
  breakEndsAt?: Date;
}

export const ActivityPomodoro = {
  /** Une pause en cours, après le bloc `completedBlocks`. */
  onBreak(args: { kind: string; startedAt: Date; endsAt: Date; completedBlocks: number }): ActivityPomodoro {
    return {
      blockNumber: Math.max(1, args.completedBlocks),
      completedBlocks: Math.max(0, args.completedBlocks),
      frozenProgress: 1,
      breakKind: args.kind,
      breakStartedAt: args.startedAt,
      breakEndsAt: args.endsAt,
    };
  },

  /** Une pause est-elle en cours ? */
  isOnBreak(p: ActivityPomodoro): boolean {
    return p.breakEndsAt !== undefined;
  },

  /** L'intervalle de la pause, pour le compte à rebours et l'anneau qui se vide. */
  breakInterval(p: ActivityPomodoro): DateInterval | null {
    if (!p.breakStartedAt || !p.breakEndsAt || !(p.breakEndsAt.getTime() > p.breakStartedAt.getTime())) return null;
    return { start: p.breakStartedAt, end: p.breakEndsAt };
  },

  /** « Pause », « Pause longue ». */
  breakLabel(p: ActivityPomodoro): string {
    return p.breakKind === "long" ? "Pause longue" : "Pause";
  },

  /** Projette l'avancement d'un bloc sur l'horloge murale.
   *
   * Les nombres viennent de `PomodoroEngine`, qui reste la seule autorité sur
   * le découpage en blocs ; ce type ne fait que les traduire en dates, parce
   * que c'est la seule forme qu'une Live Activity sait animer sans l'app.
   *
   * - `blockNumber` : le bloc en cours, à partir de 1.
   * - `elapsedInBlock` : temps de travail déjà fait dans ce bloc.
   * - `remaining` : temps de travail restant avant la pause conseillée.
   * - `completedBlocks` : blocs entièrement terminés.
   * - `running` : le chrono tourne-t-il ?
   * - `now` : l'instant de référence, injectable pour les tests.
   */
  make(args: {
    blockNumber: number;
    elapsedInBlock: number;
    remaining: number;
    completedBlocks: number;
    running: boolean;
    now?: Date;
  }): ActivityPomodoro {
    const now = args.now ?? new Date();
    const done = Math.max(0, args.elapsedInBlock);
    const left = Math.max(0, args.remaining);
    const total = done + left;
    const progress = total > 0 ? Math.min(1, done / total) : 1;
    // Les bornes n'existent que s'il reste quelque chose à animer : en pause,
    // et sur un bloc arrivé à terme, l'anneau est **figé**, et c'est
    // `frozenProgress` qui le dessine.
    const animating = args.running && left > 0;
    const result: ActivityPomodoro = {
      blockNumber: Math.max(1, args.blockNumber),
      completedBlocks: Math.max(0, args.completedBlocks),
      frozenProgress: progress,
    };
    if (animating) {
      result.startedAt = adding(now, -done);
      result.endsAt = adding(now, left);
    }
    return result;
  },

  /** L'intervalle que l'anneau doit animer, quand il y a lieu de l'animer.
   *
   * Absent en pause, et absent sur un bloc déjà terminé : un intervalle vide ou
   * inversé ferait dessiner un anneau plein d'un coup, ou rien du tout. */
  interval(p: ActivityPomodoro): DateInterval | null {
    if (!p.startedAt || !p.endsAt || !(p.endsAt.getTime() > p.startedAt.getTime())) return null;
    return { start: p.startedAt, end: p.endsAt };
  },

  /** Le bloc est fini : c'est le moment de proposer la pause. */
  isBlockComplete(p: ActivityPomodoro): boolean {
    return p.frozenProgress >= 1;
  },

  /** « Bloc 3 », ou le nom de la pause en cours. */
  label(p: ActivityPomodoro): string {
    return ActivityPomodoro.isOnBreak(p) ? ActivityPomodoro.breakLabel(p) : `Bloc ${p.blockNumber}`;
  },
};

// MARK: - La journée d'examen (Shared/ExamActivityState.swift)

/** Où en est la journée d'examen.
 *
 * **Type pur, sans ActivityKit**, comme `ActivityTimerState` : c'est ici que se
 * trouve la seule vraie logique — quand l'activité s'ouvre, quand elle se ferme.
 */
export type ExamPhase =
  /** L'épreuve n'a pas commencé : compte à rebours. */
  | "upcoming"
  /** L'épreuve est en cours. */
  | "running"
  /** L'épreuve est passée : l'activité s'efface. */
  | "over";

export interface ExamActivityState {
  phase: ExamPhase;
}

export const ExamActivityState = {
  /** Durée supposée d'une épreuve, faute de mieux.
   *
   * Le modèle `Exam` ne porte pas de durée : on ne peut donc pas annoncer « il
   * reste 40 min d'épreuve ». Trois heures couvrent un examen EPFL classique, et
   * ne servent qu'à savoir quand **retirer** l'activité de l'écran. */
  assumedDuration: 3 * 3600,

  /** Combien de temps avant l'épreuve l'activité doit apparaître.
   *
   * Douze heures : la veille au soir, quand on prépare ses affaires, et pas
   * trois jours avant, où un compte à rebours permanent n'est plus une
   * information mais une pression. */
  lead: 12 * 3600,

  /** L'activité a-t-elle sa place à l'écran pour cet examen ? */
  isRelevant(examDate: Date, now: Date = new Date()): boolean {
    return ExamActivityState.phase(examDate, now) !== "over"
      && (examDate.getTime() - now.getTime()) / 1000 <= ExamActivityState.lead;
  },

  /** La phase de la journée, déduite des dates : rien à tenir à jour. */
  phase(examDate: Date, now: Date = new Date()): ExamPhase {
    if (now.getTime() < examDate.getTime()) return "upcoming";
    if (now.getTime() < adding(examDate, ExamActivityState.assumedDuration).getTime()) return "running";
    return "over";
  },

  make(examDate: Date, now: Date = new Date()): ExamActivityState {
    return { phase: ExamActivityState.phase(examDate, now) };
  },
};
