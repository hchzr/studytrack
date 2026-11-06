// Ce qu'un PDF de série dit de lui-même **en dehors** de ses exercices : son
// numéro de série et le cours auquel il appartient (Polymestre/Domain/SeriesDocumentInference.swift).
//
// Deux causes directes d'imports « au hasard » :
//   • la série n'était lue qu'en **début de ligne**. Un en-tête « Analyse I —
//     Série 4 », un « Exercise Set 4 » ou un fichier `serie04.pdf` laissaient tout
//     en série 1 — et l'IA, qui lisait 4, créait une seconde série à côté ;
//   • l'import lancé depuis l'accueil prenait **le premier cours** de la liste,
//     sans rien demander. Le PDF porte presque toujours le code du cours.
//
// Fonctions pures : texte et nom de fichier en entrée, rien d'autre.
//
// `NLLanguageRecognizer` (NaturalLanguage) n'existe pas hors d'Apple : la langue
// est déduite ici par un profil de mots-outils, avec le même contrat — un nom en
// français, ou `null` quand ce n'est pas sûr. C'est la seule partie non 1:1.

import { icuRegExp } from "./icuRegExp.ts";
import type { PDFLayoutLine } from "./seriesLayout.ts";
import { trimAll } from "../models/util.ts";

/// D'où vient le numéro de série.
export type SeriesNumberSource = "document" | "filename";

export interface SeriesNumberResult {
  number: number;
  source: SeriesNumberSource;
}

// MARK: Langue

/// Les mots-outils qui distinguent les quatre langues des polycopiés de l'EPFL.
///
/// NaturalLanguage s'appuie sur un modèle statistique ; sans lui, on compte des
/// mots **très** fréquents dans chaque langue. Les mots communs à deux langues
/// (« la », « le », « des ») restent dans les deux listes : c'est leur proportion
/// qui tranche, pas leur présence.
const languageWords: Record<string, readonly string[]> = {
  français: [
    "le", "la", "les", "des", "une", "est", "pour", "que", "qui", "dans", "sur", "avec", "par",
    "pas", "au", "aux", "ce", "cette", "sont", "plus", "montrer", "calculer", "soit", "ensuite",
    "exercice", "série", "on", "alors", "tout", "comme", "mais", "donc",
  ],
  anglais: [
    "the", "and", "of", "to", "is", "in", "that", "with", "for", "this", "be", "are", "as", "by",
    "on", "it", "from", "find", "show", "prove", "compute", "determine", "when", "what", "which",
    "consider", "suppose", "given", "let", "each", "all", "has", "have", "been", "will",
  ],
  allemand: [
    "der", "die", "das", "und", "ist", "nicht", "mit", "für", "auf", "ein", "eine", "den", "dem",
    "des", "zu", "von", "sich", "werden", "aufgabe", "zeigen", "berechnen", "sei", "seien",
    "gilt", "dann", "auch", "als",
  ],
  italien: [
    "il", "lo", "la", "gli", "le", "di", "che", "e", "un", "una", "per", "con", "non", "sono",
    "del", "della", "dei", "nel", "esercizio", "mostrare", "calcolare", "sia", "allora",
    "anche", "come", "ma", "quindi",
  ],
};

/// Les lettres accentuées propres à une langue, quand les mots-outils manquent.
const languageLetters: Record<string, RegExp> = {
  français: /[àâçéèêëîïôùûüÿœ]/gu,
  allemand: /[äöüß]/gu,
  italien: /[àèéìòù]/gu,
};

/// `folding(options: [.diacriticInsensitive, .caseInsensitive])`, en minuscules.
function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
}

/// Le nom français de la langue du document, ou `null` quand elle n'est pas sûre.
///
/// Le contrat de `NLLanguageRecognizer` : ne rien affirmer sous 0,6 de confiance.
export function languageName(text: string): string | null {
  const sample = Array.from(text).slice(0, 4000).join("");
  if (trimAll(sample) === "") return null;
  const folded = fold(sample);
  const words = folded.split(/[^\p{L}]+/u).filter((w) => w !== "");

  const scores = new Map<string, number>();
  for (const language of Object.keys(languageWords)) scores.set(language, 0);
  for (const word of words) {
    for (const [language, set] of Object.entries(languageWords)) {
      if (set.includes(word)) scores.set(language, scores.get(language)! + 1);
    }
  }
  // Un indice typographique : « für », « série », « esercizio » ne se confondent pas.
  for (const [language, pattern] of Object.entries(languageLetters)) {
    const count = (folded.match(pattern) ?? []).length;
    scores.set(language, scores.get(language)! + count * 0.25);
  }

  const ranked = [...scores.entries()].sort((a, b) => b[1] - a[1]);
  const [best, second] = ranked;
  if (!best || best[1] === 0) return null;
  const total = ranked.reduce((sum, [, value]) => sum + value, 0);
  const confidence = total === 0 ? 0 : best[1] / total;
  if (confidence < 0.6) return null;
  // Deux langues à égalité : le modèle ne trancherait pas non plus.
  if (second && second[1] === best[1]) return null;
  return best[0] === "français" || best[0] === "anglais" || best[0] === "allemand" || best[0] === "italien"
    ? best[0]
    : null;
}

/// La ligne d'indice que le modèle lit en tête du texte.
export function languageHint(language: string | null | undefined): string | null {
  return language == null ? null : `[Langue du document : ${language}. Écris tout dans cette langue, ne traduis rien.]`;
}

// MARK: Numéro de série

/// Les mots qui annoncent une **feuille** d'exercices, n'importe où dans une ligne.
const documentPattern = icuRegExp(
  String.raw`(?:^|[^\p{L}])(?:s[ée]ries?(?:[ \t]+d['’][ \t]*exercices)?|exercise[ \t]*(?:set|sheet)|problem[ \t]*(?:set|sheet)|feuille(?:[ \t]+d['’][ \t]*exercices)?|homework|assignment|übungsblatt|übungsserie|blatt)[ \t]*(?:n[°o]\.?[ \t]*|#[ \t]*)?0*(\d{1,2})(?![\d.,])`,
  "gi");

/// Même idée dans un nom de fichier : `serie03`, `Series_4_sol`, `ex3`, `hw2`.
const filenamePattern = icuRegExp(
  String.raw`(?:^|[^a-z])(?:s[ée]ries?|serie|sheet|set|exercises?|exercices?|exos?|ex|hw|homework|td|tp|blatt|assignment|week|semaine|sol(?:ution)?s?|corr(?:ig[ée])?)[ _\-.]*0*(\d{1,2})(?!\d)`,
  "i");

/// Le numéro de série annoncé par le document, ou par son nom de fichier.
///
/// Le document fait foi : le nom d'un fichier se renomme, un en-tête non. On
/// retient le numéro **le plus souvent cité** en tête de page — un rappel
/// « voir série 2 » dans un énoncé ne l'emporte pas sur l'en-tête de chaque page.
export function seriesNumber(lines: PDFLayoutLine[], filename: string | null): SeriesNumberResult | null {
  const fromDocument = seriesNumberInDocument(lines);
  if (fromDocument !== null) return { number: fromDocument, source: "document" };
  if (filename !== null) {
    const fromFilename = seriesNumberInFilename(filename);
    if (fromFilename !== null) return { number: fromFilename, source: "filename" };
  }
  return null;
}

export function seriesNumberInDocument(lines: PDFLayoutLine[]): number | null {
  const votes = new Map<number, number>();
  const firstSeen = new Map<number, number>();
  // Les premières lignes de chaque page portent l'en-tête courant.
  const linesSeenOnPage = new Map<number, number>();
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    const position = linesSeenOnPage.get(line.pageIndex) ?? 0;
    linesSeenOnPage.set(line.pageIndex, position + 1);
    if (!(position < 8 || (line.pageIndex === 0 && position < 25))) continue;
    const text = trimAll(line.text);
    if (text === "") continue;
    for (const match of text.matchAll(documentPattern)) {
      const number = Number(match[1]);
      if (!/^\d+$/.test(match[1]) || !(number >= 1 && number <= 60)) continue;
      // Un en-tête en tête de page compte davantage qu'une mention au fil du texte.
      votes.set(number, (votes.get(number) ?? 0) + (position < 4 ? 3 : 1));
      if (!firstSeen.has(number)) firstSeen.set(number, index);
    }
  }
  let best: { number: number; votes: number; first: number } | null = null;
  for (const [number, count] of votes) {
    const candidate = { number, votes: count, first: firstSeen.get(number) ?? Number.MAX_SAFE_INTEGER };
    if (best === null
      || candidate.votes > best.votes
      || (candidate.votes === best.votes && candidate.first < best.first)) {
      best = candidate;
    }
  }
  return best === null ? null : best.number;
}

/// `NSString.deletingPathExtension`.
function deletingPathExtension(filename: string): string {
  const dot = filename.lastIndexOf(".");
  return dot > 0 ? filename.slice(0, dot) : filename;
}

export function seriesNumberInFilename(filename: string): number | null {
  const base = deletingPathExtension(filename);
  const match = filenamePattern.exec(base);
  if (!match) return null;
  const raw = match[1];
  if (!/^\d+$/.test(raw)) return null;
  const number = Number(raw);
  return number >= 1 && number <= 60 ? number : null;
}

// MARK: Cours

export interface CourseCandidate {
  id: string;
  code: string;
  name: string;
}

/// Le cours que le document désigne, s'il en désigne **un seul**.
///
/// Le code (« CS-250 », « cs250 », « CS 250 ») est cherché dans les premières
/// pages et le nom du fichier ; à défaut, le nom complet du cours. Deux cours
/// cités à égalité : on ne choisit pas, l'écran demande.
export function course(lines: PDFLayoutLine[], filename: string | null, candidates: CourseCandidate[]): string | null {
  if (candidates.length === 0) return null;
  const head = lines.filter((line) => line.pageIndex <= 1).slice(0, 200).map((line) => line.text).join(" ");
  const haystack = ` ${normalize(head + " " + (filename ?? ""))} `;
  const compact = haystack.split(" ").join("");

  const scores = new Map<string, number>();
  for (const candidate of candidates) {
    const code = normalize(candidate.code);
    const codeCompact = code.split(" ").join("");
    // Un code d'au moins une lettre et un chiffre : « CS-250 », pas « ANALYSE ».
    if (codeCompact.length >= 4
      && [...codeCompact].some((c) => /\p{N}/u.test(c))
      && [...codeCompact].some((c) => /\p{L}/u.test(c))
      && (haystack.includes(` ${code} `) || compact.includes(codeCompact))) {
      scores.set(candidate.id, (scores.get(candidate.id) ?? 0) + 10);
    }
    const name = normalize(candidate.name);
    if (name.length >= 6 && haystack.includes(` ${name} `)) {
      scores.set(candidate.id, (scores.get(candidate.id) ?? 0) + 5);
    }
  }
  if (scores.size === 0) return null;
  let best: { id: string; score: number } | null = null;
  for (const [id, score] of scores) {
    if (best === null || score > best.score) best = { id, score };
  }
  if (best === null) return null;
  const ties = [...scores.values()].filter((value) => value === best!.score).length;
  return ties === 1 ? best.id : null;
}

/// Un intitulé de série qui n'est que le nom ou le code du cours n'apprend
/// rien (« Série 4 · Analyse I » dans le cours Analyse I) : on l'efface.
export function seriesTitle(title: string, courseName: string, courseCode: string): string {
  const trimmed = trimAll(title);
  const key = normalize(trimmed);
  if (key === "") return "";
  const redundant = [normalize(courseName), normalize(courseCode), "epfl"].filter((value) => value !== "");
  return redundant.includes(key) ? "" : trimmed;
}

/// Minuscules, sans accents, ponctuation remplacée par des espaces.
export function normalize(text: string): string {
  const folded = text.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
  let mapped = "";
  for (const character of folded) {
    mapped += /\p{L}|\p{N}/u.test(character) ? character : " ";
  }
  return mapped.split(" ").filter((part) => part !== "").join(" ");
}

export const SeriesDocumentInference = {
  languageName,
  languageHint,
  seriesNumber,
  seriesNumberInDocument,
  seriesNumberInFilename,
  course,
  seriesTitle,
  normalize,
};
