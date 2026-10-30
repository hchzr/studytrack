// Le parseur du calendrier académique de l'EPFL (StudyTrack/Domain/AcademicCalendar.swift).
//
// Portés : `AcademicCalendarParser` en entier. `MilestoneKind` vit dans models/enums.ts et
// `AcademicMilestoneValue` dans models/academicMilestone.ts (leurs `label`, `icon`, `isStructural`
// ne servent à aucun moteur porté). `Calendar.current` devient l'heure locale de la machine.

import type { AcademicMilestoneValue } from "../models/academicMilestone.ts";
import { epflCalendarURL } from "../models/academicMilestone.ts";
import type { MilestoneKind } from "../models/enums.ts";
import { characters, isLetter, isNumber } from "./textRepair.ts";

/// Une section = un semestre, repérée par « Semestre automne 26-27 ».
interface Section {
  label: string;
  body: string;
}

interface Row {
  date: string;
  title: string;
  isImportant: boolean;
}

/// Les noms de mois, sans accents et en minuscules.
///
/// Un formateur de dates dépendrait de la locale de l'appareil : un téléphone en
/// anglais ne lirait pas « décembre ». Ici la table est explicite.
const months: Record<string, number> = {
  janvier: 1, fevrier: 2, mars: 3, avril: 4, mai: 5, juin: 6,
  juillet: 7, aout: 8, septembre: 9, octobre: 10,
  novembre: 11, decembre: 12,
};

const prefixPattern = /^(début|debut|mi|fin)[\s-]+(.+)$/;
const datePattern = /^(?:(\d{1,2})\s+)?([a-z]+)\s+(\d{4})$/;

/// Lit le calendrier académique de l'EPFL depuis sa page publique.
///
/// **Pourquoi un parseur et pas des dates en dur** : l'EPFL publie deux semestres
/// à la fois et fait glisser la fenêtre chaque année. Un tableau figé dans le code
/// serait périmé en quelques mois. On garde donc un **instantané** embarqué (pour
/// que l'app fonctionne hors ligne dès l'installation, et le jour de la rentrée)
/// **et** de quoi relire la page pour le rafraîchir.
///
/// Fonction **pure** : elle reçoit du HTML, donc elle se teste sur le vrai contenu.
export const AcademicCalendarParser = {
  /// `Institution.current.calendarURL` : la page publique du calendrier.
  get sourceURL(): string {
    return epflCalendarURL;
  },

  // MARK: Analyse

  parse,
  parseDate,
  kind,
  identifier,
  fold,
  decodeNumericEntities,
  plainText,
};

function parse(html: string): AcademicMilestoneValue[] {
  const result: AcademicMilestoneValue[] = [];
  const seen = new Set<string>();

  for (const section of sections(html)) {
    for (const row of rows(section.body)) {
      const parsed = parseDate(row.date);
      if (!parsed) continue;
      const title = row.title;
      if (title === "") continue;
      const nature = kind(title);
      const id = identifier(parsed.date, title);
      if (seen.has(id)) continue;
      seen.add(id);
      result.push({
        id,
        title,
        date: parsed.date,
        kind: nature,
        isImportant: row.isImportant,
        isApproximate: parsed.approximate,
        termLabel: section.label,
        sourceURL: AcademicCalendarParser.sourceURL,
      });
    }
  }
  return result.sort((a, b) => a.date.getTime() - b.date.getTime());
}

function sections(html: string): Section[] {
  const matches = [...html.matchAll(/Semestre\s+([A-Za-zéû]+)\s+(\d{2}-\d{2})/g)];
  if (matches.length === 0) {
    // Page sans en-tête reconnu : on tente quand même les tableaux, avec
    // un libellé vide plutôt que de tout perdre.
    return [{ label: "", body: html }];
  }
  return matches.map((match, index) => {
    const start = match.index!;
    const end = index + 1 < matches.length ? matches[index + 1].index! : html.length;
    return { label: `Semestre ${match[1]} ${match[2]}`, body: html.slice(start, end) };
  });
}

/// Une ligne de tableau : `<td>date</td><td>libellé</td>`.
function rows(html: string): Row[] {
  const result: Row[] = [];
  for (const match of html.matchAll(/<tr[^>]*>(.*?)<\/tr>/gs)) {
    const body = match[1];
    const cells = [...body.matchAll(/<td[^>]*>(.*?)<\/td>/gs)];
    if (cells.length < 2) continue;
    const rawDate = cells[0][1];
    const rawTitle = cells[1][1];
    result.push({
      date: plainText(rawDate),
      title: plainText(rawTitle),
      isImportant: rawDate.toLowerCase().includes("<strong>") || rawTitle.toLowerCase().includes("<strong>"),
    });
  }
  return result;
}

// MARK: Dates

/// « 16 février 2026 », « Début mars 2026 », « Mi-novembre 2026 », « Fin décembre 2025 ».
///
/// Les trois derniers sont **approximatifs** : l'EPFL ne donne pas de jour. On
/// choisit le 1er, le 15 ou le dernier jour du mois, et on le signale à
/// l'écran — une approximation assumée vaut mieux qu'une date fausse présentée
/// comme exacte, ou qu'une ligne disparue.
function parseDate(raw: string): { date: Date; approximate: boolean } | null {
  let text = fold(raw);
  let approximate = false;
  let day: number | null = null;

  const prefixed = prefixPattern.exec(text);
  if (prefixed) {
    approximate = true;
    const prefix = prefixed[1];
    text = prefixed[2];
    switch (prefix) {
      case "mi": day = 15; break;
      case "fin": day = null; break; // dernier jour du mois
      default: day = 1; break; // « début »
    }
  }

  const match = datePattern.exec(text);
  if (!match) return null;
  const explicitDay = match[1] === undefined ? null : Number(match[1]);
  const monthName = match[2];
  const year = Number(match[3]);
  const month = Object.prototype.hasOwnProperty.call(months, monthName) ? months[monthName] : undefined;
  if (month === undefined) return null;

  let resolvedDay: number;
  if (explicitDay !== null) resolvedDay = explicitDay;
  else if (day !== null) resolvedDay = day;
  else resolvedDay = lastDay(month, year);

  // Une année à deux chiffres n'existe pas ici : l'EPFL écrit « 2026 ».
  if (!(year >= 2000 && year <= 2100) || !(month >= 1 && month <= 12)) return null;
  // Une section peut annoncer des dates de l'année précédente : on les garde,
  // elles racontent le semestre en cours.
  return { date: new Date(year, month - 1, resolvedDay), approximate };
}

function lastDay(month: number, year: number): number {
  return new Date(year, month, 0).getDate();
}

// MARK: Nature

function kind(label: string): MilestoneKind {
  const text = fold(label);
  if (text.includes("jour ferie")) return "holiday";
  if (text.includes("interruption des enseignements")) return "break";
  if (text.includes("reprise des enseignements")) return "break";
  if (text.startsWith("debut des enseignements")) return "teachingStart";
  if (text.startsWith("fin des enseignements")) return "teachingEnd";
  if (text.startsWith("debut des examens")) return "examStart";
  if (text.startsWith("fin des examens")) return "examEnd";
  if (text.includes("delai")) return "deadline";
  if (text.includes("ouverture")) return "opening";
  if (text.includes("evaluation approfondie")) return "evaluation";
  if (text.includes("publication") || text.includes("envoi") || text.includes("bulletins")) {
    return "publication";
  }
  return "other";
}

// MARK: Clé stable

const pad = (value: number, width: number) => String(value).padStart(width, "0");

/// Identifiant stable d'une échéance, pour qu'un rafraîchissement **mette à
/// jour** au lieu de dupliquer.
function identifier(date: Date, title: string): string {
  const stamp = `${pad(date.getFullYear(), 4)}-${pad(date.getMonth() + 1, 2)}-${pad(date.getDate(), 2)}`;
  return `epfl.${stamp}.${slug(title)}`;
}

function slug(text: string): string {
  const allowed = characters(fold(text)).map((c) => (isLetter(c) || isNumber(c) ? c : "-")).join("");
  return allowed.split("-").filter((part) => part !== "").slice(0, 8).join("-");
}

// MARK: Texte

/// Sans accents, sans casse, espaces normalisés. Rend la lecture insensible à
/// la typographie de la page — l'EPFL écrit « é » tantôt en `&eacute;` tantôt
/// en clair.
function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().normalize("NFC")
    .split(" ").join(" ")
    .trim();
}

/// Remplace `&#233;` et `&#xE9;` par le caractère correspondant.
function decodeNumericEntities(text: string): string {
  return text.replace(/&#(x?)([0-9A-Fa-f]+);/g, (whole, hex: string, digits: string) => {
    const isHex = hex.toLowerCase() === "x";
    // `UInt32(digits, radix:)` puis `Unicode.Scalar(value)` : rien pour un nombre trop grand ou une moitié de paire.
    if (!(isHex ? /^[0-9A-Fa-f]+$/ : /^[0-9]+$/).test(digits)) return whole;
    const value = parseInt(digits, isHex ? 16 : 10);
    if (!Number.isFinite(value) || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) return whole;
    return String.fromCodePoint(value);
  });
}

const namedEntities: [string, string][] = [
  ["&nbsp;", " "], ["&amp;", "&"], ["&eacute;", "é"], ["&egrave;", "è"],
  ["&agrave;", "à"], ["&ecirc;", "ê"], ["&ccedil;", "ç"], ["&ocirc;", "ô"],
  ["&ucirc;", "û"], ["&icirc;", "î"], ["&laquo;", "«"], ["&raquo;", "»"],
  ["&rsquo;", "’"], ["&euml;", "ë"], ["&#039;", "'"], ["&quot;", "\""],
  ["&apos;", "'"], ["&times;", "×"], ["&hellip;", "…"], ["&mdash;", "—"],
];

/// Retire les balises, les entités et les espaces multiples.
function plainText(html: string): string {
  let text = html.replace(/<[^>]+>/g, " ");
  for (const [entity, replacement] of namedEntities) {
    text = text.replace(new RegExp(entity, "gi"), () => replacement);
  }
  // Entités **numériques** : `&#233;` pour « é », `&#xE9;` aussi. La page du
  // calendrier écrit ses accents en clair, mais d'autres pages de l'EPFL les
  // encodent — et un parseur qui ne lit pas « D&#233;but » rate une date.
  text = decodeNumericEntities(text);
  return text.replace(/\s+/g, " ").trim();
}
