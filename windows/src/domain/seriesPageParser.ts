// Lit une page de série publiée en HTML par un site de cours
// (StudyTrack/Domain/SeriesPageParser.swift).
//
// CS-107 (Introduction à la programmation) publie chaque série sur
// `proginsc.epfl.ch` : une page par série, avec pour chaque exercice son
// numéro (« 3.4 »), son titre, son niveau (« Niv. 2 »), un résumé d'une ligne,
// l'énoncé et le corrigé. Tout y est structuré : pas besoin de PDF ni d'IA.

import { BotafogoParser, type ContentExerciseDraft } from "./courseContentImport.ts";

export interface SeriesPageExercise extends ContentExerciseDraft {}

export interface SeriesPage {
  exercises: SeriesPageExercise[];
  /// « Tous les exercices sur une page » : énoncé et corrigé complets.
  statementURL: string;
  solutionURL: string;
}

/// Un exercice prêt à écrire, avec les valeurs par défaut de `ContentExerciseDraft`.
function makeExercise(number: string): SeriesPageExercise {
  return {
    number,
    title: "",
    statement: "",
    hint: "",
    solution: "",
    url: "",
    isBonus: false,
    questions: [],
  };
}

/// `capture` : premier match du motif, groupe 1 (`.` traverse les lignes).
function capture(text: string, pattern: string): string | null {
  const regex = new RegExp(pattern, "s");
  const match = regex.exec(text);
  return match && match[1] !== undefined ? match[1] : null;
}

/// Balises retirées, entités décodées, espaces normalisés.
export function clean(html: string): string {
  let text = html.replace(/<[^>]+>/g, "");
  const entities: [string, string][] = [
    ["&eacute;", "é"], ["&egrave;", "è"], ["&ecirc;", "ê"], ["&agrave;", "à"], ["&acirc;", "â"],
    ["&ocirc;", "ô"], ["&icirc;", "î"], ["&ucirc;", "û"], ["&ugrave;", "ù"], ["&ccedil;", "ç"],
    ["&Eacute;", "É"], ["&euml;", "ë"], ["&iuml;", "ï"], ["&nbsp;", " "], ["&laquo;", "«"], ["&raquo;", "»"],
    ["&rsquo;", "'"], ["&lsquo;", "'"], ["&hellip;", "…"], ["&oelig;", "œ"],
  ];
  for (const [entity, value] of entities) text = text.split(entity).join(value);
  text = BotafogoParser.decode(text);
  return text.split(/[\s\u{0085}]+/u).filter((part) => part !== "").join(" ");
}

/// Reconnaît une page de série de proginsc (ou de même gabarit).
export function parseProginsc(html: string, baseURL: URL): SeriesPage | null {
  const marker = new RegExp(String.raw`<font size="\+1">\s*(\d+\.\d+)\s*</font>`, "g");
  const matches = [...html.matchAll(marker)];
  const exercises: SeriesPageExercise[] = [];
  // Un exercice va de son numéro jusqu'au numéro suivant.
  matches.forEach((match, position) => {
    const start = match.index;
    if (start === undefined || match[1] === undefined) return;
    const next = matches[position + 1];
    const end = next?.index ?? html.length;
    const block = html.slice(start, end);
    const number = match[1];
    const task = capture(block, String.raw`<a href="([^"]*task\.html)">`);
    const title = capture(block, String.raw`<a href="[^"]*task\.html">([^<]+)</a>`);
    const level = capture(block, String.raw`Niv\.\s*(\d)`);
    const summary = capture(block, String.raw`<div align="justify">(.*?)</div>`);
    const exercise = makeExercise(number);
    exercise.title = title === null ? "" : clean(title);
    exercise.statement = [
      summary === null || clean(summary) === "" ? null : clean(summary),
      level === null ? null : `Niveau ${level}`,
    ].filter((part): part is string => part !== null).join(" · ");
    exercise.url = task === null ? "" : resolve(task, baseURL);
    if (!exercises.some((item) => item.number === number)) exercises.push(exercise);
  });
  if (exercises.length === 0) return null;
  const statement = capture(html, String.raw`href="([^"]*serie_print\.html)"`);
  const solution = capture(html, String.raw`href="([^"]*solution_print\.html)"`);
  return {
    exercises,
    statementURL: statement === null ? baseURL.toString() : resolve(statement, baseURL),
    solutionURL: solution === null ? "" : resolve(solution, baseURL),
  };
}

/// `URL(string:relativeTo:)?.absoluteString` ; l'adresse de base en repli.
function resolve(href: string, baseURL: URL): string {
  try {
    return new URL(href, baseURL).toString();
  } catch {
    return href;
  }
}

export const SeriesPageParser = { parseProginsc, clean };
