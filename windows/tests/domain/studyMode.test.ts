// Port des sections de Validation/main.swift qui portent sur le mode étude, le
// bureau, les notifications, les cartes, la géométrie, les cibles du chrono, la
// musique et le lien des documents. Un `it` par `check` Swift, même libellé.

import { describe, expect, it } from "vitest";
import { Course } from "../../src/models/course.ts";
import { Exercise, ExerciseSeries } from "../../src/models/exercise.ts";
import { Institution } from "../../src/domain/institution.ts";
import { decodeFocusTimerState, encodeFocusTimerState, newFocusTimerState, start } from "../../src/domain/focusTimerState.ts";
import * as SM from "../../src/domain/studyMode.ts";
import * as SLP from "../../src/domain/studyLockPlan.ts";
import * as DA from "../../src/domain/deskArrangement.ts";
import * as DN from "../../src/domain/deskNotice.ts";
import * as DW from "../../src/domain/deskWidgets.ts";
import * as DG from "../../src/domain/deskGeometry.ts";
import * as FT from "../../src/domain/focusTargets.ts";
import * as ML from "../../src/domain/musicLink.ts";
import { DeskDrop } from "../../src/domain/deskDrop.ts";
import { StudyLinkKey } from "../../src/domain/studyLinkKey.ts";
import { TimerLink } from "../../src/domain/timerLink.ts";
import { CloudRelay } from "../../src/domain/cloudRelay.ts";

/** `check(condition, label)` : la condition est évaluée tout de suite, l'assertion rejouée par vitest. */
function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

const add = (date: Date, seconds: number): Date => new Date(date.getTime() + seconds * 1000);
const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);

// MARK: Mode étude

describe("Mode étude : blocage par défaut", () => {
  const fresh = SM.memoryStudyDefaults();
  SM.settleBlockingDefaults(["studyMode.blocking"], false, fresh);
  check(fresh.object("studyMode.blocking") === false, "nouvelle installation : le mode étude ne bloque rien");
  SM.settleBlockingDefaults(["studyMode.blocking"], true, fresh);
  check(fresh.object("studyMode.blocking") === false, "un choix déjà écrit n'est pas réécrit");
  const existing = SM.memoryStudyDefaults();
  SM.settleBlockingDefaults(["mac.studyBlocking", "mac.studySystemLock"], true, existing);
  check(existing.object("mac.studyBlocking") === true && existing.object("mac.studySystemLock") === true,
    "utilisateur d'avant : blocage et verrou système gardés");
  const chosen = SM.memoryStudyDefaults({ "mac.studyBlocking": false });
  SM.settleBlockingDefaults(["mac.studyBlocking"], true, chosen);
  check(chosen.object("mac.studyBlocking") === false, "utilisateur d'avant qui l'avait coupé : reste coupé");
});

describe("Mode étude : dates, entrée, sortie", () => {
  const t0 = new Date(2_000_000_000 * 1000);
  const state = newFocusTimerState({ sessionStartedAt: t0 });
  start(state, t0);
  check(!SM.isActive(state, t0), "sans date : pas de mode étude");
  state.studyUntil = add(t0, 50 * 60);
  check(SM.isActive(state, add(t0, 60)), "pendant les 50 min : actif");
  check(!SM.isActive(state, add(t0, 50 * 60)), "à l'échéance : levé");
  check(SM.isOver(state, add(t0, 51 * 60)), "échéance passée, session ouverte : « terminé »");
  check(SM.remaining(state, add(t0, 10 * 60)) === 40 * 60, "reste 40 min après 10");
  check(Math.abs(SM.progress(state, t0, add(t0, 25 * 60)) - 0.5) < 0.001, "à mi-chemin : 0,5");
  const entered = newFocusTimerState({ sessionStartedAt: t0 });
  SM.enter(entered, 50, true, add(t0, 600));
  check(entered.studySince?.getTime() === add(t0, 600).getTime()
    && entered.studyUntil?.getTime() === add(t0, 600 + 3000).getTime(),
  "entrer en cours de session : 50 min à partir de maintenant");
  check(Math.abs(SM.progress(entered, add(t0, 600 + 1500)) - 0.5) < 0.001, "l'anneau part du début du mode étude");
  SM.leave(entered);
  check(entered.studyUntil === undefined && entered.studySince === undefined && !SM.isActive(entered),
    "sortir : plus de mode étude");
  check(SM.extended(add(t0, 600), 25, t0).getTime() === add(t0, 600 + 1500).getTime(),
    "prolonger avant la fin : à partir de la fin prévue");
  check(SM.extended(t0, 25, add(t0, 300)).getTime() === add(t0, 300 + 1500).getTime(),
    "prolonger après coup : à partir de maintenant");

  // Le mode étude voyage avec le chrono : un état sans le champ se relit.
  const back = decodeFocusTimerState(encodeFocusTimerState(state));
  check(back?.studyUntil?.getTime() === state.studyUntil?.getTime(), "la fin du mode étude passe d'un appareil à l'autre");
  const legacy = `{"accumulated":0,"sessionStartedAt":0,"taskTypeRaw":"exercise","note":"","contextLabel":"","pomodoro":false}`;
  check(decodeFocusTimerState(legacy)?.studyUntil === undefined, "un chrono d'une version précédente se relit, sans mode étude");
  const changed = { ...state };
  changed.studyUntil = undefined;
  check(!CloudRelay.sameState(changed, state), "lever le mode étude est un changement (publié aux autres appareils)");
});

describe("Mode étude : sites", () => {
  check(SM.normalizedDomain("https://www.Moodle.EPFL.ch/my/?x=1") === "moodle.epfl.ch", "adresse → domaine");
  check(SM.normalizedDomain("*.epfl.ch") === "epfl.ch", "joker → domaine");
  check(SM.normalizedDomain("claude.ai:443") === "claude.ai", "port retiré");
  check(SM.normalizedDomain("pas un site") === null && SM.normalizedDomain("") === null, "texte libre refusé");
  const sites = SM.defaultSites();
  check(SM.isAllowed("moodle.epfl.ch", sites), "Moodle permis");
  check(SM.isAllowed("botafogo.epfl.ch", sites), "Botafogo permis");
  check(SM.isAllowed("courseware.epfl.ch", sites), "Courseware permis");
  check(SM.isAllowed("claude.ai", sites), "Claude permis");
  check(!SM.isAllowed("notepfl.ch", sites), "un domaine qui finit pareil n'est pas permis");
  check(!SM.isAllowed("www.youtube.com", sites), "YouTube bloqué par défaut");
  check(!SM.isAllowed("instagram.com", sites), "Instagram bloqué");
  check(SM.isAllowedURL(new URL("about:blank"), sites), "page vide permise");
  check(!SM.isAllowedURL(new URL("file:///etc/hosts"), sites), "fichiers locaux refusés");
  check(!SM.isAllowedURL(new URL("https://epfl.ch.evil.com/"), sites), "faux sous-domaine refusé");
});

describe("Mode étude : apps (Mac)", () => {
  const apps = SM.defaultMacApps;
  check(!SM.shouldBlock("com.goodnotesapp.x", true, "me", apps), "GoodNotes permis");
  check(SM.shouldBlock("com.apple.Safari", true, "me", apps), "Safari bloqué (le navigateur du mode étude le remplace)");
  check(SM.shouldBlock("com.spotify.client", true, "me", apps), "Spotify bloqué");
  check(!SM.shouldBlock("me", true, "me", apps), "Polymestre jamais bloqué");
  check(!SM.shouldBlock("com.apple.loginwindow", true, "me", apps), "le système jamais bloqué");
  check(!SM.shouldBlock("com.example.agent", false, "me", apps), "un agent sans fenêtre n'est pas bloqué");
  check(!SM.shouldBlock("com.anthropic.claudefordesktop.helper", true, "me", apps), "l'assistant d'une app permise l'est avec elle");
});

describe("Mode étude : outils", () => {
  const tools = SM.tools("Analyse I", [
    "https://moodle.epfl.ch/course/view.php?id=1",
    "pas une url",
    "https://moodle.epfl.ch/course/view.php?id=1",
  ]);
  check(tools[0]?.title === "Moodle du cours" && tools.filter((tool) => tool.id.startsWith("course:")).length === 1,
    "outils : la page du cours d'abord, sans doublon ni lien invalide");
  check(tools.some((tool) => tool.id === "claude-app") && tools.some((tool) => tool.id === "goodnotes")
    && !tools.some((tool) => tool.id === "claude"), "outils : l'app Claude et GoodNotes, plus claude.ai en site");
});

describe("Mode étude : durée libre", () => {
  const now = new Date(2026, 9, 12, 16, 10);
  const at = (h: number, m: number): Date => new Date(2026, 0, 1, h, m);
  check(SM.minutes(at(18, 30), now) === 140, "jusqu'à 18 h 30 : 2 h 20");
  check(SM.minutes(at(16, 12), now) === 5, "trop court : 5 min au moins");
  check(SM.minutes(at(1, 0), now) === 530, "1 h du matin : demain");
  check(SM.minutes(at(16, 0), now) === 720, "heure passée de peu : bornée à 12 h");
});

describe("Mode étude sans blocage", () => {
  const state = newFocusTimerState();
  SM.enter(state, 30);
  check(SM.locks(state) && state.studyLocks === undefined, "mode étude : bloque par défaut");
  SM.enter(state, 30, false);
  check(SM.isActive(state) && !SM.locks(state), "mode étude sans blocage : actif, rien de bloqué");
  SM.leave(state);
  check(state.studyLocks === undefined && !SM.locks(state), "sortie : plus de blocage");
  const old = decodeFocusTimerState(encodeFocusTimerState(newFocusTimerState()));
  check(old?.studyLocks === undefined, "un état d'avant se lit (champ absent)");
});

describe("Mode étude : verrou", () => {
  const state = newFocusTimerState();
  SM.enter(state, 30);
  check(!SM.canLeave(state), "verrou : on ne sort pas avant l'heure");
  check(SM.canLeave(state, add(new Date(), 31 * 60)), "verrou : l'heure passée, on sort");
  SM.enter(state, 30, false);
  check(SM.canLeave(state), "sans verrou : on sort quand on veut");
  check(SM.emergencyNote("") === "Sortie d'urgence", "sortie d'urgence : notée");
  check(SM.emergencyNote("Analyse") === "Analyse · Sortie d'urgence", "sortie d'urgence : après la note");
  check(SM.emergencyNote("Analyse · Sortie d'urgence") === "Analyse · Sortie d'urgence", "sortie d'urgence : une fois");
  check(SM.defaultSites(Institution.epfl).includes("speakup.info"), "sondages en amphi permis");
});

describe("Mode étude sans fin", () => {
  const t0 = new Date((978_307_200 + 800_000_000) * 1000);
  const state = newFocusTimerState();
  SM.enter(state, null, true, t0);
  const later = add(t0, 5 * 3600);
  check(SM.isOpenEnded(state) && SM.isActive(state, later), "sans fin : actif des heures après");
  check(!SM.isOver(state, later), "sans fin : jamais « terminé » de lui-même");
  check(SM.blocks(state, later) && !SM.locks(state, later), "sans fin : bloque le reste, sans verrou");
  check(SM.canLeave(state, t0), "sans fin : on termine quand on a fini");
  check(SM.clock(state, add(t0, 90.6)) === 90, "sans fin : l'horloge compte le temps passé");
  check(Math.abs(SM.progress(state, add(t0, 5400)) - 0.5) < 0.001, "sans fin : l'anneau fait le tour en une heure");
  check(SM.extended(state.studyUntil, 25, later).getTime() === state.studyUntil?.getTime(), "sans fin : prolonger ne donne pas d'heure");
  check(SM.tickAnchor(state).getTime() === add(t0, 0.05).getTime(), "sans fin : l'horloge bat depuis le début");
  const back = decodeFocusTimerState(encodeFocusTimerState(state));
  check(back !== null && SM.isOpenEnded(back), "sans fin : passe d'un appareil à l'autre");
  SM.enter(state, 30, true, t0);
  check(!SM.isOpenEnded(state) && SM.locks(state, t0), "une durée : verrou comme avant");
  check(SM.clock(state, add(t0, 60.2)) === 29 * 60, "une durée : l'horloge compte ce qui reste");
  check(SM.backgroundApps.has("com.apple.Music"), "Music joue en arrière-plan pendant le mode étude");
  // Finder : masqué, jamais fermé ; lanceurs : fermés même sans icône dans le Dock.
  const d = (id: string | null, regular: boolean, allowed: string[]): SM.Disposition =>
    SM.disposition(id, regular, "me", allowed);
  check(!SM.defaultMacApps.includes(SM.finderBundleID), "le Finder n'est plus permis d'office");
  check(d("com.apple.finder", true, SM.defaultMacApps) === "hideOnly", "Finder : masqué quand il passe devant, jamais fermé");
  check(d("com.apple.finder", true, [...SM.defaultMacApps, "com.apple.finder"]) === "allowed", "Finder permis explicitement : permis");
  check(d("com.apple.Music", true, []) === "hideOnly", "Music : masqué, jamais fermé");
  check(d("com.raycast.macos", false, SM.defaultMacApps) === "close", "Raycast : fermé même sans icône dans le Dock");
  check(d("com.runningwithcrayons.Alfred", false, []) === "close" && d("at.obdev.LaunchBar", false, []) === "close", "Alfred et LaunchBar : fermés");
  check(d("com.lwouis.alt-tab-macos", false, SM.defaultMacApps) === "close", "AltTab : fermé, c'est une porte de sortie");
  check(d("com.raycast.macos", false, ["com.raycast.macos"]) === "allowed", "un lanceur permis explicitement le reste");
  check(d("com.example.agent", false, []) === "system", "un agent quelconque : hors de portée");
  check(d("com.apple.Safari", true, SM.defaultMacApps) === "close", "Safari : fermé");
  check(d(null, true, []) === "system" && d("", true, []) === "system", "sans identifiant : hors de portée");
  check(d("com.apple.Spotlight", true, []) === "system", "Spotlight reste hors de portée de la règle des apps");
  check(same(SM.removingFinder(["com.goodnotesapp.x", "com.apple.finder", "com.apple.Preview"]),
    ["com.goodnotesapp.x", "com.apple.Preview"]), "migration : le Finder sort de la liste");
  check(same(SM.removingFinder(SM.removingFinder(["com.apple.finder"])), []), "migration : sans effet la seconde fois");
});

describe("École : le mode étude suit le profil", () => {
  const other = new Institution({
    id: "uni", name: "Université fictive", emailDomains: ["uni.example"],
    moodle: { base: "https://cours.uni.example", oauthProviderID: null },
    openEdX: { base: "https://mooc.uni.example", loginBackend: null, ssoHost: null, ssoIdP: null },
    video: { host: "video.uni.example", kalturaAPI: "https://api.kaltura.example", kalturaPartner: 42,
      wayfHost: null, identityProvider: null, passwordIdPHost: null },
    ed: { region: "us" }, studyDomains: ["uni.example"],
  });
  const saved = Institution.current;
  Institution.current = other;
  check(SM.defaultSites()[0] === "uni.example" && !SM.defaultSites().includes("epfl.ch"), "autre école : ses sites permis");
  const moodleTool = SM.tools(null, []).find((tool) => tool.id === "moodle");
  check(moodleTool?.kind.type === "web" && moodleTool.kind.url.host === "cours.uni.example", "autre école : l'outil Moodle");
  check(Institution.generic.moodle === null && SM.defaultSites(Institution.generic).includes("claude.ai"), "école inconnue : l'essentiel marche");
  Institution.current = saved;
});

// MARK: Verrou du Mac

describe("Verrou du Mac : raccourcis éteints, puis rallumés", () => {
  const on = new Set([1, 2, 64, 65, 32, 52]);
  const first = SLP.plan([1, 2, 64, 65, 118, 28], (id) => on.has(id), null, false, true, new Date(100_000));
  check(same([...first.disable].sort((a, b) => a - b), [1, 2, 64, 65]), "verrou : seuls les raccourcis allumés sont éteints");
  check(!first.record.shortcuts.includes(118), "verrou : un raccourci déjà éteint par l'utilisateur·rice n'est pas sur la fiche");
  check(!first.disable.includes(28) && !first.record.shortcuts.includes(28), "verrou : les captures d'écran ne sont jamais touchées");
  check(first.record.dockAutohide === false && first.record.menuBarAutohide === true, "verrou : les valeurs d'origine du Dock et des menus sont gardées");
  const second = SLP.plan([1, 2, 64, 65, 32], () => false, first.record, true, false, new Date(200_000));
  check(same(second.record.shortcuts, first.record.shortcuts), "relance : la fiche d'origine gagne, rien ne s'ajoute à tort");
  check(second.record.dockAutohide === false && second.record.menuBarAutohide === true, "relance : les valeurs d'origine ne sont pas remplacées par celles que nous avons posées");
  check(second.record.createdAt.getTime() === first.record.createdAt.getTime(), "relance : la fiche garde sa date");
  check(same([...second.disable].sort((a, b) => a - b), [...first.disable].sort((a, b) => a - b)), "relance : on éteint encore ce qui est sur la fiche");
  const third = SLP.plan([32], (id) => id === 32, first.record, null, null);
  check(third.record.shortcuts.includes(32), "un raccourci allumé et voulu rejoint la fiche existante");
  check(same([...SLP.restore(first.record)].sort((a, b) => a - b), [1, 2, 64, 65]), "rétablir : seulement ce que nous avons éteint");
  check(same(SLP.restore(first.record), SLP.restore(first.record)), "rétablir deux fois : le même résultat");
  check(same(SLP.restore(new SLP.StudyLockRecord({ shortcuts: [27, 118], createdAt: new Date() })), [118]), "rétablir : jamais ⌘` ni les captures");
  const back = SLP.decode(SLP.encode(first.record));
  check(back !== null && same(back, first.record), "fiche : relue telle qu'écrite");
  const g1: SLP.GestureOriginal[] = [
    { domain: "d", key: "k", value: 2 },
    { domain: "d", key: "absent", value: null },
  ];
  const g2: SLP.GestureOriginal[] = [{ domain: "d", key: "k", value: 0 }];
  check(same(SLP.mergeGestures(null, g1), g1), "gestes : sans fiche, les valeurs lues sont gardées");
  check(same(SLP.mergeGestures(g1, g2), g1), "gestes : après une relance, la fiche d'origine gagne");
  const withGestures = new SLP.StudyLockRecord({
    shortcuts: first.record.shortcuts,
    dockAutohide: first.record.dockAutohide,
    menuBarAutohide: first.record.menuBarAutohide,
    gestures: g1,
    createdAt: first.record.createdAt,
  });
  check(same(SLP.decode(SLP.encode(withGestures))?.gestures, g1), "gestes : la fiche garde les valeurs d'origine, y compris « absente »");
  check(SLP.decode(SLP.encode(first.record))?.gestures === null, "gestes : une ancienne fiche se relit sans eux");
  check(SLP.gestureTargets.some((target) => target.key === "TrackpadThreeFingerHorizSwipeGesture" && target.blocked === 0 && !target.isBool)
    && SLP.gestureTargets.some((target) => target.key === "showMissionControlGestureEnabled" && target.isBool),
  "gestes : les balayages à trois doigts et Mission Control sont dans la liste");
  check(SLP.decode("pas du json") === null && SLP.decode(null) === null, "fiche illisible : ignorée");
  check(SLP.shortcutIDs.every((id) => !SLP.neverTouched.has(id)), "la liste ne contient aucun raccourci intouchable");
  check(SLP.shortcutIDs.includes(64) && SLP.shortcutIDs.includes(65) && SLP.shortcutIDs.includes(1),
    "la liste couvre Spotlight, ⌥⌘Espace et ⌘Tab");
});

describe("Une app permise un moment", () => {
  const t0 = new Date(5_000_000);
  const allowance = new SLP.TemporaryAllowance();
  check(allowance.allowed(t0).size === 0 && allowance.nextExpiry(t0) === null, "permission brève : rien au départ");
  allowance.allow("com.apple.systempreferences", 90, t0);
  check(same([...allowance.allowed(add(t0, 60))], ["com.apple.systempreferences"]), "permission brève : permise pendant sa durée");
  check(allowance.allowed(add(t0, 91)).size === 0, "permission brève : bloquée de nouveau après");
  check(allowance.nextExpiry(t0)?.getTime() === add(t0, 90).getTime() && allowance.nextExpiry(add(t0, 100)) === null,
    "permission brève : l'heure de fin");
  allowance.allow("com.apple.systempreferences", 30, add(t0, 80));
  check(same([...allowance.allowed(add(t0, 100))], ["com.apple.systempreferences"]), "permission brève : redemandée, elle repart");
});

// MARK: Bureau selon le contexte

describe("Bureau selon le contexte", () => {
  const ctx = (moment: DA.DeskArrangementContext["moment"] = "series", edit: (c: DA.DeskArrangementContext) => void = () => {}) => {
    const c = new DA.DeskArrangementContext({ moment });
    edit(c);
    return c;
  };
  const doing = DA.layout(ctx("series", (c) => { c.hasTarget = true; c.hasCopy = true; }));
  check(doing.center === "exercise" && same(doing.side, ["copy"]) && doing.sideOpen, "bureau : un exercice en cours → l'énoncé au centre, ta copie à côté");
  const notesOnly = DA.layout(ctx("series", (c) => { c.hasTarget = true; c.hasCourseNotes = true; }));
  check(same(notesOnly.side, ["courseNotes"]), "bureau : sans copie, les notes du cours à côté");
  const nothing = DA.layout(ctx("series", (c) => { c.hasTarget = true; }));
  check(nothing.center === "exercise" && nothing.side.length === 0 && !nothing.sideOpen, "bureau : rien à garder à côté, le volet reste fermé");
  const done = DA.layout(ctx("series", (c) => { c.hasTarget = true; c.targetDone = true; c.solutionAvailable = true; c.hasCopy = true; }));
  check(same(done.side, ["solution"]), "bureau : fait et corrigé publié → le corrigé vient à côté");
  const notPublished = DA.layout(ctx("series", (c) => { c.hasTarget = true; c.targetDone = true; c.hasCopy = true; }));
  check(same(notPublished.side, ["copy"]), "bureau : corrigé pas publié → la copie reste");
  check(DA.layout(ctx("series", (c) => { c.hasTarget = true; c.seriesComplete = true; })).openClaude, "bureau : série finie → Claude pour clore");
  check(!DA.layout(ctx("series", (c) => { c.hasTarget = true; })).openClaude, "bureau : série en cours → pas de Claude d'office");
  const writing = DA.layout(ctx("series", (c) => { c.hasTarget = true; c.hasCopy = true; c.writingApp = true; }));
  check(same(writing.side, ["series"]) && writing.sideOpen, "bureau : GoodNotes au centre → l'énoncé à côté (écrire au centre, lire à côté)");
  check(DA.signature(ctx("series", (c) => { c.hasTarget = true; c.writingApp = true; }))
    !== DA.signature(ctx("series", (c) => { c.hasTarget = true; })), "bureau : entrer dans GoodNotes est un changement de moment");
  check(DA.layout(ctx("lecture", (c) => { c.hasTarget = true; c.writingApp = true; })).side.length === 0, "bureau : en cours, GoodNotes ne déplace rien");
  const theory = DA.layout(ctx("series", (c) => { c.isTheory = true; c.hasCourseNotes = true; }));
  check(theory.center === "course" && same(theory.side, ["courseNotes"]), "bureau : théorie → le cours au centre, les notes à côté");
  const lecture = DA.layout(ctx("lecture", (c) => { c.hasTarget = true; }));
  check(lecture.center === "desk" && lecture.side.length === 0 && !lecture.openClaude, "bureau : en cours → l'accueil du cours, rien à côté");
  const revision = DA.layout(ctx("revision"));
  check(revision.center === "desk" && same(revision.side, ["sheet"]) && revision.sideOpen, "bureau : révision → l'accueil et la fiche à côté");
  check(DA.layout(ctx()).center === "desk", "bureau : sans cible → l'accueil");
  check(DA.layout(ctx("together", (c) => { c.hasTarget = true; })).center === "exercise", "bureau : ensemble → comme une série");
  // Ce qui prend l'écran.
  check(DA.takeover(ctx("series", (c) => { c.phase = "onBreak"; })) === "onBreak", "bureau : une pause Pomodoro prend l'écran");
  check(DA.takeover(ctx("series", (c) => { c.phase = "paused"; })) === "paused", "bureau : la pause manuelle aussi");
  check(DA.takeover(ctx("series", (c) => { c.minutesLeft = 4; })) === "wrapUp"
    && DA.takeover(ctx("series", (c) => { c.minutesLeft = 5; })) === "wrapUp", "bureau : cinq minutes avant la fin → le bilan");
  check(DA.takeover(ctx("series", (c) => { c.minutesLeft = 6; })) === "none" && DA.takeover(ctx()) === "none", "bureau : assez de temps, ou sans fin → rien");
  check(DA.takeover(ctx("lecture", (c) => { c.classBreak = true; })) === "classBreak", "bureau : la pause du cours");
  check(DA.takeover(ctx("series", (c) => { c.phase = "ended"; c.minutesLeft = 1; })) === "none", "bureau : session finie → rien");
  // Épingles : le bureau ne bouge pas sous les mains.
  const base = ctx("series", (c) => { c.hasTarget = true; c.hasCopy = true; });
  const key = DA.signature(base);
  check(key === DA.signature(base) && key !== DA.signature(ctx("series", (c) => { c.hasTarget = true; c.hasCopy = true; c.targetDone = true; })),
    "bureau : la clé change avec le moment");
  check(DA.signature(ctx("series", (c) => { c.minutesLeft = 40; })) === DA.signature(ctx("series", (c) => { c.minutesLeft = 12; })),
    "bureau : les minutes qui passent ne changent pas la clé");
  check(DA.signature(ctx("series", (c) => { c.phase = "paused"; })) === DA.signature(ctx("series", (c) => { c.phase = "running"; })),
    "bureau : mettre en pause puis reprendre ne réarrange pas");
  check(DA.signature(ctx("series", (c) => { c.phase = "onBreak"; })) === DA.signature(ctx("series", (c) => { c.minutesLeft = 3; })),
    "bureau : une pause ou le bilan ne réarrangent pas non plus");
  let pins = new DA.Pins({ center: true });
  check(DA.pins(pins, key, key).center === true && !DA.pins(pins, key, key).isEmpty, "bureau : même moment → les épingles restent");
  check(DA.pins(pins, key, "autre").isEmpty, "bureau : nouveau moment → les épingles tombent");
  const applicable = DA.applicable(DA.layout(base), pins);
  check(applicable.center === null && same(applicable.side, ["copy"]), "bureau : le centre épinglé n'est pas touché, le côté oui");
  pins = new DA.Pins({ side: true, claude: true });
  const again = DA.applicable(DA.layout(ctx("series", (c) => { c.hasTarget = true; c.seriesComplete = true; })), pins);
  check(again.center === "exercise" && again.side === null && !again.claude, "bureau : le côté et Claude épinglés ne bougent pas");
});

// MARK: Notifications du bureau

describe("Notifications du bureau", () => {
  const t0 = new Date(1_000_000);
  const item = (kind: DN.DeskNoticeKind, text: string, offset: number): DN.DeskNoticeItem =>
    new DN.DeskNoticeItem({ kind, text, icon: "x", at: add(t0, offset) });
  let queue: DN.DeskNoticeItem[] = [];
  queue = DN.adding(item("blockedApp", "Safari", 0), queue);
  const firstID = queue[0].id;
  queue = DN.adding(item("blockedApp", "Mail", 2), queue);
  check(queue.length === 1 && queue[0].text === "Mail" && queue[0].id === firstID, "notifications : deux du même genre à moins de 4 s n'en font qu'une");
  queue = DN.adding(item("blockedApp", "Notes", 10), queue);
  check(queue.length === 2, "notifications : plus de 4 s après, une autre");
  queue = DN.adding(item("iPhone", "Photo", 10), queue);
  queue = DN.adding(item("claude", "Réponse", 11), queue);
  check(queue.length === DN.maxVisible && queue[0].text === "Notes", "notifications : trois au plus, la plus ancienne part");
  check(DN.visible(queue, add(t0, 12)).length === 3, "notifications : elles restent un moment");
  check(same(DN.visible(queue, add(t0, 15)).map((entry) => entry.kind), ["claude"]), "notifications : chacune part à son heure");
  check(DN.visible(queue, add(t0, 30)).length === 0, "notifications : puis plus rien");
  check(DN.duration("claude") > DN.duration("blockedApp"), "notifications : la réponse de Claude reste plus longtemps");
  check((["classSoon", "solution", "breakSoon", "info"] as DN.DeskNoticeKind[]).every((kind) => DN.duration(kind) > 0),
    "notifications : chaque genre a une durée");
  let history: DN.DeskNoticeItem[] = [];
  for (let i = 0; i < 30; i++) history = DN.remembering(item("info", `n${i}`, i), history);
  check(history.length === DN.historyLimit && history[0].text === "n29" && history[history.length - 1].text === "n10",
    "notifications : l'historique garde les vingt dernières, la plus récente d'abord");
  const again = item("info", "frais", 40);
  let mergedHistory = DN.remembering(again, []);
  const refreshed = new DN.DeskNoticeItem({ id: again.id, kind: again.kind, text: "plus frais", icon: again.icon, at: again.at });
  mergedHistory = DN.remembering(refreshed, mergedHistory);
  check(mergedHistory.length === 1 && mergedHistory[0].text === "plus frais", "notifications : une notification fusionnée n'est qu'une fois dans l'historique");
});

// MARK: Cartes du bureau

describe("Cartes du bureau", () => {
  const kinds = (list: DW.DeskWidgetPlacement[]): DW.DeskWidgetKind[] => list.map((placement) => placement.kind);
  const free = DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: false }));
  check(kinds(free)[0] === "courses" && kinds(free).includes("today") && !kinds(free).includes("target") && !kinds(free).includes("steps"),
    "cartes : session libre → choisir sur quoi, l'horaire, rien sur une cible");
  const course = DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true, hasSeries: true, hasTarget: true }));
  check(same(kinds(course).slice(0, 2), ["session", "target"]) && kinds(course).includes("steps"),
    "cartes : un exercice visé → la session, l'exercice, les étapes");
  check(!kinds(course).includes("upNext"), "cartes : l'exercice montre déjà la suite, pas de seconde liste");
  check(kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true, hasSeries: true }))).includes("upNext")
    && !kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true, hasSeries: true }))).includes("target"),
  "cartes : une série sans exercice visé → la suite, pas de carte d'exercice");
  check(!kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true }))).includes("upNext"), "cartes : sans série, pas de « suite »");
  check(!kinds(course).includes("redo") && kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true, redosDue: 2 }))).includes("redo"),
    "cartes : les reprises seulement quand il y en a");
  check(kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true, daysToExam: 10 }))).includes("exam")
    && !kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true, daysToExam: 60 }))).includes("exam"),
  "cartes : l'examen à moins de trois semaines");
  const revisionCards = kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "revision", hasCourse: true })));
  check(revisionCards[0] === "revisionExam" && revisionCards.includes("revisionPast") && revisionCards.includes("revisionSheet"),
    "cartes : en révision, l'examen, la fiche, les annales");
  const lectureCards = kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "lecture", hasCourse: true })));
  check(lectureCards[0] === "lectureClock" && lectureCards.includes("lectureMarks") && lectureCards.includes("lectureWeek") && !lectureCards.includes("target"),
    "cartes : en cours, l'horloge, les repères, la semaine — pas d'exercice");
  check(kinds(course).includes("deadlines") && kinds(free).includes("deadlines"), "cartes : les échéances de la semaine sont là");
  check(!kinds(course).includes("group") && kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true, hasSeries: true, inGroup: true, hasTarget: true }))).includes("group"),
    "cartes : les membres du groupe seulement en session commune");
  check(!kinds(DW.defaults(new DW.DeskWidgetsContext({ moment: "lecture", hasCourse: false }))).includes("lectureClock"),
    "cartes : un cours sans cours choisi reste une session libre");
  // Rangement de l'étudiant·e
  let mine = course;
  mine = DW.toggled("claude", mine);
  mine = DW.resized("music", mine);
  check(mine.find((placement) => placement.kind === "claude")?.hidden === true
    && mine.find((placement) => placement.kind === "music")?.size === "medium", "cartes : masquer, agrandir");
  check(DW.resized("music", DW.resized("music", mine)).find((placement) => placement.kind === "music")?.size === "small",
    "cartes : la taille tourne (petite, moyenne, grande, petite)");
  const merged = DW.merged(course, mine);
  check(same(merged, mine), "cartes : ce qui est rangé est gardé tel quel");
  const withRedo = DW.merged(DW.defaults(new DW.DeskWidgetsContext({ moment: "series", hasCourse: true, hasSeries: true, redosDue: 1 })), mine);
  check(withRedo.some((placement) => placement.kind === "redo")
    && withRedo.find((placement) => placement.kind === "claude")?.hidden === true, "cartes : une carte du moment jamais vue s'ajoute, le reste est gardé");
  check(same(DW.merged(course, null), course), "cartes : sans rangement, les cartes du moment");
  const stale = DW.merged(free, course);
  check(!stale.some((placement) => placement.kind === "target"), "cartes : une carte que le moment n'offre pas ne reste pas");
  const moved = DW.moved("target", 1, course);
  check(moved[1].kind === "steps"
    || moved.findIndex((placement) => placement.kind === "target") > course.findIndex((placement) => placement.kind === "target"),
  "cartes : déplacer d'un cran");
  check(same(DW.moved("session", -1, course), course), "cartes : la première ne remonte pas");
  let hiddenMid = course;
  hiddenMid = DW.toggled("target", hiddenMid);
  const skip = DW.moved("session", 1, hiddenMid);
  check(skip.findIndex((placement) => placement.kind === "session") > skip.findIndex((placement) => placement.kind === "target"),
    "cartes : déplacer saute les cartes masquées");
  check(same(DW.decode(DW.encode(mine)), mine) && DW.decode(null) === null && DW.decode("x") === null, "cartes : le rangement voyage en JSON");
  check(DW.columnCount(1360) === 4 && DW.columnCount(1000) === 3 && DW.columnCount(640) === 2 && DW.columnCount(400) === 1 && DW.columnCount(100) === 1,
    "cartes : la grille a de une à quatre colonnes selon la place");
  check(DW.columnCount(3000) === DW.maximumColumns, "cartes : jamais plus de quatre colonnes");
  check(DW.span("large", 4) === 3 && DW.span("large", 2) === 2 && DW.span("medium", 1) === 1 && DW.span("small", 4) === 1,
    "cartes : une carte ne dépasse jamais la grille");
  check(DW.storageKey("lecture") !== DW.storageKey("series"), "cartes : un bureau par moment");
  check(DW.DeskWidgetSize.span("small") < DW.DeskWidgetSize.span("medium") && DW.DeskWidgetSize.span("medium") < DW.DeskWidgetSize.span("large"),
    "cartes : trois tailles");
});

// MARK: Géométrie du bureau

describe("Géométrie du bureau", () => {
  const windowRect = new DG.Rect(0, 0, 1512, 982);
  const hole = DG.accessibilityRect(windowRect, new DG.Rect(100, 86, 1100, 700), 982);
  check(same(hole, new DG.Rect(100, 86, 1100, 700)), "géométrie : fenêtre plein écran, le repère de l'Accessibilité est celui de SwiftUI");
  const preview = new DG.Rect(80, 20, 1440, 900);
  const shifted = DG.accessibilityRect(preview, new DG.Rect(100, 86, 1000, 600), 982);
  check(shifted.x === 180 && shifted.y === 62 + 86, "géométrie : une fenêtre décalée (haut à 982 − 920 = 62)");
  const fill = DG.placement(new DG.Rect(0, 0, 400, 300), null, true, hole);
  check(same(fill, hole), "placement : une fenêtre redimensionnable remplit le trou");
  const big = DG.placement(new DG.Rect(0, 0, 400, 300), { width: 1300, height: 500 }, true, hole);
  check(big.width === 1300 && big.x === hole.x && big.height === 700, "placement : un minimum plus large que le trou part du coin haut-gauche");
  const fixed = DG.placement(new DG.Rect(0, 0, 400, 300), null, false, hole);
  check(same(fixed, new DG.Rect(450, 286, 400, 300)), "placement : une fenêtre de taille fixe est centrée dans le trou");
  const huge = DG.placement(new DG.Rect(0, 0, 2000, 1200), null, false, hole);
  check(huge.x === hole.x && huge.y === hole.y, "placement : trop grande, elle part du coin haut-gauche");
  check(hole.contains(fixed) && !hole.contains(huge) && hole.contains(hole), "géométrie : « contenu dans le trou »");
  // Fenêtres du bureau : écran 1512 × 982, barre 66, colonne 76.
  const full = new DG.Rect(0, 0, 1512, 982);
  const noDock = DG.frames(full, new DG.Rect(0, 0, 1512, 958), 66, 76, null, null);
  check(same(noDock.bar, new DG.Rect(0, 916, 1512, 66)) && same(noDock.rail, new DG.Rect(0, 0, 76, 916)), "fenêtres : barre en haut, colonne dessous");
  check(same(noDock.desk, new DG.Rect(75, 0, 1437, 917)) && noDock.side === null, "fenêtres : le bureau passe 1 pt sous la barre et la colonne, rien à côté");
  const withSide = DG.frames(full, new DG.Rect(0, 0, 1512, 958), 66, 76, 460, null);
  check(withSide.desk.width === 1437 - 460 && same(withSide.side, new DG.Rect(1052, 0, 460, 916)), "fenêtres : le volet prend la droite, le centre le reste");
  const dockBottom = DG.frames(full, new DG.Rect(0, 70, 1512, 888), 66, 76, null, null);
  check(dockBottom.desk.y === 70 && dockBottom.rail.y === 70 && dockBottom.rail.height === 846, "fenêtres : un Dock visible n'est jamais recouvert");
  const dockLeft = DG.frames(full, new DG.Rect(80, 0, 1432, 958), 66, 76, null, null);
  check(dockLeft.rail.x === 80 && dockLeft.desk.x === 155, "fenêtres : un Dock à gauche pousse la colonne");
  const second = new DG.Rect(1512, 0, 1920, 1080);
  const onSecond = DG.frames(full, new DG.Rect(0, 0, 1512, 958), 66, 76, 460, second);
  check(same(onSecond.side, second) && onSecond.desk.width === 1437, "fenêtres : le volet sur un second écran le remplit, le centre garde toute la largeur");
  check(DG.StudyReadiness.missing(false, true, false, true, false).length === 0, "permissions : sans blocage, rien à demander");
  check(same(DG.StudyReadiness.missing(true, true, false, true, false), ["accessibility", "systemEvents"]), "permissions : Accessibilité et System Events manquent");
  check(DG.StudyReadiness.missing(true, false, false, false, false).length === 0, "permissions : réglages éteints, rien à demander");
  check(DG.StudyReadiness.missing(true, true, true, true, true).length === 0, "permissions : tout est accordé");
  check(SM.writingApps.has("com.goodnotesapp.x") && !SM.writingApps.has("com.anthropic.claudefordesktop"), "apps d'écriture : GoodNotes oui, Claude non");
});

// MARK: Chrono : le prochain exercice d'abord

describe("Chrono : le prochain exercice d'abord", () => {
  const course = new Course({ code: "TEST-777", name: "Chrono" });
  const old = new ExerciseSeries({ course, seriesNumber: 1, plannedWeek: 1 });
  const current = new ExerciseSeries({ course, seriesNumber: 2, plannedWeek: 2 });
  const o1 = new Exercise({ series: old, exerciseNumber: "1.1", sortOrder: 0 });
  const o2 = new Exercise({ series: old, exerciseNumber: "1.2", sortOrder: 1 });
  const c1 = new Exercise({ series: current, exerciseNumber: "2.1", sortOrder: 0 });
  const c2 = new Exercise({ series: current, exerciseNumber: "2.2", sortOrder: 1 });
  const cb = new Exercise({ series: current, exerciseNumber: "2.3", isBonus: true, sortOrder: 2 });
  o1.doneAt = new Date();
  o2.doneAt = new Date();
  c1.doneAt = new Date();
  const ordered = FT.exercises([old, current], "exercise");
  check(same(ordered.upNext.map((exercise) => exercise.exerciseNumber), ["2.2", "2.3"]),
    `à faire : 2.2 puis le bonus (${ordered.upNext.map((exercise) => exercise.exerciseNumber)})`);
  check(same(ordered.done.map((exercise) => exercise.exerciseNumber), ["2.1", "1.1", "1.2"]),
    `déjà faits ensuite, série en cours d'abord (${ordered.done.map((exercise) => exercise.exerciseNumber)})`);
  o2.correctedAt = new Date();
  o2.correctnessRaw = "wrong";
  o2.redoRequired = true;
  const correction = FT.exercises([old, current], "correction");
  check(correction.upNext[0]?.exerciseNumber !== "1.2" && correction.upNext[correction.upNext.length - 1]?.exerciseNumber === "1.2",
    `correction : corriger avant de refaire (${correction.upNext.map((exercise) => exercise.exerciseNumber)})`);

  check(FT.ExerciseRegions.shortNumber("4.3") === "3" && FT.ExerciseRegions.shortNumber("Ex-02-03") === "3"
    && FT.ExerciseRegions.shortNumber("3b") === "3b", "numéro court d'un exercice");
  const regions = FT.ExerciseRegions.slices([
    { number: "3.1", page: 0, top: 0.2 },
    { number: "3.2", page: 0, top: 0.7 },
    { number: "3.3", page: 1, top: 0.5 },
  ], 2);
  check(regions["1"]?.length === 1 && Math.abs((regions["1"]?.[0]?.top ?? 0) - 0.18) < 1e-9
    && Math.abs((regions["1"]?.[0]?.bottom ?? 0) - 0.689) < 1e-9, "l'exercice 1 va jusqu'au titre du 2");
  check(regions["2"]?.length === 2 && regions["2"]?.[1]?.page === 1 && Math.abs((regions["2"]?.[1]?.bottom ?? 0) - 0.489) < 1e-9,
    "l'exercice 2 continue sur la page suivante");
  check(regions["3"]?.[0]?.bottom === 1 && Math.abs((regions["3"]?.[0]?.top ?? 0) - 0.48) < 1e-9, "le dernier va jusqu'en bas");
  const paged = FT.ExerciseRegions.slices([{ number: "1", page: 0, top: 0.15 }, { number: "2", page: 1, top: 0.11 }], 2);
  check(paged["1"]?.length === 1, "la suite d'un énoncé réduite à l'en-tête de page n'est pas montrée");
});

describe("Chrono : ce que l'horaire dit du moment", () => {
  const now = new Date();
  const analyse = crypto.randomUUID();
  const physique = crypto.randomUUID();
  const slots: FT.FocusContextSlot[] = [
    { courseID: analyse, courseCode: "MATH-101", kind: "exerciseSession", start: add(now, -1800), end: add(now, 4500) },
    { courseID: physique, courseCode: "PHYS-101", kind: "lecture", start: add(now, -7200), end: add(now, -600) },
  ];
  const during = FT.suggestion(now, slots);
  check(during?.courseID === analyse && during?.taskType === "exercise", "pendant une séance d'exercices : ce cours, des séries");
  const after = FT.suggestion(now, [slots[1]]);
  check(after?.courseID === physique && after?.taskType === "theory", "juste après un amphi : sa théorie");
  const soon: FT.FocusContextSlot = { courseID: analyse, courseCode: "MATH-101", kind: "exerciseSession", start: add(now, 1200), end: add(now, 7500) };
  check(FT.suggestion(now, [soon])?.taskType === "exercise", "une séance dans 20 min se prépare");
  const late: FT.FocusContextSlot = { courseID: analyse, courseCode: "MATH-101", kind: "exerciseSession", start: add(now, 4 * 3600), end: add(now, 6 * 3600) };
  check(FT.suggestion(now, [late]) === null, "rien d'imminent : pas de proposition");
});

// MARK: Musique

describe("Musique", () => {
  const t0 = new Date(1_800_000_000 * 1000);
  const mac = new ML.MusicState({
    device: "MAC", platform: "mac", title: "Wait for Me", artist: "Reeve Carney", duration: 240, elapsed: 30,
    readAt: t0, isPlaying: true, updatedAt: t0,
  });
  const linkKey = TimerLink.key("_identity");

  it("Musique : état chiffré, relu à l'identique", async () => {
    const key = await linkKey;
    const sealed = await ML.seal({ kind: "state", state: mac }, key);
    expect(sealed).not.toBeNull();
    expect(await ML.open(sealed!, key)).toEqual({ kind: "state", state: mac });
  });
  it("Musique : illisible sans la clé du compte", async () => {
    const sealed = await ML.seal({ kind: "state", state: mac }, await linkKey);
    expect(await ML.open(sealed!, await TimerLink.key("autre"))).toBeNull();
  });
  it("Musique : commande de passage chiffrée", async () => {
    const key = await linkKey;
    const command = new ML.MusicCommand({
      from: "PHONE", to: "MAC",
      action: { kind: "handoff", item: new ML.MusicItem({ title: "Wait for Me", artist: "Reeve Carney", duration: 240 }), elapsed: 95, playing: true },
      sentAt: t0,
    });
    const sealed = await ML.seal({ kind: "command", command }, key);
    expect(await ML.open(sealed!, key)).toEqual({ kind: "command", command });
  });
  check(same(ML.route(false, true, [mac], null, add(t0, 60)), { kind: "remote", device: "MAC" }),
    "Musique : le lecteur montre l'appareil qui joue");
  check(ML.route(true, true, [mac], "MAC", t0).kind === "local", "Musique : ici joue, ici d'abord");
  check(ML.route(false, true, [mac], null, add(t0, 3 * 3600)).kind === "local",
    "Musique : un état « en lecture » périmé (appareil éteint) ne compte plus");
  const paused = new ML.MusicState({ ...mac, isPlaying: false });
  check(same(ML.route(false, true, [paused], "MAC", t0), { kind: "remote", device: "MAC" }),
    "Musique : rien ne joue, le choix fait à la main");
  const drifted = new ML.MusicState({ ...mac, readAt: add(t0, 10), elapsed: 40 });
  check(!ML.changed(mac, drifted), "Musique : la position qui avance ne republie pas");
  const jumped = new ML.MusicState({ ...mac, readAt: add(t0, 10), elapsed: 120 });
  check(ML.changed(mac, jumped), "Musique : un saut republie");
  check(ML.changed(mac, paused), "Musique : une pause republie");
  check(Math.abs(mac.elapsedAt(add(t0, 20)) - 50) < 0.01, "Musique : la position se déduit de l'instant de lecture");
});

// MARK: Bureau : chute chiffrée

describe("Bureau : une numérisation passe le relais", () => {
  const t0 = new Date(1_800_000_000 * 1000);
  const drop = new DeskDrop({
    from: "PHONE", intent: "stuck", document: new Uint8Array(300_000).fill(7), isPDF: true,
    question: "bloqué sur le 6.2", exerciseID: crypto.randomUUID(), sentAt: t0,
  });
  it("Bureau : une numérisation de 300 Ko passe le relais, chiffrée", async () => {
    const key = await TimerLink.key("_identity");
    const sealed = await DeskDrop.seal(drop, key);
    expect(sealed).not.toBeNull();
    expect(sealed!.length).toBeLessThan(950_000);
    expect(await DeskDrop.open(sealed!, key)).toEqual(drop);
  });
  it("Bureau : trop lourde, refusée avant l'envoi", async () => {
    const heavy = new DeskDrop({ ...drop, document: new Uint8Array(DeskDrop.maxDocumentBytes + 1) });
    expect(await DeskDrop.seal(heavy, await TimerLink.key("_identity"))).toBeNull();
  });
});

// MARK: Liens du cours

describe("Liens du cours", () => {
  const a = StudyLinkKey.key("https://botafogo.epfl.ch/analyse-1-flipped/?cours=&polycopie=/handout/matiere/m_Suites_Cauchy");
  const b = StudyLinkKey.key("https://botafogo.epfl.ch/analyse-1-flipped/?polycopie=matiere/m_suites_cauchy");
  check(a === b && a === StudyLinkKey.key("/handout/matiere/m_suites_cauchy"),
    `polycopié : trois formes du même lien, une seule section — ${a}`);
  const unit = "block-v1:EPFL+Algebre123+2025+type@video+block@635aa0b7";
  check(StudyLinkKey.key("https://courseware.epfl.ch/xblock/" + unit) === StudyLinkKey.key(unit),
    "Courseware : le bloc, avec ou sans adresse");
  check(StudyLinkKey.key("https://moodle.epfl.ch/pluginfile.php/1/x.pdf#page=2")
    === StudyLinkKey.key("https://moodle.epfl.ch/pluginfile.php/1/x.pdf/"), "document : sans fragment ni barre finale");
});
