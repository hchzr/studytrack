// Avec mesure : ce qui se décide à chaque demande, sans entrée ni sortie.
//
// Le même calcul vit en Swift dans StudyTrack (`StudyTrack/Domain/ClaudeMeasure.swift`),
// pour l'afficher : les deux suivent ce fichier, et leurs tests portent les mêmes cas.
//
// Ce qui se compte : le temps passé avec Claude Code, séance par séance —
// d'une demande à la fin de la réponse (au plus 20 min : une longue tâche
// qu'on laisse tourner ne compte pas des heures), et entre une réponse et la
// demande suivante si l'écart reste sous 5 min (on lit, on réfléchit, on
// tape) ; au-delà, on était parti. Les séances simultanées ne comptent qu'une
// fois (union des intervalles). Les séances sans clavier (`claude -p`, le
// tuteur de StudyTrack, les scripts) ne comptent pas et ne sont jamais bloquées.

export const IDLE_MS = 5 * 60_000
export const TURN_CAP_MS = 20 * 60_000
const MINUTE = 60_000

/** Étude (le dossier du projet Claude de l'étudiant·e), projets (le reste), libre (exempté). */
export type Category = 'etude' | 'projets' | 'libre'

export type EventKind = 's' | 'p' | 'd' | 'e'
export type SessionEvent = { t: number; k: EventKind }

/** `sessions/<jour>/<séance>.json`, écrit par le mod, lu par StudyTrack. */
export type SessionRecord = {
  v: 1
  session: string
  cwd: string
  category: Category
  headless: boolean
  events: SessionEvent[]
  blocks: { t: number; rule: RuleId }[]
}

/** `passes/<jour>/<instant>.json` : « encore 15 min », avec sa raison. */
export type Pass = { v: 1; at: number; from: number; until: number; reason: string; rule: RuleId | null; session: string }

export type Curfew = { start: string; end: string }

export type Rules = {
  /** Minutes de projets par jour de semaine ; `null` : sans limite. */
  budgetWeekday: number | null
  budgetWeekend: number | null
  curfew: Curfew | null
  /** Le couvre-feu vaut aussi pour l'étude. */
  curfewAll: boolean
  /** Minutes d'étude (StudyTrack) avant d'ouvrir les projets ; 0 : pas de condition. */
  studyFirstWeekday: number
  studyFirstWeekend: number
  duringClasses: boolean
  duringStudyMode: boolean
  /** Minutes d'affilée sur les projets avant une pause ; `null` : jamais. */
  streak: number | null
  pause: number
  passes: number
  passMinutes: number
  /** Délai de réflexion : un pass ne s'ouvre qu'au bout de ces minutes. */
  passDelay: number
  studyFolders: string[]
  freeFolders: string[]
}

export const DEFAULT_RULES: Rules = {
  budgetWeekday: 90,
  budgetWeekend: 180,
  curfew: { start: '23:30', end: '07:00' },
  curfewAll: false,
  studyFirstWeekday: 60,
  studyFirstWeekend: 0,
  duringClasses: true,
  duringStudyMode: true,
  streak: 50,
  pause: 10,
  passes: 2,
  passMinutes: 15,
  passDelay: 2,
  studyFolders: ['~/EPFL'],
  freeFolders: [],
}

export type StudyContext = {
  /** Le mode étude de StudyTrack : `locks`, le verrou (on ne sort pas avant l'heure). */
  studyMode: { since: number; until: number; blocks: boolean; locks: boolean } | null
  classes: { start: number; end: number; title: string }[]
  /** Le temps d'étude du jour, compté comme StudyTrack le compte, plus le chrono qui tourne. */
  studied: { day: string; seconds: number; accumulated: number; runningSince: number | null } | null
}

/** `policy.json`, écrit par StudyTrack (Réglages › Claude Code), lu à chaque demande. */
export type Policy = {
  v: 1
  writtenAt: number
  enabled: boolean
  /** Avant cet instant, Avec mesure observe : il compte et prévient, ne bloque rien. */
  enforceFrom: number
  rules: Rules
  /** Un assouplissement attend le lendemain (durcir s'applique tout de suite). */
  pending: { rules: Rules; from: number; enabled?: boolean } | null
  context: StudyContext
}

export type RuleId = 'lock' | 'studyMode' | 'class' | 'curfew' | 'studyFirst' | 'pause' | 'budget'

export type Usage = {
  projetsMs: number
  etudeMs: number
  libreMs: number
  /** La série en cours sur les projets (pauses de moins de `pause` minutes comprises). */
  streak: { start: number; end: number } | null
}

export type Verdict = {
  allow: boolean
  rule: RuleId | null
  until: number | null
  message: string
  /** Un pass peut lever ce blocage. */
  passable: boolean
  /** Bloquerait, mais Avec mesure observe encore. */
  observing: boolean
  /** Permis, mais près d'une limite. */
  warn: string | null
  /** Les minutes de projets qui restent aujourd'hui (`null` : sans limite). */
  remainingMin: number | null
}

// MARK: - Jours et heures

export function dayKey(t: number): string {
  const d = new Date(t)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export function startOfDay(t: number): number {
  const d = new Date(t)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

export function addDays(t: number, n: number): number {
  const d = new Date(t)
  d.setDate(d.getDate() + n)
  return d.getTime()
}

export function isWeekend(t: number): boolean {
  const day = new Date(t).getDay()
  return day === 0 || day === 6
}

/** « 7 h 05 » */
export function clock(t: number): string {
  const d = new Date(t)
  return `${d.getHours()} h ${String(d.getMinutes()).padStart(2, '0')}`
}

/** « 1 h 05 », « 42 min » */
export function duration(ms: number): string {
  const minutes = Math.max(0, Math.round(ms / MINUTE))
  if (minutes < 60) return `${minutes} min`
  return `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, '0')}`
}

function minutesOf(hhmm: string): number {
  const [h, m] = hhmm.split(':').map(Number)
  return ((h || 0) % 24) * 60 + (m || 0)
}

/** L'instant `hh:mm` du jour de `t`. */
function at(t: number, hhmm: string): number {
  return startOfDay(t) + minutesOf(hhmm) * MINUTE
}

/** Le couvre-feu en cours à `now` : sa fin, ou `null`. Il peut passer minuit. */
export function curfewEnd(curfew: Curfew | null, now: number): number | null {
  if (curfew == null) return null
  const start = minutesOf(curfew.start)
  const end = minutesOf(curfew.end)
  if (start === end) return null
  const minute = new Date(now).getHours() * 60 + new Date(now).getMinutes()
  if (start < end) return minute >= start && minute < end ? at(now, curfew.end) : null
  if (minute >= start) return at(addDays(now, 1), curfew.end)
  if (minute < end) return at(now, curfew.end)
  return null
}

// MARK: - Classement

export function expand(path: string, home: string): string {
  const p = path.startsWith('~') ? home + path.slice(1) : path
  return p.replace(/\/+$/, '')
}

function inside(cwd: string, folder: string): boolean {
  return folder !== '' && (cwd === folder || cwd.startsWith(folder + '/'))
}

export function categorize(cwd: string, rules: Rules, home: string): Category {
  const dir = cwd.replace(/\/+$/, '')
  if (rules.freeFolders.some(f => inside(dir, expand(f, home)))) return 'libre'
  if (rules.studyFolders.some(f => inside(dir, expand(f, home)))) return 'etude'
  return 'projets'
}

// MARK: - Le temps compté

/** Les intervalles comptés d'une séance, bornés à [from, to). `live` : prolonger jusqu'à `now`. */
export function intervals(record: SessionRecord, from: number, to: number, now: number, live: boolean): [number, number][] {
  const events = [...record.events].sort((a, b) => a.t - b.t)
  // Finie si la dernière marque est une fin (après un /clear, on reprend).
  const ended = events[events.length - 1]?.k === 'e'
  if (live && !ended && events.length > 0) events.push({ t: now, k: 'e' })
  const out: [number, number][] = []
  for (let i = 0; i + 1 < events.length; i++) {
    const a = events[i]!
    const gap = events[i + 1]!.t - a.t
    let credit = 0
    if (a.k === 'p') credit = Math.min(gap, TURN_CAP_MS)
    else if (a.k === 'd' || a.k === 's') credit = gap <= IDLE_MS ? gap : 0
    const start = Math.max(a.t, from)
    const end = Math.min(a.t + credit, to)
    if (end > start) out.push([start, end])
  }
  return out
}

/** L'union d'intervalles, fusionnés quand l'écart est sous `join`. */
export function union(list: [number, number][], join = 0): [number, number][] {
  const sorted = [...list].sort((a, b) => a[0] - b[0])
  const out: [number, number][] = []
  for (const [s, e] of sorted) {
    const last = out[out.length - 1]
    if (last && s - last[1] <= join) last[1] = Math.max(last[1], e)
    else out.push([s, e])
  }
  return out
}

const total = (list: [number, number][]) => list.reduce((sum, [s, e]) => sum + (e - s), 0)

export function usage(records: SessionRecord[], now: number, rules: Rules, liveSession?: string): Usage {
  const from = startOfDay(now)
  const to = addDays(from, 1)
  const by: Record<Category, [number, number][]> = { etude: [], projets: [], libre: [] }
  const recorded: [number, number][] = []
  for (const record of records) {
    if (record.headless) continue
    by[record.category].push(...intervals(record, from, to, now, record.session === liveSession))
    if (record.category === 'projets') recorded.push(...intervals(record, from, to, now, false))
  }
  // La série : les intervalles enregistrés (pas la frappe en cours), qui se
  // touchent à moins d'une pause près.
  const blocks = union(recorded, rules.pause * MINUTE)
  const last = blocks[blocks.length - 1]
  return {
    projetsMs: total(union(by.projets)),
    etudeMs: total(union(by.etude)),
    libreMs: total(union(by.libre)),
    streak: last && now - last[1] < rules.pause * MINUTE ? { start: last[0], end: last[1] } : null,
  }
}

export function studiedKnown(context: StudyContext, now: number): boolean {
  return context.studied != null && context.studied.day === dayKey(now)
}

export function studiedSeconds(context: StudyContext, now: number): number {
  const s = context.studied
  if (!s || s.day !== dayKey(now)) return 0
  const live = s.runningSince ? Math.max(0, (now - s.runningSince) / 1000) : 0
  return s.seconds + s.accumulated + live
}

// MARK: - La règle du moment

export function effectiveRules(policy: Policy, now: number): Rules {
  const rules = policy.pending && now >= policy.pending.from ? policy.pending.rules : policy.rules
  return { ...DEFAULT_RULES, ...rules, budgetWeekday: rules.budgetWeekday ?? null, budgetWeekend: rules.budgetWeekend ?? null,
           curfew: rules.curfew ?? null, streak: rules.streak ?? null }
}

/** Couper Avec mesure attend aussi le lendemain : l'état voulu est dans `pending`. */
export function effectiveEnabled(policy: Policy, now: number): boolean {
  return policy.pending && now >= policy.pending.from ? (policy.pending.enabled ?? policy.enabled) : policy.enabled
}

export function activePass(passes: Pass[], now: number): Pass | null {
  return passes.find(p => now >= p.from && now < p.until) ?? null
}

/** Un pass demandé dont le délai de réflexion court encore. */
export function waitingPass(passes: Pass[], now: number): Pass | null {
  return passes.find(p => now >= p.at && now < p.from) ?? null
}

export function passesLeft(rules: Rules, passes: Pass[], now: number): number {
  return Math.max(0, rules.passes - passes.filter(p => dayKey(p.at) === dayKey(now)).length)
}

export function budgetMinutes(rules: Rules, now: number): number | null {
  // `== null` partout : un champ absent (un écrivain qui omet les nuls) vaut « sans limite ».
  return (isWeekend(now) ? rules.budgetWeekend : rules.budgetWeekday) ?? null
}

type Block = { rule: RuleId; until: number | null; message: string; passable: boolean }

function firstBlock(category: Category, rules: Rules, context: StudyContext, use: Usage, now: number): Block | null {
  const mode = context.studyMode
  const inMode = mode && now >= mode.since && now < mode.until
  if (inMode && mode.locks && category !== 'etude') {
    return { rule: 'lock', until: mode.until, passable: false,
             message: `Verrou du mode étude jusqu'à ${clock(mode.until)} : ici, Claude ne sert qu'à étudier.` }
  }
  const curfew = curfewEnd(rules.curfew, now)
  if (curfew && rules.curfewAll && category !== 'libre') {
    return { rule: 'curfew', until: curfew, passable: true, message: `Couvre-feu jusqu'à ${clock(curfew)}. Dors : tout sera là demain.` }
  }
  if (category !== 'projets') return null
  if (inMode && mode.blocks && rules.duringStudyMode) {
    return { rule: 'studyMode', until: mode.until, passable: false,
             message: `Mode étude en cours jusqu'à ${clock(mode.until)} : les projets attendent.` }
  }
  const lesson = rules.duringClasses ? context.classes.find(c => now >= c.start && now < c.end) : undefined
  if (lesson) {
    return { rule: 'class', until: lesson.end, passable: false,
             message: `Cours en ce moment (${lesson.title}, jusqu'à ${clock(lesson.end)}) : les projets attendent.` }
  }
  if (curfew) {
    return { rule: 'curfew', until: curfew, passable: true, message: `Couvre-feu jusqu'à ${clock(curfew)}. Dors : le code sera là demain.` }
  }
  // Le temps étudié n'est connu que si StudyTrack l'a écrit aujourd'hui : sinon
  // (l'app fermée depuis hier), la règle ne peut pas se vérifier et ne bloque pas.
  const needed = (isWeekend(now) ? rules.studyFirstWeekend : rules.studyFirstWeekday) * 60
  const studied = studiedSeconds(context, now)
  if (needed > 0 && studiedKnown(context, now) && studied < needed) {
    return { rule: 'studyFirst', until: null, passable: true,
             message: `D'abord étudier : encore ${duration((needed - studied) * 1000)} dans StudyTrack (${duration(studied * 1000)} sur ${duration(needed * 1000)} aujourd'hui).` }
  }
  if (rules.streak != null && use.streak && use.streak.end - use.streak.start >= rules.streak * MINUTE) {
    const until = use.streak.end + rules.pause * MINUTE
    return { rule: 'pause', until, passable: true,
             message: `Pause : ${duration(use.streak.end - use.streak.start)} d'affilée sur les projets. Reprends à ${clock(until)}.` }
  }
  const budget = budgetMinutes(rules, now)
  if (budget != null && use.projetsMs >= budget * MINUTE) {
    return { rule: 'budget', until: addDays(startOfDay(now), 1), passable: true,
             message: `Budget du jour atteint : ${duration(use.projetsMs)} sur ${duration(budget * MINUTE)} de projets.` }
  }
  return null
}

export function evaluate(category: Category, headless: boolean, policy: Policy | null, use: Usage, passes: Pass[], now: number): Verdict {
  const open: Verdict = { allow: true, rule: null, until: null, message: '', passable: false, observing: false, warn: null, remainingMin: null }
  if (!policy || !effectiveEnabled(policy, now) || headless) return open
  const rules = effectiveRules(policy, now)
  const budget = budgetMinutes(rules, now)
  const remainingMin = category === 'projets' && budget != null
    ? Math.max(0, Math.round(budget - use.projetsMs / MINUTE)) : null
  const block = firstBlock(category, rules, policy.context, use, now)
  const pass = activePass(passes, now)
  const left = passesLeft(rules, passes, now)
  if (block && !(block.passable && pass)) {
    const waiting = waitingPass(passes, now)
    const hint = !block.passable ? ''
      : waiting ? ` Ton pass s'ouvre à ${clock(waiting.from)}.`
      : left > 0 ? ` /mesure encore <raison> : ${left} pass ${left > 1 ? 'restants' : 'restant'}.`
      : ' Plus de pass aujourd\'hui.'
    const message = block.message + hint
    if (now < policy.enforceFrom) {
      return { ...open, observing: true, rule: block.rule, until: block.until, remainingMin,
               message: `Observation : ${message}` }
    }
    return { allow: false, rule: block.rule, until: block.until, message, passable: block.passable,
             observing: false, warn: null, remainingMin }
  }
  let warn: string | null = null
  if (pass) warn = `Pass ouvert jusqu'à ${clock(pass.until)} (${pass.reason}).`
  else if (category === 'projets' && budget != null && use.projetsMs >= budget * MINUTE * 0.8) {
    warn = `Projets : ${duration(use.projetsMs)} sur ${duration(budget * MINUTE)} aujourd'hui.`
  } else if (category === 'projets' && rules.streak != null && use.streak
             && use.streak.end - use.streak.start >= (rules.streak - 10) * MINUTE) {
    warn = `${duration(use.streak.end - use.streak.start)} d'affilée : une pause arrive à ${rules.streak} min.`
  }
  return { ...open, warn, remainingMin }
}

/** Un pass demandé maintenant : refusé (avec la raison), ou ce qu'il faut écrire. */
export function requestPass(reason: string, verdict: Verdict, rules: Rules, passes: Pass[], session: string, now: number): Pass | string {
  const words = reason.trim().split(/\s+/).filter(Boolean)
  if (verdict.allow && !verdict.observing) return 'Rien ne bloque en ce moment : pas besoin de pass.'
  if (!verdict.passable && !verdict.observing) return `Pas de pass pour ça : ${verdict.message}`
  if (activePass(passes, now) || waitingPass(passes, now)) return 'Un pass est déjà ouvert ou en attente.'
  if (passesLeft(rules, passes, now) === 0) return 'Plus de pass aujourd\'hui. Demain, de nouveau.'
  if (words.length < 3) return 'Dis pourquoi, en quelques mots (trois au moins) : /mesure encore <raison>.'
  const from = now + rules.passDelay * MINUTE
  return { v: 1, at: now, from, until: from + rules.passMinutes * MINUTE, reason: reason.trim().slice(0, 280), rule: verdict.rule, session }
}
