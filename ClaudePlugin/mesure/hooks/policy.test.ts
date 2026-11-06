// Les cas de `policy.ts`. Les mêmes, en Swift, sont dans Validation/main.swift
// (« Avec mesure ») : les deux calculs doivent rendre les mêmes verdicts.
import { expect, test } from 'claude-code/testing'

import {
  DEFAULT_RULES, categorize, curfewEnd, effectiveRules, evaluate, intervals, requestPass, union, usage,
} from './policy'
import type { Pass, Policy, Rules, SessionRecord, StudyContext } from './policy'

const MIN = 60_000
/** Mardi 27 octobre 2026, à l'heure locale. */
const at = (h: number, m = 0, day = 27) => new Date(2026, 9, day, h, m).getTime()
const HOME = '/Users/eleve'

function session(id: string, category: SessionRecord['category'], marks: [number, 's' | 'p' | 'd' | 'e'][]): SessionRecord {
  return { v: 1, session: id, cwd: '/x', category, headless: false, events: marks.map(([t, k]) => ({ t, k })), blocks: [] }
}

const empty: StudyContext = { studyMode: null, classes: [], studied: { day: '2026-10-27', seconds: 4 * 3600, accumulated: 0, runningSince: null } }

function policy(rules: Partial<Rules> = {}, context: Partial<StudyContext> = {}, extra: Partial<Policy> = {}): Policy {
  return { v: 1, writtenAt: 0, enabled: true, enforceFrom: 0, rules: { ...DEFAULT_RULES, ...rules },
           pending: null, context: { ...empty, ...context }, ...extra }
}

const noUse = { projetsMs: 0, etudeMs: 0, libreMs: 0, streak: null }

test('le temps compté : une réponse longue plafonnée, une absence oubliée', () => {
  const t0 = at(14)
  const rec = session('a', 'projets', [[t0, 's'], [t0 + MIN, 'p'], [t0 + 3 * MIN, 'd'], [t0 + 6 * MIN, 'p'],
                                       [t0 + 40 * MIN, 'd'], [t0 + 60 * MIN, 'p'], [t0 + 61 * MIN, 'd'], [t0 + 62 * MIN, 'e']])
  const total = intervals(rec, at(0), at(0, 0, 28), t0 + 70 * MIN, false).reduce((s, [a, b]) => s + b - a, 0)
  // 1 (lecture) + 2 (réponse) + 3 (lecture) + 20 (réponse plafonnée) + 0 (20 min d'absence) + 1 + 1
  expect(total).toBe(28 * MIN)
})

test('deux terminaux en même temps ne comptent qu\'une fois', () => {
  const t0 = at(15)
  const a = session('a', 'projets', [[t0, 'p'], [t0 + 10 * MIN, 'd'], [t0 + 11 * MIN, 'e']])
  const b = session('b', 'projets', [[t0 + 5 * MIN, 'p'], [t0 + 12 * MIN, 'd'], [t0 + 12 * MIN, 'e']])
  expect(usage([a, b], t0 + 30 * MIN, DEFAULT_RULES).projetsMs).toBe(12 * MIN)
  expect(union([[0, 5], [5, 8], [20, 30]])).toEqual([[0, 8], [20, 30]])
})

test('la frappe en cours compte pour la séance vivante seulement', () => {
  const t0 = at(16)
  const rec = session('a', 'projets', [[t0, 'p'], [t0 + 2 * MIN, 'd']])
  expect(usage([rec], t0 + 5 * MIN, DEFAULT_RULES, 'a').projetsMs).toBe(5 * MIN)
  expect(usage([rec], t0 + 5 * MIN, DEFAULT_RULES).projetsMs).toBe(2 * MIN)
})

test('le couvre-feu passe minuit', () => {
  const curfew = { start: '23:30', end: '07:00' }
  expect(curfewEnd(curfew, at(23, 45))).toBe(at(7, 0, 28))
  expect(curfewEnd(curfew, at(6, 0))).toBe(at(7))
  expect(curfewEnd(curfew, at(12))).toBeNull()
  expect(curfewEnd({ start: '13:00', end: '14:00' }, at(13, 30))).toBe(at(14))
})

test('classement par dossier', () => {
  expect(categorize(`${HOME}/EPFL/AICC`, DEFAULT_RULES, HOME)).toBe('etude')
  expect(categorize(`${HOME}/EPFL`, DEFAULT_RULES, HOME)).toBe('etude')
  expect(categorize(`${HOME}/EPFLX`, DEFAULT_RULES, HOME)).toBe('projets')
  expect(categorize(`${HOME}/Prog/studytrack`, DEFAULT_RULES, HOME)).toBe('projets')
  expect(categorize(`${HOME}/Notes`, { ...DEFAULT_RULES, freeFolders: ['~/Notes'] }, HOME)).toBe('libre')
})

test('budget atteint : bloqué, levé par un pass', () => {
  const now = at(15)
  const use = { ...noUse, projetsMs: 95 * MIN }
  const v = evaluate('projets', false, policy(), use, [], now)
  expect(v.allow).toBe(false)
  expect(v.rule).toBe('budget')
  expect(v.passable).toBe(true)
  expect(v.message).toContain('/mesure encore')
  const pass: Pass = { v: 1, at: now - 5 * MIN, from: now - 3 * MIN, until: now + 12 * MIN, reason: 'finir le correctif', rule: 'budget', session: 'a' }
  const open = evaluate('projets', false, policy(), use, [pass], now)
  expect(open.allow).toBe(true)
  expect(open.warn).toContain('Pass ouvert')
  // L'étude n'a pas de budget.
  expect(evaluate('etude', false, policy(), use, [], now).allow).toBe(true)
})

test('près du budget : une alerte, et ce qui reste', () => {
  const v = evaluate('projets', false, policy(), { ...noUse, projetsMs: 75 * MIN }, [], at(15))
  expect(v.allow).toBe(true)
  expect(v.warn).toContain('Projets')
  expect(v.remainingMin).toBe(15)
})

test('pendant un cours : bloqué, sans pass', () => {
  const v = evaluate('projets', false, policy({}, { classes: [{ start: at(14), end: at(16), title: 'AICC' }] }), noUse, [], at(15))
  expect(v.rule).toBe('class')
  expect(v.passable).toBe(false)
})

test('mode étude : les projets attendent ; le verrou ferme aussi le libre', () => {
  const mode = { since: at(14), until: at(16), blocks: true, locks: false }
  expect(evaluate('projets', false, policy({}, { studyMode: mode }), noUse, [], at(15)).rule).toBe('studyMode')
  expect(evaluate('etude', false, policy({}, { studyMode: mode }), noUse, [], at(15)).allow).toBe(true)
  const lock = { ...mode, locks: true }
  expect(evaluate('libre', false, policy({}, { studyMode: lock }), noUse, [], at(15)).rule).toBe('lock')
  expect(evaluate('etude', false, policy({}, { studyMode: lock }), noUse, [], at(15)).allow).toBe(true)
})

test('d\'abord étudier', () => {
  const ctx = { studied: { day: '2026-10-27', seconds: 20 * 60, accumulated: 5 * 60, runningSince: at(14, 50) } }
  const v = evaluate('projets', false, policy({}, ctx), noUse, [], at(15))
  // 20 + 5 + 10 (le chrono qui tourne) = 35 min sur 60.
  expect(v.rule).toBe('studyFirst')
  expect(v.message).toContain('25 min')
  // Le week-end (samedi 31), pas de condition par défaut.
  const saturday = new Date(2026, 9, 31, 15).getTime()
  const weekend = { studied: { day: '2026-10-31', seconds: 0, accumulated: 0, runningSince: null } }
  expect(evaluate('projets', false, policy({}, weekend), noUse, [], saturday).allow).toBe(true)
  // Polymestre fermé depuis hier : la règle ne peut pas se vérifier, elle ne bloque pas.
  const stale = { studied: { day: '2026-10-26', seconds: 0, accumulated: 0, runningSince: null } }
  expect(evaluate('projets', false, policy({}, stale), noUse, [], at(15)).allow).toBe(true)
  expect(evaluate('projets', false, policy({}, { studied: null }), noUse, [], at(15)).allow).toBe(true)
})

test('couvre-feu : les projets seulement, sauf « tout »', () => {
  const night = at(23, 50)
  expect(evaluate('projets', false, policy(), noUse, [], night).rule).toBe('curfew')
  expect(evaluate('etude', false, policy(), noUse, [], night).allow).toBe(true)
  expect(evaluate('etude', false, policy({ curfewAll: true }), noUse, [], night).rule).toBe('curfew')
})

test('pause après une longue série', () => {
  const t0 = at(14)
  const marks: [number, 's' | 'p' | 'd' | 'e'][] = []
  for (let i = 0; i < 12; i++) marks.push([t0 + i * 5 * MIN, 'p'], [t0 + i * 5 * MIN + 4 * MIN, 'd'])
  const use = usage([session('a', 'projets', marks)], t0 + 60 * MIN, DEFAULT_RULES)
  const v = evaluate('projets', false, policy(), use, [], t0 + 60 * MIN)
  expect(v.rule).toBe('pause')
  expect(v.until).toBe(t0 + 59 * MIN + 10 * MIN)
  // Dix minutes sans rien : la série est finie.
  const later = usage([session('a', 'projets', marks)], t0 + 70 * MIN, DEFAULT_RULES)
  expect(later.streak).toBeNull()
})

test('observation : bloquerait, ne bloque pas', () => {
  const v = evaluate('projets', false, policy({}, {}, { enforceFrom: at(16) }), { ...noUse, projetsMs: 200 * MIN }, [], at(15))
  expect(v.allow).toBe(true)
  expect(v.observing).toBe(true)
  expect(v.message).toContain('Observation')
})

test('sans clavier ni règles : jamais bloqué', () => {
  const heavy = { ...noUse, projetsMs: 500 * MIN }
  expect(evaluate('projets', true, policy(), heavy, [], at(15)).allow).toBe(true)
  expect(evaluate('projets', false, null, heavy, [], at(15)).allow).toBe(true)
  expect(evaluate('projets', false, policy({}, {}, { enabled: false }), heavy, [], at(15)).allow).toBe(true)
})

test('un assouplissement attend son heure', () => {
  const p = policy({ budgetWeekday: 60 }, {}, { pending: { rules: { ...DEFAULT_RULES, budgetWeekday: 120 }, from: at(4, 0, 28) } })
  expect(effectiveRules(p, at(15)).budgetWeekday).toBe(60)
  expect(effectiveRules(p, at(5, 0, 28)).budgetWeekday).toBe(120)
})

test('un pass : une raison, un délai, un nombre', () => {
  const now = at(15)
  const blocked = evaluate('projets', false, policy(), { ...noUse, projetsMs: 95 * MIN }, [], now)
  expect(typeof requestPass('vite', blocked, DEFAULT_RULES, [], 'a', now)).toBe('string')
  const pass = requestPass('finir le correctif du build', blocked, DEFAULT_RULES, [], 'a', now)
  expect(typeof pass).toBe('object')
  if (typeof pass === 'object') {
    expect(pass.from).toBe(now + 2 * MIN)
    expect(pass.until).toBe(now + 17 * MIN)
  }
  const used: Pass[] = [0, 1].map(i => ({ v: 1, at: at(10 + i), from: at(10 + i), until: at(10 + i, 15), reason: 'x y z', rule: 'budget', session: 'a' }))
  expect(requestPass('encore un peu de temps', blocked, DEFAULT_RULES, used, 'a', now)).toContain('Plus de pass')
  const lesson = evaluate('projets', false, policy({}, { classes: [{ start: at(14), end: at(16), title: 'AICC' }] }), noUse, [], now)
  expect(requestPass('je veux vraiment coder', lesson, DEFAULT_RULES, [], 'a', now)).toContain('Pas de pass')
})
