// Port de StudyTrack/Domain/RevisionSheet.swift : la fiche de révision d'un
// cours, chapitre par chapitre — définitions, théorèmes, formules, méthodes,
// pièges. Deux origines, une seule forme : le polycopié (énoncés tels quels) ou
// le modèle. La même liste sert à « À savoir » dans une série (`relevant`).

import { MathMarkup } from "./mathMarkup.ts";
import { BotafogoPage, type BotafogoBlock, type BotafogoTheoremKind } from "./botafogoPage.ts";
import { characters, trimWhitespacesAndNewlines } from "./textRepair.ts";
import { StudyLinkKey } from "./studyLinkKey.ts";

// MARK: - La fiche

export type RevisionOrigin = "handout" | "ai";

export type RevisionEntryKind =
  | "definition" | "theorem" | "proposition" | "lemma" | "corollary"
  | "formula" | "method" | "pitfall" | "example" | "remark";

export const RevisionEntryKind = {
  allCases: [
    "definition", "theorem", "proposition", "lemma", "corollary",
    "formula", "method", "pitfall", "example", "remark",
  ] as readonly RevisionEntryKind[],

  fromRaw(raw: string | null | undefined): RevisionEntryKind | undefined {
    return raw != null && (RevisionEntryKind.allCases as readonly string[]).includes(raw)
      ? (raw as RevisionEntryKind) : undefined;
  },

  label(kind: RevisionEntryKind): string {
    switch (kind) {
      case "definition": return "Définition";
      case "theorem": return "Théorème";
      case "proposition": return "Proposition";
      case "lemma": return "Lemme";
      case "corollary": return "Corollaire";
      case "formula": return "Formule";
      case "method": return "Méthode";
      case "pitfall": return "Piège";
      case "example": return "Exemple";
      case "remark": return "Remarque";
    }
  },

  icon(kind: RevisionEntryKind): string {
    switch (kind) {
      case "definition": return "character.book.closed";
      case "theorem": case "proposition": case "lemma": case "corollary": return "seal";
      case "formula": return "function";
      case "method": return "list.bullet.clipboard";
      case "pitfall": return "exclamationmark.triangle";
      case "example": return "lightbulb";
      case "remark": return "text.bubble";
    }
  },

  /** Ce qu'un modèle écrit, ramené à un genre connu. */
  parse(raw: string): RevisionEntryKind {
    const value = fold(raw);
    const exact = RevisionEntryKind.fromRaw(value);
    if (exact) return exact;
    if (value.startsWith("def")) return "definition";
    if (value.startsWith("theo") || value.startsWith("thm")) return "theorem";
    if (value.startsWith("prop")) return "proposition";
    if (value.startsWith("lem")) return "lemma";
    if (value.startsWith("cor")) return "corollary";
    if (value.startsWith("form")) return "formula";
    if (value.startsWith("meth") || value.includes("method") || value.includes("techni")) return "method";
    if (value.startsWith("pi") || value.includes("erreur") || value.includes("pitfall") || value.includes("mistake")) return "pitfall";
    if (value.startsWith("ex")) return "example";
    return "remark";
  },
};

export interface RevisionEntryInit {
  id: string;
  kind: RevisionEntryKind;
  /** « Théorème 3.4 (des gendarmes) ». */
  title: string;
  /** L'énoncé : Markdown léger, formules entre `$…$` et `$$…$$`. */
  body: string;
  /** D'où il vient : « § 3.5 Les suites monotones », « Série 4 », « Cours 6 ». */
  source?: string;
  /** Où le relire : le chemin d'une section du polycopié, ou une adresse. */
  link?: string;
}

export class RevisionEntry {
  id: string;
  kind: RevisionEntryKind;
  title: string;
  body: string;
  source: string;
  link: string;

  constructor(o: RevisionEntryInit) {
    this.id = o.id;
    this.kind = o.kind;
    this.title = o.title;
    this.body = o.body;
    this.source = o.source ?? "";
    this.link = o.link ?? "";
  }

  /** Les genres, accessibles comme `Entry.Kind` côté Swift. */
  static readonly Kind = RevisionEntryKind;
}

export class RevisionChapter {
  id: string;
  title: string;
  entries: RevisionEntry[];

  constructor(o: { id: string; title: string; entries: RevisionEntry[] }) {
    this.id = o.id;
    this.title = o.title;
    this.entries = o.entries;
  }
}

/** Une notion avec sa clé stable et sa place dans la fiche. */
export interface KeyedEntryInit {
  key: string;
  entry: RevisionEntry;
  chapterID: string;
  chapterTitle: string;
  index: number;
}

export class KeyedEntry {
  key: string;
  entry: RevisionEntry;
  chapterID: string;
  chapterTitle: string;
  index: number;

  constructor(o: KeyedEntryInit) {
    this.key = o.key;
    this.entry = o.entry;
    this.chapterID = o.chapterID;
    this.chapterTitle = o.chapterTitle;
    this.index = o.index;
  }

  get id(): string { return this.key; }
}

export interface RevisionSheetInit {
  origin: RevisionOrigin;
  generatedAt: Date;
  chapters: RevisionChapter[];
}

export class RevisionSheet {
  origin: RevisionOrigin;
  generatedAt: Date;
  chapters: RevisionChapter[];

  constructor(o: RevisionSheetInit) {
    this.origin = o.origin;
    this.generatedAt = o.generatedAt;
    this.chapters = o.chapters;
  }

  static readonly Entry = RevisionEntry;
  static readonly Chapter = RevisionChapter;

  get entries(): RevisionEntry[] { return this.chapters.flatMap((chapter) => chapter.entries); }
  get isEmpty(): boolean { return this.chapters.every((chapter) => chapter.entries.length === 0); }

  /** `RevisionSheet.decode` : `null` quand c'est vide ou illisible. */
  static decode(raw: string): RevisionSheet | null {
    if (raw === "") return null;
    let value: unknown;
    try { value = JSON.parse(raw); } catch { return null; }
    if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
    return sheetFromJSON(value as Record<string, unknown>);
  }

  /** `JSONEncoder` avec `.sortedKeys` ; les dates en secondes depuis 2001 (défaut d'Apple). */
  encoded(): string {
    return canonicalJSON({
      origin: this.origin,
      generatedAt: this.generatedAt.getTime() / 1000 - referenceEpochSeconds,
      chapters: this.chapters.map((chapter) => ({
        id: chapter.id,
        title: chapter.title,
        entries: chapter.entries.map((entry) => ({
          id: entry.id,
          kind: entry.kind,
          title: entry.title,
          body: entry.body,
          source: entry.source,
          link: entry.link,
        })),
      })),
    });
  }

  /** Chaque notion de la fiche avec sa clé stable : le titre sans accents ni casse ; un doublon prend « #2 ». */
  get keyed(): KeyedEntry[] {
    const seen = new Map<string, number>();
    const result: KeyedEntry[] = [];
    for (const chapter of this.chapters) {
      for (const entry of chapter.entries) {
        let key = trimWhitespacesAndNewlines(RevisionText.fold(entry.title));
        if (key === "") key = entry.kind;
        const count = (seen.get(key) ?? 0) + 1;
        seen.set(key, count);
        if (count > 1) key += `#${count}`;
        result.push(new KeyedEntry({
          key, entry, chapterID: chapter.id, chapterTitle: chapter.title, index: result.length,
        }));
      }
    }
    return result;
  }

  entryForKey(key: string): KeyedEntry | null {
    return this.keyed.find((item) => item.key === key) ?? null;
  }

  /** Les notions d'un chapitre (`null` : toutes) ; les clés restent celles de la fiche entière. */
  keyedIn(chapter: string | null): KeyedEntry[] {
    if (chapter === null) return this.keyed;
    return this.keyed.filter((item) => item.chapterID === chapter);
  }

  chapter(id: string | null): RevisionChapter | null {
    if (id === null) return null;
    return this.chapters.find((chapter) => chapter.id === id) ?? null;
  }

  // MARK: Relier à la semaine

  /** Les chapitres dont une entrée renvoie à cette section du polycopié (ou l'une de ses sous-sections). */
  chaptersForPath(path: string): RevisionChapter[] {
    const wanted = RevisionSheet.normalizedPath(path);
    if (wanted === "") return [];
    return this.chapters.filter((chapter) => chapter.entries.some((entry) => {
      const other = RevisionSheet.normalizedPath(entry.link);
      return other !== "" && (other === wanted || other.startsWith(wanted + "/") || wanted.startsWith(other + "/"));
    }));
  }

  /** Le chemin d'une section, qu'on l'ait écrit en chemin du site ou en lien de l'app. */
  static normalizedPath(link: string): string {
    if (link === "") return "";
    let url: URL | null = null;
    try { url = new URL(link); } catch { url = null; }
    if (url !== null) {
      const path = BotafogoPage.handoutPathFromLink(url);
      if (path !== null) return path.toLowerCase();
    }
    return StudyLinkKey.handoutPath(link) ?? link.toLowerCase();
  }

  // MARK: Chercher

  /** La fiche réduite à ce qui contient tous les mots de la recherche (titre, énoncé, source). */
  filtered(query: string): RevisionChapter[] {
    const words = RevisionText.words(query, 1);
    if (words.length === 0) return this.chapters;
    const result: RevisionChapter[] = [];
    for (const chapter of this.chapters) {
      const kept = chapter.entries.filter((entry) => {
        const haystack = RevisionText.fold(entry.title + " " + entry.body + " " + entry.source + " " + chapter.title);
        return words.every((word) => haystack.includes(word));
      });
      if (kept.length !== 0) result.push(new RevisionChapter({ id: chapter.id, title: chapter.title, entries: kept }));
    }
    return result;
  }

  // MARK: À savoir pour un exercice

  /** Les entrées les plus utiles pour un exercice : mots partagés (pondérés par leur rareté), numéros cités, sections. */
  relevant(to: string, preferred: Set<string> = new Set(), limit = 6): RevisionEntry[] {
    const all = this.entries;
    if (all.length === 0) return [];
    const exerciseWords = new Set(RevisionText.words(to));
    const folded = RevisionText.fold(to);
    const frequency = new Map<string, number>();
    const entryWords = all.map((entry) => [...new Set(RevisionText.words(entry.title + " " + entry.body))]);
    for (const words of entryWords) for (const word of words) frequency.set(word, (frequency.get(word) ?? 0) + 1);
    const count = all.length;

    const scored: { entry: RevisionEntry; score: number }[] = [];
    all.forEach((entry, index) => {
      let score = 0;
      for (const word of entryWords[index]) {
        if (exerciseWords.has(word)) score += Math.log(1 + count / (frequency.get(word) ?? 1));
      }
      const number = RevisionText.number(entry.title);
      if (number !== null && folded.includes(number)) score += 6;
      if (entry.link !== "" && preferred.has(entry.link.toLowerCase())) score += 2.5;
      switch (entry.kind) {
        case "definition": case "theorem": case "proposition": case "corollary":
        case "lemma": case "formula": case "method":
          score *= 1.15;
          break;
        case "example": case "remark":
          score *= 0.7;
          break;
        case "pitfall":
          break;
      }
      scored.push({ entry, score });
    });
    const threshold = 3.0;
    return scored.filter((item) => item.score >= threshold)
      .sort((a, b) => b.score - a.score)
      .slice(0, limit)
      .map((item) => item.entry);
  }
}

// MARK: - Le texte, pour comparer

export const RevisionText = {
  /** Sans accents ni casse. */
  fold(text: string): string {
    return fold(text);
  },

  /** Les mots qui portent du sens : sans LaTeX, sans mots-outils. */
  words(text: string, minimum = 4): string[] {
    const cleaned = fold(text).replace(/\\[a-zA-Z]+/g, " ");
    return cleaned.split(/[^\p{L}\p{N}]+/u)
      .filter((word) => word !== "")
      .filter((word) => Array.from(word).length >= minimum && !stopwords.has(word) && !isAllNumbers(word));
  },

  /** « Théorème 3.4 » → « 3.4 » ; « Définition 2.1.3 » → « 2.1.3 ». */
  number(title: string): string | null {
    const match = /\d+(?:\.\d+)+/.exec(title);
    return match === null ? null : match[0];
  },
};

const stopwords = new Set([
  "dans", "pour", "avec", "sans", "sont", "est", "une", "des", "les", "que", "qui", "par", "sur", "tout", "tous",
  "toute", "toutes", "cette", "ces", "son", "ses", "leur", "leurs", "elle", "elles", "nous", "vous", "alors",
  "donc", "ainsi", "comme", "mais", "plus", "moins", "tres", "bien", "etre", "avoir", "fait", "faire", "peut",
  "peuvent", "doit", "soit", "soient", "entre", "chaque", "aussi", "meme", "autre", "autres", "dont", "deux",
  "trois", "montrer", "calculer", "determiner", "trouver", "donner", "verifier", "justifier", "suivant",
  "suivante", "suivants", "suivantes", "ci-dessous", "dessous", "exercice", "question", "partie", "cas",
  "that", "this", "with", "from", "have", "which", "where", "when", "then", "there", "their", "show", "find",
  "compute", "prove", "following", "each", "such", "into", "only", "also", "some", "every",
]);

/** `folding(options: [.diacriticInsensitive, .caseInsensitive], locale: fr)`. */
export function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}

function isAllNumbers(word: string): boolean {
  return Array.from(word).every((c) => /\p{N}/u.test(c));
}

// MARK: - Depuis le polycopié

export interface HandoutSection {
  title: string;
  path: string;
}

export interface HandoutChapter {
  title: string;
  sections: HandoutSection[];
}

const handoutKinds = new Set<BotafogoTheoremKind>(["definition", "theorem", "proposition", "lemma", "corollary"]);

function sheetKind(kind: BotafogoTheoremKind): RevisionEntryKind {
  switch (kind) {
    case "theorem": return "theorem";
    case "definition": return "definition";
    case "proposition": return "proposition";
    case "lemma": return "lemma";
    case "corollary": return "corollary";
    case "example": return "example";
    case "remark": case "other": return "remark";
  }
}

export const RevisionSheetBuilder = {
  /** Les genres repris d'un polycopié : ce qu'on doit savoir énoncer. */
  handoutKinds,

  /** Les énoncés d'une section du polycopié, **sans leurs preuves**. */
  entries(fromHandout: BotafogoBlock[], section: string, path: string): RevisionEntry[] {
    const result: RevisionEntry[] = [];
    const walk = (blocks: BotafogoBlock[]): void => {
      for (const block of blocks) {
        switch (block.type) {
          case "theorem": {
            if (!handoutKinds.has(block.kind)) continue;
            const body = trimWhitespacesAndNewlines(BotafogoPage.text(statement(block.content)));
            if (body === "") continue;
            const kind = sheetKind(block.kind);
            const shown = block.title === "" ? RevisionEntryKind.label(kind) : block.title;
            result.push(new RevisionEntry({
              id: path + "#" + result.length, kind, title: shown, body, source: section, link: path,
            }));
            break;
          }
          case "aside":
            // Un énoncé posé dans un encadré reste un énoncé ; un exercice, non.
            walk(block.content);
            break;
          case "list":
            for (const item of block.items) walk(item);
            break;
          default:
            break;
        }
      }
    };
    walk(fromHandout);
    return result;
  },

  /** Le contenu d'un énoncé sans ce qui se déplie (preuves, solutions, remarques repliées). */
  statement,

  /** La fiche d'un polycopié : un chapitre par chapitre du sommaire, ses énoncés dans l'ordre. */
  sheet(chapters: HandoutChapter[], pages: Record<string, BotafogoBlock[]>, now: Date = new Date()): RevisionSheet {
    const result: RevisionChapter[] = [];
    for (const chapter of chapters) {
      const entries: RevisionEntry[] = [];
      for (const section of chapter.sections) {
        const blocks = pages[section.path];
        if (blocks !== undefined) {
          entries.push(...RevisionSheetBuilder.entries(blocks, MathMarkup.plain(section.title), section.path));
        }
      }
      if (entries.length === 0) continue;
      result.push(new RevisionChapter({ id: chapter.title, title: MathMarkup.plain(chapter.title), entries }));
    }
    return new RevisionSheet({ origin: "handout", generatedAt: now, chapters: result });
  },
};

function statement(blocks: BotafogoBlock[]): BotafogoBlock[] {
  const result: BotafogoBlock[] = [];
  for (const block of blocks) {
    switch (block.type) {
      case "folded": case "quiz": case "video": case "kaltura": case "animation": case "figure":
        continue;
      case "list":
        result.push({ ...block, items: block.items.map(statement) });
        break;
      default:
        result.push(block);
        break;
    }
  }
  return result;
}

// MARK: - Par le modèle

export const RevisionSheetAI = {
  instructions: `Tu écris la FICHE DE RÉVISION complète d'un cours EPFL, à partir de tout son matériel (diapositives, notes, séries d'exercices et corrigés).
But : qu'un·e étudiant·e puisse réviser l'examen avec cette seule fiche. Sois exhaustif·ve sur ce qui est enseigné, et bref·ve dans chaque entrée.
Réponds UNIQUEMENT avec un objet JSON :
{"chapters":[{"title":"Applications linéaires","entries":[{"kind":"definition","title":"Noyau","body":"$\\\\ker T = \\\\{v \\\\in V : T(v) = 0\\\\}$, sous-espace de $V$.","source":"Cours 5"}]}]}
• « kind » : definition, theorem, proposition, formula, method, pitfall ou example.
  – definition, theorem, proposition, formula : l'énoncé exact, avec ses hypothèses.
  – method : comment résoudre un type d'exercice des séries, en étapes courtes (« Pour montrer qu'une famille est libre : … »).
  – pitfall : une erreur classique ou une hypothèse qu'on oublie.
  – example : seulement un exemple-type qui revient à l'examen.
• « title » : court, avec le numéro du cours s'il en a un (« Théorème 4.2 (rang) »).
• « body » : Markdown léger ; formules en LaTeX entre $…$ (ou $$…$$ seules sur leur ligne). Pas de preuve.
• « source » : d'où ça vient (« Cours 5 », « Série 3 », « Diapos semaine 2 »).
• Chapitres dans l'ordre du cours, 5 à 40 entrées chacun. Chaque série doit avoir au moins une « method ».
• Écris dans la langue du matériel. N'invente rien qui ne soit pas dans le matériel.
`,

  /** Pour un cours dont le polycopié donne déjà les énoncés : seulement les méthodes et les pièges. */
  methodsInstructions: `Les énoncés de ce cours EPFL (définitions, théorèmes) sont déjà sur la fiche de révision. Tu ajoutes ce qui manque : les MÉTHODES et les PIÈGES, tirés des séries d'exercices et de leurs corrigés.
Réponds UNIQUEMENT avec un objet JSON :
{"chapters":[{"title":"Séries numériques","entries":[{"kind":"method","title":"Étudier la convergence d'une série","body":"1. Terme général → 0 ? …","source":"Séries 6 et 7"}]}]}
• « kind » : method (comment résoudre un type d'exercice, en étapes courtes) ou pitfall (erreur classique, hypothèse oubliée).
• Un chapitre par grand thème des séries, dans l'ordre du cours ; 3 à 15 entrées chacun.
• Formules en LaTeX entre $…$. Écris dans la langue du matériel. N'invente rien qui ne soit pas dans le matériel.
`,

  /** Le message envoyé : le cours, puis chaque document, coupé pour tenir. */
  prompt(course: string, documents: { title: string; text: string }[], budget = 360_000): string {
    const parts = ["COURS : " + course, ""];
    const cleaned = documents
      .map((document) => ({ title: document.title, text: trimWhitespacesAndNewlines(document.text) }))
      .filter((document) => document.text !== "");
    const total = cleaned.reduce((sum, document) => sum + characters(document.text).length, 0);
    // Au-delà du budget, chaque document est réduit en proportion, sans descendre
    // sous 1500 caractères : un long polycopié n'efface pas les séries.
    const ratio = total > budget ? budget / total : 1;
    for (const document of cleaned) {
      const length = characters(document.text).length;
      const keep = ratio < 1 ? Math.max(1500, Math.trunc(length * ratio)) : length;
      parts.push("=== " + document.title + " ===");
      parts.push(characters(document.text).slice(0, keep).join(""));
      parts.push("");
    }
    return parts.join("\n");
  },

  /** La réponse du modèle (avec ou sans bloc de code, avec du texte autour). */
  sheet(fromAnswer: string, now: Date = new Date()): RevisionSheet | null {
    const start = fromAnswer.indexOf("{");
    const end = fromAnswer.lastIndexOf("}");
    if (start < 0 || end < 0 || start >= end) return null;
    let object: unknown;
    try { object = JSON.parse(fromAnswer.slice(start, end + 1)); } catch { return null; }
    if (object === null || typeof object !== "object" || Array.isArray(object)) return null;
    const chapters = (object as Record<string, unknown>)["chapters"];
    if (!Array.isArray(chapters)) return null;
    // `as? [[String: Any]]` : un seul chapitre qui n'est pas un objet fait échouer toute la lecture.
    if (!chapters.every((chapter) => chapter !== null && typeof chapter === "object" && !Array.isArray(chapter))) return null;

    const result: RevisionChapter[] = [];
    chapters.forEach((chapterValue, c) => {
      const chapter = chapterValue !== null && typeof chapterValue === "object" && !Array.isArray(chapterValue)
        ? (chapterValue as Record<string, unknown>) : {};
      const title = trimWhitespacesAndNewlines(typeof chapter["title"] === "string" ? (chapter["title"] as string) : "");
      const raw = Array.isArray(chapter["entries"]) ? (chapter["entries"] as unknown[]) : [];
      const entries: RevisionEntry[] = [];
      raw.forEach((entryValue, e) => {
        const entry = entryValue !== null && typeof entryValue === "object" && !Array.isArray(entryValue)
          ? (entryValue as Record<string, unknown>) : {};
        const body = trimWhitespacesAndNewlines(typeof entry["body"] === "string" ? (entry["body"] as string) : "");
        const name = trimWhitespacesAndNewlines(typeof entry["title"] === "string" ? (entry["title"] as string) : "");
        if (body === "" && name === "") return;
        const kind = RevisionEntryKind.parse(typeof entry["kind"] === "string" ? (entry["kind"] as string) : "");
        entries.push(new RevisionEntry({
          id: `ai-${c}-${e}`,
          kind,
          title: name === "" ? RevisionEntryKind.label(kind) : name,
          body,
          source: trimWhitespacesAndNewlines(typeof entry["source"] === "string" ? (entry["source"] as string) : ""),
        }));
      });
      if (entries.length !== 0) {
        result.push(new RevisionChapter({ id: `ai-${c}`, title: title === "" ? `Chapitre ${c + 1}` : title, entries }));
      }
    });
    return result.length === 0 ? null : new RevisionSheet({ origin: "ai", generatedAt: now, chapters: result });
  },
};

// MARK: - Garder (formats)

/** Secondes entre 1970 et la date de référence d'Apple (`Date` par défaut de `Codable`). */
const referenceEpochSeconds = Date.UTC(2001, 0, 1) / 1000;

function sheetFromJSON(value: Record<string, unknown>): RevisionSheet | null {
  const origin = value["origin"];
  if (origin !== "handout" && origin !== "ai") return null;
  const generated = value["generatedAt"];
  if (typeof generated !== "number") return null;
  const chaptersRaw = value["chapters"];
  if (!Array.isArray(chaptersRaw)) return null;
  const chapters: RevisionChapter[] = [];
  for (const chapterValue of chaptersRaw) {
    if (chapterValue === null || typeof chapterValue !== "object") return null;
    const chapter = chapterValue as Record<string, unknown>;
    if (typeof chapter["id"] !== "string" || typeof chapter["title"] !== "string" || !Array.isArray(chapter["entries"])) return null;
    const entries: RevisionEntry[] = [];
    for (const entryValue of chapter["entries"] as unknown[]) {
      if (entryValue === null || typeof entryValue !== "object") return null;
      const entry = entryValue as Record<string, unknown>;
      const kind = RevisionEntryKind.fromRaw(typeof entry["kind"] === "string" ? entry["kind"] as string : undefined);
      if (kind === undefined || typeof entry["id"] !== "string" || typeof entry["title"] !== "string"
          || typeof entry["body"] !== "string") return null;
      entries.push(new RevisionEntry({
        id: entry["id"] as string,
        kind,
        title: entry["title"] as string,
        body: entry["body"] as string,
        source: typeof entry["source"] === "string" ? entry["source"] as string : "",
        link: typeof entry["link"] === "string" ? entry["link"] as string : "",
      }));
    }
    chapters.push(new RevisionChapter({ id: chapter["id"] as string, title: chapter["title"] as string, entries }));
  }
  return new RevisionSheet({ origin, generatedAt: new Date(generated * 1000 + referenceEpochSeconds * 1000), chapters });
}

/** `JSONEncoder` avec `.sortedKeys` : les clés d'un objet sont triées, l'ordre des tableaux est gardé. */
export function canonicalJSON(value: unknown): string {
  if (value === null) return "null";
  switch (typeof value) {
    case "number": return Number.isFinite(value) ? String(value) : "null";
    case "boolean": return value ? "true" : "false";
    case "string": return JSON.stringify(value);
    case "undefined": return "null";
  }
  if (Array.isArray(value)) return "[" + value.map((item) => canonicalJSON(item)).join(",") + "]";
  const object = value as Record<string, unknown>;
  const keys = Object.keys(object).filter((key) => object[key] !== undefined).sort();
  return "{" + keys.map((key) => JSON.stringify(key) + ":" + canonicalJSON(object[key])).join(",") + "}";
}
