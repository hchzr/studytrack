// Port de Polymestre/Domain/SearchEngine.swift : recherche dans tout ce que
// l'app contient. Fonction **pure** : elle reçoit des documents et une requête,
// sans base ni interface — et notamment ce qui ne doit **pas** ressortir.

import { characters, trimWhitespaces } from "./textRepair.ts";
import { localizedStandardCompare } from "../models/util.ts";
import { Plural } from "./plural.ts";

export type SearchKind =
  | "course" | "series" | "exercise" | "theory" | "exam"
  | "session" | "task" | "milestone" | "group";

export const SearchKind = {
  allCases: ["course", "series", "exercise", "theory", "exam", "session", "task", "milestone", "group"] as readonly SearchKind[],

  fromRaw(raw: string | null | undefined): SearchKind | undefined {
    return raw != null && (SearchKind.allCases as readonly string[]).includes(raw) ? (raw as SearchKind) : undefined;
  },

  label(kind: SearchKind): string {
    switch (kind) {
      case "course": return "Cours";
      case "series": return "Séries";
      case "exercise": return "Exercices";
      case "theory": return "Théorie";
      case "exam": return "Évaluations";
      case "session": return "Sessions de travail";
      case "task": return "Tâches";
      case "milestone": return "Vie de l'EPFL";
      case "group": return "Groupes";
    }
  },

  icon(kind: SearchKind): string {
    switch (kind) {
      case "course": return "books.vertical.fill";
      case "series": return "list.number";
      case "exercise": return "checklist";
      case "theory": return "play.rectangle.fill";
      case "exam": return "graduationcap.fill";
      case "session": return "timer";
      case "task": return "checkmark.circle";
      case "milestone": return "building.columns.fill";
      case "group": return "person.3.fill";
    }
  },

  /** Rang d'affichage : plus petit = plus haut. */
  rank(kind: SearchKind): number { return SearchKind.allCases.indexOf(kind); },
};

/** Ce sur quoi porte la correspondance — affiché pour expliquer le résultat. */
export type SearchMatch = "title" | "detail" | "course";

export const SearchMatch = {
  label(match: SearchMatch): string {
    switch (match) {
      case "title": return "intitulé";
      case "detail": return "détail";
      case "course": return "cours";
    }
  },
};

export interface SearchDocumentInit {
  id: string;
  kind: SearchKind;
  /** Ce qui s'affiche en gras dans la liste. */
  title: string;
  /** La ligne secondaire : date, nature, contexte. */
  subtitle?: string;
  /** Tout le texte cherchable en plus du titre, déjà normalisé par le moteur. */
  detail?: string;
  /** Code du cours, pour rattacher le résultat et permettre d'y aller. */
  courseCode?: string | null;
  /** Date, pour trier à égalité de score. */
  date?: Date | null;
}

/** Un document indexable, indépendant de la persistance. */
export class SearchDocument {
  id: string;
  kind: SearchKind;
  title: string;
  subtitle: string;
  detail: string;
  courseCode: string | null;
  date: Date | null;

  constructor(o: SearchDocumentInit) {
    this.id = o.id;
    this.kind = o.kind;
    this.title = o.title;
    this.subtitle = o.subtitle ?? "";
    this.detail = o.detail ?? "";
    this.courseCode = o.courseCode ?? null;
    this.date = o.date ?? null;
  }
}

/** Un résultat, avec de quoi expliquer pourquoi il sort. */
export interface SearchHitInit {
  document: SearchDocument;
  score: number;
  match: SearchMatch;
}

export class SearchHit {
  document: SearchDocument;
  score: number;
  match: SearchMatch;

  constructor(o: SearchHitInit) {
    this.document = o.document;
    this.score = o.score;
    this.match = o.match;
  }

  get id(): string { return this.document.id; }
  get kind(): SearchKind { return this.document.kind; }
}

export const SearchEngine = {
  /** Nombre maximal de résultats rendus. Au-delà, la liste cesse d'aider. */
  limit: 60,

  /** Normalise pour comparer : sans accents, sans casse, ponctuation réduite. */
  normalize(text: string): string {
    const folded = text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
    return characters(folded)
      .map((char) => (/^\p{L}$/u.test(char) || /^\p{N}$/u.test(char) ? char : " "))
      .join("")
      .split(" ")
      .filter((word) => word !== "")
      .join(" ");
  },

  tokens(query: string): string[] {
    return SearchEngine.normalize(query).split(" ").filter((word) => word !== "");
  },

  /** Cherche, tous types confondus ; tous les mots de la requête doivent correspondre. */
  search(query: string, documents: SearchDocument[]): SearchHit[] {
    const words = SearchEngine.tokens(query);
    if (words.length === 0) return [];
    const hits: SearchHit[] = [];
    for (const document of documents) {
      const scored = SearchEngine.score(document, words, SearchEngine.normalize(query));
      if (scored !== null) hits.push(scored);
    }
    return hits.sort((lhs, rhs) => {
      if (lhs.score !== rhs.score) return rhs.score - lhs.score;
      if (lhs.kind !== rhs.kind) return SearchKind.rank(lhs.kind) - SearchKind.rank(rhs.kind);
      // À score égal, le plus récent d'abord ; sinon l'ordre alphabétique.
      const left = lhs.document.date;
      const right = rhs.document.date;
      if (left !== null && right !== null && left.getTime() !== right.getTime()) {
        return right.getTime() - left.getTime();
      }
      return localizedStandardCompare(lhs.document.title, rhs.document.title);
    }).slice(0, SearchEngine.limit);
  },

  /** Note un document, ou `null` s'il ne correspond pas à **tous** les mots. */
  score(document: SearchDocument, words: string[], query: string): SearchHit | null {
    const title = SearchEngine.normalize(document.title);
    const detail = SearchEngine.normalize(document.detail);
    const subtitle = SearchEngine.normalize(document.subtitle);
    const course = SearchEngine.normalize(document.courseCode ?? "");
    // Formes **collées**. Personne ne tape « CS-250 » : on tape « cs250 ».
    const titleCompact = title.split(" ").join("");
    const courseCompact = course.split(" ").join("");

    let total = 0;
    let best: SearchMatch = "detail";
    let bestScore = 0;

    for (const word of words) {
      let wordScore: number;
      let where: SearchMatch;
      if (title === query || titleCompact === query) {
        wordScore = 120; where = "title";
      } else if (title.startsWith(word) || titleCompact.startsWith(word)) {
        wordScore = 90; where = "title";
      } else if (title.split(" ").some((part) => part.startsWith(word))) {
        wordScore = 70; where = "title";
      } else if (title.includes(word) || titleCompact.includes(word)) {
        wordScore = 45; where = "title";
      } else if (course.includes(word) || courseCompact.includes(word)) {
        // Le code du cours est presque un intitulé : « cs250 » doit trouver ses exercices.
        wordScore = 40; where = "course";
      } else if (subtitle.includes(word)) {
        wordScore = 25; where = "detail";
      } else if (detail.includes(word)) {
        wordScore = 15; where = "detail";
      } else {
        return null;
      }
      total += wordScore;
      if (wordScore > bestScore) {
        bestScore = wordScore;
        best = where;
      }
    }

    // Un titre qui commence par la requête entière passe devant.
    if (title.startsWith(query)) total += 25;
    // Un intitulé court qui contient la requête vaut mieux qu'un long.
    if (title.includes(query) && characters(document.title).length <= characters(query).length + 12) total += 10;

    return new SearchHit({ document, score: total, match: best });
  },

  /** Groupe les résultats par nature, dans l'ordre d'affichage. */
  grouped(hits: SearchHit[]): { kind: SearchKind; hits: SearchHit[] }[] {
    const buckets = new Map<SearchKind, SearchHit[]>();
    for (const hit of hits) {
      const list = buckets.get(hit.kind) ?? [];
      list.push(hit);
      buckets.set(hit.kind, list);
    }
    const result: { kind: SearchKind; hits: SearchHit[] }[] = [];
    for (const kind of SearchKind.allCases) {
      const items = buckets.get(kind);
      if (items !== undefined && items.length !== 0) result.push({ kind, hits: items });
    }
    return result;
  },

  /** Une phrase qui dit ce qui a été trouvé, ou pourquoi rien ne l'a été. */
  summary(hits: SearchHit[], query: string): string {
    if (SearchEngine.tokens(query).length === 0) {
      return "Tape un code de cours, un titre d'exercice, un mot d'un résumé…";
    }
    if (hits.length === 0) {
      return `Rien trouvé pour « ${trimWhitespaces(query)} ».`;
    }
    const parts = SearchEngine.grouped(hits).map((group) => `${group.hits.length} ${SearchKind.label(group.kind).toLowerCase()}`);
    return `${Plural.count(hits.length, `${hits.length} résultat`, `${hits.length} résultats`)} · ` + parts.join(" · ");
  },
};
