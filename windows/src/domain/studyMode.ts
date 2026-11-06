// Le **mode étude** (Polymestre/Domain/StudyMode.swift) : pendant une session,
// le Mac et l'iPhone n'ouvrent que ce qui sert à travailler — les sites de cours,
// Claude, GoodNotes.
//
// Il n'a pas d'état à lui : c'est une date (`FocusTimerState.studyUntil`) portée
// par le chrono partagé. Les décisions sont ici, pures et testées ; le blocage
// lui-même est propre à chaque système.

import { Institution } from "./institution.ts";
import type { Course } from "../models/course.ts";
import type { FocusTimerState } from "./focusTimerState.ts";

/** Les durées proposées au lancement, en minutes. */
export const durations: number[] = [25, 50, 90, 120];

/** Les bornes d'une durée choisie à la main (5 min à 12 h). */
export const minuteRange = { lowerBound: 5, upperBound: 720 } as const;

const seconds = (date: Date): number => date.getTime() / 1000;
const addSeconds = (date: Date, amount: number): Date => new Date(Math.round(date.getTime() + amount * 1000));

/** « Jusqu'à 18 h 30 » → la durée en minutes depuis maintenant. */
export function minutes(until: Date, now: Date = new Date(), _calendar?: unknown): number {
  let target = new Date(now.getFullYear(), now.getMonth(), now.getDate(), until.getHours(), until.getMinutes(), 0, 0);
  if (target <= now) target = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, until.getHours(), until.getMinutes(), 0, 0);
  const value = Math.ceil((target.getTime() - now.getTime()) / 60_000);
  return Math.min(Math.max(value, minuteRange.lowerBound), minuteRange.upperBound);
}

/** Le mode étude est-il en vigueur à `now` ? */
export function isActive(state: FocusTimerState | null | undefined, at: Date = new Date()): boolean {
  const until = state?.studyUntil;
  if (!until) return false;
  return at < until;
}

/** L'échéance d'un mode étude **sans fin** : on s'arrête quand on veut. */
export const openEnd = new Date((63_113_904_000 + 978_307_200) * 1000);

/** Le mode étude n'a pas d'heure de fin. */
export function isOpenEnded(state: FocusTimerState | null | undefined): boolean {
  const until = state?.studyUntil;
  if (!until) return false;
  return seconds(until) > seconds(openEnd) - 86_400 * 365;
}

/** Le temps passé en mode étude (depuis `studySince`). */
export function elapsed(state: FocusTimerState | null | undefined, at: Date = new Date()): number {
  if (!state?.studyUntil) return 0;
  const since = state.studySince ?? state.sessionStartedAt ?? at;
  return Math.max(0, seconds(at) - seconds(since));
}

/** Ce que montre l'horloge : ce qui reste, ou, sans fin, le temps passé. */
export function clock(state: FocusTimerState | null | undefined, at: Date = new Date()): number {
  return isOpenEnded(state) ? Math.floor(elapsed(state, at)) : Math.ceil(remaining(state, at));
}

/** L'origine des secondes de l'horloge (les vues s'y calent pour battre juste). */
export function tickAnchor(state: FocusTimerState | null | undefined): Date {
  const anchor = isOpenEnded(state) ? state?.studySince ?? new Date() : state?.studyUntil ?? new Date();
  return addSeconds(anchor, 0.05);
}

/** Ce qui reste, en secondes (zéro une fois passé). */
export function remaining(state: FocusTimerState | null | undefined, at: Date = new Date()): number {
  const until = state?.studyUntil;
  if (!until) return 0;
  return Math.max(0, seconds(until) - seconds(at));
}

function progressFrom(state: FocusTimerState | null | undefined, start: Date, at: Date): number {
  const until = state?.studyUntil;
  if (!until) return 0;
  // Sans fin : l'anneau fait le tour en une heure, puis recommence.
  if (isOpenEnded(state)) {
    return (seconds(at) - seconds(start)) % 3600 / 3600;
  }
  const total = seconds(until) - seconds(start);
  if (!(total > 0)) return 1;
  return Math.min(1, Math.max(0, (seconds(at) - seconds(start)) / total));
}

/** La fraction écoulée du mode étude (0 → 1), depuis `studySince`. */
export function progress(state: FocusTimerState | null | undefined, at?: Date): number;
export function progress(state: FocusTimerState | null | undefined, since: Date, at: Date): number;
export function progress(
  state: FocusTimerState | null | undefined,
  sinceOrAt: Date = new Date(),
  at?: Date,
): number {
  if (at !== undefined) return progressFrom(state, sinceOrAt, at);
  const start = state?.studySince ?? state?.sessionStartedAt ?? sinceOrAt;
  return progressFrom(state, start, sinceOrAt);
}

/** Le mode étude a fini (la date est passée) mais la session tourne encore. */
export function isOver(state: FocusTimerState | null | undefined, at: Date = new Date()): boolean {
  const until = state?.studyUntil;
  if (!until) return false;
  return at >= until;
}

/** Prolonger : à partir de la fin prévue si elle n'est pas passée, sinon de maintenant. */
export function extended(until: Date | null | undefined, by: number, now: Date = new Date()): Date {
  if (until && until >= addSeconds(openEnd, -86_400 * 365)) return until;
  const base = Math.max(until?.getTime() ?? now.getTime(), now.getTime());
  return addSeconds(new Date(base), by * 60);
}

// MARK: Blocage par défaut

/** Ce que les réglages doivent offrir (`UserDefaults` côté Swift). */
export interface StudyDefaults {
  object(key: string): unknown;
  set(value: boolean, key: string): void;
}

/** Un `UserDefaults` en mémoire, pour les tests et l'amorçage. */
export function memoryStudyDefaults(initial: Record<string, unknown> = {}): StudyDefaults {
  const values = new Map<string, unknown>(Object.entries(initial));
  return {
    object: (key) => values.get(key) ?? null,
    set: (value, key) => { values.set(key, value); },
  };
}

/**
 * Bloquer le reste se **choisit** : une nouvelle installation ouvre le mode
 * étude sans rien bloquer, qui s'en servait avec l'ancien défaut le garde. Un
 * choix déjà fait n'est jamais touché.
 */
const standardStudyDefaults = memoryStudyDefaults();

export function settleBlockingDefaults(
  keys: string[],
  existingUser: boolean,
  defaults: StudyDefaults = standardStudyDefaults,
): void {
  for (const key of keys) {
    if (defaults.object(key) === null || defaults.object(key) === undefined) defaults.set(existingUser, key);
  }
}

/** Entre en mode étude pour `minutes` à partir de `now` ; `null` : sans fin. */
export function enter(
  state: FocusTimerState,
  minutesValue: number | null | undefined,
  locks = true,
  now: Date = new Date(),
): void {
  state.studySince = now;
  state.studyUntil = minutesValue !== null && minutesValue !== undefined ? addSeconds(now, minutesValue * 60) : openEnd;
  state.studyLocks = locks ? undefined : false;
}

/** Le mode étude est actif **et** bloque le reste. */
export function blocks(state: FocusTimerState | null | undefined, at: Date = new Date()): boolean {
  return isActive(state, at) && state?.studyLocks !== false;
}

/** Le **verrou** : le reste est bloqué et on ne sort pas avant l'heure. */
export function locks(state: FocusTimerState | null | undefined, at: Date = new Date()): boolean {
  return blocks(state, at) && !isOpenEnded(state);
}

/** Le bouclier d'une session sans fin se lève de lui-même au bout de ce temps. */
export const openEndedShieldSafety = 12 * 3600;

/** La sortie d'urgence : secondes à tenir pour lever un verrou avant l'heure. */
export const emergencyHold = 8;

/** Peut-on terminer, abandonner ou sortir maintenant ? */
export function canLeave(state: FocusTimerState | null | undefined, at: Date = new Date()): boolean {
  return !locks(state, at);
}

/** La note d'une session levée par la sortie d'urgence (une fois). */
export function emergencyNote(note: string): string {
  const mark = "Sortie d'urgence";
  if (note.includes(mark)) return note;
  return note === "" ? mark : `${note} · ${mark}`;
}

/** Lève le mode étude (la session continue). */
export function leave(state: FocusTimerState): void {
  state.studyUntil = undefined;
  state.studySince = undefined;
  state.studyLocks = undefined;
}

// MARK: Sites permis

/** Les pages de connexion qui doivent rester ouvertes pour se connecter aux cours. */
const commonSites = [
  "claude.ai", "anthropic.com", "claudeusercontent.com",
  "login.microsoftonline.com", "login.live.com", "msauth.net", "msftauth.net",
  "accounts.google.com", "appleid.apple.com",
  "geogebra.org", "desmos.com", "wolframalpha.com",
  "speakup.info", "wooclap.com", "app.wooclap.com", "particify.de",
];

/**
 * Les sites ouverts par défaut : ceux de l'école, puis ceux de tout le monde.
 * Un domaine couvre ses sous-domaines.
 */
export function defaultSites(institution: Institution = Institution.current): string[] {
  const sites = [...institution.studyDomains];
  for (const site of commonSites) if (!sites.includes(site)) sites.push(site);
  return sites;
}

/** Les sites ajoutés à la liste par défaut après coup. */
export const addedLater = new Set([
  "geogebra.org", "desmos.com", "wolframalpha.com",
  "edstem.org", "edusercontent.com", "openlearnity.org",
  "speakup.info", "wooclap.com", "app.wooclap.com", "particify.de",
]);

/** `https://www.Moodle.epfl.ch/my/` → `moodle.epfl.ch`. */
export function normalizedDomain(entry: string): string | null {
  let text = entry.trim().toLowerCase();
  if (text === "") return null;
  const scheme = text.indexOf("://");
  if (scheme >= 0) text = text.slice(scheme + 3);
  const slash = text.search(/[/?#]/);
  if (slash >= 0) text = text.slice(0, slash);
  const at = text.lastIndexOf("@");
  if (at >= 0) text = text.slice(at + 1);
  const colon = text.indexOf(":");
  if (colon >= 0) text = text.slice(0, colon);
  if (text.startsWith("*.")) text = text.slice(2);
  if (text.startsWith("www.")) text = text.slice(4);
  while (text.endsWith(".")) text = text.slice(0, -1);
  // `CharacterSet.alphanumerics.union(".-")` : lettres et chiffres Unicode.
  if (!text.includes(".") || text.startsWith(".") || text.includes("..") || !/^[\p{L}\p{N}.-]+$/u.test(text)) return null;
  return text;
}

/** Ce site est-il permis ? À une frontière de point : `epfl.ch` permet `moodle.epfl.ch`, pas `notepfl.ch`. */
export function isAllowedHost(host: string | null | undefined, sites: string[]): boolean {
  const normalized = host != null ? normalizedDomain(host) : null;
  if (normalized === null) return false;
  return sites
    .map((site) => normalizedDomain(site))
    .some((site) => site !== null && (normalized === site || normalized.endsWith("." + site)));
}

/** Une adresse est-elle permise ? Les pages internes (`about:`, `data:`, `blob:`) le sont toujours. */
export function isAllowedURL(url: URL | null | undefined, sites: string[]): boolean {
  if (!url) return false;
  switch (url.protocol.toLowerCase()) {
    case "about:":
    case "data:":
    case "blob:":
      return true;
    case "http:":
    case "https:":
      return isAllowedHost(url.hostname, sites);
    default:
      return false;
  }
}

/** `isAllowed(host:)` ou `isAllowed(url:)`, selon ce qu'on passe. */
export function isAllowed(hostOrURL: string | URL | null | undefined, sites: string[]): boolean {
  if (hostOrURL instanceof URL) return isAllowedURL(hostOrURL, sites);
  return isAllowedHost(hostOrURL, sites);
}

// MARK: Apps permises (Mac)

/** Les apps permises par défaut sur le Mac. */
export const defaultMacApps: string[] = [
  "com.goodnotesapp.x",
  "com.anthropic.claudefordesktop",
  "com.apple.Preview",
  "com.apple.calculator",
];

/** Le Finder n'est plus permis d'office. */
export const finderBundleID = "com.apple.finder";

export function removingFinder(from: string[]): string[] {
  return from.filter((bundleID) => bundleID !== finderBundleID);
}

/** Ce qui fait marcher le Mac lui-même : jamais bloqué. */
export const systemBundles = new Set([
  "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.coreautha",
  "com.apple.ScreenSaver.Engine", "com.apple.dock", "com.apple.Spotlight",
  "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver",
  "com.apple.screencaptureui", "com.apple.PIPAgent", "com.apple.UserNotificationCenter",
  "com.apple.universalcontrol", "com.apple.WindowManager", "com.apple.accessibility.AXVisualSupportAgent",
]);

/** Les apps qui travaillent pour le mode étude en arrière-plan (Music). */
export const backgroundApps = new Set(["com.apple.Music"]);

/** Les apps qu'on masque quand elles passent devant, sans jamais les fermer. */
export const hideOnlyApps = new Set([...backgroundApps, finderBundleID]);

/** Les lanceurs (Raycast, Alfred, LaunchBar) : des portes de sortie. */
export const launcherApps = new Set([
  "com.raycast.macos", "com.runningwithcrayons.Alfred", "at.obdev.LaunchBar",
  "com.lwouis.alt-tab-macos", "com.contextsformac.Contexts", "com.manytricks.Witch",
]);

/** Ce qu'il faut faire d'une app qui passe au premier plan. */
export type Disposition = "allowed" | "hideOnly" | "close" | "system";

export const Disposition = {
  allowed: "allowed" as Disposition,
  hideOnly: "hideOnly" as Disposition,
  close: "close" as Disposition,
  system: "system" as Disposition,
};

export function disposition(
  bundleID: string | null | undefined,
  isRegular: boolean,
  own: string,
  allowed: string[],
): Disposition {
  if (bundleID === null || bundleID === undefined || bundleID === "") return "system";
  if (bundleID === own || systemBundles.has(bundleID)) return "system";
  // Les assistants d'une app permise (« … .helper ») le sont avec elle.
  if (allowed.some((entry) => bundleID === entry || bundleID.startsWith(entry + "."))) return "allowed";
  if (launcherApps.has(bundleID)) return "close";
  if (!isRegular) return "system";
  return hideOnlyApps.has(bundleID) ? "hideOnly" : "close";
}

/** Une app qui passe au premier plan doit-elle être arrêtée ? */
export function shouldBlock(
  bundleID: string | null | undefined,
  isRegular: boolean,
  own: string,
  allowed: string[],
): boolean {
  const result = disposition(bundleID, isRegular, own, allowed);
  return result === "close" || result === "hideOnly";
}

// MARK: Outils

/** Ce que l'écran du mode étude propose d'ouvrir. */
export type StudyToolKind =
  | { type: "web"; url: URL }
  | { type: "app"; bundleID: string; scheme: string };

export interface StudyTool {
  id: string;
  title: string;
  subtitle: string;
  icon: string;
  kind: StudyToolKind;
}

/** Le nom et l'icône d'un site de cours connu. */
export function siteLabel(host: string): [string, string] {
  if (host.startsWith("moodle.")) return ["Moodle du cours", "graduationcap"];
  if (host.startsWith("courseware.")) return ["Courseware", "play.rectangle"];
  if (host.startsWith("botafogo.")) return ["Botafogo", "book.pages"];
  if (host.startsWith("mediaspace.")) return ["Vidéos du cours", "video"];
  if (host.startsWith("explique.")) return ["Explique", "text.bubble"];
  return [host.replace(/www\./g, ""), "globe"];
}

/** Les outils de la session : les pages du cours travaillé, puis les outils de toujours. */
export function tools(
  courseName: string | null,
  courseLinks: string[],
  institution: Institution = Institution.current,
): StudyTool[] {
  const result: StudyTool[] = [];
  const seen = new Set<string>();
  for (const link of courseLinks) {
    let url: URL;
    try {
      url = new URL(link);
    } catch {
      continue;
    }
    if (!url.protocol.toLowerCase().startsWith("http")) continue;
    const host = url.hostname.toLowerCase();
    if (seen.has(url.href)) continue;
    seen.add(url.href);
    const [title, icon] = siteLabel(host);
    result.push({
      id: "course:" + url.href,
      title,
      subtitle: courseName ?? host,
      icon,
      kind: { type: "web", url },
    });
  }
  // Claude n'est plus un site : il est dans l'app. L'ordre reste celui d'avant :
  // Moodle, Claude, GoodNotes, Courseware.
  const base: StudyTool[] = [];
  const moodle = institution.moodleURL("/my/");
  if (moodle) {
    base.push({ id: "moodle", title: "Moodle", subtitle: "Tes cours", icon: "graduationcap", kind: { type: "web", url: moodle } });
  }
  base.push({
    id: "claude-app", title: "Claude", subtitle: "L'app", icon: "sparkles",
    kind: { type: "app", bundleID: "com.anthropic.claudefordesktop", scheme: "claude://" },
  });
  base.push({
    id: "goodnotes", title: "GoodNotes", subtitle: "Écrire", icon: "pencil.and.scribble",
    kind: { type: "app", bundleID: "com.goodnotesapp.x", scheme: "goodnotes://" },
  });
  const courseware = institution.coursewareURL("/dashboard");
  if (courseware) {
    base.push({ id: "courseware", title: "Courseware", subtitle: "MOOC et vidéos", icon: "play.rectangle", kind: { type: "web", url: courseware } });
  }
  return result.concat(base);
}

/** Les sites **du cours** (sa page Moodle, Courseware, Botafogo, ses vidéos…). */
export function courseSites(course: Course, institution: Institution = Institution.current): StudyTool[] {
  const links = [...(course.moodleLink ? [course.moodleLink.href] : []), ...course.contentSources];
  return tools(course.name, links, institution).filter((tool) => tool.id.startsWith("course:"));
}

/** Les apps où l'on écrit : quand l'une occupe le centre, l'énoncé passe à côté. */
export const writingApps = new Set(["com.goodnotesapp.x", "com.apple.Notes", "com.apple.Preview"]);

export const StudyMode = {
  durations,
  minuteRange,
  minutes,
  isActive,
  openEnd,
  isOpenEnded,
  elapsed,
  clock,
  tickAnchor,
  remaining,
  progress,
  isOver,
  extended,
  settleBlockingDefaults,
  memoryStudyDefaults,
  enter,
  blocks,
  locks,
  openEndedShieldSafety,
  emergencyHold,
  canLeave,
  emergencyNote,
  leave,
  defaultSites,
  addedLater,
  normalizedDomain,
  isAllowed,
  isAllowedHost,
  isAllowedURL,
  defaultMacApps,
  finderBundleID,
  removingFinder,
  systemBundles,
  backgroundApps,
  hideOnlyApps,
  launcherApps,
  disposition,
  Disposition,
  shouldBlock,
  siteLabel,
  tools,
  courseSites,
  writingApps,
};
