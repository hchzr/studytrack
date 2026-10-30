// Port de StudyTrack/Domain/TutorFramework.swift : ce que Claude doit savoir à
// **chaque** tour, et la façon de répondre. Une conversation de série dure des
// jours ; les défauts vus en vrai venaient d'un état absent. Tout est pur.

import { SeriesReview } from "./seriesReview.ts";

/** Les bornes du contexte ajouté par l'app (ClaudeTutor les retire à l'affichage). */
export const contextOpen = "[StudyTrack]";
export const contextClose = "[/StudyTrack]";

export type TutorMarked =
  | { kind: "notMarked" }
  | { kind: "done" }
  | { kind: "corrected"; word: string };

export const TutorMarked = {
  notMarked: { kind: "notMarked" } as TutorMarked,
  done: { kind: "done" } as TutorMarked,
  corrected(word: string): TutorMarked { return { kind: "corrected", word }; },
};

export type TutorOrigin =
  | { kind: "series"; title: string }
  | { kind: "copy"; notebook: string; pages: number[]; total: number; requested: boolean }
  | { kind: "photo" }
  | { kind: "file"; name: string };

export type TutorNext =
  | { kind: "hint"; level: number }
  | { kind: "tryIt" }
  | { kind: "check" }
  | { kind: "nextStep" }
  | { kind: "explain" }
  | { kind: "solution" };

export const TutorNext = {
  hint(level: number): TutorNext { return { kind: "hint", level }; },
  tryIt: { kind: "tryIt" } as TutorNext,
  check: { kind: "check" } as TutorNext,
  nextStep: { kind: "nextStep" } as TutorNext,
  explain: { kind: "explain" } as TutorNext,
  solution: { kind: "solution" } as TutorNext,
};

/** Ta copie : le cahier, et les pages que cette conversation a déjà reçues. */
export interface TutorCopy {
  notebook: string;
  pagesSeen: number[];
  total: number;
}

export interface TutorStateInit {
  /** « Série 6 · Exercice 6.3 » (`null` : pas d'exercice choisi). */
  exercise?: string | null;
  marked?: TutorMarked;
  hintLevel?: number;
  questionsDone?: number;
  questionsTotal?: number;
  copy?: TutorCopy | null;
  tutor?: boolean;
}

/** Ce qui est vrai de l'exercice, à ce message. */
export class TutorState {
  exercise: string | null;
  /** Où l'exercice en est dans l'app : le mot est choisi pour ne pas dire « pas essayé ». */
  marked: TutorMarked;
  /** Le niveau d'indice le plus haut déjà donné (0 : aucun). */
  hintLevel: number;
  questionsDone: number;
  questionsTotal: number;
  copy: TutorCopy | null;
  tutor: boolean;

  constructor(o: TutorStateInit = {}) {
    this.exercise = o.exercise ?? null;
    this.marked = o.marked ?? TutorMarked.notMarked;
    this.hintLevel = o.hintLevel ?? 0;
    this.questionsDone = o.questionsDone ?? 0;
    this.questionsTotal = o.questionsTotal ?? 0;
    this.copy = o.copy ?? null;
    this.tutor = o.tutor ?? true;
  }
}

function sameNext(a: TutorNext, b: TutorNext): boolean {
  return a.kind === b.kind && (a.kind !== "hint" || a.level === (b as { level: number }).level);
}

export const TutorFramework = {
  contract: `Façon de répondre :
- Réponds à ce qui est demandé, rien d'autre. En mode tuteur, une centaine de mots au plus. Ne dresse jamais l'inventaire d'une pièce jointe, ni un « ordre suggéré », ni un rappel d'autres exercices, sauf si on te le demande.
- Finis par une seule question, ou une seule chose à faire. Jamais deux.
- Ce que l'étudiant·e t'envoie est à elle ou lui : sa copie GoodNotes (son écriture : ses tentatives et ses notes prises en séance), ses photos, ses captures. Ce n'est pas un corrigé, même si une page ressemble à une rédaction complète. Ne refuse jamais de lire une page qu'on te montre ou dont on te donne le numéro : dis ce que tu y vois. Si une page contient la solution entière de l'exercice en cours, demande une fois : « Tu veux que j'explique cette rédaction, ou tu préfères la refaire sans ? » — sans sermon.
- « pas encore marqué fait » dans l'app veut dire « pas coché », pas « pas essayé » : regarde la copie avant de dire que quelque chose n'a pas été tenté.
- Les numéros de page sont ceux du cahier. Le PDF joint peut ne contenir que certaines pages ; le message dit lesquelles.
- À chaque message, l'app te donne l'état entre [StudyTrack] et [/StudyTrack] : fie-toi à lui, pas à ta mémoire.`,

  tutor: `Mode tuteur. Ne donne pas la solution d'emblée.
Échelle d'indices : 1 orientation (où regarder, quelle question se poser) · 2 outil (la définition, le théorème ou la propriété à utiliser) · 3 amorce (le premier geste concret, sans finir) · 4 solution rédigée.
- L'état te dit le niveau déjà donné. Si l'étudiant·e redemande de l'aide, dit qu'elle ou il bloque, ou écrit seulement « et maintenant ? », sans nouvelle tentative : donne le niveau **suivant**. Ne répète jamais un indice, ne renvoie pas à l'indice précédent.
- Si elle ou il montre une tentative (texte, photo, copie) : dis ce qui est juste, désigne la **première** erreur seulement, sans la corriger, et pose une question qui la fait voir.
- Une question de compréhension (« je ne comprends pas l'idée ») appelle une explication de l'idée, avec l'intuition, pas un nouvel indice sur la preuve.
- La solution complète seulement si on la demande explicitement.`,

  explain: `Mode explications. Explique clairement ce qui est demandé, avec l'intuition et un exemple simple, puis le lien avec l'exercice en cours. Donne des solutions complètes si on les demande.`,

  State: TutorState,

  markedWords(marked: TutorMarked): string {
    switch (marked.kind) {
      case "notMarked": return "pas encore marqué fait dans l'app (ça ne dit pas si j'ai essayé)";
      case "done": return "marqué fait, pas encore corrigé";
      case "corrected": return "corrigé : " + marked.word;
    }
  },

  levelName(level: number): string {
    switch (level) {
      case 1: return "orientation";
      case 2: return "outil";
      case 3: return "amorce";
      case 4: return "solution";
      default: return "aucun";
    }
  },

  /** Ce que la pièce jointe est, en une phrase — pour Claude. */
  describe(origin: TutorOrigin): string {
    switch (origin.kind) {
      case "series":
        return `« ${origin.title} » : l'énoncé officiel de la série (PDF).`;
      case "copy": {
        const list = TutorFramework.ranges(origin.pages);
        let line = `ma copie : mon cahier GoodNotes « ${origin.notebook} » — c'est mon écriture (mes tentatives et mes notes de séance), pas un corrigé. Pages du cahier jointes : ${list} sur ${origin.total}`;
        if (origin.requested) line += " (celles que je te demande de regarder)";
        if (origin.pages.length > 1 || origin.pages[0] !== 1) {
          const first = [...origin.pages].sort((a, b) => a - b)[0] ?? 1;
          line += `. Le PDF joint ne contient que ces pages, dans l'ordre : sa 1re page est la page ${first} du cahier`;
        }
        return line + ".";
      }
      case "photo":
        return "une photo ou une capture de mon travail.";
      case "file":
        return `« ${origin.name} ».`;
    }
  },

  /** Le nom court d'une pièce jointe dans la bulle de l'étudiant·e. */
  chip(origin: TutorOrigin): string {
    switch (origin.kind) {
      case "series": return origin.title;
      case "copy":
        return origin.pages.length === 1 ? `Ma copie · p. ${origin.pages[0]}` : `Ma copie · p. ${TutorFramework.ranges(origin.pages)}`;
      case "photo": return "Photo";
      case "file": return origin.name;
    }
  },

  /** L'état tel que Claude le reçoit : court, exact, dans le bloc que l'app retire à l'affichage. */
  card(state: TutorState, attached: TutorOrigin[] = []): string {
    const lines: string[] = [];
    if (state.exercise !== null) {
      lines.push(`État : ${state.exercise} — ${TutorFramework.markedWords(state.marked)}`);
      if (state.hintLevel > 0) {
        const next = Math.min(state.hintLevel + 1, 4);
        lines.push(`Indices déjà donnés : jusqu'au niveau ${state.hintLevel}/4 (${TutorFramework.levelName(state.hintLevel)}).`
          + (state.tutor && state.hintLevel < 4
            ? ` Si je redemande de l'aide sans nouvelle tentative : niveau ${next} (${TutorFramework.levelName(next)}).` : ""));
      } else if (state.tutor) {
        lines.push("Indices déjà donnés : aucun. Un premier indice est de niveau 1 (orientation).");
      }
      if (state.questionsTotal > 0) lines.push(`Questions cochées : ${state.questionsDone}/${state.questionsTotal}.`);
    } else {
      lines.push("État : pas d'exercice choisi.");
    }
    if (state.copy !== null) {
      const seen = state.copy.pagesSeen.length === 0
        ? "aucune page reçue pour l'instant"
        : `pages que tu as déjà reçues : ${TutorFramework.ranges(state.copy.pagesSeen)} sur ${state.copy.total}`;
      lines.push(`Ma copie : cahier GoodNotes « ${state.copy.notebook} » (mon écriture) ; ${seen}.`);
    }
    if (attached.length !== 0) {
      lines.push("En pièce jointe, cette fois : " + attached.map((origin) => TutorFramework.describe(origin)).join(" "));
    }
    lines.push(`Façon de répondre : ${state.tutor ? "tuteur" : "explications"}.`);
    return contextOpen + "\n" + lines.join("\n") + "\n" + contextClose + "\n\n";
  },

  /** L'exercice d'un message déjà envoyé, relu dans son état. */
  exercise(inSent: string): string | null {
    for (const line of inSent.split("\n")) {
      if (!line.startsWith("État : ")) continue;
      const body = line.slice("État : ".length);
      const exercise = body.split(" — ")[0];
      if (exercise.startsWith("pas d'exercice")) return null;
      return exercise;
    }
    return null;
  },

  /** « Série 6 · Exercice 6.3 » → « Exercice 6.3 ». */
  shortExercise(label: string): string {
    const parts = label.split(" · ");
    return parts[parts.length - 1] ?? label;
  },

  /** L'indice demandé par le bouton : un cran au-dessus du dernier donné (au plus 3). */
  hintPrompt(after: number): string {
    switch (Math.min(Math.max(after, 0) + 1, 3)) {
      case 1: return "Donne-moi un indice de niveau 1 (orientation) : où regarder, sans l'outil ni la solution.";
      case 2: return "Donne-moi l'indice de niveau 2 (l'outil) : la propriété ou le théorème à utiliser, sans l'appliquer à ma place.";
      default: return "Donne-moi l'indice de niveau 3 (l'amorce) : le premier geste concret, sans finir.";
    }
  },

  /** Ce qu'on propose après une réponse, selon l'état. */
  suggestions(state: TutorState, replyAsksQuestion: boolean): TutorNext[] {
    if (state.exercise === null) return [TutorNext.explain];
    const check: TutorNext[] = state.copy === null ? [] : [TutorNext.check];
    const level = state.hintLevel;
    let list: TutorNext[];
    if (!state.tutor) {
      list = [TutorNext.explain, ...check, TutorNext.nextStep];
    } else if (replyAsksQuestion && level >= 1) {
      list = [TutorNext.tryIt, ...(level < 3 ? [TutorNext.hint(level + 1)] : [TutorNext.solution]), ...check];
    } else {
      switch (level) {
        case 0: list = [TutorNext.hint(1), ...check, TutorNext.explain]; break;
        case 1: case 2: list = [TutorNext.hint(level + 1), ...check, TutorNext.explain]; break;
        case 3: list = [...check, TutorNext.solution, TutorNext.explain]; break;
        default: list = [...check, TutorNext.nextStep]; break;
      }
    }
    if (state.marked.kind !== "notMarked" && !list.some((next) => sameNext(next, TutorNext.nextStep))) {
      list.push(TutorNext.nextStep);
    }
    return list.slice(0, 3);
  },

  /** Une réponse qui se termine sur une question : c'est à l'étudiant·e de jouer. */
  asksQuestion(reply: string): boolean {
    const tail = SeriesReview.withoutBlocks(reply);
    return tail.endsWith("?") || tail.slice(-3).includes("?");
  },

  /** Les pages de **la copie** demandées : rien si le message parle de la série ou du polycopié. */
  copyPageRequest(inText: string): number[] {
    const folded = inText.toLowerCase().normalize("NFD").replace(/\p{M}/gu, "");
    for (const word of ["serie", "enonce", "polycopie", "poly", "cours", "corrige", "slides", "diapo"]) {
      if (folded.includes(word)) return [];
    }
    return TutorFramework.pageRequest(inText);
  },

  /** Les numéros de page demandés (« page 4 », « pages 3-5 », « p. 4 et 5 », « p4 »), au plus 4. */
  pageRequest(inText: string): number[] {
    const pattern = /\b(?:pages?|p)\.?\s*(\d{1,3})(?:\s*(?:-|–|à|a)\s*(\d{1,3})|\s*(?:,|et)\s*(\d{1,3}))?/giu;
    const found: number[] = [];
    for (const match of inText.matchAll(pattern)) {
      const number = (index: number): number | null => {
        const text = match[index];
        return text === undefined ? null : Number(text);
      };
      const first = number(1);
      if (first === null || first <= 0) continue;
      const upper = number(2);
      if (upper !== null && upper >= first && upper - first < 4) {
        for (let page = first; page <= upper; page++) found.push(page);
      } else {
        found.push(first);
        const other = number(3);
        if (other !== null && other > 0) found.push(other);
      }
    }
    return [...new Set(found)].sort((a, b) => a - b).slice(0, 4);
  },

  /** 3, 4, 5, 9 → « 3–5, 9 ». */
  ranges(pages: number[]): string {
    const parts: string[] = [];
    let start: number | null = null;
    let last: number | null = null;
    for (const page of [...new Set(pages)].sort((a, b) => a - b)) {
      if (last !== null && page === last + 1) { last = page; continue; }
      if (start !== null && last !== null) parts.push(start === last ? `${start}` : `${start}–${last}`);
      start = page;
      last = page;
    }
    if (start !== null && last !== null) parts.push(start === last ? `${start}` : `${start}–${last}`);
    return parts.join(", ");
  },
};

