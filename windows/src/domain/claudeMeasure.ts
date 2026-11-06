/// **Avec mesure** : le temps passé avec Claude Code, et les règles qu'on s'y donne.
///
/// Deux moitiés, un contrat de fichiers (le dossier `Polymestre/Claude/` des
/// données de l'app) :
///
/// - le mod Claude Code (`ClaudePlugin/mesure`) compte chaque séance
///   (`sessions/<jour>/<séance>.json`), note les passes (`passes/<jour>/…`) et
///   applique les règles à chaque demande ;
/// - Polymestre écrit les règles et le contexte (`policy.json` : mode étude,
///   cours de la semaine, temps étudié) et montre le bilan.
///
/// Le calcul est le même des deux côtés : `ClaudePlugin/mesure/hooks/policy.ts` en
/// est la version du mod, ses tests et ceux de `Validation` portent les mêmes cas.
/// Les instants du contrat sont en **millisecondes** depuis 1970 (ceux du mod).
///
/// Ce qui ne vit qu'ici : **durcir s'applique tout de suite, assouplir le
/// lendemain** (`apply`). On ne lâche pas ses limites sur un coup de tête —
/// c'est tout l'intérêt de se les donner à froid.
///
/// Heure locale partout (jour, week-end, couvre-feu), comme `Calendar.current`.

export const idle = 5 * 60;
export const turnCap = 20 * 60;

/// Étude (les dossiers d'étude, `~/EPFL` par défaut), projets (le reste), libre (exempté).
export type Category = "etude" | "projets" | "libre";
export const categories: readonly Category[] = ["etude", "projets", "libre"];
export function categoryLabel(c: Category): string {
  return { etude: "étude", projets: "projets", libre: "libre" }[c];
}

export type EventKind = "s" | "p" | "d" | "e";
export interface Event { t: number; k: EventKind }

export type RuleID = "lock" | "studyMode" | "lesson" | "curfew" | "studyFirst" | "pause" | "budget";
export const ruleIDs: readonly RuleID[] = ["lock", "studyMode", "lesson", "curfew", "studyFirst", "pause", "budget"];
export function ruleLabel(r: RuleID): string {
  return {
    lock: "verrou du mode étude", studyMode: "mode étude", lesson: "cours", curfew: "couvre-feu",
    studyFirst: "d'abord étudier", pause: "pause", budget: "budget",
  }[r];
}
/// La valeur écrite dans les fichiers : le mod dit « class » pour un cours.
export const ruleRaw = (r: RuleID): string => (r === "lesson" ? "class" : r);
export function ruleFromRaw(raw: string): RuleID | null {
  const id = raw === "class" ? "lesson" : raw;
  return (ruleIDs as readonly string[]).includes(id) ? (id as RuleID) : null;
}

export interface Blocked { t: number; rule: RuleID }

export interface SessionRecord {
  v: number;
  session: string;
  cwd: string;
  category: Category;
  headless: boolean;
  events: Event[];
  blocks: Blocked[];
}

export function sessionRecord(
  p: Pick<SessionRecord, "session" | "cwd" | "category" | "headless" | "events" | "blocks">,
): SessionRecord {
  return { v: 1, ...p };
}

/// Une séance écrite par le mod se relit (« class » → cours).
export function decodeSessionRecord(json: string): SessionRecord | null {
  try {
    const o = JSON.parse(json);
    if (!o || typeof o !== "object") return null;
    return {
      v: o.v ?? 1, session: o.session, cwd: o.cwd, category: o.category, headless: o.headless,
      events: o.events,
      blocks: (o.blocks as { t: number; rule: string }[]).flatMap((b) => {
        const rule = ruleFromRaw(b.rule);
        return rule ? [{ t: b.t, rule }] : [];
      }),
    };
  } catch {
    return null;
  }
}

export interface Pass {
  v: number;
  at: number;
  from: number;
  until: number;
  reason: string;
  rule: RuleID | null;
  session: string;
}

export function pass(p: Omit<Pass, "v">): Pass { return { v: 1, ...p }; }

export interface Curfew { start: string; end: string }

/// Les règles. Les clés sont celles du mod : un `null` s'écrit `null` (le mod
/// lit « sans limite »), jamais omis.
export interface Rules {
  budgetWeekday: number | null;
  budgetWeekend: number | null;
  curfew: Curfew | null;
  curfewAll: boolean;
  studyFirstWeekday: number;
  studyFirstWeekend: number;
  duringClasses: boolean;
  duringStudyMode: boolean;
  streak: number | null;
  pause: number;
  passes: number;
  passMinutes: number;
  passDelay: number;
  studyFolders: string[];
  freeFolders: string[];
}

/// Les règles par défaut (`Rules.standard`) : un objet neuf à chaque appel.
export function standardRules(): Rules {
  return {
    budgetWeekday: 90, budgetWeekend: 180, curfew: { start: "23:30", end: "07:00" }, curfewAll: false,
    studyFirstWeekday: 60, studyFirstWeekend: 0, duringClasses: true, duringStudyMode: true, streak: 50,
    pause: 10, passes: 2, passMinutes: 15, passDelay: 2, studyFolders: ["~/EPFL"], freeFolders: [],
  };
}

/// Des règles incomplètes (ancienne version) prennent les défauts ; une clé
/// présente à `null` reste « sans limite ».
export function decodeRules(json: Record<string, unknown>): Rules {
  const d = standardRules();
  const out: Record<string, unknown> = { ...d };
  const nullable = ["budgetWeekday", "budgetWeekend", "curfew", "streak"];
  for (const key of Object.keys(d)) {
    if (nullable.includes(key)) {
      if (key in json) out[key] = json[key];
    } else if (json[key] !== undefined && json[key] !== null) {
      out[key] = json[key];
    }
  }
  return out as unknown as Rules;
}

export interface StudyModeInfo { since: number; until: number; blocks: boolean; locks: boolean }
export interface Lesson { start: number; end: number; title: string }

/// Le temps d'étude du jour : `seconds` déjà enregistré (sessions et cours
/// suivis, `StudyTime`), plus le chrono ouvert (`accumulated`, `runningSince`).
export interface Studied { day: string; seconds: number; accumulated: number; runningSince: number | null }

export interface Context { studyMode: StudyModeInfo | null; classes: Lesson[]; studied: Studied | null }
export const emptyContext = (): Context => ({ studyMode: null, classes: [], studied: null });

/// Ce qui attend le lendemain : les règles voulues, et l'état voulu (couper
/// Avec mesure attend aussi). Le mod l'applique de lui-même à l'heure dite.
export interface Pending { rules: Rules; from: number; enabled: boolean }

export interface Policy {
  v: number;
  writtenAt: number;
  enabled: boolean;
  enforceFrom: number;
  rules: Rules;
  pending: Pending | null;
  context: Context;
}

export function policyOf(p: Omit<Policy, "v">): Policy { return { v: 1, ...p }; }

/// Les règles voulues : celles qui attendent, sinon celles en vigueur.
export const desired = (policy: Policy): Rules => policy.pending?.rules ?? policy.rules;

// MARK: Instants

export const ms = (date: Date): number => Math.round(date.getTime());
export const date = (milliseconds: number): Date => new Date(milliseconds);

const startOfDay = (d: Date): Date => new Date(d.getFullYear(), d.getMonth(), d.getDate());
/// `calendar.date(byAdding: .day, value: n, to:)` : même heure locale, n jours plus loin.
const addDays = (d: Date, n: number): Date =>
  new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds());
const addSeconds = (d: Date, s: number): Date => new Date(d.getTime() + s * 1000);

const pad = (n: number, width = 2): string => String(n).padStart(width, "0");

export function dayKey(d: Date): string {
  return `${pad(d.getFullYear(), 4)}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function isWeekend(d: Date): boolean {
  const day = d.getDay();
  return day === 0 || day === 6;
}

function minutes(hhmm: string): number {
  const parts = hhmm.split(":").filter((p) => p.length > 0).map((p) => {
    const n = parseInt(p, 10);
    return Number.isNaN(n) ? 0 : n;
  });
  return ((parts[0] ?? 0) % 24) * 60 + (parts.length > 1 ? parts[1] : 0);
}

function at(day: Date, hhmm: string): Date {
  return addSeconds(startOfDay(day), minutes(hhmm) * 60);
}

/// Le couvre-feu en cours à `now` : sa fin, ou `null`. Il peut passer minuit.
export function curfewEnd(curfew: Curfew | null, now: Date): Date | null {
  if (!curfew) return null;
  const start = minutes(curfew.start), end = minutes(curfew.end);
  if (start === end) return null;
  const minute = now.getHours() * 60 + now.getMinutes();
  if (start < end) return minute >= start && minute < end ? at(now, curfew.end) : null;
  if (minute >= start) return at(addDays(now, 1), curfew.end);
  if (minute < end) return at(now, curfew.end);
  return null;
}

// MARK: Classement

export function expand(path: string, home: string): string {
  let p = path.startsWith("~") ? home + path.slice(1) : path;
  while (p.length > 1 && p.endsWith("/")) p = p.slice(0, -1);
  return p;
}

export function categorize(cwd: string, rules: Rules, home: string): Category {
  let dir = cwd;
  while (dir.length > 1 && dir.endsWith("/")) dir = dir.slice(0, -1);
  const inside = (folder: string) => folder !== "" && (dir === folder || dir.startsWith(folder + "/"));
  if (rules.freeFolders.some((f) => inside(expand(f, home)))) return "libre";
  if (rules.studyFolders.some((f) => inside(expand(f, home)))) return "etude";
  return "projets";
}

// MARK: Le temps compté

export interface Span { start: number; end: number }

/// Les intervalles comptés d'une séance, bornés à [from, to) : d'une demande à
/// la réponse (20 min au plus), d'une réponse à la demande suivante sous 5 min.
export function intervals(record: SessionRecord, from: number, to: number, now: number, live: boolean): Span[] {
  const events = [...record.events].sort((a, b) => a.t - b.t);
  const last = events[events.length - 1];
  if (live && last && last.k !== "e") events.push({ t: now, k: "e" });
  const out: Span[] = [];
  for (let i = 0; i + 1 < events.length; i++) {
    const a = events[i], b = events[i + 1];
    const gap = b.t - a.t;
    let credit: number;
    switch (a.k) {
      case "p": credit = Math.min(gap, turnCap * 1000); break;
      case "d":
      case "s": credit = gap <= idle * 1000 ? gap : 0; break;
      default: credit = 0;
    }
    const start = Math.max(a.t, from), end = Math.min(a.t + credit, to);
    if (end > start) out.push({ start, end });
  }
  return out;
}

export function union(list: Span[], join = 0): Span[] {
  const out: Span[] = [];
  for (const span of [...list].sort((a, b) => a.start - b.start)) {
    const last = out[out.length - 1];
    if (last && span.start - last.end <= join) {
      out[out.length - 1] = { start: last.start, end: Math.max(last.end, span.end) };
    } else {
      out.push({ ...span });
    }
  }
  return out;
}

const total = (list: Span[]): number => list.reduce((sum, s) => sum + s.end - s.start, 0);

export interface Usage {
  projets: number;
  etude: number;
  libre: number;
  /// La série en cours sur les projets (ms), pauses courtes comprises.
  streak: Span | null;
}
export const emptyUsage = (): Usage => ({ projets: 0, etude: 0, libre: 0, streak: null });
export const usageSeconds = (u: Usage, c: Category): number => u[c];

/// Le temps du jour de `now`, par catégorie (en secondes).
export function usage(records: SessionRecord[], now: Date, rules: Rules, liveSession: string | null = null): Usage {
  const start = startOfDay(now);
  const end = addDays(start, 1);
  const from = ms(start), to = ms(end), t = ms(now);
  const by: Record<Category, Span[]> = { etude: [], projets: [], libre: [] };
  const recorded: Span[] = [];
  for (const record of records) {
    if (record.headless) continue;
    by[record.category].push(...intervals(record, from, to, t, record.session === liveSession));
    if (record.category === "projets") recorded.push(...intervals(record, from, to, t, false));
  }
  const blocks = union(recorded, rules.pause * 60_000);
  const use = emptyUsage();
  use.projets = total(union(by.projets)) / 1000;
  use.etude = total(union(by.etude)) / 1000;
  use.libre = total(union(by.libre)) / 1000;
  const last = blocks[blocks.length - 1];
  if (last && t - last.end < rules.pause * 60_000) use.streak = { start: last.start, end: last.end };
  return use;
}

export function studiedKnown(context: Context, now: Date): boolean {
  return context.studied?.day === dayKey(now);
}

export function studiedSeconds(context: Context, now: Date): number {
  const s = context.studied;
  if (!s || s.day !== dayKey(now)) return 0;
  const live = s.runningSince !== null ? Math.max(0, (ms(now) - s.runningSince) / 1000) : 0;
  return s.seconds + s.accumulated + live;
}

// MARK: La règle du moment

export function effectiveRules(policy: Policy, now: Date): Rules {
  if (policy.pending && ms(now) >= policy.pending.from) return policy.pending.rules;
  return policy.rules;
}

export function effectiveEnabled(policy: Policy, now: Date): boolean {
  if (policy.pending && ms(now) >= policy.pending.from) return policy.pending.enabled;
  return policy.enabled;
}

export function budgetMinutes(rules: Rules, now: Date): number | null {
  return isWeekend(now) ? rules.budgetWeekend : rules.budgetWeekday;
}

export function activePass(passes: Pass[], now: Date): Pass | null {
  const t = ms(now);
  return passes.find((p) => t >= p.from && t < p.until) ?? null;
}

export function waitingPass(passes: Pass[], now: Date): Pass | null {
  const t = ms(now);
  return passes.find((p) => t >= p.at && t < p.from) ?? null;
}

export function passesLeft(rules: Rules, passes: Pass[], now: Date): number {
  const today = dayKey(now);
  return Math.max(0, rules.passes - passes.filter((p) => dayKey(date(p.at)) === today).length);
}

export interface Verdict {
  allow: boolean;
  rule: RuleID | null;
  until: Date | null;
  message: string;
  passable: boolean;
  observing: boolean;
  warn: string | null;
  remainingMinutes: number | null;
}

const verdict = (v: Partial<Verdict> = {}): Verdict => ({
  allow: true, rule: null, until: null, message: "", passable: false, observing: false, warn: null,
  remainingMinutes: null, ...v,
});

export function clock(d: Date): string {
  return `${d.getHours()} h ${pad(d.getMinutes())}`;
}

/// `Double.rounded()` de Swift arrondit la moitié à l'écart de zéro ; `Math.round` vers +∞.
const rounded = (x: number): number => (x < 0 ? -Math.round(-x) : Math.round(x));

export function duration(seconds: number): string {
  const m = Math.max(0, rounded(seconds / 60));
  return m < 60 ? `${m} min` : `${Math.trunc(m / 60)} h ${pad(m % 60)}`;
}

interface Block { rule: RuleID; until: Date | null; message: string; passable: boolean }

function firstBlock(category: Category, rules: Rules, context: Context, use: Usage, now: Date): Block | null {
  const t = ms(now);
  const mode = context.studyMode && t >= context.studyMode.since && t < context.studyMode.until ? context.studyMode : null;
  if (mode && mode.locks && category !== "etude") {
    return { rule: "lock", until: date(mode.until),
      message: `Verrou du mode étude jusqu'à ${clock(date(mode.until))} : ici, Claude ne sert qu'à étudier.`, passable: false };
  }
  const curfew = curfewEnd(rules.curfew, now);
  if (curfew && rules.curfewAll && category !== "libre") {
    return { rule: "curfew", until: curfew, message: `Couvre-feu jusqu'à ${clock(curfew)}. Dors : tout sera là demain.`, passable: true };
  }
  if (category !== "projets") return null;
  if (mode && mode.blocks && rules.duringStudyMode) {
    return { rule: "studyMode", until: date(mode.until),
      message: `Mode étude en cours jusqu'à ${clock(date(mode.until))} : les projets attendent.`, passable: false };
  }
  if (rules.duringClasses) {
    const lesson = context.classes.find((l) => t >= l.start && t < l.end);
    if (lesson) {
      return { rule: "lesson", until: date(lesson.end),
        message: `Cours en ce moment (${lesson.title}, jusqu'à ${clock(date(lesson.end))}) : les projets attendent.`, passable: false };
    }
  }
  if (curfew) {
    return { rule: "curfew", until: curfew, message: `Couvre-feu jusqu'à ${clock(curfew)}. Dors : le code sera là demain.`, passable: true };
  }
  // Le temps étudié n'est connu que si Polymestre l'a écrit aujourd'hui : sinon
  // (l'app fermée depuis hier), la règle ne peut pas se vérifier et ne bloque pas.
  const needed = (isWeekend(now) ? rules.studyFirstWeekend : rules.studyFirstWeekday) * 60;
  const studied = studiedSeconds(context, now);
  if (needed > 0 && studiedKnown(context, now) && studied < needed) {
    return { rule: "studyFirst", until: null,
      message: `D'abord étudier : encore ${duration(needed - studied)} dans Polymestre (${duration(studied)} sur ${duration(needed)} aujourd'hui).`,
      passable: true };
  }
  if (rules.streak !== null && use.streak && use.streak.end - use.streak.start >= rules.streak * 60_000) {
    const until = date(use.streak.end + rules.pause * 60_000);
    return { rule: "pause", until,
      message: `Pause : ${duration((use.streak.end - use.streak.start) / 1000)} d'affilée sur les projets. Reprends à ${clock(until)}.`, passable: true };
  }
  const budget = budgetMinutes(rules, now);
  if (budget !== null && use.projets >= budget * 60) {
    return { rule: "budget", until: addDays(startOfDay(now), 1),
      message: `Budget du jour atteint : ${duration(use.projets)} sur ${duration(budget * 60)} de projets.`, passable: true };
  }
  return null;
}

export function evaluate(category: Category, headless: boolean, policy: Policy | null, use: Usage, passes: Pass[], now: Date): Verdict {
  if (!policy || !effectiveEnabled(policy, now) || headless) return verdict();
  const rules = effectiveRules(policy, now);
  const budget = budgetMinutes(rules, now);
  const remaining = category === "projets" && budget !== null ? Math.max(0, rounded(budget - use.projets / 60)) : null;
  const active = activePass(passes, now);
  const block = firstBlock(category, rules, policy.context, use, now);
  if (block && !(block.passable && active)) {
    const left = passesLeft(rules, passes, now);
    let hint: string;
    const waiting = waitingPass(passes, now);
    if (!block.passable) hint = "";
    else if (waiting) hint = ` Ton pass s'ouvre à ${clock(date(waiting.from))}.`;
    else if (left > 0) hint = ` /mesure encore <raison> : ${left} pass ${left > 1 ? "restants" : "restant"}.`;
    else hint = " Plus de pass aujourd'hui.";
    if (ms(now) < policy.enforceFrom) {
      return verdict({ allow: true, rule: block.rule, until: block.until, message: "Observation : " + block.message + hint,
        observing: true, remainingMinutes: remaining });
    }
    return verdict({ allow: false, rule: block.rule, until: block.until, message: block.message + hint,
      passable: block.passable, remainingMinutes: remaining });
  }
  const v = verdict({ remainingMinutes: remaining });
  if (active) {
    v.warn = `Pass ouvert jusqu'à ${clock(date(active.until))} (${active.reason}).`;
  } else if (category === "projets" && budget !== null && use.projets >= budget * 60 * 0.8) {
    v.warn = `Projets : ${duration(use.projets)} sur ${duration(budget * 60)} aujourd'hui.`;
  } else if (category === "projets" && rules.streak !== null && use.streak
             && use.streak.end - use.streak.start >= (rules.streak - 10) * 60_000) {
    v.warn = `${duration((use.streak.end - use.streak.start) / 1000)} d'affilée : une pause arrive à ${rules.streak} min.`;
  }
  return v;
}

// MARK: Durcir tout de suite, assouplir le lendemain

/// Le premier 4 h du matin au moins douze heures après `now` : un assouplissement
/// demandé le soir ne s'applique pas dans la nuit même.
export function nextMorning(now: Date): Date {
  let day = startOfDay(now);
  for (;;) {
    const candidate = addSeconds(day, 4 * 3600);
    if ((candidate.getTime() - now.getTime()) / 1000 >= 12 * 3600) return candidate;
    day = addDays(day, 1);
  }
}

/// Les minutes d'un créneau (couvre-feu) comme ensemble, pour comparer deux couvre-feux.
function curfewMinutes(curfew: Curfew | null): Set<number> {
  const out = new Set<number>();
  if (!curfew) return out;
  const start = minutes(curfew.start), end = minutes(curfew.end);
  if (start === end) return out;
  if (start < end) {
    for (let m = start; m < end; m++) out.add(m);
  } else {
    for (let m = start; m < 1440; m++) out.add(m);
    for (let m = 0; m < end; m++) out.add(m);
  }
  return out;
}

const isSuperset = (a: Set<number>, b: Set<number>): boolean => [...b].every((x) => a.has(x));

/// `null` (sans limite) est le plus lâche ; sinon le plus petit est le plus strict.
function stricterLimit(a: number | null, b: number | null): number | null {
  if (a !== null && b !== null) return Math.min(a, b);
  if (a !== null) return a;
  if (b !== null) return b;
  return null;
}

/// Règle par règle, la plus stricte des deux.
export function stricter(a: Rules, b: Rules): Rules {
  const r: Rules = { ...a };
  r.budgetWeekday = stricterLimit(a.budgetWeekday, b.budgetWeekday);
  r.budgetWeekend = stricterLimit(a.budgetWeekend, b.budgetWeekend);
  const ca = curfewMinutes(a.curfew), cb = curfewMinutes(b.curfew);
  r.curfew = isSuperset(cb, ca) ? b.curfew : isSuperset(ca, cb) ? a.curfew : (ca.size >= cb.size ? a.curfew : b.curfew);
  r.curfewAll = a.curfewAll || b.curfewAll;
  r.studyFirstWeekday = Math.max(a.studyFirstWeekday, b.studyFirstWeekday);
  r.studyFirstWeekend = Math.max(a.studyFirstWeekend, b.studyFirstWeekend);
  r.duringClasses = a.duringClasses || b.duringClasses;
  r.duringStudyMode = a.duringStudyMode || b.duringStudyMode;
  r.streak = stricterLimit(a.streak, b.streak);
  r.pause = Math.max(a.pause, b.pause);
  r.passes = Math.min(a.passes, b.passes);
  r.passMinutes = Math.min(a.passMinutes, b.passMinutes);
  r.passDelay = Math.max(a.passDelay, b.passDelay);
  // Un dossier exempté ou d'étude de plus, c'est plus lâche : on garde ceux des deux qui sont communs.
  r.studyFolders = a.studyFolders.filter((f) => b.studyFolders.includes(f));
  r.freeFolders = a.freeFolders.filter((f) => b.freeFolders.includes(f));
  return r;
}

/// Égalité structurelle (clés dans n'importe quel ordre), pour comparer deux jeux de règles.
export function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  return ka.every((k) => deepEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
}

/// Les réglages voulus appliqués à la règle écrite : ce qui durcit vaut tout
/// de suite, ce qui assouplit attend le lendemain matin (`pending`). Couper
/// Avec mesure est un assouplissement comme un autre.
export function apply(wanted: Rules, enabled: boolean, to: Policy | null, now: Date): Policy {
  const t = ms(now);
  if (!to || !to.enabled) {
    // Première mise en route (ou reprise) : une journée d'observation, rien ne bloque.
    return policyOf({ writtenAt: t, enabled, enforceFrom: ms(nextMorning(now)),
      rules: structuredClone(wanted), pending: null, context: to ? structuredClone(to.context) : emptyContext() });
  }
  const policy: Policy = structuredClone(to);
  const current = effectiveRules(policy, now);
  policy.rules = stricter(current, wanted);
  policy.writtenAt = t;
  if (!deepEqual(policy.rules, wanted) || !enabled) {
    // Une demande déjà en attente garde son heure : y revenir ne la repousse pas.
    const from = policy.pending?.from ?? ms(nextMorning(now));
    policy.pending = { rules: structuredClone(wanted), from, enabled };
  } else {
    policy.pending = null;
  }
  return structuredClone(policy);
}

/// Ce qui attend son heure : à la relecture, une demande échue s'applique.
export function settle(policy: Policy, now: Date): Policy {
  const p: Policy = structuredClone(policy);
  const t = ms(now);
  if (p.pending && t >= p.pending.from) {
    p.rules = p.pending.rules;
    p.enabled = p.pending.enabled;
    p.pending = null;
  }
  return p;
}

// MARK: Le bilan

export interface DaySummary {
  day: string;
  projets: number;
  etude: number;
  libre: number;
  passes: number;
  blocks: number;
}

/// Un jour, des séances lues dans les dossiers du jour et de la veille.
export function summary(day: Date, records: SessionRecord[], passes: Pass[], rules: Rules, now: Date): DaySummary {
  const start = startOfDay(day);
  const end = addDays(start, 1);
  const moment = new Date(Math.min(now.getTime(), end.getTime() - 1000));
  const use = usage(records, moment, rules);
  const key = dayKey(start);
  const from = ms(start), to = ms(end);
  const blocks = records.reduce((n, r) => n + r.blocks.filter((b) => b.t >= from && b.t < to).length, 0);
  return { day: key, projets: use.projets, etude: use.etude, libre: use.libre,
    passes: passes.filter((p) => dayKey(date(p.at)) === key).length, blocks };
}

export const ClaudeMeasure = {
  idle, turnCap, ms, date, dayKey, isWeekend, curfewEnd, expand, categorize, intervals, union, usage,
  studiedKnown, studiedSeconds, effectiveRules, effectiveEnabled, budgetMinutes, activePass, waitingPass,
  passesLeft, clock, duration, evaluate, nextMorning, stricter, apply, settle, summary,
};
