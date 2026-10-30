// MARK: - Les objets d'Anki, tels que la collection (schéma 11) les range

/// `Double.rounded()` de Swift arrondit la moitié à l'écart de zéro ; `Math.round` vers +∞.
const rounded = (x: number): number => (x < 0 ? -Math.round(-x) : Math.round(x));

/// Une réponse à une carte : « À revoir », « Difficile », « Bien », « Facile ».
export const AnkiRating = { again: 1, hard: 2, good: 3, easy: 4 } as const;
export type AnkiRating = 1 | 2 | 3 | 4;
export const ankiRatings: readonly AnkiRating[] = [1, 2, 3, 4];

export function ratingLabel(rating: AnkiRating): string {
  switch (rating) {
    case 1: return "À revoir";
    case 2: return "Difficile";
    case 3: return "Bien";
    case 4: return "Facile";
  }
}

/// L'état de planification d'une carte : les colonnes de la table `cards`.
///
/// `type` : 0 nouvelle, 1 en apprentissage, 2 en révision, 3 en réapprentissage.
/// `queue` : 0 nouvelle, 1 apprentissage (échéance en secondes), 2 révision et
/// 3 apprentissage sur plusieurs jours (échéance en jours), −1 suspendue,
/// −2/−3 enterrée. `due` : position (nouvelle), instant Unix (file 1) ou
/// numéro de jour depuis la création de la collection (files 2 et 3).
export interface AnkiCardState {
  type: number;
  queue: number;
  due: number;
  ivl: number;
  factor: number;
  reps: number;
  lapses: number;
  left: number;
  /** JSON libre ; FSRS y garde l'état de mémoire (`{"s":…,"d":…}`). */
  data: string;
}

export function cardState(partial: Partial<AnkiCardState> = {}): AnkiCardState {
  return { type: 0, queue: 0, due: 0, ivl: 0, factor: 0, reps: 0, lapses: 0, left: 0, data: "", ...partial };
}

export const isNewCard = (card: AnkiCardState): boolean => card.type === 0;

/// Les options du paquet (`dconf`), celles qui planifient.
export interface AnkiDeckOptions {
  /** Étapes d'apprentissage, en minutes. */
  learnSteps: number[];
  graduatingInterval: number;
  easyInterval: number;
  /** Facilité de départ, en pour mille (2500 = 250 %). */
  startingEase: number;
  relearnSteps: number[];
  lapseMultiplier: number;
  minimumLapseInterval: number;
  easyBonus: number;
  hardMultiplier: number;
  intervalModifier: number;
  maximumInterval: number;
  newPerDay: number;
  reviewsPerDay: number;
  desiredRetention: number;
  /** Paramètres FSRS du préréglage ; vides : les paramètres par défaut. */
  fsrsParams: number[];
}

export function defaultDeckOptions(): AnkiDeckOptions {
  return {
    learnSteps: [1, 10], graduatingInterval: 1, easyInterval: 4, startingEase: 2500, relearnSteps: [10],
    lapseMultiplier: 0, minimumLapseInterval: 1, easyBonus: 1.3, hardMultiplier: 1.2, intervalModifier: 1,
    maximumInterval: 36_500, newPerDay: 20, reviewsPerDay: 200, desiredRetention: 0.9, fsrsParams: [],
  };
}

type Json = Record<string, unknown>;
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const numberArray = (v: unknown): number[] | undefined =>
  Array.isArray(v) && v.every(isNumber) ? (v as number[]) : undefined;
const dict = (v: unknown): Json =>
  v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Json) : {};

/// Lu dans le JSON d'un `dconf` (schéma 11).
export function deckOptionsFromJSON(json: Json): AnkiDeckOptions {
  const o = defaultDeckOptions();
  const number = (v: unknown): number | undefined => (isNumber(v) ? v : undefined);
  const newConf = dict(json.new);
  const lapse = dict(json.lapse);
  const rev = dict(json.rev);
  const learn = numberArray(newConf.delays);
  if (learn) o.learnSteps = learn;
  const ints = numberArray(newConf.ints);
  if (ints) {
    if (ints.length > 0) o.graduatingInterval = Math.max(1, Math.trunc(ints[0]));
    if (ints.length > 1) o.easyInterval = Math.max(1, Math.trunc(ints[1]));
  }
  let n: number | undefined;
  if ((n = number(newConf.initialFactor)) !== undefined) o.startingEase = Math.trunc(n);
  if ((n = number(newConf.perDay)) !== undefined) o.newPerDay = Math.trunc(n);
  const relearn = numberArray(lapse.delays);
  if (relearn) o.relearnSteps = relearn;
  if ((n = number(lapse.mult)) !== undefined) o.lapseMultiplier = n;
  if ((n = number(lapse.minInt)) !== undefined) o.minimumLapseInterval = Math.max(1, Math.trunc(n));
  if ((n = number(rev.perDay)) !== undefined) o.reviewsPerDay = Math.trunc(n);
  if ((n = number(rev.ease4)) !== undefined) o.easyBonus = n;
  if ((n = number(rev.ivlFct)) !== undefined && n > 0) o.intervalModifier = n;
  if ((n = number(rev.maxIvl)) !== undefined) o.maximumInterval = Math.max(1, Math.trunc(n));
  if ((n = number(rev.hardFactor)) !== undefined) o.hardMultiplier = n;
  if ((n = number(json.desiredRetention)) !== undefined && n > 0 && n < 1) o.desiredRetention = n;
  for (const key of ["fsrsParams6", "fsrsParams5", "fsrsWeights"]) {
    const params = numberArray(json[key]);
    if (params && [17, 19, 21].includes(params.length)) {
      o.fsrsParams = params;
      break;
    }
  }
  return o;
}

/// Le jour d'Anki : il commence à l'heure de bascule (4 h par défaut), et se
/// compte depuis le jour de création de la collection. Heure locale, comme
/// `Calendar.current` côté Swift.
export class AnkiClock {
  now: Date;
  creation: Date;
  rolloverHour: number;

  constructor(now: Date, creation: Date, rolloverHour = 4) {
    this.now = now;
    this.creation = creation;
    this.rolloverHour = rolloverHour;
  }

  private dayStart(date: Date): Date {
    const shifted = new Date(date.getTime() - this.rolloverHour * 3600 * 1000);
    const start = new Date(shifted.getFullYear(), shifted.getMonth(), shifted.getDate());
    return new Date(start.getTime() + this.rolloverHour * 3600 * 1000);
  }

  /// Numéro du jour courant (celui des échéances de révision).
  get today(): number {
    const start = this.dayStart(this.creation);
    const current = this.dayStart(this.now);
    const utc = (d: Date) => Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
    return Math.round((utc(current) - utc(start)) / 86_400_000);
  }

  /// Début du jour d'Anki suivant : au-delà, une étape passe en file 3.
  get nextDayStart(): Date {
    const d = this.dayStart(this.now);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, d.getHours(), d.getMinutes(), d.getSeconds());
  }

  /// Début du jour d'Anki courant, en millisecondes (comme `revlog.id`).
  get todayStartMillis(): number { return this.dayStart(this.now).getTime(); }

  get seconds(): number { return Math.trunc(this.now.getTime() / 1000); }
}

// MARK: - FSRS

/// FSRS (Free Spaced Repetition Scheduler), versions 4.5, 5 et 6 — celle
/// qu'Anki utilise quand FSRS est activé dans la collection.
export class FSRS {
  readonly w: number[];

  static readonly defaults: number[] = [0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575,
    0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621];

  constructor(params: number[]) {
    this.w = [17, 19, 21].includes(params.length) ? params : FSRS.defaults;
  }

  private get isV6(): boolean { return this.w.length >= 21; }
  get decay(): number { return this.isV6 ? -this.w[20] : -0.5; }
  get factor(): number { return Math.pow(0.9, 1 / this.decay) - 1; }

  retrievability(days: number, stability: number): number {
    return Math.pow(1 + (this.factor * days) / Math.max(stability, 0.001), this.decay);
  }

  /// L'intervalle (en jours) qui ramène la rétention à `retention`.
  interval(stability: number, retention: number): number {
    return (stability / this.factor) * (Math.pow(retention, 1 / this.decay) - 1);
  }

  initialStability(rating: AnkiRating): number { return Math.max(this.w[rating - 1], 0.1); }

  initialDifficulty(rating: AnkiRating): number {
    return this.clampD(this.w[4] - Math.exp(this.w[5] * (rating - 1)) + 1);
  }

  nextDifficulty(d: number, rating: AnkiRating): number {
    const w = this.w;
    const delta = -w[6] * (rating - 3);
    // FSRS 5 amortit le changement près de 10 ; 4.5 non.
    const moved = w.length >= 19 ? d + (delta * (10 - d)) / 9 : d + delta;
    return this.clampD(w[7] * this.initialDifficulty(4) + (1 - w[7]) * moved);
  }

  recallStability(s: number, d: number, r: number, rating: AnkiRating): number {
    const w = this.w;
    const hard = rating === 2 ? w[15] : 1;
    const easy = rating === 4 ? w[16] : 1;
    return s * (1 + Math.exp(w[8]) * (11 - d) * Math.pow(s, -w[9]) * (Math.exp((1 - r) * w[10]) - 1) * hard * easy);
  }

  forgetStability(s: number, d: number, r: number): number {
    const w = this.w;
    const value = w[11] * Math.pow(d, -w[12]) * (Math.pow(s + 1, w[13]) - 1) * Math.exp((1 - r) * w[14]);
    return Math.min(value, s);
  }

  /// Révision le jour même (étapes d'apprentissage) : FSRS 5 et 6.
  shortTermStability(s: number, rating: AnkiRating): number {
    const w = this.w;
    if (w.length < 19) return s;
    let value = s * Math.exp(w[17] * (rating - 3 + w[18]));
    if (this.isV6) {
      value *= Math.pow(s, -w[19]);
      if (rating >= 3) value = Math.max(value, s);
    }
    return value;
  }

  private clampD(d: number): number { return Math.min(Math.max(d, 1), 10); }
}

// MARK: - Le planificateur

/// Ce que produit une réponse : la carte replanifiée et la ligne d'historique.
export interface AnkiAnswer {
  card: AnkiCardState;
  /// `revlog` : facilité (1–4), intervalle et intervalle précédent (jours si
  /// positifs, secondes si négatifs), facilité de la carte, type (0
  /// apprentissage, 1 révision, 2 réapprentissage).
  ease: number;
  interval: number;
  lastInterval: number;
  factor: number;
  reviewType: number;
}

/// La planification d'Anki (planificateur v3), en SM-2 classique ou en FSRS
/// selon la collection.
///
/// Fidèle à ce qu'Anki fait de chaque bouton : étapes d'apprentissage et de
/// réapprentissage, intervalle de passage et intervalle « facile », facilité
/// (−20 % sur « à revoir », −15 % sur « difficile », +15 % sur « facile »),
/// retard pris en compte, plafonds du paquet. Pas de « fuzz » (la petite
/// variation aléatoire qu'Anki ajoute aux intervalles) : une révision faite
/// ici tombe un jour pile, ce qui ne change rien à la mémorisation.
export const AnkiScheduler = {
  answer(card: AnkiCardState, rating: AnkiRating, options: AnkiDeckOptions, clock: AnkiClock, useFSRS: boolean): AnkiAnswer {
    const next: AnkiCardState = { ...card };
    next.reps += 1;
    const fsrs = useFSRS ? new FSRS(options.fsrsParams) : null;
    const lastInterval = currentInterval(card, clock);
    let reviewType: number;
    switch (card.type) {
      case 2:
        reviewType = 1;
        review(next, card, rating, options, clock, fsrs);
        break;
      case 3:
        reviewType = 2;
        learn(next, card, options.relearnSteps, true, rating, options, clock, fsrs);
        break;
      default:
        reviewType = 0;
        learn(next, card, options.learnSteps, false, rating, options, clock, fsrs);
    }
    return { card: next, ease: rating, interval: currentInterval(next, clock), lastInterval, factor: next.factor, reviewType };
  },

  /// « 1 min », « 10 min », « 3 j » : ce que chaque bouton planifierait.
  previews(card: AnkiCardState, options: AnkiDeckOptions, clock: AnkiClock, useFSRS: boolean): Record<AnkiRating, string> {
    const result = {} as Record<AnkiRating, string>;
    for (const rating of ankiRatings) {
      const next = AnkiScheduler.answer(card, rating, options, clock, useFSRS).card;
      result[rating] = AnkiScheduler.label(next, clock);
    }
    return result;
  },

  label(card: AnkiCardState, clock: AnkiClock): string {
    if (card.queue === 1) {
      const seconds = Math.max(0, card.due - clock.seconds);
      if (seconds < 3600) return `${Math.max(1, Math.trunc(rounded(seconds / 60)))} min`;
      return `${Math.trunc(rounded(seconds / 3600))} h`;
    }
    const days = Math.max(1, Math.trunc(card.due) - clock.today);
    return AnkiScheduler.dayLabel(days);
  },

  dayLabel(days: number): string {
    if (days < 31) return `${days} j`;
    if (days < 365) return `${(days / 30.4).toFixed(1).replace(".", ",")} mois`;
    return `${(days / 365).toFixed(1).replace(".", ",")} an`;
  },

  memory(card: AnkiCardState): { s: number; d: number } | null {
    const json = parseObject(card.data);
    if (!json || !isNumber(json.s) || !isNumber(json.d) || !(json.s > 0)) return null;
    return { s: json.s, d: json.d };
  },
};

function parseObject(text: string): Json | null {
  try {
    const value: unknown = JSON.parse(text);
    return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Json) : null;
  } catch {
    return null;
  }
}

// MARK: Apprentissage

function learn(card: AnkiCardState, previous: AnkiCardState, steps: number[], relearning: boolean,
               rating: AnkiRating, options: AnkiDeckOptions, clock: AnkiClock, fsrs: FSRS | null): void {
  if (fsrs) updateMemory(card, previous, rating, clock, fsrs);
  if (previous.type === 0) {
    card.type = 1;
    card.left = steps.length;
    if (card.factor === 0) card.factor = options.startingEase;
  }
  if (steps.length === 0) {
    graduate(card, rating === 4, relearning, options, clock, fsrs);
    return;
  }
  let remaining = card.left % 1000;
  if (remaining <= 0 || remaining > steps.length) remaining = steps.length;
  const index = Math.min(Math.max(steps.length - remaining, 0), steps.length - 1);
  switch (rating) {
    case 1:
      card.left = steps.length;
      schedule(card, steps[0], clock);
      break;
    case 2: {
      let delay: number;
      if (index === 0) {
        delay = steps.length > 1 ? (steps[0] + steps[1]) / 2 : Math.min(steps[0] * 1.5, steps[0] + 1440);
      } else {
        delay = steps[index];
      }
      card.left = remaining;
      schedule(card, delay, clock);
      break;
    }
    case 3:
      remaining -= 1;
      if (remaining <= 0) {
        graduate(card, false, relearning, options, clock, fsrs);
      } else {
        card.left = remaining;
        schedule(card, steps[steps.length - remaining], clock);
      }
      break;
    case 4:
      graduate(card, true, relearning, options, clock, fsrs);
      break;
  }
}

/// Une étape : dans la journée, file 1 (en secondes) ; au-delà, file 3 (en jours).
function schedule(card: AnkiCardState, minutes: number, clock: AnkiClock): void {
  const seconds = rounded(minutes * 60);
  const due = clock.seconds + seconds;
  if (due * 1000 < clock.nextDayStart.getTime()) {
    card.queue = 1;
    card.due = due;
  } else {
    card.queue = 3;
    card.due = clock.today + Math.max(1, Math.trunc(rounded(minutes / 1440)));
  }
}

function graduate(card: AnkiCardState, easy: boolean, relearning: boolean,
                  options: AnkiDeckOptions, clock: AnkiClock, fsrs: FSRS | null): void {
  let interval: number;
  const memory = fsrs ? AnkiScheduler.memory(card) : null;
  if (fsrs && memory) {
    interval = fsrsInterval(memory.s, options, fsrs);
    if (easy) interval = Math.max(interval, relearning ? card.ivl + 1 : options.easyInterval);
  } else if (relearning) {
    interval = easy ? card.ivl + 1 : Math.max(card.ivl, 1);
  } else {
    interval = easy ? options.easyInterval : options.graduatingInterval;
  }
  interval = Math.min(Math.max(interval, 1), options.maximumInterval);
  card.type = 2;
  card.queue = 2;
  card.ivl = interval;
  card.due = clock.today + interval;
  card.left = 0;
  if (card.factor === 0) card.factor = options.startingEase;
}

// MARK: Révision

function review(card: AnkiCardState, previous: AnkiCardState, rating: AnkiRating,
                options: AnkiDeckOptions, clock: AnkiClock, fsrs: FSRS | null): void {
  const today = clock.today;
  const daysLate = Math.max(0, today - Math.trunc(previous.due));
  const ivl = Math.max(previous.ivl, 1);
  if (fsrs) updateMemory(card, previous, rating, clock, fsrs);

  if (rating === 1) {
    card.lapses += 1;
    card.factor = Math.max(1300, previous.factor - 200);
    let lapsed = Math.max(options.minimumLapseInterval, Math.trunc(rounded(ivl * options.lapseMultiplier)));
    const memory = fsrs ? AnkiScheduler.memory(card) : null;
    if (fsrs && memory) {
      lapsed = Math.max(options.minimumLapseInterval, Math.min(fsrsInterval(memory.s, options, fsrs), ivl));
    }
    card.ivl = Math.min(lapsed, options.maximumInterval);
    if (options.relearnSteps.length === 0) {
      card.queue = 2;
      card.due = today + card.ivl;
    } else {
      card.type = 3;
      card.left = options.relearnSteps.length;
      schedule(card, options.relearnSteps[0], clock);
    }
    return;
  }

  let interval: number;
  const memory = fsrs ? AnkiScheduler.memory(card) : null;
  if (fsrs && memory) {
    const base = fsrsInterval(memory.s, options, fsrs);
    // L'ordre des boutons est garanti : difficile < bien < facile.
    const hardIvl = fsrsIntervalFor(previous, 2, options, clock, fsrs);
    const goodIvl = Math.max(hardIvl + 1, fsrsIntervalFor(previous, 3, options, clock, fsrs));
    switch (rating) {
      case 2: interval = hardIvl; break;
      case 3: interval = goodIvl; break;
      default: interval = Math.max(goodIvl + 1, base);
    }
  } else {
    const modifier = options.intervalModifier;
    const hardIvl = constrained(ivl * options.hardMultiplier * modifier,
      options.hardMultiplier > 1 ? ivl + 1 : ivl, options);
    const goodIvl = constrained((ivl + daysLate / 2) * previous.factor / 1000 * modifier, hardIvl + 1, options);
    switch (rating) {
      case 2:
        card.factor = Math.max(1300, previous.factor - 150);
        interval = hardIvl;
        break;
      case 3:
        interval = goodIvl;
        break;
      default:
        card.factor = previous.factor + 150;
        interval = constrained((ivl + daysLate) * previous.factor / 1000 * options.easyBonus * modifier,
          goodIvl + 1, options);
    }
  }
  interval = Math.min(Math.max(interval, 1), options.maximumInterval);
  card.ivl = interval;
  card.due = today + interval;
  card.queue = 2;
  card.type = 2;
}

function constrained(value: number, minimum: number, options: AnkiDeckOptions): number {
  return Math.min(Math.max(Math.trunc(rounded(value)), minimum, 1), options.maximumInterval);
}

/// L'intervalle qu'un bouton donnerait, en FSRS (pour ordonner les boutons).
function fsrsIntervalFor(card: AnkiCardState, rating: AnkiRating, options: AnkiDeckOptions,
                         clock: AnkiClock, fsrs: FSRS): number {
  const copy: AnkiCardState = { ...card };
  updateMemory(copy, card, rating, clock, fsrs);
  const memory = AnkiScheduler.memory(copy);
  return memory ? fsrsInterval(memory.s, options, fsrs) : Math.max(card.ivl, 1);
}

function fsrsInterval(stability: number, options: AnkiDeckOptions, fsrs: FSRS): number {
  const days = fsrs.interval(stability, options.desiredRetention) * options.intervalModifier;
  return Math.min(Math.max(Math.trunc(rounded(days)), 1), options.maximumInterval);
}

// MARK: Mémoire FSRS

function updateMemory(card: AnkiCardState, previous: AnkiCardState, rating: AnkiRating,
                      clock: AnkiClock, fsrs: FSRS): void {
  let s: number, d: number;
  const memory = AnkiScheduler.memory(previous);
  if (memory) {
    // Jours depuis la dernière révision : nul pendant les étapes.
    const elapsed = previous.type === 2 ? Math.max(0, clock.today - (Math.trunc(previous.due) - previous.ivl)) : 0;
    if (elapsed < 1) {
      s = fsrs.shortTermStability(memory.s, rating);
    } else {
      const r = fsrs.retrievability(elapsed, memory.s);
      s = rating === 1 ? fsrs.forgetStability(memory.s, memory.d, r) : fsrs.recallStability(memory.s, memory.d, r, rating);
    }
    d = fsrs.nextDifficulty(memory.d, rating);
  } else if (previous.type === 0) {
    s = fsrs.initialStability(rating);
    d = fsrs.initialDifficulty(rating);
  } else {
    // Une carte révisée avant FSRS, sans état : on part de son intervalle.
    s = Math.max(previous.ivl, 1);
    d = fsrs.nextDifficulty(5, rating);
  }
  const json: Json = { ...(parseObject(previous.data) ?? {}) };
  json.s = rounded(Math.max(s, 0.001) * 10_000) / 10_000;
  json.d = rounded(d * 1000) / 1000;
  // Clés triées (`.sortedKeys` côté Swift) : la sérialisation reste stable.
  const sorted: Json = {};
  for (const key of Object.keys(json).sort()) sorted[key] = json[key];
  card.data = JSON.stringify(sorted);
}

/// Intervalle courant pour l'historique : jours, ou −secondes en apprentissage.
function currentInterval(card: AnkiCardState, clock: AnkiClock): number {
  switch (card.queue) {
    case 1: return 0 - Math.trunc(Math.max(0, card.due - clock.seconds));
    case 3: return 0 - Math.trunc(Math.max(0, Math.trunc(card.due) - clock.today)) * 86_400;
    case 0: return 0;
    default: return card.ivl;
  }
}
