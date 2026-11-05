// Ce que Claude rapporte d'une série, lu dans le bloc ```studytrack qui termine
// sa réponse : corrections, erreurs du carnet, exercices admis dans la file de
// reprise et indices donnés (StudyTrack/Domain/SeriesReview.swift).
//
// Rien n'est noté sans que l'étudiant·e le confirme — sauf les indices, un
// simple journal.
//
// Le format est fait pour être écrit par Claude et relu sans ambiguïté, une
// ligne par fait :
//
// ```studytrack
// 2 : faux
// erreur 2 | méthode | oubli de vérifier la continuité en 0 | vérifier f continue en 0 avant le TAF | continuité
// reprise 2 | méthode : n'a pas vu le critère | Pose M_n = sup |f_n(x)|
// indice 3 | 2 | Le critère de Weierstrass s'applique : vérifie la majoration
// ```

import { Correctness, MistakeKind as MistakeKindValue } from "../models/enums.ts";
import { Mistake } from "../models/mistake.ts";
import type { Exercise } from "../models/exercise.ts";
import type { ExerciseSeries } from "../models/exercise.ts";
import type { Course } from "../models/course.ts";
import type { ModelStore } from "../models/store.ts";
import { DateUtils } from "./dateUtils.ts";
import { characters, isLetter, isNumber } from "./textRepair.ts";
import { trimAll, trimWhitespaces } from "../models/util.ts";
// Les méthodes `correct` / `setDone` viennent de l'extension `Exercise`.
import "./exerciseFlow.ts";

// MARK: Types

export interface MistakeNote {
  exercise: string;
  kind: MistakeKindValue;
  /** Précis : « oubli de vérifier l'hypothèse de continuité en 0 ». */
  summary: string;
  /** La bonne démarche, en une ou deux phrases. */
  correction: string;
  /** La notion en jeu. */
  notion: string;
}

export interface Admission {
  exercise: string;
  /** Le type d'erreur et ce qui a coincé, en une phrase. */
  why: string;
  /** Le premier geste — jamais la solution. Montré seulement après une
   * tentative, en reprise. */
  firstMove: string;
}

export interface Hint {
  exercise: string;
  /** 1 orientation · 2 outil · 3 amorce · 4 solution. */
  level: number;
  text: string;
}

export interface ReviewVerdict {
  exercise: string;
  result: Correctness;
}

export class Report {
  verdicts: ReviewVerdict[] = [];
  mistakes: MistakeNote[] = [];
  admissions: Admission[] = [];
  hints: Hint[] = [];

  get isEmpty(): boolean {
    return this.verdicts.length === 0 && this.mistakes.length === 0
      && this.admissions.length === 0 && this.hints.length === 0;
  }
  /** Ce qui demande une confirmation (les indices s'écrivent seuls). */
  get needsConfirmation(): boolean {
    return this.verdicts.length !== 0 || this.mistakes.length !== 0 || this.admissions.length !== 0;
  }
}

export class Features {
  mistakes = true;
  redo = true;
  hints = true;
  redoPerSeries = 2;

  constructor(init: Partial<Features> = {}) {
    Object.assign(this, init);
  }
}

// MARK: Lecture

const fold = (text: string): string => text.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();

/** `Int(String)` de Swift. */
function swiftInt(text: string): number | null {
  return /^[+-]?\d+$/.test(text) ? Number(text) : null;
}

/** `split(separator:maxSplits:omittingEmptySubsequences: false)`, puis trim. */
function splitFields(text: string, limit: number): string[] {
  const pieces: string[] = [];
  let rest = text;
  for (let index = 0; index < limit - 1; index++) {
    const at = rest.indexOf("|");
    if (at < 0) break;
    pieces.push(rest.slice(0, at));
    rest = rest.slice(at + 1);
  }
  pieces.push(rest);
  return pieces.map((piece) => trimWhitespaces(piece));
}

/// « erreur 2 | méthode | … » → ["2", "méthode", …] ; « Ex. 2 », « exercice 2 » → « 2 ».
/// Au plus `limit` champs : le dernier garde ses « | » (une valeur absolue dans une amorce).
function pipeFields(line: string, keyword: string, limit: number): string[] {
  let body = line.slice(keyword.length).replace(/^[ :]+|[ :]+$/g, "");
  for (const prefix of ["exercice", "ex.", "ex"]) {
    if (body.toLowerCase().startsWith(prefix)) {
      body = trimWhitespaces(body.slice(prefix.length));
      break;
    }
  }
  return splitFields(body, limit);
}

/// « 6.3 | 1 | … » : Claude oublie souvent le mot « indice » (vu en vrai).
function bareHint(line: string): Hint | null {
  const fields = splitFields(line, 3);
  if (fields.length !== 3 || fields[2] === "") return null;
  const exercise = fields[0];
  const first = characters(exercise)[0];
  if (first === undefined || !isNumber(first)) return null;
  if (![...characters(exercise)].every((c) => isNumber(c) || c === "." || c === "-")) return null;
  const level = swiftInt(fields[1]);
  if (level === null || !(level >= 1 && level <= 4)) return null;
  return { exercise, level, text: fields[2] };
}

/// Les verdicts du bloc ```studytrack d'une réponse.
function verdicts(inText: string): ReviewVerdict[] {
  const open = inText.indexOf("```studytrack");
  if (open < 0) return [];
  const after = inText.slice(open + "```studytrack".length);
  const close = after.indexOf("```");
  const block = close < 0 ? after : after.slice(0, close);
  const result: ReviewVerdict[] = [];
  for (const raw of block.split("\n")) {
    const colon = raw.indexOf(":");
    if (colon < 0) continue;
    const first = trimWhitespaces(raw.slice(0, colon));
    if (first === "") continue;
    const word = fold(trimWhitespaces(raw.slice(colon + 1)));
    let correctness: Correctness;
    if (word.startsWith("juste") || word.startsWith("correct")) correctness = "correct";
    else if (word.startsWith("moy") || word.startsWith("partiel")) correctness = "partial";
    else if (word.startsWith("faux") || word.startsWith("fausse")) correctness = "wrong";
    else continue;
    let number = first;
    for (const prefix of ["exercice", "ex.", "ex"]) {
      if (number.toLowerCase().startsWith(prefix)) {
        number = trimWhitespaces(number.slice(prefix.length));
        break;
      }
    }
    result.push({ exercise: number, result: correctness });
  }
  return result;
}

function blocks(inText: string): string[] {
  const found: string[] = [];
  let rest = inText;
  for (;;) {
    const open = rest.indexOf("```studytrack");
    if (open < 0) break;
    const after = rest.slice(open + "```studytrack".length);
    const close = after.indexOf("```");
    found.push(close < 0 ? after : after.slice(0, close));
    rest = close < 0 ? "" : after.slice(close + 3);
  }
  return found;
}

/// Tous les blocs ```studytrack d'une réponse, lus ligne à ligne.
function parse(text: string): Report {
  const report = new Report();
  for (const block of blocks(text)) {
    for (const raw of block.split("\n")) {
      const line = trimWhitespaces(raw);
      if (line === "") continue;
      const lower = fold(line);
      if (lower.startsWith("erreur")) {
        const fields = pipeFields(line, "erreur", 5);
        const kind = fields.length >= 3 ? SeriesReview.MistakeKind.parse(fields[1]) : null;
        if (fields.length < 3 || kind === null || fields[0] === "" || fields[2] === "") continue;
        report.mistakes.push({
          exercise: fields[0],
          kind,
          summary: fields[2],
          correction: fields.length > 3 ? fields[3] : "",
          notion: fields.length > 4 ? fields[4] : "",
        });
      } else if (lower.startsWith("reprise")) {
        const fields = pipeFields(line, "reprise", 3);
        if (fields.length < 2 || fields[0] === "") continue;
        // L'amorce est le dernier champ : elle peut contenir « | » (une valeur absolue).
        report.admissions.push({
          exercise: fields[0],
          why: fields[1],
          firstMove: fields.length > 2 ? fields[2] : "",
        });
      } else if (lower.startsWith("indice")) {
        const fields = pipeFields(line, "indice", 3);
        const digits = (fields[1] ?? "").split("").filter((c) => /^[0-9]$/.test(c)).join("");
        const level = digits === "" ? null : swiftInt(digits);
        if (fields.length < 3 || fields[0] === "" || level === null) continue;
        report.hints.push({
          exercise: fields[0],
          level: Math.min(4, Math.max(1, level)),
          text: fields[2],
        });
      } else {
        const hint = bareHint(line);
        if (hint !== null) {
          // « 6.3 | 1 | … » : Claude oublie souvent le mot « indice » (vu en vrai).
          report.hints.push(hint);
        } else {
          const verdict = verdicts(`\`\`\`studytrack\n${line}\n\`\`\``)[0];
          if (verdict) report.verdicts.push(verdict);
        }
      }
    }
  }
  return report;
}

/// La réponse sans ses blocs (ils s'affichent en carte à part).
function withoutBlocks(text: string): string {
  let copy = text;
  for (;;) {
    const open = copy.indexOf("```studytrack");
    if (open < 0) break;
    const after = copy.indexOf("```", open + "```studytrack".length);
    copy = copy.slice(0, open) + (after < 0 ? "" : copy.slice(after + 3));
  }
  return trimAll(copy);
}

// MARK: Les consignes

/// Le format, tel qu'on le décrit à Claude — selon ce qui est allumé.
function instruction(features: Features): string {
  const lines = ["Termine par un bloc de code ```studytrack, une ligne par fait :",
    "- « numéro : juste », « numéro : moyen » ou « numéro : faux » pour chaque exercice corrigé ;"];
  if (features.mistakes) {
    lines.push("- « erreur numéro | type | résumé précis | la bonne démarche en une phrase | notion » pour chaque écart, même une étourderie ; type parmi calcul, méthode, compréhension, étourderie, lacune de cours, gestion du temps, lecture de l'énoncé ;");
  }
  if (features.redo) {
    lines.push(`- « reprise numéro | type d'erreur et ce qui a coincé | le premier geste (jamais la solution) » pour les exercices à refaire sur papier : seulement des erreurs de méthode ou des lacunes de cours, que l'étudiant·e ne saurait pas refaire sans ses notes, ${features.redoPerSeries} au plus pour la série.`);
  }
  lines.push("Polymestre le propose à l'étudiant·e, qui confirme avant que rien ne soit noté.");
  return lines.join("\n");
}

/// La consigne des indices, pendant la résolution.
const hintInstruction = "Quand tu donnes un indice sur un exercice, ajoute à la fin de ta réponse un bloc ```studytrack "
  + "d'une ligne, **avec le mot « indice »** : « indice 6.3 | 2 | l'indice en une phrase », niveau 1 (orientation), "
  + "2 (outil), 3 (amorce) ou 4 (solution). Polymestre le note pour la reprise et le post-mortem.";

// MARK: La file de reprise

export type RedoStep = { days: number } | "exam";

export class RedoLadderConfig {
  steps: RedoStep[] = [{ days: 7 }, { days: 21 }, "exam"];
  /** Au plus, par série (l'admission est stricte, sinon la file meurt). */
  maxPerSeries = 2;
  /** Au-delà, on le dit : l'admission a été trop large. */
  maxActive = 10;
  /** Combien d'exercices par séance de reprise. */
  perSession = 3;

  constructor(init: Partial<RedoLadderConfig> = {}) {
    Object.assign(this, init);
  }

  /// `init(from:)` : chaque champ retombe sur sa valeur par défaut.
  static fromJSON(raw: unknown): RedoLadderConfig {
    const config = new RedoLadderConfig();
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return config;
    const object = raw as Record<string, unknown>;
    if (Array.isArray(object.steps)) {
      const steps: RedoStep[] = [];
      let valid = true;
      for (const step of object.steps) {
        if (typeof step === "number" && Number.isFinite(step)) steps.push({ days: Math.trunc(step) });
        else if (step === "exam") steps.push("exam");
        else { valid = false; break; }
      }
      if (valid && steps.length > 0) config.steps = steps;
    }
    if (typeof object.maxPerSeries === "number" && Number.isInteger(object.maxPerSeries)) {
      config.maxPerSeries = object.maxPerSeries;
    }
    if (typeof object.maxActive === "number" && Number.isInteger(object.maxActive)) {
      config.maxActive = object.maxActive;
    }
    if (typeof object.perSession === "number" && Number.isInteger(object.perSession)) {
      config.perSession = object.perSession;
    }
    return config;
  }
}

export type RedoResult = "cleared" | "passed" | "failed";

export interface RedoOutcome {
  /** `null` : sorti de la file. */
  pass: number | null;
  due: Date | null;
  failures: number;
  /** Deux échecs de suite : une lacune de cours, pas un manque d'entraînement. */
  gap: boolean;
}

/// Refaire sur papier, à intervalles : J+7 → J+21 → avant l'examen, par
/// défaut ; trois passes. Réussi sans notes à n'importe quelle passe : sorti.
/// Raté : la même passe, une semaine plus tard ; deux échecs de suite, c'est
/// une lacune de cours (on le dit).
export const RedoLadder = {
  Config: RedoLadderConfig,

  Result: {
    allCases: ["cleared", "passed", "failed"] as readonly RedoResult[],
    label(result: RedoResult): string {
      switch (result) {
        case "cleared": return "Réussi sans notes";
        case "passed": return "Réussi avec aide";
        case "failed": return "Raté";
      }
    },
  },

  stepLabel(step: RedoStep): string {
    return step === "exam" ? "Pré-examen" : `J+${step.days}`;
  },

  /// Quand refaire, à une passe donnée. `exam` : quelques jours avant
  /// l'examen du cours (sans date d'examen : pas de date).
  due(step: RedoStep, from: Date, examDate: Date | null): Date | null {
    if (step === "exam") {
      if (examDate === null) return null;
      return DateUtils.addDays(-5, DateUtils.startOfDay(examDate));
    }
    return DateUtils.addDays(step.days, DateUtils.startOfDay(from));
  },

  /// Après une reprise : le palier suivant et sa date.
  after(result: RedoResult, pass: number, failures: number, config: RedoLadderConfig,
    now: Date, examDate: Date | null): RedoOutcome {
    switch (result) {
      case "cleared":
        return { pass: null, due: null, failures: 0, gap: false };
      case "passed": {
        const next = pass + 1;
        if (!(next >= 0 && next < config.steps.length)) {
          return { pass: null, due: null, failures: 0, gap: false };
        }
        return {
          pass: next,
          due: RedoLadder.due(config.steps[next], now, examDate),
          failures: 0,
          gap: false,
        };
      }
      case "failed": {
        const count = failures + 1;
        return {
          pass,
          due: DateUtils.addDays(7, DateUtils.startOfDay(now)),
          failures: count,
          gap: count >= 2,
        };
      }
    }
  },

  /// Ce qu'on peut admettre d'une série : les admissions proposées, dans
  /// l'ordre, sans dépasser le plafond (moins ce qui y est déjà).
  admissible(proposed: Admission[], alreadyQueued: number, config: RedoLadderConfig): Admission[] {
    return proposed.slice(0, Math.max(0, config.maxPerSeries - alreadyQueued));
  },
};

// MARK: Noter un rapport

export class Applied {
  corrected = 0;
  mistakes = 0;
  queued: string[] = [];
  /** Admissions refusées : plafond de la série atteint. */
  overCap: string[] = [];
  unmatched: string[] = [];

  get summary(): string {
    const parts: string[] = [];
    if (this.corrected > 0) parts.push(`${this.corrected} correction${this.corrected > 1 ? "s" : ""}`);
    if (this.mistakes > 0) parts.push(`${this.mistakes} erreur${this.mistakes > 1 ? "s" : ""} au carnet`);
    if (this.queued.length > 0) parts.push(`en reprise : ${this.queued.join(", ")}`);
    if (this.overCap.length > 0) parts.push(`écarté${this.overCap.length > 1 ? "s" : ""} (plafond) : ${this.overCap.join(", ")}`);
    return parts.length === 0 ? "Rien de nouveau." : parts.join(" · ");
  }
}

/// L'exercice que désigne un numéro du rapport (« 2 », « 1.3 », « Ex 2 »).
export function matchExercise(label: string, numbers: string[]): number | null {
  const key = (text: string): string => {
    const filtered = [...characters(text)].filter((c) => isNumber(c) || c === "." || isLetter(c)).join("").toLowerCase();
    return filtered.split("exercice").join("").replace(/^[.]+|[.]+$/g, "");
  };
  const wanted = key(label);
  if (wanted === "") return null;
  const exact = numbers.map((number, index) => key(number) === wanted ? index : -1)
    .filter((index) => index >= 0);
  if (exact.length === 1) return exact[0];
  // « 3 » pour « Ex-03-03 » : le dernier nombre.
  const wantedValue = swiftInt(wanted);
  const tail = numbers.map((number, index) => {
    const groups = number.split(/[^0-9]/).filter((part) => part !== "");
    const digits = groups[groups.length - 1];
    const value = digits === undefined ? -1 : (swiftInt(digits) ?? -1);
    return value === (wantedValue ?? -2) ? index : -1;
  }).filter((index) => index >= 0);
  return tail.length === 1 ? tail[0] : null;
}

/// L'exercice que désigne un numéro du rapport.
export function exercise(label: string, series: ExerciseSeries): Exercise | null {
  const exercises = series.sortedExercises;
  const index = matchExercise(label, exercises.map((item) => item.exerciseNumber));
  return index === null ? null : exercises[index];
}

/// Note le rapport confirmé : corrections, erreurs (sans doublon), et les
/// admissions en reprise dans la limite du plafond.
function apply(report: Report, series: ExerciseSeries, features: Features, ladder: RedoLadderConfig,
  examDate: Date | null, context: ModelStore | null, now: Date = new Date()): Applied {
  const applied = new Applied();
  for (const verdict of report.verdicts) {
    const target = exercise(verdict.exercise, series);
    if (target === null) { applied.unmatched.push(verdict.exercise); continue; }
    if (target.correctness !== verdict.result || !target.isCorrected) {
      target.correct(verdict.result);
      applied.corrected += 1;
    }
  }
  if (features.mistakes) {
    for (const mistake of report.mistakes) {
      const target = exercise(mistake.exercise, series);
      if (target === null) { applied.unmatched.push(mistake.exercise); continue; }
      // Le même post-mortem relu (la conversation reprise) ne double pas le carnet.
      if (target.mistakes.some((entry) => entry.summary === mistake.summary)) continue;
      const entry = new Mistake({
        exercise: target,
        kind: mistake.kind,
        summary: mistake.summary,
        correction: mistake.correction,
        notion: mistake.notion,
        source: "claude",
        createdAt: now,
      });
      context?.insert(entry);
      target.mistakesStore = [...target.mistakesStore, entry];
      applied.mistakes += 1;
    }
  }
  if (features.redo) {
    let queued = series.exercises.filter((item) => item.isQueuedForRedo).length;
    for (const admission of report.admissions) {
      const target = exercise(admission.exercise, series);
      if (target === null) { applied.unmatched.push(admission.exercise); continue; }
      if (target.isQueuedForRedo) continue;
      if (!(queued < Math.min(ladder.maxPerSeries, features.redoPerSeries))) {
        applied.overCap.push(target.exerciseNumber);
        continue;
      }
      target.redoPass = 0;
      target.redoDueAt = ladder.steps.length > 0
        ? RedoLadder.due(ladder.steps[0], now, examDate)
        : null;
      target.redoWhy = admission.why;
      target.redoFirstMove = admission.firstMove;
      target.redoFailures = 0;
      target.redoClearedAt = null;
      target.redoRequired = true;
      queued += 1;
      applied.queued.push(target.exerciseNumber);
    }
  }
  return applied;
}

/// Les indices d'une réponse, notés sur leurs exercices (une fois chacun).
function recordHints(hints: Hint[], series: ExerciseSeries, now: Date = new Date()): number {
  let count = 0;
  for (const hint of hints) {
    const target = exercise(hint.exercise, series);
    if (target === null) continue;
    const text = hint.text.split("|").join("/");
    if (target.hints.some((entry) => entry.text === text)) continue;
    target.recordHint(hint.level, hint.text, now);
    count += 1;
  }
  return count;
}

/// Une reprise faite : le palier suivant, ou la sortie de la file.
function recordRedo(result: RedoResult, target: Exercise, ladder: RedoLadderConfig,
  examDate: Date | null, now: Date = new Date()): RedoOutcome {
  const outcome = RedoLadder.after(result, target.redoPass ?? 0, target.redoFailures,
    ladder, now, examDate);
  target.redoLastResultRaw = result;
  target.redoPass = outcome.pass;
  target.redoDueAt = outcome.due;
  target.redoFailures = outcome.failures;
  if (outcome.pass === null) {
    target.redoClearedAt = now;
    target.redoRequired = false;
  }
  return outcome;
}

/// La file de reprise d'un ensemble de cours : ce qui est dû d'abord.
function redoQueue(courses: Course[]): Exercise[] {
  return courses.flatMap((course) => course.allExercises)
    .filter((item) => item.isQueuedForRedo)
    .sort((a, b) => (a.redoDueAt?.getTime() ?? Number.POSITIVE_INFINITY)
      - (b.redoDueAt?.getTime() ?? Number.POSITIVE_INFINITY));
}

export const SeriesReview = {
  MistakeKind: {
    allCases: ["calculation", "method", "understanding", "slip", "gap", "time", "reading"] as readonly MistakeKindValue[],

    label(kind: MistakeKindValue): string {
      switch (kind) {
        case "calculation": return "Calcul";
        case "method": return "Méthode";
        case "understanding": return "Compréhension";
        case "slip": return "Étourderie";
        case "gap": return "Lacune de cours";
        case "time": return "Gestion du temps";
        case "reading": return "Lecture de l'énoncé";
      }
    },

    icon(kind: MistakeKindValue): string {
      switch (kind) {
        case "calculation": return "plus.forwardslash.minus";
        case "method": return "point.topleft.down.to.point.bottomright.curvepath";
        case "understanding": return "brain";
        case "slip": return "exclamationmark.triangle";
        case "gap": return "book.closed";
        case "time": return "timer";
        case "reading": return "text.magnifyingglass";
      }
    },

    /** Les erreurs qui récidivent : elles seules entrent en file de reprise. */
    recurs(kind: MistakeKindValue): boolean {
      return kind === "method" || kind === "gap";
    },

    /// « méthode », « Lacune de cours », « étourderie »… → le genre.
    parse(word: string): MistakeKindValue | null {
      const key = trimWhitespaces(fold(word));
      if (key.startsWith("calcul")) return "calculation";
      if (key.startsWith("method") || key.startsWith("methode")) return "method";
      if (key.startsWith("compreh")) return "understanding";
      if (key.startsWith("etourd") || key.startsWith("inatten")) return "slip";
      if (key.startsWith("lacune") || key.includes("cours")) return "gap";
      if (key.includes("temps") || key.startsWith("time")) return "time";
      if (key.startsWith("lecture") || key.includes("enonce")) return "reading";
      return null;
    },
  },

  Features,
  parse,
  bareHint,
  withoutBlocks,
  instruction,
  hintInstruction,
  exercise,
  apply,
  recordHints,
  recordRedo,
  redoQueue,
};
