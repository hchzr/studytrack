// Avec mesure, côté Claude Code : compter, prévenir, et appliquer les règles
// réglées dans Polymestre (Réglages › Claude Code).
//
// Les fichiers, dans `~/Library/Application Support/Polymestre/Claude/` :
//   policy.json                  Polymestre → ici : les règles et le contexte (mode
//                                étude, cours du jour, temps étudié) ;
//   sessions/<jour>/<séance>.json ici → Polymestre : les marques de chaque séance ;
//   passes/<jour>/<instant>.json  ici → Polymestre : « encore 15 min », avec sa raison ;
//   mod.json                     ici → Polymestre : le mod est branché (version, vu à).
// Chaque séance n'écrit que son fichier : plusieurs terminaux ne se marchent pas dessus.
//
// Coût au repos : nul. Rien ne tourne entre deux demandes, sauf une minuterie
// unique posée à l'instant où un blocage se lève (pour rafraîchir le bandeau).

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Band } from '../types'
import {
  DEFAULT_RULES, activePass, budgetMinutes, categorize, clock, dayKey, addDays, duration, effectiveEnabled, effectiveRules,
  evaluate, passesLeft, requestPass, studiedKnown, studiedSeconds, usage, waitingPass,
} from './policy'
import type { Category, EventKind, Pass, Policy, Rules, SessionRecord, Verdict } from './policy'

const VERSION = '0.1.0'
const band = atom({ plugin: 'mesure', key: 'band' } as const, null)

/** Ce que l'on peut encore taper quand tout est bloqué : rien qui fasse travailler le modèle. */
const ALLOWED_COMMANDS = new Set([
  'mesure', 'exit', 'quit', 'help', 'status', 'config', 'plugin', 'plugins', 'reload-plugins',
  'hooks', 'login', 'logout', 'cost', 'usage', 'doctor', 'export', 'permissions', 'model', 'clear',
])

const CATEGORY_LABEL: Record<Category, string> = { etude: 'étude', projets: 'projets', libre: 'libre' }

// L'état de la séance : celui du module, refait à chaque rechargement (la
// séance se relit alors depuis son fichier).
let home = ''
let root = ''
let record: SessionRecord | null = null
let file = ''
let unblockTimer: { cancel: () => void } | null = null
/** `MESURE_ENFORCE_HEADLESS=1` : les demandes d'un `claude -p` comptent comme tapées. */
let forcedHeadless = false

const paths = {
  policy: () => `${root}/policy.json`,
  sessions: (day: string) => `${root}/sessions/${day}`,
  passes: (day: string) => `${root}/passes/${day}`,
}

async function readJSON<T>($: EngineInterface, path: string): Promise<T | null> {
  try {
    return JSON.parse(await $.fs.read(path)) as T
  } catch {
    return null
  }
}

async function readPolicy($: EngineInterface): Promise<Policy | null> {
  const policy = await readJSON<Policy>($, paths.policy())
  return policy && policy.v === 1 ? policy : null
}

/** Les fichiers JSON d'un dossier du jour (et de la veille : une séance passe minuit). */
async function readDays<T>($: EngineInterface, folder: (day: string) => string, now: number): Promise<T[]> {
  const out: T[] = []
  for (const day of [dayKey(addDays(now, -1)), dayKey(now)]) {
    const entries = await $.fs.list(folder(day)).catch(() => [])
    for (const entry of entries) {
      if (entry.kind !== 'file' || !entry.name.endsWith('.json')) continue
      const value = await readJSON<T>($, `${folder(day)}/${entry.name}`)
      if (value) out.push(value)
    }
  }
  return out
}

async function ensureRoot($: EngineInterface) {
  if (root) return
  home = (await $.env.get('HOME')) ?? ''
  root = `${home}/Library/Application Support/Polymestre/Claude`
}

/** La séance de ce processus : relue après un rechargement, refaite après un /clear. */
async function ensureRecord($: EngineInterface, cwd?: string, headless?: boolean): Promise<SessionRecord> {
  await ensureRoot($)
  const id = await $.session.id()
  if (record && record.session === id) return record
  const now = await $.clock.now()
  const policy = await readPolicy($)
  const rules = policy ? effectiveRules(policy, now) : DEFAULT_RULES
  const dir = cwd ?? (await $.session.cwd())
  file = `${paths.sessions(dayKey(now))}/${id}.json`
  const existing = await readJSON<SessionRecord>($, file)
  record = existing ?? {
    v: 1, session: id, cwd: dir, category: categorize(dir, rules, home),
    headless: headless ?? record?.headless ?? false, events: [], blocks: [],
  }
  if (!existing) await mark($, 's')
  return record
}

async function save($: EngineInterface) {
  if (record) await $.fs.write(file, JSON.stringify(record))
}

async function mark($: EngineInterface, k: EventKind) {
  if (!record) return
  record.events.push({ t: await $.clock.now(), k })
  // Une séance très longue garde ses 2 000 dernières marques (le fichier reste petit).
  if (record.events.length > 2000) record.events = record.events.slice(-2000)
  await save($)
}

async function verdictNow($: EngineInterface): Promise<{ verdict: Verdict; policy: Policy | null; passes: Pass[]; now: number }> {
  const rec = await ensureRecord($)
  const now = await $.clock.now()
  const policy = await readPolicy($)
  const records = await readDays<SessionRecord>($, paths.sessions, now)
  if (!records.some(r => r.session === rec.session)) records.push(rec)
  const rules = policy ? effectiveRules(policy, now) : DEFAULT_RULES
  const use = usage(records.map(r => (r.session === rec.session ? rec : r)), now, rules, rec.session)
  const passes = await readDays<Pass>($, paths.passes, now)
  return { verdict: evaluate(rec.category, rec.headless, policy, use, passes, now), policy, passes, now }
}

/** La ligne d'état et le bandeau, d'après le verdict. */
async function show($: EngineInterface, verdict: Verdict, now: number) {
  const rec = record
  if (!rec || rec.headless) return
  const policy = await readPolicy($)
  if (!policy || !effectiveEnabled(policy, now)) {
    $.ui.status(undefined)
    await update($, band, () => null)
    return
  }
  const rules = effectiveRules(policy, now)
  const budget = budgetMinutes(rules, now)
  let status = `mesure · ${CATEGORY_LABEL[rec.category]}`
  if (rec.category === 'projets' && budget != null && verdict.remainingMin != null) {
    status = `mesure · projets ${Math.max(0, budget - verdict.remainingMin)}/${budget} min`
  }
  if (!verdict.allow) status += ' · bloqué'
  $.ui.status(status)
  const next: Band | null = !verdict.allow ? { tone: 'block', text: verdict.message }
    : verdict.observing ? { tone: 'observe', text: verdict.message }
    : verdict.warn ? { tone: 'warn', text: verdict.warn }
    : null
  await update($, band, () => next)
  // Une minuterie, une seule : à l'instant où le blocage se lève.
  unblockTimer?.cancel()
  unblockTimer = null
  if (!verdict.allow && verdict.until && verdict.until > now && verdict.until - now < 24 * 3_600_000) {
    unblockTimer = $.clock.after(verdict.until - now + 1000, () => { void refresh($) })
  }
}

async function refresh($: EngineInterface) {
  const { verdict, now } = await verdictNow($)
  await show($, verdict, now)
}

async function askPass($: EngineInterface, reason: string): Promise<string> {
  const { verdict, policy, passes, now } = await verdictNow($)
  if (!policy || !effectiveEnabled(policy, now)) return "Avec mesure n'est pas réglé : Polymestre › Réglages › Claude Code."
  const rules = effectiveRules(policy, now)
  const result = requestPass(reason, verdict, rules, passes, record?.session ?? '', now)
  if (typeof result === 'string') return result
  await $.fs.write(`${paths.passes(dayKey(now))}/${now}.json`, JSON.stringify(result))
  const all = [...passes, result]
  await show($, { ...verdict, message: `${verdict.message.split(' /mesure')[0]} Ton pass s'ouvre à ${clock(result.from)}.` }, now)
  return `Pass noté : il s'ouvre à ${clock(result.from)} (${rules.passDelay} min pour y repenser) et dure ${rules.passMinutes} min, `
    + `jusqu'à ${clock(result.until)}. Raison : « ${result.reason} ». `
    + `${passesLeft(rules, all, now)} pass restant aujourd'hui. Polymestre le garde dans ton bilan.`
}

async function today($: EngineInterface): Promise<string> {
  const { verdict, policy, passes, now } = await verdictNow($)
  const rules = policy ? effectiveRules(policy, now) : DEFAULT_RULES
  const records = await readDays<SessionRecord>($, paths.sessions, now)
  const use = usage(records, now, rules, record?.session)
  const budget = budgetMinutes(rules, now)
  const lines = ['Avec mesure — aujourd\'hui']
  lines.push(`Projets : ${duration(use.projetsMs)}${budget != null ? ` sur ${duration(budget * 60_000)}` : ''}`
    + ` · étude : ${duration(use.etudeMs)} · libre : ${duration(use.libreMs)}`)
  if (policy) {
    lines.push(studiedKnown(policy.context, now)
      ? `Étudié dans Polymestre : ${duration(studiedSeconds(policy.context, now) * 1000)}`
      : 'Étudié dans Polymestre : inconnu (Polymestre ne tourne pas sur ce Mac) — « d\'abord étudier » ne bloque pas.')
  }
  lines.push(`Cette séance : ${CATEGORY_LABEL[record?.category ?? 'projets']} (${record?.cwd ?? ''})`)
  if (!policy || !effectiveEnabled(policy, now)) {
    lines.push('Pas encore réglé : Polymestre › Réglages › Claude Code. En attendant, Avec mesure compte et ne bloque rien.')
    return lines.join('\n')
  }
  lines.push(verdict.allow ? `Maintenant : permis.${verdict.warn ? ' ' + verdict.warn : ''}` : `Maintenant : ${verdict.message}`)
  if (verdict.observing) lines.push(`Observation jusqu'à ${clock(policy.enforceFrom)} le ${new Date(policy.enforceFrom).toLocaleDateString('fr-CH')} : rien n'est encore bloqué.`)
  const open = activePass(passes, now)
  const waiting = waitingPass(passes, now)
  lines.push(open ? `Pass ouvert jusqu'à ${clock(open.until)}.` : waiting ? `Pass en attente : il s'ouvre à ${clock(waiting.from)}.`
    : `Pass : ${passesLeft(rules, passes, now)} sur ${rules.passes} aujourd'hui (${rules.passMinutes} min, ${rules.passDelay} min de réflexion).`)
  lines.push(`Règles : ${describe(rules)}`)
  if (policy.pending && now < policy.pending.from) {
    lines.push(`Assouplissement en attente : appliqué le ${new Date(policy.pending.from).toLocaleDateString('fr-CH')} à ${clock(policy.pending.from)} (durcir s'applique tout de suite, assouplir le lendemain).`)
  }
  lines.push('Réglages : Polymestre › Réglages › Claude Code · /mesure semaine · /mesure aide')
  return lines.join('\n')
}

async function week($: EngineInterface): Promise<string> {
  await ensureRoot($)
  const now = await $.clock.now()
  const policy = await readPolicy($)
  const rules = policy ? effectiveRules(policy, now) : DEFAULT_RULES
  const lines = ['Avec mesure — 7 derniers jours (projets · étude)']
  for (let i = 6; i >= 0; i--) {
    const day = addDays(now, -i)
    const records: SessionRecord[] = []
    for (const key of [dayKey(addDays(day, -1)), dayKey(day)]) {
      const entries = await $.fs.list(paths.sessions(key)).catch(() => [])
      for (const entry of entries) {
        const value = entry.name.endsWith('.json') ? await readJSON<SessionRecord>($, `${paths.sessions(key)}/${entry.name}`) : null
        if (value) records.push(value)
      }
    }
    const end = i === 0 ? now : addDays(new Date(day).setHours(0, 0, 0, 0), 1) - 1
    const use = usage(records, end, rules)
    const label = new Date(day).toLocaleDateString('fr-CH', { weekday: 'short', day: 'numeric' })
    const bar = '█'.repeat(Math.min(24, Math.round(use.projetsMs / (15 * 60_000))))
    lines.push(`${label.padEnd(8)} ${duration(use.projetsMs).padStart(8)} · ${duration(use.etudeMs).padStart(8)}  ${bar}`)
  }
  lines.push('Un █ : 15 min de projets. Le détail (et les raisons des passes) : Polymestre › Bilan.')
  return lines.join('\n')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await ensureRoot($)
    await $.command.register({
      name: 'mesure',
      description: "Avec mesure : ton temps de Claude Code aujourd'hui ; « encore <raison> » pour un pass",
      argumentHint: '[encore <raison> | semaine | aide]',
      immediate: true,
    })
    // `MESURE_ENFORCE_HEADLESS=1` : une séance sans clavier compte et se bloque
    // comme les autres (pour compter ses scripts — et pour l'essai de bout en bout).
    forcedHeadless = (await $.env.get('MESURE_ENFORCE_HEADLESS')) === '1'
    await ensureRecord($, e.cwd, !e.isInteractive && !forcedHeadless)
    await $.fs.write(`${root}/mod.json`, JSON.stringify({ v: 1, version: VERSION, seenAt: await $.clock.now() }))
    await refresh($)
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (e.isMeta) return next(e)
    if (e.command) {
      if (e.command.name === 'mesure' || ALLOWED_COMMANDS.has(e.command.name)) return next(e)
      const { verdict } = await verdictNow($)
      return verdict.allow ? next(e) : { drop: verdict.message }
    }
    const typed = e.origin.kind === 'composer' || e.origin.kind === 'bridge' || (forcedHeadless && e.origin.kind === 'sdk')
    const { verdict, now } = await verdictNow($)
    if (typed && !verdict.allow) {
      if (record && verdict.rule) {
        record.blocks.push({ t: now, rule: verdict.rule })
        await save($)
      }
      await show($, verdict, now)
      return { drop: verdict.message }
    }
    await mark($, 'p')
    await show($, verdict, now)
    // Quand il reste peu, Claude le sait : il aide à conclure plutôt qu'à ouvrir un chantier.
    if (typed && verdict.remainingMin != null && verdict.remainingMin <= 15) {
      const note = `[Avec mesure] Il reste ${verdict.remainingMin} min de projets à l'utilisateur aujourd'hui `
        + "(règle qu'il s'est donnée). Aide-le à conclure proprement : finir l'étape en cours, noter où reprendre."
      return next({ ...e, context: [...(e.context ?? []), note] })
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId) return next(e)
    await mark($, 'd')
    const { verdict, now } = await verdictNow($)
    await show($, verdict, now)
    if (!verdict.allow && !record?.headless) $.ui.toast(verdict.message)
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    if (record && record.session === e.sessionId) await mark($, 'e')
    return next(e)
  })

  on('command.run', { command: 'mesure' }, async ($, e) => {
    const args = e.args.trim()
    const [word, ...rest] = args.split(/\s+/)
    const verb = (word ?? '').toLowerCase()
    if (verb === 'encore' || verb === 'pass') return { text: await askPass($, rest.join(' ')) }
    if (verb === 'semaine') return { text: await week($) }
    if (verb === 'aide' || verb === 'help') return { text: HELP }
    return { text: await today($) }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const current = await read($, band)
    if (!current || e.props.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const color = current.tone === 'block' ? 'warning' : current.tone === 'warn' ? 'suggestion' : 'subtle'
    return (
      <Box>
        <Text color={color}>{current.tone === 'block' ? '⏸ ' : '· '}{current.text}</Text>
      </Box>
    )
  })
}

const HELP = [
  'Avec mesure — Claude Code, compté et réglé avec Polymestre',
  '/mesure            aujourd\'hui : le temps, ce qui bloque, les passes',
  '/mesure encore <raison>   un pass : s\'ouvre après le délai de réflexion, raison gardée',
  '/mesure semaine    les 7 derniers jours',
  'Étude : les dossiers d\'étude (par défaut ~/EPFL) ne sont jamais limités, seulement comptés.',
  'Projets : tout le reste — budget, couvre-feu, cours, mode étude, d\'abord étudier, pauses.',
  'Les règles se règlent dans Polymestre (Mac) › Réglages › Claude Code. Durcir s\'applique',
  'tout de suite ; assouplir, le lendemain à 4 h : on ne lâche pas ses limites sur un coup de tête.',
].join('\n')

function describe(rules: Rules): string {
  const parts: string[] = []
  if (rules.budgetWeekday != null || rules.budgetWeekend != null) {
    parts.push(`projets ${rules.budgetWeekday ?? '∞'} min en semaine, ${rules.budgetWeekend ?? '∞'} le week-end`)
  }
  if (rules.curfew) parts.push(`couvre-feu ${rules.curfew.start}–${rules.curfew.end}${rules.curfewAll ? ' (tout)' : ''}`)
  if (rules.studyFirstWeekday > 0) parts.push(`d'abord ${rules.studyFirstWeekday} min d'étude en semaine`)
  if (rules.duringClasses) parts.push('pas pendant les cours')
  if (rules.duringStudyMode) parts.push('pas en mode étude')
  if (rules.streak != null) parts.push(`pause de ${rules.pause} min après ${rules.streak} min d'affilée`)
  return parts.join(' · ') || 'aucune'
}

