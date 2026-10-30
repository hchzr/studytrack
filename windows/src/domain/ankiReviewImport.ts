// Le temps passé dans Anki, relevé sans rien demander (StudyTrack/Domain/AnkiReviewImport.swift).
//
// `Int64` devient un `number` : les identifiants de révision sont des millisecondes depuis
// 1970 (environ 1,7e12), très en deçà de 2^53.

import { characters } from "./textRepair.ts";

/// Une révision lue dans l'historique d'Anki (`revlog`).
export interface AnkiReview {
  /// Identifiant de la révision = son instant, en millisecondes depuis 1970.
  id: number;
  /// Temps passé sur la carte, en millisecondes (Anki le plafonne à 60 s).
  durationMs: number;
  deck: string;
}

/// `AnkiReview.date`.
export function ankiReviewDate(review: AnkiReview): Date {
  return new Date(review.id);
}

/// Une session Anki reconstituée, prête à devenir une `StudySession`.
export interface AnkiSessionDraft {
  deck: string;
  start: Date;
  seconds: number;
  reviewCount: number;
  /// Stable d'un import à l'autre : la première révision de la session.
  key: string;
}

/// Un cours tel que l'import le compare à un paquet.
export interface AnkiCourseKey {
  code: string;
  shortName: string;
  name: string;
}

const depth = (deck: string): number => deck.split("::").length;

/// `folding(options: [.caseInsensitive, .diacriticInsensitive])`, puis les séparateurs
/// ramenés à une espace simple.
function normalize(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().normalize("NFC")
    .split("-").join(" ")
    .split("_").join(" ")
    // `CharacterSet.whitespaces` : espaces, tabulations et séparateurs d'espace Unicode.
    .split(/[\p{Zs}\t]+/u).filter((part) => part !== "").join(" ");
}

/// Le temps passé dans Anki, relevé **sans rien demander** à l'étudiant·e.
///
/// Anki ne connaît pas de « sessions » : il note chaque carte révisée, avec le
/// temps passé dessus. On les regroupe donc : deux révisions d'un même paquet
/// séparées de moins de `gap` appartiennent à la même session. Le temps retenu
/// est la **somme des temps de réponse**, pas l'écart entre la première et la
/// dernière carte — une pause café au milieu d'un paquet ne compte pas.
export const AnkiReviewImport = {
  gap: 5 * 60,
  /// En dessous, ce n'est pas une session : une carte révisée en passant.
  minimumSeconds: 60,

  /// Regroupe des révisions en sessions, paquet par paquet.
  ///
  /// Une révision présente dans deux paquets (un paquet parent et son sous-
  /// paquet renvoient la même carte) n'est comptée qu'une fois : on garde le
  /// paquet le plus précis, celui qui a le plus de niveaux `::`.
  sessions(reviews: AnkiReview[]): AnkiSessionDraft[] {
    const byID = new Map<number, AnkiReview>();
    for (const review of reviews) {
      const existing = byID.get(review.id);
      if (existing && depth(existing.deck) >= depth(review.deck)) continue;
      byID.set(review.id, review);
    }
    const grouped = new Map<string, AnkiReview[]>();
    for (const review of byID.values()) {
      const list = grouped.get(review.deck);
      if (list) list.push(review);
      else grouped.set(review.deck, [review]);
    }
    const result: AnkiSessionDraft[] = [];
    for (const [deck, items] of grouped) {
      const sorted = [...items].sort((a, b) => a.id - b.id);
      let current: AnkiReview[] = [];
      const flush = () => {
        const first = current[0];
        if (!first) return;
        const seconds = Math.trunc(current.reduce((total, r) => total + r.durationMs, 0) / 1000);
        if (seconds >= AnkiReviewImport.minimumSeconds) {
          result.push({
            deck,
            start: ankiReviewDate(first),
            seconds,
            reviewCount: current.length,
            key: `anki:${deck}:${first.id}`,
          });
        }
        current = [];
      };
      for (const review of sorted) {
        const last = current[current.length - 1];
        if (last && (review.id - last.id) / 1000 > AnkiReviewImport.gap) flush();
        current.push(review);
      }
      flush();
    }
    return result.sort((a, b) => a.start.getTime() - b.start.getTime());
  },

  /// Le cours d'un paquet, d'après son nom : « EPFL::MATH-101 Analyse I »,
  /// « Ana I », « Algorithms ». Le code officiel, l'abréviation ou le nom
  /// suffisent ; en cas de doute, aucun cours — le temps reste compté, étiqueté
  /// Anki, sans être attribué au hasard.
  courseIndex(deck: string, courses: AnkiCourseKey[]): number | null {
    const parts = deck.split("::").map(normalize).reverse();
    for (const part of parts) {
      const matches: number[] = [];
      courses.forEach((course, index) => {
        const keys = [course.code, course.shortName, course.name].map(normalize).filter((key) => characters(key).length >= 3);
        if (keys.some((key) => part === key || part.includes(key))) matches.push(index);
      });
      if (matches.length === 1) return matches[0];
    }
    return null;
  },
};
