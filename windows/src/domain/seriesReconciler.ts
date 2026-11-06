// Retrouve, dans une nouvelle lecture d'un énoncé, les exercices déjà
// enregistrés — **par leur contenu, pas par leur numéro**
// (Polymestre/Domain/SeriesReconciler.swift).
//
// La série 6 d'AICC a été révisée après l'import : un « Exercise 1 (repris de la
// semaine 5) » ajouté en tête, trois exercices retirés. Tout s'était décalé
// d'un cran : la « 6.1 » de l'app était l'« Exercise 2 » du PDF, et Claude,
// qui lisait le PDF, ne parlait plus du même exercice. Fusionner par numéro
// aurait mis l'avancement du télescopage sur l'exercice des fonctions
// génératrices.
//
// Un enseignant ajoute et retire des exercices, il les réordonne rarement :
// l'appariement est un **alignement qui garde l'ordre** (comme un diff), qui
// maximise la ressemblance des textes (titre et énoncé, mots communs). Le
// numéro ne sert qu'à départager.

import { characters } from "./textRepair.ts";

export interface ReconcilerItem {
  number: string;
  title: string;
  statement: string;
}

/// En dessous, deux exercices ne sont pas « le même » (sauf même numéro et
/// textes vides).
export const threshold = 0.18;

/// `result[i]` : l'indice dans `existing` de l'exercice qui devient le
/// i-ième de `incoming`, ou `null` (un nouvel exercice).
export function match(existing: ReconcilerItem[], incoming: ReconcilerItem[]): (number | null)[] {
  const n = existing.length;
  const m = incoming.length;
  if (n === 0 || m === 0) return Array.from({ length: m }, () => null);
  const oldWords = existing.map(words);
  const newWords = incoming.map(words);
  const score: number[][] = Array.from({ length: n }, () => Array.from({ length: m }, () => 0));
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < m; j++) {
      score[i][j] = similarity(oldWords[i], newWords[j], minor(existing[i].number) === minor(incoming[j].number));
    }
  }
  // Alignement : best[i][j] = meilleur total avec les i premiers anciens
  // et les j premiers nouveaux.
  const best: number[][] = Array.from({ length: n + 1 }, () => Array.from({ length: m + 1 }, () => 0));
  for (let i = 1; i <= n; i++) {
    for (let j = 1; j <= m; j++) {
      let value = Math.max(best[i - 1][j], best[i][j - 1]);
      if (score[i - 1][j - 1] >= threshold) value = Math.max(value, best[i - 1][j - 1] + score[i - 1][j - 1]);
      best[i][j] = value;
    }
  }
  const result: (number | null)[] = Array.from({ length: m }, () => null);
  let i = n;
  let j = m;
  while (i > 0 && j > 0) {
    const s = score[i - 1][j - 1];
    if (s >= threshold && Math.abs(best[i][j] - (best[i - 1][j - 1] + s)) < 1e-9) {
      result[j - 1] = i - 1;
      i -= 1;
      j -= 1;
    } else if (best[i - 1][j] >= best[i][j - 1]) {
      i -= 1;
    } else {
      j -= 1;
    }
  }
  return result;
}

/// Ressemblance de deux exercices (0 → 1) : la part de mots en commun
/// (Dice), plus un petit bonus pour le même numéro.
export function similarity(a: Set<string>, b: Set<string>, sameNumber: boolean): number {
  const bonus = sameNumber ? 0.05 : 0;
  if (a.size === 0 || b.size === 0) return sameNumber ? threshold : 0;
  let common = 0;
  for (const word of a) if (b.has(word)) common += 1;
  return 2 * common / (a.size + b.size) + bonus;
}

/// Les mots qui portent le sens : minuscules, sans accents ni formules,
/// au moins trois lettres, sans les mots outils des consignes.
export function words(item: ReconcilerItem): Set<string> {
  const text = (item.title + " " + item.statement)
    .normalize("NFD").replace(/\p{M}+/gu, "")
    .toLowerCase();
  const raw = text.split(/[^\p{L}]+/u).filter((word) => word !== "");
  return new Set(raw
    .filter((word) => characters(word).length >= 3 && !stopWords.has(word))
    .map(stem));
}

/// « algorithms » et « algorithm » sont le même mot.
function stem(word: string): string {
  return characters(word).length > 4 && word.endsWith("s") ? word.slice(0, -1) : word;
}

function minor(number: string): string {
  const parts = number.split(/[.-]/).filter((part) => part !== "");
  return parts[parts.length - 1] ?? number;
}

const stopWords = new Set([
  "the", "and", "for", "that", "this", "with", "from", "are", "each", "following", "given", "use", "using",
  "find", "show", "determine", "which", "what", "how", "its", "their", "these", "those", "into", "when",
  "exercise", "exercice", "les", "des", "une", "pour", "que", "qui", "dans", "est", "sur", "avec", "par",
  "montrer", "trouver", "determiner", "suivant", "suivante", "suivants", "suivantes", "soit", "the",
  "not", "all", "any", "can", "you", "your", "his", "her", "has", "have", "been", "will",
]);

export const SeriesReconciler = { threshold, match, similarity, words };
