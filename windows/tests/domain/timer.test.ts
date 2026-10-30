import { describe, expect, it } from "vitest";
import { ActivityPomodoro, ActivityTimerState, ExamActivityState } from "../../src/domain/activityTimerState.ts";
import {
  FocusTimerStore,
  GroupClock,
  allocatedSeconds,
  allocation,
  currentTargetElapsed,
  cycleOr,
  decodeFocusTimerState,
  elapsed,
  encodeFocusTimerState,
  isRestorable,
  isRunning,
  maxRestorableAge,
  newFocusTimerState,
  pause,
  start,
  switchContext,
  tickAnchor,
  type FocusTimerState,
  type KeyValueStore,
} from "../../src/domain/focusTimerState.ts";
import { HoldProgress } from "../../src/domain/holdProgress.ts";
import { KeepAwakePolicy } from "../../src/domain/keepAwakePolicy.ts";
import {
  PomodoroEngine,
  advance,
  blockEndDate,
  breakKindAfterBlock,
  currentBreak,
  cycleAccumulated,
  cycleOriginSeconds,
  extendBreak,
  makePomodoroSettings,
  phase,
  setPomodoro,
  skipBreak,
  statusIsBlockComplete,
  statusLabel,
  statusProgress,
} from "../../src/domain/pomodoroEngine.ts";
import {
  FocusShortcutDefaults,
  focusShortcutId,
  moveStep,
  standardSessionFlow,
  toggleStep,
} from "../../src/domain/sessionFlow.ts";
import { SessionSoundtrack, type SoundtrackPhase, type SoundtrackBreakPolicy } from "../../src/domain/sessionSoundtrack.ts";
import { StudySearchQuery, StudySwitcherModel } from "../../src/domain/studySwitcher.ts";
import { TimerLink } from "../../src/domain/timerLink.ts";
import { TimerText, WidgetFormat } from "../../src/domain/timerText.ts";

/** Un `UserDefaults` jetable. */
function memoryStore(): KeyValueStore {
  const data = new Map<string, string>();
  return {
    get: (key) => data.get(key) ?? null,
    set: (key, value) => void data.set(key, value),
    remove: (key) => void data.delete(key),
  };
}

const at = (base: Date, seconds: number) => new Date(base.getTime() + seconds * 1000);
const roundTrip = (state: FocusTimerState) => decodeFocusTimerState(encodeFocusTimerState(state));

describe("Saisie d'un temps au clavier", () => {
  const s = TimerText.seconds;
  it("« 1:30 » = 1 h 30", () => expect(s("1:30")).toBe(5400));
  it("« 90 » = 90 minutes, le geste naturel", () => expect(s("90")).toBe(5400));
  it("« 1h30 »", () => expect(s("1h30")).toBe(5400));
  it("« 1 h 30 », avec des espaces", () => expect(s("1 h 30")).toBe(5400));
  it("« 1,5h », virgule française", () => expect(s("1,5h")).toBe(5400));
  it("« 1.5h », point", () => expect(s("1.5h")).toBe(5400));
  it("« 45m »", () => expect(s("45m")).toBe(2700));
  it("« 0:45 » = 45 minutes, comme le champ les écrit", () => expect(s("0:45")).toBe(2700));
  it("« :30 » se lit comme « 0:30 » = 30 minutes", () => expect(s(":30")).toBe(1800));
  it("« 1:30:15 »", () => expect(s("1:30:15")).toBe(5415));
  it("« 2 heures » en toutes lettres", () => expect(s("2 heures")).toBe(7200));
  it("« 1 h » seule", () => expect(s("1 h")).toBe(3600));

  it("une saisie vide ne donne rien", () => expect(s("")).toBeNull());
  it("une saisie blanche non plus", () => expect(s("   ")).toBeNull());
  it("un texte sans nombre est refusé", () => expect(s("abc")).toBeNull());
  it("trop de segments est refusé", () => expect(s("1:2:3:4")).toBeNull());

  it(`une saisie démesurée est bornée à ${TimerText.maximumHours} h`, () => {
    expect(s("999")).toBe(TimerText.maximumHours * 3600);
  });
  it("une saisie négative vaut zéro", () => expect(s("-30")).toBe(0));
  it("zéro est une valeur valide", () => expect(s("0")).toBe(0));

  it("écriture heures:minutes — 1:30", () => expect(TimerText.text(5400)).toBe("1:30"));
  it("moins d'une heure", () => expect(TimerText.text(2700)).toBe("0:45"));
  it("zéro", () => expect(TimerText.text(0)).toBe("0:00"));
  it("un négatif s'affiche zéro", () => expect(TimerText.text(-10)).toBe("0:00"));

  for (const seconds of [0, 60, 600, 2700, 5400, 7200]) {
    it(`aller-retour à ${seconds} s`, () => expect(s(TimerText.text(seconds))).toBe(seconds));
  }
});

describe("Live Activity : le compteur ne repart pas de zéro", () => {
  // Le bogue : l'état portait `accumulated` **et** `runningSince`, et le compteur
  // système n'affichait que le second. Après une pause, il repartait de zéro.
  const now = new Date(1_700_000_000 * 1000);
  const running = ActivityTimerState.make({ elapsed: 600, running: true, now });
  it("un chrono qui tourne est marqué en cours", () => expect(ActivityTimerState.isRunning(running)).toBe(true));
  it("…et affiche le total accumulé, pas zéro — 600 s", () => {
    expect(ActivityTimerState.elapsed(running, now)).toBe(600);
  });
  it("…et il continue d'avancer", () => expect(ActivityTimerState.elapsed(running, at(now, 60))).toBe(660));
  it("l'instant de départ est reculé du total déjà écoulé", () => {
    expect(Math.abs((running.countingSince ?? now).getTime() - now.getTime()) / 1000 - 600).toBeLessThan(0.001);
    expect((running.countingSince!.getTime() - now.getTime()) / 1000 + 600).toBeLessThan(0.001);
  });

  const resumed = ActivityTimerState.make({ elapsed: 3600, running: true, now });
  it("reprendre après 1 h affiche 1 h, pas 00:01 — 3600 s", () => {
    expect(ActivityTimerState.elapsed(resumed, now)).toBe(3600);
  });
  it("…et deux secondes plus tard, 1 h 00 min 02", () => {
    expect(ActivityTimerState.elapsed(resumed, at(now, 2))).toBe(3602);
  });

  const paused = ActivityTimerState.make({ elapsed: 600, running: false, now });
  it("en pause, le chrono n'est pas marqué en cours", () => expect(ActivityTimerState.isRunning(paused)).toBe(false));
  it("…et rien ne s'écoule", () => expect(paused.countingSince).toBeUndefined());
  it("…le total reste figé même cinq minutes plus tard", () => {
    expect(ActivityTimerState.elapsed(paused, at(now, 300))).toBe(600);
  });
  it("le total figé est conservé", () => expect(paused.frozenTotal).toBe(600));

  it("un chrono neuf part de zéro", () => {
    expect(ActivityTimerState.elapsed(ActivityTimerState.make({ elapsed: 0, running: true, now }), now)).toBe(0);
  });
  it("un total négatif est ramené à zéro", () => {
    expect(ActivityTimerState.make({ elapsed: -50, running: false, now }).frozenTotal).toBe(0);
  });
});

describe("Live Activity : sous-questions et anneau Pomodoro", () => {
  const now = new Date(1_700_000_000 * 1000);
  const bare = ActivityTimerState.make({ elapsed: 120, running: true, now });
  it("sans cible, aucun compte de sous-questions", () => expect(ActivityTimerState.questionsLabel(bare)).toBeNull());
  it("…et donc pas de bouton « question suivante »", () => expect(ActivityTimerState.hasNextQuestion(bare)).toBe(false));
  it("…ni de barre de progression", () => expect(ActivityTimerState.questionsProgress(bare)).toBeNull());

  const withQuestions = ActivityTimerState.make({ elapsed: 120, running: true, questionsDone: 3, questionsTotal: 9, now });
  it("trois sur neuf — 3/9", () => expect(ActivityTimerState.questionsLabel(withQuestions)).toBe("3/9"));
  it("il reste des questions à cocher", () => expect(ActivityTimerState.hasNextQuestion(withQuestions)).toBe(true));
  it("un tiers fait", () => {
    expect(Math.abs((ActivityTimerState.questionsProgress(withQuestions) ?? 0) - 1 / 3)).toBeLessThan(0.001);
  });

  const finished = ActivityTimerState.make({ elapsed: 120, running: true, questionsDone: 9, questionsTotal: 9, now });
  it("tout coché : plus de question suivante", () => expect(ActivityTimerState.hasNextQuestion(finished)).toBe(false));
  it("…mais le compte reste affiché", () => expect(ActivityTimerState.questionsLabel(finished)).toBe("9/9"));

  const single = ActivityTimerState.make({ elapsed: 120, running: true, questionsDone: 0, questionsTotal: 1, now });
  it("une cible à une seule case n'affiche pas « 0/1 » : le bouton « fait » le dit déjà", () => {
    expect(ActivityTimerState.questionsLabel(single)).toBeNull();
  });
  it("…elle garde pourtant sa question suivante", () => expect(ActivityTimerState.hasNextQuestion(single)).toBe(true));

  // Décodage d'une activité écrite **avant** ces champs : le contrat de compatibilité.
  const legacy = ActivityTimerState.decode('{"countingSince":"2023-11-14T22:13:20Z","frozenTotal":600}');
  it("un état d'avant les sous-questions se décode encore", () => {
    expect(legacy).not.toBeNull();
    expect(legacy?.frozenTotal).toBe(600);
  });
  it("…et ses champs absents valent nil", () => expect(legacy?.questionsTotal).toBeUndefined());
  it("…y compris le bloc Pomodoro", () => expect(legacy?.pomodoro).toBeUndefined());

  // Les libellés vivent dans l'**état**.
  const labelled = ActivityTimerState.make({
    elapsed: 60, running: true, title: "CS-250",
    subtitle: ActivityTimerState.subtitle("Exercices", "3.4"), now,
  });
  it("le cours est porté par l'état de l'activité", () => expect(labelled.title).toBe("CS-250"));
  it("le type et la cible aussi", () => expect(labelled.subtitle).toBe("Exercices · 3.4"));
  it("sans cible, le type seul", () => expect(ActivityTimerState.subtitle("Théorie", null)).toBe("Théorie"));
  it("une cible vide ne laisse pas de « · »", () => expect(ActivityTimerState.subtitle("Théorie", "")).toBe("Théorie"));
  const relabelled = ActivityTimerState.make({ elapsed: 60, running: true, title: "MATH-101", now });
  it("changer de cours change l'état : l'activité est republiée", () => expect(relabelled).not.toEqual(labelled));
  it("un état sans libellés se décode : l'extension retombe sur les attributs", () => {
    const old = ActivityTimerState.decode('{"countingSince":null,"frozenTotal":30}');
    expect(old).not.toBeNull();
    expect(old?.title === undefined && old?.subtitle === undefined).toBe(true);
  });

  // L'anneau : les bornes en horloge murale sont ce que le système sait animer.
  const ring = ActivityPomodoro.make({ blockNumber: 1, elapsedInBlock: 600, remaining: 900, completedBlocks: 0, running: true, now });
  it("le bloc a commencé il y a dix minutes de travail", () => expect(ring.startedAt).toEqual(at(now, -600)));
  it("…et se termine dans quinze", () => expect(ring.endsAt).toEqual(at(now, 900)));
  it("l'anneau a un intervalle à animer", () => expect(ActivityPomodoro.interval(ring)).not.toBeNull());
  it("40 % du bloc", () => expect(Math.abs(ring.frozenProgress - 0.4)).toBeLessThan(0.001));
  it("libellé du bloc", () => expect(ActivityPomodoro.label(ring)).toBe("Bloc 1"));

  const pausedRing = ActivityPomodoro.make({ blockNumber: 2, elapsedInBlock: 300, remaining: 1200, completedBlocks: 1, running: false, now });
  it("en pause, aucun intervalle : un anneau qui continue de se remplir mentirait", () => {
    expect(ActivityPomodoro.interval(pausedRing)).toBeNull();
  });
  it("…mais la part faite reste connue", () => expect(Math.abs(pausedRing.frozenProgress - 0.2)).toBeLessThan(0.001));
  it("un bloc déjà terminé", () => expect(pausedRing.completedBlocks).toBe(1));

  const completeRing = ActivityPomodoro.make({ blockNumber: 1, elapsedInBlock: 1500, remaining: 0, completedBlocks: 1, running: true, now });
  it("un bloc à terme est marqué terminé", () => expect(ActivityPomodoro.isBlockComplete(completeRing)).toBe(true));
  it("…et n'anime plus rien : l'intervalle serait vide", () => expect(ActivityPomodoro.interval(completeRing)).toBeNull());

  // Le pont entre le moteur et l'anneau : ce que l'app fera réellement.
  const engineStatus = PomodoroEngine.status(1500 * 2 + 600, 25);
  const fromEngine = ActivityPomodoro.make({
    blockNumber: engineStatus.blockNumber, elapsedInBlock: engineStatus.elapsedInBlock,
    remaining: engineStatus.remaining, completedBlocks: engineStatus.completedBlocks, running: true, now,
  });
  it("le moteur donne le bloc 3, l'anneau le reprend", () => expect(fromEngine.blockNumber).toBe(3));
  it("…et ses deux blocs terminés", () => expect(fromEngine.completedBlocks).toBe(2));
  it("…sans changer la fraction que le moteur a calculée", () => {
    expect(Math.abs(fromEngine.frozenProgress - statusProgress(engineStatus))).toBeLessThan(0.001);
  });
});

describe("Live Activity : le jour d'examen", () => {
  // L'activité d'examen n'est déclenchée par aucun geste : elle s'ouvre et se ferme **par le temps**.
  const examAt = new Date(1_700_000_000 * 1000);
  it("une heure avant, l'épreuve est à venir", () => {
    expect(ExamActivityState.phase(examAt, at(examAt, -3600))).toBe("upcoming");
  });
  it("à l'heure pile, l'épreuve est en cours", () => expect(ExamActivityState.phase(examAt, examAt)).toBe("running"));
  it("une heure après le début, toujours en cours", () => {
    expect(ExamActivityState.phase(examAt, at(examAt, 3600))).toBe("running");
  });
  it("passé la durée supposée, l'épreuve est terminée", () => {
    expect(ExamActivityState.phase(examAt, at(examAt, ExamActivityState.assumedDuration + 1))).toBe("over");
  });

  // La fenêtre d'affichage : ni trop tôt, ni après coup.
  it("trois jours avant, aucune activité", () => {
    expect(ExamActivityState.isRelevant(examAt, at(examAt, -3 * 86400))).toBe(false);
  });
  it("juste avant la fenêtre, toujours rien", () => {
    expect(ExamActivityState.isRelevant(examAt, at(examAt, -ExamActivityState.lead - 60))).toBe(false);
  });
  it("dans les douze heures, l'activité s'affiche", () => {
    expect(ExamActivityState.isRelevant(examAt, at(examAt, -ExamActivityState.lead + 60))).toBe(true);
  });
  it("une demi-heure avant, elle est là", () => expect(ExamActivityState.isRelevant(examAt, at(examAt, -1800))).toBe(true));
  it("pendant l'épreuve, elle reste", () => expect(ExamActivityState.isRelevant(examAt, at(examAt, 1800))).toBe(true));
  it("après l'épreuve, elle disparaît — c'est ce qui laissait un îlot mort à l'écran", () => {
    expect(ExamActivityState.isRelevant(examAt, at(examAt, ExamActivityState.assumedDuration + 60))).toBe(false);
  });
  it("l'état publié reprend la phase déduite", () => {
    expect(ExamActivityState.make(examAt, at(examAt, -600)).phase).toBe("upcoming");
  });
});

describe("Pomodoro : le cycle travail / pause", () => {
  const cfg = makePomodoroSettings({ focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, longBreakEvery: 4, autoStartFocus: false });
  const t0 = new Date(1_800_000_000 * 1000);
  const s = newFocusTimerState({ runningSince: t0, sessionStartedAt: t0, pomodoro: true });
  const back = at(t0, 28 * 60);
  let events: ReturnType<typeof advance> = [];

  it("à 10 min, rien ne se passe", () => expect(advance(s, cfg, at(t0, 600))).toEqual([]));
  it("on travaille", () => expect(phase(s, cfg, at(t0, 600))).toEqual({ type: "working" }));
  it("le bloc finira à 25 min", () => expect(blockEndDate(s, cfg)).toEqual(at(t0, 1500)));

  // L'app revient 28 min après le départ : le bloc a fini à 25 min, pas à 28.
  it("le bloc 1 est annoncé fini", () => {
    events = advance(s, cfg, back);
    expect(events).toEqual([{ type: "blockEnded", block: 1, kind: "short" }]);
  });
  it("le travail est coupé **au terme** : 25 min, pas 28", () => expect(s.accumulated).toBe(1500));
  it("le chrono de travail est arrêté pendant la pause", () => expect(isRunning(s)).toBe(false));
  it("la pause a commencé à la fin du bloc", () => expect(s.breakStartedAt).toEqual(at(t0, 1500)));
  it("…et dure 5 min", () => expect(s.breakEndsAt).toEqual(at(t0, 1500 + 300)));
  it("la phase affichée est la pause", () => {
    expect(phase(s, cfg, back)).toMatchObject({ type: "onBreak", kind: "short" });
  });
  it("une session en pause Pomodoro reste une session vivante", () => expect(isRestorable(s, back)).toBe(true));

  // Fin de pause sans démarrage automatique : on attend un geste.
  const afterBreak = at(t0, 1500 + 360);
  it("la pause s'achève", () => {
    expect(advance(s, cfg, afterBreak)).toEqual([{ type: "breakEnded", nextBlock: 2 }]);
  });
  it("le bloc 2 attend un geste", () => expect(phase(s, cfg, afterBreak)).toEqual({ type: "readyForBlock", block: 2 }));
  it("la pause n'a rien ajouté au travail", () => expect(s.accumulated).toBe(1500));

  // Passer la pause relance le travail tout de suite.
  const skip = newFocusTimerState({ runningSince: t0, sessionStartedAt: t0, pomodoro: true });
  it("passer la pause relance le travail", () => {
    advance(skip, cfg, at(t0, 1510));
    skipBreak(skip, at(t0, 1520));
    expect(isRunning(skip) && currentBreak(skip) === null).toBe(true);
  });
  it("…à partir des 25 min comptées", () => expect(elapsed(skip, at(t0, 1580))).toBe(1560));

  // Allonger la pause.
  const longer = newFocusTimerState({ runningSince: t0, sessionStartedAt: t0, pomodoro: true });
  it("+5 min allonge la pause", () => {
    advance(longer, cfg, at(t0, 1500));
    extendBreak(longer, 300);
    expect(longer.breakEndsAt).toEqual(at(t0, 1500 + 600));
  });

  // Démarrage automatique : plusieurs cycles rattrapés d'un coup.
  const auto = { ...cfg, autoStartFocus: true };
  const chain = newFocusTimerState({ runningSince: t0, sessionStartedAt: t0, pomodoro: true });
  // 4 blocs de 25 + 3 pauses de 5 = 115 min ; on revient à 116 min.
  let chained: ReturnType<typeof advance> = [];
  it("quatre blocs rattrapés — 8 événements", () => {
    chained = advance(chain, auto, at(t0, 116 * 60));
    expect(chained.filter((e) => e.type === "blockEnded").length).toBe(4);
  });
  it("le quatrième bloc ouvre la pause longue", () => {
    expect(chained[chained.length - 1]).toEqual({ type: "blockEnded", block: 4, kind: "long" });
  });
  it("exactement 100 min de travail comptées", () => expect(chain.accumulated).toBe(4 * 1500));
  it("la pause longue dure 15 min", () => expect(chain.breakEndsAt).toEqual(at(t0, 115 * 60 + 900)));

  // Hors Pomodoro : aucune pause, jamais.
  const plain = newFocusTimerState({ runningSince: t0, sessionStartedAt: t0, pomodoro: false });
  it("hors Pomodoro, rien", () => expect(advance(plain, cfg, at(t0, 4000))).toEqual([]));
  it("…et le chrono continue", () => expect(isRunning(plain)).toBe(true));

  // Un état écrit avant l'ajout des pauses se relit.
  it("un chrono enregistré par l'ancienne version se relit", () => {
    const legacyState = decodeFocusTimerState(
      '{"accumulated":60,"sessionStartedAt":"2027-01-15T08:00:00Z","taskTypeRaw":"exercise","note":"","contextLabel":"","pomodoro":true}');
    expect(legacyState).not.toBeNull();
    expect(legacyState !== null && currentBreak(legacyState) === null && legacyState.accumulated === 60).toBe(true);
  });

  it("pause longue tous les quatre blocs", () => {
    expect(breakKindAfterBlock(cfg, 3) === "short" && breakKindAfterBlock(cfg, 8) === "long").toBe(true);
  });
});

describe("Pomodoro", () => {
  it("25 min = 1500 s", () => expect(PomodoroEngine.blockDuration(25)).toBe(1500));
  it("un bloc nul est borné à une minute — sinon la boucle d'alerte ne s'arrête jamais", () => {
    expect(PomodoroEngine.blockDuration(0)).toBe(60);
  });
  it("un bloc négatif est borné aussi", () => expect(PomodoroEngine.blockDuration(-10)).toBe(60));

  const begin = PomodoroEngine.status(0, 25);
  it("au départ, bloc 1", () => expect(begin.blockNumber).toBe(1));
  it("rien d'écoulé dans le bloc", () => expect(begin.elapsedInBlock).toBe(0));
  it("25 min restantes", () => expect(begin.remaining).toBe(1500));
  it("anneau à zéro", () => expect(statusProgress(begin)).toBe(0));
  it("bloc non terminé", () => expect(statusIsBlockComplete(begin)).toBe(false));

  const midway = PomodoroEngine.status(600, 25);
  it("10 min plus tard, toujours bloc 1", () => expect(midway.blockNumber).toBe(1));
  it("15 min restantes — 900 s", () => expect(midway.remaining).toBe(900));
  it("anneau à 40 % — 0.40", () => expect(Math.abs(statusProgress(midway) - 0.4)).toBeLessThan(0.001));

  // L'instant exact où la pause est due : c'est le cas qui compte.
  const exactly = PomodoroEngine.status(1500, 25);
  it("à 25 min pile, le bloc est terminé", () => expect(statusIsBlockComplete(exactly)).toBe(true));
  it("…et on est encore sur le bloc 1, pas déjà le 2", () => expect(exactly.blockNumber).toBe(1));
  it("un bloc terminé", () => expect(exactly.completedBlocks).toBe(1));
  it("anneau plein", () => expect(statusProgress(exactly)).toBe(1));

  const second = PomodoroEngine.status(1501, 25);
  it("une seconde plus tard, bloc 2", () => expect(second.blockNumber).toBe(2));
  it("toujours un bloc terminé", () => expect(second.completedBlocks).toBe(1));
  it("le nouveau bloc vient de commencer", () => expect(second.remaining).toBe(1499));

  const third = PomodoroEngine.status(1500 * 2 + 60, 25);
  it("après deux blocs et une minute, bloc 3", () => expect(third.blockNumber).toBe(3));
  it("deux blocs terminés", () => expect(third.completedBlocks).toBe(2));
  it("24 min restantes", () => expect(third.remaining).toBe(1440));
  it("libellé du bloc", () => expect(statusLabel(third)).toBe("Bloc 3"));

  it("un temps négatif ne produit pas un bloc négatif", () => {
    expect(PomodoroEngine.status(-5, 25).blockNumber).toBe(1);
  });
});

describe("Raccourcis du chrono", () => {
  const defaultShortcuts = FocusShortcutDefaults.make(["CS-250", "MATH-101"]);
  it("deux cours × deux natures = quatre raccourcis (4)", () => expect(defaultShortcuts.length).toBe(4));
  it("l'ordre des cours est conservé", () => expect(defaultShortcuts[0]?.courseCode).toBe("CS-250"));
  it("la vidéo vient en premier", () => expect(defaultShortcuts[0]?.taskTypeRaw).toBe("video"));
  it("puis les exercices", () => expect(defaultShortcuts[1].taskTypeRaw).toBe("exercise"));

  const manyCourses = Array.from({ length: 10 }, (_, i) => `C-${i + 1}`);
  it(`la proposition est plafonnée à ${FocusShortcutDefaults.maxDefaults}`, () => {
    expect(FocusShortcutDefaults.make(manyCourses).length).toBe(FocusShortcutDefaults.maxDefaults);
  });

  // Un cours supprimé ne doit pas laisser une tuile morte.
  const pruned = FocusShortcutDefaults.sanitize(
    [{ courseCode: "CS-250", taskTypeRaw: "video" },
      { courseCode: "DISPARU-1", taskTypeRaw: "video" },
      { courseCode: "CS-250", taskTypeRaw: "video" },
      { courseCode: "CS-250", taskTypeRaw: "exercise" }],
    new Set(["CS-250"]));
  it("cours disparu retiré et doublon supprimé (2)", () => expect(pruned.length).toBe(2));
  it("l'ordre est préservé", () => expect(pruned.map((p) => p.taskTypeRaw)).toEqual(["video", "exercise"]));
  it("une liste vide reste vide", () => expect(FocusShortcutDefaults.sanitize([], new Set())).toEqual([]));

  // Aller-retour JSON : c'est ainsi que les raccourcis sont conservés.
  const encoded = FocusShortcutDefaults.encode(defaultShortcuts);
  it("les raccourcis survivent à l'encodage", () => expect(FocusShortcutDefaults.decode(encoded)).toEqual(defaultShortcuts));
  it("un contenu illisible ne plante pas", () => expect(FocusShortcutDefaults.decode("pas du json")).toEqual([]));
  it("un contenu vide ne plante pas", () => expect(FocusShortcutDefaults.decode("")).toEqual([]));
  it("l'identifiant est stable — CS-250|video", () => {
    expect(focusShortcutId({ courseCode: "CS-250", taskTypeRaw: "video" })).toBe("CS-250|video");
  });
});

describe("FocusTimerState : le chrono survit à une fermeture", () => {
  const t0 = new Date(1_800_000_000 * 1000);
  const timer = newFocusTimerState({ sessionStartedAt: t0, taskTypeRaw: "exercise" });
  it("démarré : en cours", () => {
    start(timer, t0);
    expect(isRunning(timer)).toBe(true);
  });
  it("90 s écoulées après 90 s", () => expect(Math.trunc(elapsed(timer, at(t0, 90)))).toBe(90));
  it("pause : 120 s accumulées", () => {
    pause(timer, at(t0, 120));
    expect(!isRunning(timer) && Math.trunc(timer.accumulated) === 120).toBe(true);
  });
  it("en pause, le temps ne court plus", () => expect(Math.trunc(elapsed(timer, at(t0, 9_999)))).toBe(120));
  it("reprise : 120 + 60 = 180 s", () => {
    start(timer, at(t0, 200));
    expect(Math.trunc(elapsed(timer, at(t0, 260)))).toBe(180);
  });
  it("un second « start » en cours ne remet rien à zéro", () => {
    start(timer, at(t0, 300));
    expect(Math.trunc(elapsed(timer, at(t0, 360)))).toBe(280);
  });
  it("restaurable une heure plus tard", () => expect(isRestorable(timer, at(t0, 3_600))).toBe(true));
  it("plus restaurable au-delà de 18 h", () => {
    expect(isRestorable(timer, at(t0, maxRestorableAge + 1))).toBe(false);
  });
  it("un chrono à zéro n'est pas restauré", () => {
    expect(isRestorable(newFocusTimerState({ sessionStartedAt: t0 }), t0)).toBe(false);
  });

  const store = memoryStore();
  it("aller-retour UserDefaults sans perte", () => {
    FocusTimerStore.save(timer, store);
    expect(FocusTimerStore.load(store)).toEqual(timer);
  });
  it("effacement du chrono", () => {
    FocusTimerStore.save(null, store);
    expect(FocusTimerStore.load(store)).toBeNull();
  });
});

describe("Chrono : le temps suit l'exercice", () => {
  const t0 = new Date(1_800_000_000 * 1000);
  const course = "course", ex1 = "ex1", ex2 = "ex2", ex3 = "ex3";
  const timer = newFocusTimerState({ sessionStartedAt: t0, courseID: course, taskTypeRaw: "exercise", targetID: ex1 });
  start(timer, t0);
  // 40 min sur 3.1, puis 3.2 pendant 10 min, retour sur 3.1 pendant 5 min.
  it("la nouvelle cible part de zéro", () => {
    switchContext(timer, { courseID: course, taskTypeRaw: "exercise", targetID: ex2 }, at(t0, 2400));
    expect(currentTargetElapsed(timer, at(t0, 2460))).toBe(60);
  });
  it("revenir sur la même cible n'ouvre pas de segment", () => {
    switchContext(timer, { courseID: course, taskTypeRaw: "exercise", targetID: ex2 }, at(t0, 2500));
    expect(timer.segments?.length).toBe(1);
  });
  const end = at(t0, 3300);
  let parts: ReturnType<typeof allocation> = [];
  it("deux cibles, deux parts (2) — les passages sur 3.1 fusionnent", () => {
    switchContext(timer, { courseID: course, taskTypeRaw: "exercise", targetID: ex1 }, at(t0, 3000));
    parts = allocation(timer, end);
    expect(parts.length).toBe(2);
  });
  it("3.1 : 40 + 5 min", () => expect(parts.find((p) => p.targetID === ex1)?.seconds).toBe(2700));
  it("3.2 : 10 min", () => expect(parts.find((p) => p.targetID === ex2)?.seconds).toBe(600));
  it("la somme des sessions vaut exactement le temps affiché", () => {
    expect(allocatedSeconds(timer, end).reduce((sum, p) => sum + p.seconds, 0)).toBe(3300);
  });

  // Pause : le temps en pause n'est attribué à personne.
  const paused = newFocusTimerState({ sessionStartedAt: t0, courseID: course, taskTypeRaw: "exercise", targetID: ex1 });
  start(paused, t0);
  pause(paused, at(t0, 600));
  switchContext(paused, { courseID: course, taskTypeRaw: "exercise", targetID: ex3 }, at(t0, 5000));
  start(paused, at(t0, 5000));
  const pausedParts = allocation(paused, at(t0, 5300));
  it("une pause entre deux exercices ne compte pour aucun", () => {
    expect(pausedParts.find((p) => p.targetID === ex1)?.seconds).toBe(600);
  });
  it("…et le suivant ne compte que son temps", () => {
    expect(pausedParts.find((p) => p.targetID === ex3)?.seconds).toBe(300);
  });

  // Temps corrigé à la baisse sous la somme des segments : réduction proportionnelle.
  const corrected = { ...timer };
  pause(corrected, end);
  corrected.accumulated = 1650;
  const shrunk = allocatedSeconds(corrected, end);
  it("un total corrigé à la baisse reste la somme exacte", () => {
    expect(shrunk.reduce((sum, p) => sum + p.seconds, 0)).toBe(1650);
  });
  it("aucune session vide", () => expect(shrunk.every((p) => p.seconds >= 1)).toBe(true));

  // Un état écrit avant les segments se relit.
  const oldTimer = '{"accumulated":120,"sessionStartedAt":"2026-09-20T10:00:00Z","taskTypeRaw":"exercise","note":"","contextLabel":"","pomodoro":false}';
  const decoded = decodeFocusTimerState(oldTimer);
  it("un chrono d'avant les segments se relit", () => {
    expect(decoded).not.toBeNull();
    expect(decoded?.segments).toBeUndefined();
  });
  it("…et s'enregistre en une seule session", () => {
    expect(allocatedSeconds(decoded!, t0).map((p) => p.seconds)).toEqual([120]);
  });
});

describe("WidgetFormat : heures en dixièmes arrondis", () => {
  it("45 min", () => expect(WidgetFormat.hours(45 * 60)).toBe("45 min"));
  it("2 h", () => expect(WidgetFormat.hours(2 * 3600)).toBe("2 h"));
  it("1 h 35 → 1,6 h (l'ancien code donnait 1,3 h)", () => expect(WidgetFormat.hours(95 * 60)).toBe("1,6 h"));
  it("1 h 57 → 2 h (arrondi, pas 1,10)", () => expect(WidgetFormat.hours(117 * 60)).toBe("2 h"));
  it("1 h 03 → 1,1 h", () => expect(WidgetFormat.hours(63 * 60)).toBe("1,1 h"));
  it("négatif → 0 min", () => expect(WidgetFormat.hours(-5)).toBe("0 min"));
  it("J-3", () => {
    const inThreeDays = new Date();
    inThreeDays.setDate(inThreeDays.getDate() + 3);
    expect(WidgetFormat.countdown(inThreeDays)).toBe("J-3");
  });
  it("aujourd'hui", () => expect(WidgetFormat.countdown(new Date())).toBe("Aujourd'hui"));
});

describe("Mode étude : le chrono voyage (FocusTimerState seul)", () => {
  // Les contrôles de « Mode étude » qui ne touchent que le codage de l'état ;
  // ceux de StudyMode (isActive, enter, leave…) ne sont pas dans ce périmètre.
  const t0 = new Date(2_000_000_000 * 1000);
  const state = newFocusTimerState({ sessionStartedAt: t0 });
  start(state, t0);
  state.studyUntil = at(t0, 50 * 60);
  it("la fin du mode étude passe d'un appareil à l'autre", () => {
    expect(roundTrip(state)?.studyUntil).toEqual(state.studyUntil);
  });
  it("un chrono d'une version précédente se relit, sans mode étude", () => {
    const legacy = '{"accumulated":0,"sessionStartedAt":0,"taskTypeRaw":"exercise","note":"","contextLabel":"","pomodoro":false}';
    const decoded = decodeFocusTimerState(legacy);
    expect(decoded).not.toBeNull();
    expect(decoded?.studyUntil).toBeUndefined();
  });
  it("lever le mode étude est un changement (publié aux autres appareils)", () => {
    const changed = { ...state, studyUntil: undefined };
    expect(changed).not.toEqual(state);
  });
  it("un état d'avant se lit (champ absent)", () => {
    const old = roundTrip(newFocusTimerState());
    expect(old?.studyLocks).toBeUndefined();
  });
});

describe("Personnalisation : étapes de la session", () => {
  const flow = standardSessionFlow();
  it("session : les quatre étapes par défaut", () => expect(flow.steps).toEqual(["course", "series", "help", "debrief"]));
  it("session : une étape retirée", () => {
    toggleStep(flow, "course");
    expect(flow.steps).toEqual(["series", "help", "debrief"]);
  });
  it("session : remise à sa place", () => {
    toggleStep(flow, "course");
    expect(flow.steps).toEqual(["course", "series", "help", "debrief"]);
  });
  it("session : réordonnée", () => {
    moveStep(flow, "debrief", -3);
    expect(flow.steps[0]).toBe("debrief");
  });
  it("session : jamais vide", () => {
    const single = { steps: ["series" as const] };
    toggleStep(single, "series");
    expect(single.steps).toEqual(["series"]);
  });
});

describe("Sélecteur et recherche d'étude", () => {
  const model = new StudySwitcherModel();
  model.touch("pane:exercise"); model.touch("app:goodnotes"); model.touch("pane:course");
  const all = ["pane:desk", "pane:exercise", "pane:course", "app:goodnotes", "claude"];
  it("sélecteur : le plus récent d'abord, puis l'ordre donné", () => {
    expect(model.order(all)).toEqual(["pane:course", "app:goodnotes", "pane:exercise", "pane:desk", "claude"]);
  });
  it("sélecteur : seulement ce qui existe", () => {
    expect(model.order(["claude", "pane:course"])).toEqual(["pane:course", "claude"]);
  });
  it("sélecteur : pas de doublon", () => {
    model.touch("pane:exercise");
    expect(model.recent[0] === "pane:exercise" && model.recent.filter((id) => id === "pane:exercise").length === 1).toBe(true);
  });
  it("sélecteur : mémoire bornée", () => {
    for (let i = 0; i < 40; i++) model.touch(`x${i}`);
    expect(model.recent.length).toBe(StudySwitcherModel.memory);
  });
  it("sélecteur : en avant, en boucle", () => {
    expect(StudySwitcherModel.move(0, 1, 4) === 1 && StudySwitcherModel.move(3, 1, 4) === 0).toBe(true);
  });
  it("sélecteur : en arrière, en boucle ; vide", () => {
    expect(StudySwitcherModel.move(0, -1, 4) === 3 && StudySwitcherModel.move(0, 1, 0) === 0).toBe(true);
  });
  const m = StudySearchQuery.mathExpression;
  it("recherche : un calcul est un calcul", () => expect(m("2+3*4")).toBe("2+3*4"));
  it("recherche : « = » force le calcul", () => expect(m("= x^2 - 2")).toBe("x^2 - 2"));
  it("recherche : les fonctions connues", () => expect(m("sqrt(2)+1")).toBe("sqrt(2)+1"));
  it("recherche : « série 3 » et un code de cours restent des recherches", () => {
    expect(m("série 3") === null && m("PHYS-101") === null).toBe(true);
  });
  it("recherche : des mots, du vide", () => {
    expect(m("analyse") === null && m("") === null && m("=") === null).toBe(true);
  });
  it("recherche : un nombre seul n'est pas un calcul", () => expect(m("12")).toBeNull());
  const Q = StudySearchQuery;
  const G = Q.Group;
  it("recherche : un outil dont le nom commence par la requête passe avant", () => {
    expect(Q.group(G.tool, "GoodNotes", "good") === G.toolPrefix && Q.group(G.tool, "GoodNotes", "notes") === G.tool).toBe(true);
  });
  it("recherche : sans casse ni accents", () => {
    expect(Q.group(G.tool, "Calcul", "CALC") === G.toolPrefix && Q.group(G.tool, "Écrire", "ecr") === G.toolPrefix).toBe(true);
  });
  it("recherche : le reste garde son groupe", () => {
    expect(Q.group(G.content, "Série 3", "se") === G.content && Q.group(G.site, "x", "x") === G.site).toBe(true);
  });
  it("recherche : calcul, outil préfixé, contenu, autres outils, actions, gardés, sites", () => {
    expect(G.math < G.toolPrefix && G.toolPrefix < G.content && G.content < G.tool && G.tool < G.action
      && G.action < G.kept && G.kept < G.site).toBe(true);
  });
  it("recherche : une phrase devient une question pour Claude, un mot reste une recherche", () => {
    expect(Q.claudeQuestion("pourquoi la suite est croissante ?") !== null && Q.claudeQuestion("comment faire 3.2") !== null
      && Q.claudeQuestion("calcul") === null && Q.claudeQuestion("  ") === null && Q.claudeQuestion("quoi?") !== null).toBe(true);
  });
});

describe("Bande-son de la session", () => {
  type S = typeof SessionSoundtrack;
  const act = (from: SoundtrackPhase | null, to: SoundtrackPhase,
    o: { moment?: "lecture" | "series"; choice?: boolean; owns?: boolean; policy?: SoundtrackBreakPolicy } = {}) =>
    SessionSoundtrack.action({ from, to, moment: o.moment ?? "series", hasChoice: o.choice ?? true,
      ownsPlayback: o.owns ?? true, policy: o.policy ?? "pause" }) as ReturnType<S["action"]>;
  it("bande-son : démarre avec la session", () => expect(act(null, "running", { owns: false })).toBe("start"));
  it("bande-son : redémarre après une session finie", () => expect(act("ended", "running", { owns: false })).toBe("start"));
  it("bande-son : jamais pendant un cours", () => expect(act(null, "running", { moment: "lecture" })).toBe("none"));
  it("bande-son : rien sans playlist choisie", () => expect(act(null, "running", { choice: false })).toBe("none"));
  it("bande-son : fondu et pause pendant la pause", () => expect(act("running", "onBreak")).toBe("fadeOutAndPause"));
  it("bande-son : reprise en fondu après la pause", () => expect(act("onBreak", "running")).toBe("resumeAndFadeIn"));
  it("bande-son : baisser puis rétablir", () => {
    expect(act("running", "onBreak", { policy: "lower" }) === "lower" && act("onBreak", "running", { policy: "lower" }) === "restoreVolume").toBe(true);
  });
  it("bande-son : continuer pendant la pause", () => {
    expect(act("running", "onBreak", { policy: "keep" }) === "none" && act("onBreak", "running", { policy: "keep" }) === "none").toBe(true);
  });
  it("bande-son : la musique de l'étudiant·e n'est pas touchée pendant une pause", () => {
    expect(act("running", "onBreak", { owns: false })).toBe("none");
  });
  it("bande-son : une pause manuelle ne touche pas à la musique", () => {
    expect(act("running", "paused") === "none" && act("paused", "running") === "none").toBe(true);
  });
  it("bande-son : s'éteint à la fin", () => expect(act("running", "ended")).toBe("fadeOutAndStop"));
  it("bande-son : à la fin, sa propre musique reste", () => expect(act("running", "ended", { owns: false })).toBe("none"));
  it("bande-son : lancée avant un cours changé en cours de route, elle s'éteint quand même", () => {
    expect(act("running", "ended", { moment: "lecture" })).toBe("fadeOutAndStop");
  });
  const steps = SessionSoundtrack.fade(1, 0, 4);
  it("bande-son : fondu en paliers jusqu'à la cible", () => {
    expect(steps.length === 4 && steps[steps.length - 1] === 0 && Math.abs(steps[0] - 0.75) < 1e-9).toBe(true);
  });
  it("bande-son : le choix voyage en JSON", () => {
    const choice = { kind: "playlist" as const, id: "p.123", title: "Focus", shuffled: false };
    expect(SessionSoundtrack.decode(SessionSoundtrack.encode(choice)) !== null
      && JSON.stringify(SessionSoundtrack.decode(SessionSoundtrack.encode(choice))) === JSON.stringify(choice)
      && SessionSoundtrack.decode(null) === null && SessionSoundtrack.decode("x") === null).toBe(true);
  });
});

describe("Pomodoro allumé en cours de séance", () => {
  const cycle = makePomodoroSettings({ focusMinutes: 25, shortBreakMinutes: 5 });
  const t0 = new Date(100_000 * 1000);
  // Une séance de 37 minutes de travail, le chrono tourne.
  const state = newFocusTimerState({ accumulated: 37 * 60, runningSince: t0, sessionStartedAt: at(t0, -37 * 60), pomodoro: false });
  it("pomodoro : sans origine, le cycle compte depuis le début", () => {
    expect(cycleOriginSeconds(state) === 0 && cycleAccumulated(state) === 37 * 60).toBe(true);
  });
  it("pomodoro : allumé à 39 min de travail, le cycle repart de zéro", () => {
    setPomodoro(state, true, at(t0, 120));
    expect(state.pomodoro && Math.abs(cycleOriginSeconds(state) - 39 * 60) < 0.01 && cycleAccumulated(state) === 0).toBe(true);
  });
  it("pomodoro : le temps déjà travaillé reste compté", () => {
    expect(Math.abs(elapsed(state, at(t0, 120)) - 39 * 60)).toBeLessThan(0.01);
  });
  it("pomodoro : le premier bloc dure un bloc entier à partir de maintenant", () => {
    expect(blockEndDate(state, cycle)).toEqual(at(t0, 120 + 25 * 60));
  });
  // Avant la fin du bloc : rien ; à la fin : une pause.
  it("pomodoro : pas de pause avant la fin du bloc", () => {
    expect(advance(state, cycle, at(t0, 120 + 24 * 60))).toEqual([]);
  });
  it("pomodoro : à la fin du premier bloc, la première pause", () => {
    expect(advance(state, cycle, at(t0, 120 + 26 * 60))).toEqual([{ type: "blockEnded", block: 1, kind: "short" }]);
  });
  it("pomodoro : le travail est coupé à la frontière du bloc", () => {
    expect(Math.abs(state.accumulated - (39 + 25) * 60) < 0.01 && currentBreak(state) !== null).toBe(true);
  });
  it("pomodoro : le statut compte depuis l'origine", () => {
    const status = PomodoroEngine.status(64 * 60, 25, 39 * 60);
    expect(status.completedBlocks === 1 && status.blockNumber === 1).toBe(true);
  });
  // La pause finie, le bloc suivant : numéro 2.
  it("pomodoro : la pause finit", () => {
    advance(state, cycle, at(t0, 120 + 26 * 60 + 5 * 60 + 1));
    expect(currentBreak(state)).toBeNull();
  });
  // Couper pendant une pause : la pause s'arrête, le travail reprend.
  const onBreak = newFocusTimerState({ accumulated: 25 * 60, sessionStartedAt: t0, pomodoro: true });
  it("pomodoro : coupé pendant une pause, la pause s'arrête et le travail reprend", () => {
    const paused = { ...state };
    skipBreak(paused, at(t0, 4000));
    onBreak.breakKindRaw = "short";
    onBreak.breakStartedAt = t0;
    onBreak.breakEndsAt = at(t0, 300);
    setPomodoro(onBreak, false, at(t0, 60));
    expect(!onBreak.pomodoro && currentBreak(onBreak) === null && onBreak.cycleOrigin === undefined && onBreak.runningSince !== undefined).toBe(true);
  });
  // Rallumer plus tard repart d'un bloc plein.
  it("pomodoro : rallumé, un nouveau cycle", () => {
    setPomodoro(onBreak, true, at(t0, 600));
    expect(cycleOriginSeconds(onBreak) > 25 * 60 && Math.abs(cycleAccumulated(onBreak)) < 0.01).toBe(true);
  });
  // Ancien état sans origine : lu comme avant.
  it("pomodoro : un état d'avant se lit comme avant", () => {
    const legacy = newFocusTimerState({ accumulated: 50 * 60, sessionStartedAt: t0, pomodoro: true });
    expect(PomodoroEngine.status(50 * 60, 25).completedBlocks === 2 && legacy.cycleOrigin === undefined).toBe(true);
  });
  // Aller-retour JSON, groupe compris.
  it("pomodoro : l'origine voyage d'un appareil à l'autre", () => {
    expect(roundTrip(state)?.cycleOrigin).toBe(state.cycleOrigin);
  });
  it("pomodoro : l'horloge d'un groupe la porte aussi", () => {
    expect(GroupClock.from(state).cycleOrigin).toBe(state.cycleOrigin);
  });
});

describe("Réveil des autres appareils (verrou)", () => {
  it("réveil : un premier état verrouillé réveille", () => expect(TimerLink.shouldWake(null, true)).toBe(true));
  it("réveil : un premier état libre, non", () => expect(TimerLink.shouldWake(null, false)).toBe(false));
  it("réveil : le verrou se lève", () => expect(TimerLink.shouldWake(true, false)).toBe(true));
  it("réveil : rien ne change, rien n'est envoyé", () => expect(TimerLink.shouldWake(true, true)).toBe(false));
});

describe("Entre appareils : chrono partagé — voie instantanée (canal, clé, chiffrement)", () => {
  // Voie instantanée : même canal et même clé sur chaque appareil, contenu illisible sans la clé.
  it("le canal se déduit de l'identité iCloud, pareil partout", async () => {
    expect(await TimerLink.channel("_abc")).toBe(await TimerLink.channel("_abc"));
    expect(await TimerLink.channel("_abc")).not.toBe(await TimerLink.channel("_abd"));
  });
  it("le nom du canal ne révèle pas l'identité", async () => {
    expect((await TimerLink.channel("_abc")).includes("abc")).toBe(false);
  });
  // Le contenu d'un instantané (CloudRelay.TimerSnapshot, hors périmètre) : l'état du chrono encodé.
  const t0 = new Date(2_000_000_000 * 1000);
  const session = newFocusTimerState({ sessionStartedAt: t0 });
  start(session, t0);
  pause(session, at(t0, 60));
  const snapshot = { state: encodeFocusTimerState(session), endedSession: "2033-05-18T03:33:20Z", updatedAt: 42, device: "mac" };
  it("chiffré puis déchiffré : le même état", async () => {
    const key = await TimerLink.key("_abc");
    const sealed = await TimerLink.seal(snapshot, key);
    expect(sealed).not.toBeNull();
    expect(await TimerLink.open(sealed!, key)).toEqual(snapshot);
  });
  it("une autre clé ne lit rien", async () => {
    const sealed = await TimerLink.seal(snapshot, await TimerLink.key("_abc"));
    expect(await TimerLink.open(sealed!, await TimerLink.key("_autre"))).toBeNull();
  });
});

describe("Session de groupe : l'horloge commune, le travail à soi", () => {
  const begin = new Date(1_800_000_000 * 1000);
  const host = newFocusTimerState({ sessionStartedAt: begin, pomodoro: true });
  host.cycle = makePomodoroSettings({ focusMinutes: 50, shortBreakMinutes: 10 });
  start(host, begin);
  const clock = GroupClock.from(host);
  const link = { sessionID: "s", groupID: "g", groupName: "BA3" };
  const joinedAt = at(begin, 20 * 60);
  const course = "course-uuid";
  const joiner = GroupClock.joining(clock, link, { courseID: course, taskTypeRaw: "exercise" }, joinedAt);
  it("le membre qui rejoint finit le bloc au même instant que l'hôte", () => {
    expect(blockEndDate(joiner, cycleOr(joiner, makePomodoroSettings()))).toEqual(blockEndDate(host, host.cycle!));
  });
  it("seul le temps depuis son arrivée est à lui (25 min sur 45), sur son cours", () => {
    const end = at(begin, 45 * 60);
    const own = allocatedSeconds(joiner, end).filter((p) => p.segment.excluded !== true);
    expect(own.reduce((sum, p) => sum + p.seconds, 0) === 25 * 60 && own.every((p) => p.segment.courseID === course)).toBe(true);
  });
  it("une pause de l'hôte arrête le chrono du membre, qui garde son cours et son lien", () => {
    const paused = { ...host };
    pause(paused, at(begin, 30 * 60));
    GroupClock.apply(GroupClock.from(paused), joiner);
    expect(!isRunning(joiner) && joiner.courseID === course && joiner.groupSession === link).toBe(true);
  });
});

describe("Chrono partagé : le cycle Pomodoro voyage avec la session", () => {
  const begin = new Date(1_800_000_000 * 1000);
  const mac = makePomodoroSettings({ focusMinutes: 50, shortBreakMinutes: 10 });
  const phone = makePomodoroSettings({ focusMinutes: 25, shortBreakMinutes: 5 });
  const session = newFocusTimerState({ sessionStartedAt: begin, pomodoro: true });
  session.cycle = mac;
  start(session, begin);
  // L'iPhone (25/5) lit la session démarrée sur le Mac (50/10) : même fin de bloc.
  it("le bloc finit à 50 min sur les deux appareils, pas à 25 sur l'iPhone", () => {
    expect(blockEndDate(session, cycleOr(session, phone))).toEqual(at(begin, 50 * 60));
  });
  it("à 30 min, l'iPhone ne coupe pas le bloc du Mac", () => {
    const onPhone = { ...session };
    const events = advance(onPhone, cycleOr(onPhone, phone), at(begin, 30 * 60));
    expect(events.length === 0 && isRunning(onPhone)).toBe(true);
  });
  it("le cycle est publié avec l'état", () => expect(roundTrip(session)?.cycle).toEqual(mac));
  it("un état d'avant (sans cycle) prend les réglages de l'appareil", () => {
    const old = { ...session };
    old.cycle = undefined;
    expect(cycleOr(roundTrip(old)!, phone)).toEqual(phone);
  });
});

describe("Mode étude : garder le Mac éveillé", () => {
  const plugged = KeepAwakePolicy.plugged;
  const hold = (mode: "off" | "system" | "display", running: boolean, onBreak: boolean, power: ReturnType<typeof KeepAwakePolicy.power>) =>
    KeepAwakePolicy.hold({ mode, studying: true, running, onBreak, power });
  it("veille : réglage « Non », rien n'est tenu", () => expect(hold("off", true, false, plugged)).toBeNull());
  it("veille : hors mode étude, rien n'est tenu", () => {
    expect(KeepAwakePolicy.hold({ mode: "display", studying: false, running: true, onBreak: false, power: plugged })).toBeNull();
  });
  it("veille : chrono en pause, le Mac dort", () => expect(hold("display", false, false, plugged)).toBeNull());
  it("veille : « Le Mac », l'écran s'éteint comme d'habitude", () => expect(hold("system", true, false, plugged)).toBe("system"));
  it("veille : « Le Mac et l'écran », sur secteur", () => expect(hold("display", true, false, plugged)).toBe("display"));
  it("veille : pause Pomodoro, l'écran peut s'éteindre", () => expect(hold("display", false, true, plugged)).toBe("system"));
  it("veille : économie d'énergie, l'écran n'est plus tenu", () => {
    expect(hold("display", true, false, KeepAwakePolicy.power({ lowPowerMode: true }))).toBe("system");
  });
  it("veille : batterie sous 20 %, l'écran n'est plus tenu", () => {
    expect(hold("display", true, false, KeepAwakePolicy.power({ onBattery: true, batteryLevel: 0.15 }))).toBe("system");
  });
  it("veille : batterie suffisante, l'écran reste allumé", () => {
    expect(hold("display", true, false, KeepAwakePolicy.power({ onBattery: true, batteryLevel: 0.6 }))).toBe("display");
  });
  const now = new Date(1_600_000_000 * 1000);
  it("veille : l'assertion expire avec la session (plus une marge)", () => {
    expect(KeepAwakePolicy.expiry(at(now, 3000), now)).toEqual(at(now, 3000 + KeepAwakePolicy.endMargin));
  });
  it("veille : session sans fin, un bail de deux heures renouvelé", () => {
    expect(KeepAwakePolicy.expiry(null, now)).toEqual(at(now, KeepAwakePolicy.openEndedLease));
  });
});

describe("Tenir pour terminer (le geste et son temps)", () => {
  const hold = new HoldProgress(1.5);
  it("tenir : la barre suit le temps à mi-chemin", () => {
    expect(hold.fraction(0) === 0 && hold.fraction(0.75) === 0.5).toBe(true);
  });
  it("tenir : la barre avance dès le premier instant (le doigt voit qu'il est pris en compte)", () => {
    expect(hold.fraction(0.01)).toBeGreaterThan(0);
  });
  it("tenir : au bout du temps, le geste compte", () => expect(hold.isComplete(1.5) && hold.isComplete(9)).toBe(true));
  it("tenir : juste avant, il ne compte pas encore", () => expect(hold.isComplete(1.49)).toBe(false));
  it("tenir : la barre ne déborde pas", () => expect(hold.fraction(99)).toBe(1));
  it("tenir : ce qui reste se dit au doigt", () => expect(hold.remaining(0.5)).toBe(1));
  // Une sortie d'urgence tient huit secondes (StudyMode.emergencyHold, hors périmètre : 8).
  it("tenir : la sortie d'urgence demande bien ses huit secondes", () => {
    const urgent = new HoldProgress(8);
    expect(!urgent.isComplete(1.5) && urgent.isComplete(8)).toBe(true);
  });
  // Le doigt qui glisse : la page défile, l'appui se relâche.
  it("tenir : un doigt qui bouge un peu reste sur le bouton", () => {
    expect(HoldProgress.isOnButton({ width: 30, height: 30 })).toBe(true);
  });
  it("tenir : un doigt qui glisse de 60 points relâche l'appui (le défilement reprend)", () => {
    expect(HoldProgress.isOnButton({ width: 0, height: 60 })).toBe(false);
  });
  it("tenir : une glissade latérale aussi", () => expect(HoldProgress.isOnButton({ width: -200, height: 5 })).toBe(false));
  // Un appui bref dit quoi faire ; un tapotement ne le dit pas à chaque fois.
  it("tenir : lâché trop tôt, on dit quoi faire", () => expect(hold.shouldExplainRelease(0.5)).toBe(true));
  it("tenir : un vrai tapotement ne déclenche pas de conseil", () => expect(hold.shouldExplainRelease(0.02)).toBe(false));
  it("tenir : une fois tenu, rien à expliquer", () => expect(hold.shouldExplainRelease(2)).toBe(false));
  // Un bouton sans tenir (clic) agit au contact.
  it("tenir : un bouton qui n'attend pas de tenir agit au contact", () => {
    const click = new HoldProgress(0);
    expect(click.isComplete(0) && !click.shouldExplainRelease(0)).toBe(true);
  });
  it("tenir : un temps négatif ne fait pas tenir à l'envers", () => expect(new HoldProgress(-3).duration).toBe(0));
});

describe("Ancre du chrono (tickAnchor)", () => {
  const t0 = new Date(2_000_000_000 * 1000);
  it("l'ancre est décalée de 50 ms pour ne pas tomber pile sur la frontière", () => {
    const state = newFocusTimerState({ sessionStartedAt: t0 });
    expect(tickAnchor(state)).toEqual(new Date(t0.getTime() + 50));
  });
});
