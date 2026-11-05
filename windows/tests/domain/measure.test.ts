// Port de la section « Avec mesure (Claude Code) » de Validation/main.swift — les mêmes
// cas que ClaudePlugin/mesure/hooks/policy.test.ts. Un `it` par check Swift.
import { describe, expect, it } from "vitest";

import * as CM from "../../src/domain/claudeMeasure.ts";
import type { Category, Context, EventKind, Rules, SessionRecord } from "../../src/domain/claudeMeasure.ts";

const at = (h: number, m = 0, day = 27): Date => new Date(2026, 9, day, h, m);
const ms = CM.ms;
const minute = 60_000;
const session = (id: string, category: Category, marks: [number, EventKind][], headless = false): SessionRecord =>
  CM.sessionRecord({ session: id, cwd: "/x", category, headless, events: marks.map(([t, k]) => ({ t, k })), blocks: [] });
const studied: CM.Studied = { day: "2026-10-27", seconds: 4 * 3600, accumulated: 0, runningSince: null };
const policy = (rules: Rules = CM.standardRules(), context?: Context, enforceFrom = 0): CM.Policy =>
  CM.policyOf({ writtenAt: 0, enabled: true, enforceFrom, rules, pending: null,
    context: context ?? { studyMode: null, classes: [], studied } });
const none = CM.emptyUsage();
const evalP = (c: Category, p: CM.Policy | null, use: CM.Usage, passes: CM.Pass[], now: Date, headless = false) =>
  CM.evaluate(c, headless, p, use, passes, now);
const std = CM.standardRules;

describe("Avec mesure : temps de Claude Code et règles", () => {
  // Le temps compté : une réponse longue plafonnée, une absence oubliée.
  const t0 = ms(at(14));
  const long = session("a", "projets", [[t0, "s"], [t0 + minute, "p"], [t0 + 3 * minute, "d"], [t0 + 6 * minute, "p"],
    [t0 + 40 * minute, "d"], [t0 + 60 * minute, "p"], [t0 + 61 * minute, "d"], [t0 + 62 * minute, "e"]]);
  it("mesure : 1 + 2 + 3 + 20 (plafond) + 0 (absence) + 1 + 1 = 28 min", () => {
    const counted = CM.intervals(long, ms(at(0)), ms(at(0, 0, 28)), t0 + 70 * minute, false)
      .reduce((n, s) => n + s.end - s.start, 0);
    expect(counted).toBe(28 * minute);
  });

  // Deux terminaux en même temps : une seule fois.
  const t1 = ms(at(15));
  const a = session("a", "projets", [[t1, "p"], [t1 + 10 * minute, "d"], [t1 + 11 * minute, "e"]]);
  const b = session("b", "projets", [[t1 + 5 * minute, "p"], [t1 + 12 * minute, "d"], [t1 + 12 * minute, "e"]]);
  it("mesure : deux terminaux en même temps ne comptent qu'une fois", () => {
    expect(CM.usage([a, b], CM.date(t1 + 30 * minute), std()).projets).toBe(12 * 60);
  });
  it("mesure : la frappe en cours compte pour la séance vivante seulement", () => {
    const live = session("a", "projets", [[ms(at(16)), "p"], [ms(at(16, 2)), "d"]]);
    expect(CM.usage([live], at(16, 5), std(), "a").projets === 5 * 60
      && CM.usage([live], at(16, 5), std()).projets === 2 * 60).toBe(true);
  });
  it("mesure : une séance sans clavier (claude -p) ne compte pas", () => {
    expect(CM.usage([session("h", "projets", [[t1, "p"], [t1 + 30 * minute, "d"]], true)], at(16), std()).projets).toBe(0);
  });

  // Couvre-feu, classement.
  it("mesure : le couvre-feu passe minuit", () => {
    const curfew = { start: "23:30", end: "07:00" };
    expect(CM.curfewEnd(curfew, at(23, 45))?.getTime() === at(7, 0, 28).getTime()
      && CM.curfewEnd(curfew, at(6))?.getTime() === at(7).getTime()
      && CM.curfewEnd(curfew, at(12)) === null).toBe(true);
  });
  const home = "/Users/eleve";
  it("mesure : ~/EPFL est l'étude, ~/EPFLX non, le reste est projets", () => {
    expect(CM.categorize(`${home}/EPFL/AICC`, std(), home) === "etude"
      && CM.categorize(`${home}/EPFLX`, std(), home) === "projets"
      && CM.categorize(`${home}/Prog/studytrack`, std(), home) === "projets").toBe(true);
  });
  it("mesure : un dossier libre est exempté", () => {
    const free = std();
    free.freeFolders = ["~/Notes"];
    expect(CM.categorize(`${home}/Notes/x`, free, home)).toBe("libre");
  });

  // Les règles, dans l'ordre.
  const spent = CM.emptyUsage();
  spent.projets = 95 * 60;
  it("mesure : budget atteint → bloqué, un pass possible", () => {
    const budget = evalP("projets", policy(), spent, [], at(15));
    expect(!budget.allow && budget.rule === "budget" && budget.passable && budget.message.includes("/mesure encore")).toBe(true);
  });
  const pass = CM.pass({ at: ms(at(14, 55)), from: ms(at(14, 57)), until: ms(at(15, 12)), reason: "finir le correctif", rule: "budget", session: "a" });
  it("mesure : un pass ouvert lève le budget", () => {
    const withPass = evalP("projets", policy(), spent, [pass], at(15));
    expect(withPass.allow && (withPass.warn ?? "").includes("Pass ouvert")).toBe(true);
  });
  it("mesure : l'étude n'a pas de budget", () => {
    expect(evalP("etude", policy(), spent, [], at(15)).allow).toBe(true);
  });
  it("mesure : près du budget, une alerte", () => {
    const near = CM.emptyUsage();
    near.projets = 75 * 60;
    const warned = evalP("projets", policy(), near, [], at(15));
    expect(warned.allow && warned.remainingMinutes === 15 && (warned.warn ?? "").includes("Projets")).toBe(true);
  });
  it("mesure : pendant un cours, bloqué sans pass", () => {
    const lesson: Context = { studyMode: null, classes: [{ start: ms(at(14)), end: ms(at(16)), title: "AICC" }], studied };
    const inClass = evalP("projets", policy(std(), lesson), none, [], at(15));
    expect(inClass.rule === "lesson" && !inClass.passable).toBe(true);
  });
  const mode: CM.StudyModeInfo = { since: ms(at(14)), until: ms(at(16)), blocks: true, locks: false };
  it("mesure : mode étude → les projets attendent", () => {
    expect(evalP("projets", policy(std(), { studyMode: mode, classes: [], studied }), none, [], at(15)).rule).toBe("studyMode");
  });
  it("mesure : le verrou ferme aussi le libre, pas l'étude", () => {
    const lockCtx: Context = { studyMode: { ...mode, locks: true }, classes: [], studied };
    expect(evalP("libre", policy(std(), lockCtx), none, [], at(15)).rule === "lock"
      && evalP("etude", policy(std(), lockCtx), none, [], at(15)).allow).toBe(true);
  });
  it("mesure : d'abord étudier (35 min sur 60, encore 25)", () => {
    const early: Context = { studyMode: null, classes: [],
      studied: { day: "2026-10-27", seconds: 20 * 60, accumulated: 5 * 60, runningSince: ms(at(14, 50)) } };
    const first = evalP("projets", policy(std(), early), none, [], at(15));
    expect(first.rule === "studyFirst" && first.message.includes("25 min")).toBe(true);
  });
  it("mesure : temps étudié inconnu (Polymestre fermé) → « d'abord étudier » ne bloque pas", () => {
    const stale: Context = { studyMode: null, classes: [], studied: { day: "2026-10-26", seconds: 0, accumulated: 0, runningSince: null } };
    expect(evalP("projets", policy(std(), stale), none, [], at(15)).allow
      && evalP("projets", policy(std(), CM.emptyContext()), none, [], at(15)).allow).toBe(true);
  });
  it("mesure : couvre-feu pour les projets, pas pour l'étude", () => {
    expect(evalP("projets", policy(), none, [], at(23, 50)).rule === "curfew"
      && evalP("etude", policy(), none, [], at(23, 50)).allow).toBe(true);
  });
  it("mesure : couvre-feu « tout »", () => {
    const all = std();
    all.curfewAll = true;
    expect(evalP("etude", policy(all), none, [], at(23, 50)).rule).toBe("curfew");
  });

  const marks: [number, EventKind][] = [];
  for (let i = 0; i < 12; i++) marks.push([t0 + i * 5 * minute, "p"], [t0 + i * 5 * minute + 4 * minute, "d"]);
  it("mesure : pause de 10 min après 59 min d'affilée", () => {
    const run = CM.usage([session("a", "projets", marks)], CM.date(t0 + 60 * minute), std());
    const paused = evalP("projets", policy(), run, [], CM.date(t0 + 60 * minute));
    expect(paused.rule === "pause" && paused.until?.getTime() === CM.date(t0 + 69 * minute).getTime()).toBe(true);
  });
  it("mesure : dix minutes sans rien, la série est finie", () => {
    expect(CM.usage([session("a", "projets", marks)], CM.date(t0 + 70 * minute), std()).streak).toBeNull();
  });
  const lots = CM.emptyUsage();
  lots.projets = 200 * 60;
  it("mesure : le jour d'observation ne bloque rien", () => {
    const observing = evalP("projets", policy(std(), undefined, ms(at(16))), lots, [], at(15));
    expect(observing.allow && observing.observing && observing.message.startsWith("Observation")).toBe(true);
  });
  it("mesure : sans clavier ou sans règles, jamais bloqué", () => {
    expect(evalP("projets", policy(), lots, [], at(15), true).allow
      && evalP("projets", null, lots, [], at(15)).allow).toBe(true);
  });

  // Le contrat de fichiers : des `null` écrits, et ce que le mod écrit se relit.
  it("mesure : « sans limite » s'écrit null (le mod ne le lirait pas absent)", () => {
    const open = std();
    open.budgetWeekday = null;
    open.curfew = null;
    const json = JSON.stringify(policy(open));
    expect(json.includes('"budgetWeekday":null') && json.includes('"curfew":null') && json.includes('"pending":null')).toBe(true);
  });
  it("mesure : une séance écrite par le mod se relit (« class » → cours)", () => {
    const fromMod = '{"v":1,"session":"s1","cwd":"/Users/eleve/Prog","category":"projets","headless":false,"events":[{"t":1793054518868,"k":"s"},{"t":1793054519000,"k":"p"}],"blocks":[{"t":1793054520000,"rule":"class"}]}';
    const decoded = CM.decodeSessionRecord(fromMod);
    expect(decoded?.events.length === 2 && decoded?.blocks[0]?.rule === "lesson").toBe(true);
  });
  it("mesure : des règles incomplètes prennent les défauts", () => {
    const partial = CM.decodeRules(JSON.parse('{"budgetWeekday":45}'));
    expect(partial.budgetWeekday === 45 && CM.deepEqual(partial.curfew, std().curfew)).toBe(true);
  });

  // Durcir tout de suite, assouplir le lendemain.
  it("mesure : « le lendemain » = 4 h du matin, au moins 12 h plus tard", () => {
    expect(CM.nextMorning(at(23, 45)).getTime() === at(4, 0, 29).getTime()
      && CM.nextMorning(at(10)).getTime() === at(4, 0, 28).getTime()).toBe(true);
  });
  const start = CM.apply(std(), true, null, at(23, 45));
  it("mesure : mise en route → une journée d'observation", () => {
    expect(start.enabled && start.enforceFrom === ms(at(4, 0, 29))).toBe(true);
  });
  const running = { ...start, enforceFrom: 0 };
  const tighter = std();
  tighter.budgetWeekday = 45;
  const tightened = CM.apply(tighter, true, running, at(15));
  it("mesure : durcir s'applique tout de suite", () => {
    expect(tightened.rules.budgetWeekday === 45 && tightened.pending === null).toBe(true);
  });
  const looser = std();
  looser.budgetWeekday = 240;
  looser.curfew = { start: "01:00", end: "06:00" };
  const loosened = CM.apply(looser, true, tightened, at(15));
  it("mesure : assouplir attend le lendemain à 4 h (la règle en vigueur reste la plus stricte)", () => {
    expect(loosened.rules.budgetWeekday === 45 && CM.deepEqual(loosened.rules.curfew, std().curfew)
      && CM.deepEqual(loosened.pending?.rules, looser) && loosened.pending?.from === ms(at(4, 0, 28))).toBe(true);
  });
  it("mesure : dans un même réglage, ce qui durcit vaut déjà", () => {
    const mixed = { ...looser, studyFirstWeekday: 90 };
    const both = CM.apply(mixed, true, tightened, at(15));
    expect(both.rules.studyFirstWeekday === 90 && both.rules.budgetWeekday === 45).toBe(true);
  });
  it("mesure : redemander n'avance ni ne repousse l'heure", () => {
    const again = CM.apply(looser, true, loosened, at(18));
    expect(again.pending?.from).toBe(loosened.pending?.from);
  });
  it("mesure : couper Avec mesure attend aussi le lendemain", () => {
    const off = CM.apply(std(), false, running, at(15));
    expect(off.enabled && off.pending?.enabled === false
      && !evalP("projets", off, lots, [], at(15)).allow
      && evalP("projets", off, lots, [], at(5, 0, 28)).allow).toBe(true);
  });
  it("mesure : à l'heure dite, l'assouplissement s'applique", () => {
    const settled = CM.settle(loosened, at(5, 0, 28));
    expect(CM.deepEqual(settled.rules, looser) && settled.pending === null).toBe(true);
  });
  it("mesure : ajouter un dossier d'étude est un assouplissement", () => {
    const widened = std();
    widened.studyFolders = ["~/EPFL", "~/Prog"];
    expect(CM.apply(widened, true, running, at(15)).rules.studyFolders).toEqual(["~/EPFL"]);
  });

  // Le bilan d'un jour.
  it("mesure : le bilan du jour (38 min, 1 pass)", () => {
    // 26 min (14 h) + 12 min (15 h, trois séances qui se chevauchent : comptées une fois).
    const day = CM.summary(at(12), [a, b, long], [pass], std(), at(20));
    expect(day.day === "2026-10-27" && day.projets === 38 * 60 && day.passes === 1).toBe(true);
  });
});
