// Le programme d'un site de cours Botafogo (StudyTrack/Domain/BotafogoProgram.swift).
//
// Le programme n'est ni dans le HTML ni dans une API : il est **écrit dans le
// code** du site, un littéral JavaScript que la barre latérale déplie. On le
// retrouve dans le bon fichier `_nuxt/*.js` et on le relit.

import { swiftInt } from "../services/seriesPDFParser.ts";
import {
  BotafogoParser, ContentDraft, ContentDraftBuilder, ContentDraftItem, ContentDraftSection,
  type ContentExerciseDraft,
} from "./courseContentImport.ts";
import { Institution } from "./institution.ts";
import { icuRegExp } from "./icuRegExp.ts";
import type { MoodleCourseSnapshot } from "./moodleCourseAnalyzer.ts";
import type { NavNode } from "./nuxtPayload.ts";

// MARK: - Un nœud du programme

export interface BotafogoNodeInit {
  type: string;
  name?: string | null;
  url?: string | null;
  metadata?: Record<string, string> | null;
  children?: BotafogoNode[] | null;
}

export class BotafogoNode {
  type: string;
  name: string | null;
  url: string | null;
  metadata: Record<string, string> | null;
  children: BotafogoNode[] | null;

  constructor(o: BotafogoNodeInit) {
    this.type = o.type;
    this.name = o.name ?? null;
    this.url = o.url ?? null;
    this.metadata = o.metadata ?? null;
    this.children = o.children ?? null;
  }

  /** `Decodable` : champs manquants tolérés, métadonnées réduites aux scalaires texte. */
  static fromJSON(raw: unknown): BotafogoNode | null {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    const object = raw as Record<string, unknown>;
    const metadataRaw = object["metadata"];
    let metadata: Record<string, string> | null = null;
    if (metadataRaw !== null && typeof metadataRaw === "object" && !Array.isArray(metadataRaw)) {
      metadata = {};
      for (const [key, value] of Object.entries(metadataRaw as Record<string, unknown>)) {
        const text = scalarText(value);
        if (text !== null) metadata[key] = text;
      }
    }
    const childrenRaw = object["children"];
    const children = Array.isArray(childrenRaw)
      ? childrenRaw.map(BotafogoNode.fromJSON).filter((n): n is BotafogoNode => n !== null)
      : null;
    return new BotafogoNode({
      type: typeof object["type"] === "string" ? object["type"] : "",
      name: typeof object["name"] === "string" ? object["name"] : null,
      url: typeof object["url"] === "string" ? object["url"] : null,
      metadata,
      children,
    });
  }

  meta(key: string): string | null {
    return this.metadata?.[key] ?? null;
  }

  /** Le nom à montrer : « seance-HY-03 » → « Séance 3 », « week-HY-02 » → « La semaine ». */
  get displayName(): string {
    const raw = (this.name ?? this.meta("title") ?? this.url ?? "").trim();
    const tail = /(\d+)$/.exec(raw);
    const number = tail === null ? null : swiftInt(tail[1]);
    const slug = /^[a-z]+(-[A-Za-z0-9]+)+$/.test(raw);
    switch (this.type) {
      case "session":
        if (slug || raw === "") return number !== null ? `Séance ${number}` : "Séance";
        break;
      case "weekContent":
        if (slug || raw === "") return "La semaine";
        break;
      case "lecture":
        if (slug || raw === "") return number !== null ? `Cours ${number}` : "Cours";
        break;
      default:
        break;
    }
    if (raw.startsWith("seance-")) return number !== null ? `Séance ${number}` : "Séance";
    if (raw.startsWith("week-")) return "La semaine";
    return raw;
  }
}

/** Une valeur scalaire de JSON, lue comme texte. */
export function scalarText(value: unknown): string | null {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  if (typeof value === "boolean") return String(value);
  return null;
}

// MARK: - Le littéral JavaScript

export const BotafogoProgram = {
  /** Le programme contenu dans un fichier JavaScript du site, s'il y est. */
  extract(fromScript: string): BotafogoNode[] | null {
    const weekMarker = "type:`week`";
    const arrayMarker = "[{type:`";
    const weeks = occurrences(fromScript, weekMarker);
    const firstWeek = weeks[0];
    const lastWeek = weeks[weeks.length - 1];
    if (firstWeek === undefined || lastWeek === undefined) return null;
    // Le plus petit tableau qui contient **toutes** les semaines.
    for (const start of occurrences(fromScript, arrayMarker)) {
      if (!(start < firstWeek)) continue;
      const end = matchingEnd(fromScript, start);
      if (end === null || !(end > lastWeek)) continue;
      const literal = fromScript.slice(start, end + 1);
      const json = BotafogoProgram.jsonFromLiteral(literal);
      if (json === null) continue;
      let raw: unknown;
      try {
        raw = JSON.parse(json);
      } catch {
        continue;
      }
      if (!Array.isArray(raw)) continue;
      const nodes = raw.map(BotafogoNode.fromJSON).filter((n): n is BotafogoNode => n !== null);
      if (!nodes.some((n) => n.type === "week")) continue;
      return nodes;
    }
    return null;
  },

  /** Un littéral d'objet JavaScript minifié → JSON. */
  jsonFromLiteral(literal: string): string | null {
    const chars = [...literal];
    let out = "";
    let index = 0;
    while (index < chars.length) {
      const c = chars[index];
      if (c === "`") {
        let buffer = "";
        index += 1;
        while (index < chars.length && chars[index] !== "`") {
          if (chars[index] === "\\" && index + 1 < chars.length) {
            buffer += chars[index + 1];
            index += 2;
            continue;
          }
          buffer += chars[index];
          index += 1;
        }
        out += JSON.stringify(buffer);
        index += 1;
        continue;
      }
      if (/^\p{L}$/u.test(c) || c === "_" || c === "$") {
        let end = index;
        while (end < chars.length && (/^\p{L}$/u.test(chars[end]) || /^\p{N}$/u.test(chars[end])
               || chars[end] === "_" || chars[end] === "$")) end += 1;
        const word = chars.slice(index, end).join("");
        if (end < chars.length && chars[end] === ":") {
          out += JSON.stringify(word);
        } else if (word === "void") {
          out += "null";
          end += 2; // « void 0 »
        } else if (["true", "false", "null"].includes(word)) {
          out += word;
        } else {
          out += JSON.stringify(word);
        }
        index = end;
        continue;
      }
      if (c === "!" && index + 1 < chars.length && (chars[index + 1] === "0" || chars[index + 1] === "1")) {
        out += chars[index + 1] === "0" ? "true" : "false";
        index += 2;
        continue;
      }
      out += c;
      index += 1;
    }
    return out;
  },

  // MARK: Chemins

  /** `series/AN_serie_03` → `/course_material/series/an_serie_03`. */
  contentPath(url: string): string {
    return "/course_material/" + url.toLowerCase();
  },

  /** La page d'un élément du site. */
  pageURL(root: URL, url: string): string {
    return BotafogoLinks.coursURL(root, url);
  },

  /** Une section du polycopié : `…/?polycopie=matiere/m_suites_gendarmes`. */
  handoutURL(root: URL, target: string): string {
    return BotafogoLinks.polycopieURL(root, "matiere/" + target);
  },

  /** `series/AN_serie_03` → 3. */
  seriesNumber(url: string): number | null {
    const range = /(\d+)\s*$/.exec(url);
    return range === null ? null : swiftInt(range[1]);
  },

  date(iso: string | null): Date | null {
    if (iso === null) return null;
    const value = new Date(iso);
    return Number.isNaN(value.getTime()) ? null : value;
  },
};

/** Les occurrences d'un motif (indices d'octets côté Swift, d'unités UTF-16 ici). */
function occurrences(haystack: string, needle: string): number[] {
  const result: number[] = [];
  let index = haystack.indexOf(needle);
  while (index >= 0) {
    result.push(index);
    index = haystack.indexOf(needle, index + 1);
  }
  return result;
}

/** La fin du tableau ouvert en `start`, en sautant les chaînes `` `…` ``. */
function matchingEnd(chars: string, start: number): number | null {
  let depth = 0;
  let inString = false;
  let index = start;
  while (index < chars.length) {
    const c = chars[index];
    if (inString) {
      if (c === "\\") {
        index += 2;
        continue;
      }
      if (c === "`") inString = false;
    } else {
      switch (c) {
        case "`": inString = true; break;
        case "[":
        case "{":
        case "(":
          depth += 1;
          break;
        case "]":
        case "}":
        case ")":
          depth -= 1;
          if (depth === 0) return index;
          break;
        default:
          break;
      }
    }
    index += 1;
  }
  return null;
}

// MARK: - Les quatre parties du site

export interface ChapterSection {
  title: string;
  /** `/handout/matiere/m_suites_gendarmes`. */
  path: string;
}

export interface Chapter {
  title: string;
  sections: ChapterSection[];
}

export const BotafogoSite = {
  /** `BotafogoSite.Chapter(title:sections:)` / `Section(title:path:)`. */
  Chapter(title: string, sections: ChapterSection[]): Chapter { return { title, sections }; },
  Section(title: string, path: string): ChapterSection { return { title, path }; },

  /** Une adresse de document du polycopié (et non du cours). */
  isHandout(path: string): boolean { return path.startsWith("/handout/"); },

  /** La collection du polycopié, annoncée par la page. */
  handoutCollection(html: string): string | null {
    const range = /handout:\{url:"([^"]+)"/.exec(html);
    return range === null ? null : range[1];
  },

  /** Le sommaire du polycopié : chapitres → sections. */
  chapters(fromNavJSON: string | Uint8Array): Chapter[] {
    let text: string;
    if (typeof fromNavJSON === "string") text = fromNavJSON;
    else text = new TextDecoder().decode(fromNavJSON);
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return [];
    }
    if (!Array.isArray(parsed)) return [];
    interface Node { title: string | null; path: string | null; children: Node[] }
    const toNode = (raw: unknown): Node | null => {
      if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
      const o = raw as Record<string, unknown>;
      return {
        title: typeof o["title"] === "string" ? o["title"] : null,
        path: typeof o["path"] === "string" ? o["path"] : null,
        children: Array.isArray(o["children"])
          ? o["children"].map(toNode).filter((n): n is Node => n !== null) : [],
      };
    };
    const roots = parsed.map(toNode).filter((n): n is Node => n !== null);
    const chapters: Chapter[] = [];
    const sections = (node: Node): ChapterSection[] => {
      const found: ChapterSection[] = [];
      if (node.path !== null && BotafogoSite.isHandout(node.path) && node.children.length === 0) {
        found.push({ title: node.title ?? node.path, path: node.path });
      }
      for (const child of node.children) found.push(...sections(child));
      return found;
    };
    for (const root of roots) {
      for (const chapter of root.children) {
        const found = sections(chapter);
        if (found.length === 0) continue;
        chapters.push({ title: chapter.title ?? "", sections: found });
      }
    }
    return chapters;
  },

  /** La semaine en cours : la dernière dont la séance a commencé (à deux jours près). */
  currentWeek(weeks: BotafogoNode[], now: Date = new Date()): number | null {
    const horizon = new Date(now.getTime() + 2 * 86_400_000);
    let current: number | null = null;
    weeks.forEach((week, index) => {
      const dates = (week.children ?? [])
        .map((child) => BotafogoProgram.date(child.meta("date")))
        .filter((d): d is Date => d !== null);
      if (dates.length === 0) return;
      const first = new Date(Math.min(...dates.map((d) => d.getTime())));
      if (first.getTime() <= horizon.getTime()) current = index;
    });
    return current;
  },

  /** Ce qu'on fait en séance (et non en exercice) : séance, contenu de la semaine, cours, examen. */
  isSessionPart(node: BotafogoNode): boolean {
    return ["session", "weekContent", "lecture", "exam"].includes(node.type);
  },

  /** « Série 3 » (le nom de la série devient le sous-titre). */
  seriesTitle(node: BotafogoNode): string {
    const number = BotafogoProgram.seriesNumber(node.url ?? "");
    return number !== null ? `Série ${number}` : node.displayName;
  },
};

// MARK: - Les documents du site

export interface BotafogoLectureReference { target: string; title: string }
export interface BotafogoLectureVideo { id: string; title: string }

/** Ce qu'une page de cours (ou de semaine) annonce : les sections couvertes et les vidéos. */
export class BotafogoLectureContent {
  references: BotafogoLectureReference[] = [];
  videos: BotafogoLectureVideo[] = [];
}

/** Un exercice lu dans le document d'une série. */
export interface BotafogoExercise {
  /** « 3.1 ». */
  number: string;
  statement: string;
  hint: string;
  solution: string;
  questions: import("../services/seriesPDFParser.ts").DetectedSubQuestion[];
}

export const BotafogoDocument = {
  /** Le corps d'une réponse de `/api/content/node`. */
  body(fromNodeJSON: string | Uint8Array): Record<string, any> | null {
    let text: string;
    if (typeof fromNodeJSON === "string") text = fromNodeJSON;
    else text = new TextDecoder().decode(fromNodeJSON);
    let object: unknown;
    try {
      object = JSON.parse(text);
    } catch {
      return null;
    }
    if (object === null || typeof object !== "object" || Array.isArray(object)) return null;
    const o = object as Record<string, unknown>;
    if (o["body"] !== null && typeof o["body"] === "object" && !Array.isArray(o["body"])) {
      return o["body"] as Record<string, any>;
    }
    if (typeof o["body"] === "string") {
      try {
        const body = JSON.parse(o["body"]);
        return body !== null && typeof body === "object" && !Array.isArray(body) ? body as Record<string, any> : null;
      } catch {
        return null;
      }
    }
    return null;
  },

  // MARK: Pages de cours

  lecture(fromNodeJSON: string | Uint8Array): BotafogoLectureContent {
    const body = BotafogoDocument.body(fromNodeJSON);
    const content = new BotafogoLectureContent();
    if (body === null) return content;
    const seenTargets = new Set<string>();
    const seenVideos = new Set<string>();
    BotafogoDocument.walk(body, (node) => {
      const tag = node["tagName"];
      const properties = node["properties"] !== null && typeof node["properties"] === "object"
        ? node["properties"] as Record<string, any> : {};
      if (tag === "latex-ref" && typeof properties["target"] === "string"
          && properties["target"].startsWith("m_") && !seenTargets.has(properties["target"])) {
        seenTargets.add(properties["target"]);
        content.references.push({ target: properties["target"], title: BotafogoDocument.text(node) });
      }
      if (tag === "videokaltura" && typeof properties["entryId"] === "string"
          && !seenVideos.has(properties["entryId"])) {
        seenVideos.add(properties["entryId"]);
        content.videos.push({
          id: properties["entryId"],
          title: typeof properties["title"] === "string" ? properties["title"] : "Vidéo",
        });
      }
    });
    return content;
  },

  // MARK: Séries

  /** Une page jamais publiée : marquée brouillon, ou sans contenu. */
  isUnpublished(nodeJSON: string | Uint8Array): boolean {
    let text: string;
    if (typeof nodeJSON === "string") text = nodeJSON;
    else text = new TextDecoder().decode(nodeJSON);
    let object: unknown;
    try {
      object = JSON.parse(text);
    } catch {
      return false;
    }
    if (object === null || typeof object !== "object" || Array.isArray(object)) return false;
    const o = object as Record<string, unknown>;
    const meta = o["meta"];
    if (meta !== null && typeof meta === "object" && !Array.isArray(meta)
        && (meta as Record<string, unknown>)["_draft"] === true) return true;
    return o["body"] === undefined || o["body"] === null;
  },

  /** Les exercices d'une série, dans l'ordre : énoncé, questions, indication, solution. */
  exercises(fromNodeJSON: string | Uint8Array): BotafogoExercise[] {
    const body = BotafogoDocument.body(fromNodeJSON);
    if (body === null) return [];
    const elements: Record<string, any>[] = [];
    BotafogoDocument.collect(body, "exercise", elements);
    return elements.map(BotafogoDocument.exercise).filter((e): e is BotafogoExercise => e !== null);
  },

  exercise(element: Record<string, any>): BotafogoExercise | null {
    const root = BotafogoDocument.contentRoot(element);
    if (root === null) return null;
    let number = "";
    const statement: string[] = [];
    let hint = "";
    let solution = "";
    let questions: import("../services/seriesPDFParser.ts").DetectedSubQuestion[] = [];

    const visit = (children: Record<string, any>[]) => {
      for (const child of children) {
        const tag = child["tagName"];
        switch (tag) {
          case "b":
            if (number !== "") {
              const value = BotafogoDocument.text(child);
              if (value.trim() !== "") statement.push(value);
              break;
            }
            {
              const label = BotafogoDocument.text(child);
              const range = /\d+\s*[-.]\s*\d+/.exec(label);
              if (range !== null) {
                number = range[0].split("-").join(".")
                  .split(" ").join("")
                  .split(".").map((part) => String(swiftInt(part) ?? 0)).join(".");
              } else {
                statement.push(label);
              }
            }
            break;
          case "indication":
            hint = BotafogoDocument.contentRoot(child) !== null
              ? BotafogoDocument.text(BotafogoDocument.contentRoot(child)!) : BotafogoDocument.text(child);
            break;
          case "solution":
            solution = BotafogoDocument.contentRoot(child) !== null
              ? BotafogoDocument.text(BotafogoDocument.contentRoot(child)!) : BotafogoDocument.text(child);
            break;
          case "ol":
            if (questions.length === 0) questions = BotafogoDocument.list(child, 0);
            break;
          case "multicols":
          case "template": {
            const inner = BotafogoDocument.contentRoot(child);
            visit(inner !== null ? BotafogoDocument.nodes(inner) : BotafogoDocument.nodes(child));
            break;
          }
          case "br":
          case "img":
          case "div": {
            const value = BotafogoDocument.text(child);
            if (value.trim() !== "") statement.push(value);
            break;
          }
          default: {
            const value = BotafogoDocument.text(child);
            if (value.trim() !== "") statement.push(value);
            break;
          }
        }
      }
    };
    visit(BotafogoDocument.nodes(root));
    if (number === "") return null;
    return {
      number,
      statement: BotafogoDocument.tidy(statement.join(" "), 700),
      hint: BotafogoDocument.tidy(hint, 1500),
      solution: BotafogoDocument.tidy(solution, 4000),
      questions,
    };
  },

  /** Une liste numérotée : « 1. 2. 3. », et dedans « (a) (b) ». */
  list(element: Record<string, any>, depth: number): import("../services/seriesPDFParser.ts").DetectedSubQuestion[] {
    const items = BotafogoDocument.nodes(element).filter((n) => n["tagName"] === "li");
    return items.map((item, index) => {
      const ownText: string[] = [];
      let children: import("../services/seriesPDFParser.ts").DetectedSubQuestion[] = [];
      for (const child of BotafogoDocument.nodes(item)) {
        if (child["tagName"] === "ol" && depth === 0 && children.length === 0) {
          children = BotafogoDocument.list(child, 1);
        } else {
          ownText.push(BotafogoDocument.text(child));
        }
      }
      const label = depth === 0 ? String(index + 1) : String.fromCharCode(97 + Math.min(index, 25));
      return {
        label,
        text: BotafogoDocument.tidy(ownText.join(" "), 280),
        kind: "question" as const,
        children,
        id: crypto.randomUUID(),
      };
    });
  },

  // MARK: Arbre

  nodes(node: Record<string, any>): Record<string, any>[] {
    return Array.isArray(node["children"]) ? node["children"] as Record<string, any>[] : [];
  },

  /** Le contenu d'un élément à gabarit : `exercise` → `template` → `content`. */
  contentRoot(element: Record<string, any>): Record<string, any> | null {
    if (element["content"] !== null && typeof element["content"] === "object" && !Array.isArray(element["content"])) {
      return element["content"] as Record<string, any>;
    }
    for (const child of BotafogoDocument.nodes(element)) {
      if (child["tagName"] !== "template") continue;
      if (child["content"] !== null && typeof child["content"] === "object" && !Array.isArray(child["content"])) {
        return child["content"] as Record<string, any>;
      }
    }
    return null;
  },

  walk(node: Record<string, any>, visit: (node: Record<string, any>) => void): void {
    visit(node);
    for (const child of BotafogoDocument.nodes(node)) BotafogoDocument.walk(child, visit);
    if (node["content"] !== null && typeof node["content"] === "object" && !Array.isArray(node["content"])) {
      BotafogoDocument.walk(node["content"] as Record<string, any>, visit);
    }
  },

  collect(node: Record<string, any>, tag: string, result: Record<string, any>[]): void {
    if (node["tagName"] === tag) {
      result.push(node);
      return;
    }
    for (const child of BotafogoDocument.nodes(node)) BotafogoDocument.collect(child, tag, result);
    if (node["content"] !== null && typeof node["content"] === "object" && !Array.isArray(node["content"])) {
      BotafogoDocument.collect(node["content"] as Record<string, any>, tag, result);
    }
  },

  /** Le texte d'un nœud ; les formules gardent leur LaTeX entre `$…$`. */
  text(node: Record<string, any>): string {
    if (node["type"] === "text") return typeof node["value"] === "string" ? node["value"] : "";
    const tag = node["tagName"];
    if (tag === "katex-renderer") {
      const properties = node["properties"] !== null && typeof node["properties"] === "object"
        ? node["properties"] as Record<string, any> : {};
      return "$" + BotafogoDocument.simplifyMath(typeof properties["content"] === "string" ? properties["content"] : "") + "$";
    }
    if (tag === "img" || tag === "jsxgraph" || tag === "videokaltura") return "";
    if (tag === "br") return " ";
    const parts = BotafogoDocument.nodes(node).map((child) => BotafogoDocument.text(child));
    if (node["content"] !== null && typeof node["content"] === "object" && !Array.isArray(node["content"])) {
      parts.push(BotafogoDocument.text(node["content"] as Record<string, any>));
    }
    const joined = parts.join("");
    if (tag === "p" || tag === "li" || tag === "div") return joined + " ";
    return joined;
  },

  /** `\begin{align*} a &= b \\ c \end{align*}` → `a = b ; c`. */
  simplifyMath(latex: string): string {
    let text = latex;
    text = text.replace(/\\(begin|end)\{[a-z*]+\}(\{[^}]*\})?/g, "");
    text = text.replace(/\\\\/g, " ; ");
    text = text.split("&").join("");
    return text.trim();
  },

  /** Espaces normalisés, longueur bornée à un mot près. */
  tidy(text: string, limit: number): string {
    const collapsed = text.split(/\s+/u).filter((part) => part !== "").join(" ")
      .split(" ,").join(",").split(" .").join(".");
    if ([...collapsed].length <= limit) return collapsed;
    let prefix = [...collapsed].slice(0, limit).join("");
    // Ne pas couper une formule en deux : on recule avant un `$` ouvert.
    if ((prefix.split("$").length - 1) % 2 === 1) {
      const last = prefix.lastIndexOf("$");
      if (last >= 0) prefix = prefix.slice(0, last);
    }
    const space = prefix.lastIndexOf(" ");
    if (space >= 0) prefix = prefix.slice(0, space);
    return prefix + "…";
  },
};

/// Un exercice prêt à écrire.
export function contentExerciseDraft(o: Partial<ContentExerciseDraft> & { number: string }): ContentExerciseDraft {
  return {
    number: o.number,
    title: o.title ?? "",
    statement: o.statement ?? "",
    hint: o.hint ?? "",
    solution: o.solution ?? "",
    url: o.url ?? "",
    isBonus: o.isBonus ?? false,
    questions: o.questions ?? [],
  };
}

// MARK: - Le brouillon d'import

export const BotafogoProgramBuilder = {
  /** Le programme, semaine par semaine, en brouillon d'import. */
  draft(o: {
    title: string;
    program: BotafogoNode[];
    root: URL;
    handout: NavNode[];
    lectures: Record<string, BotafogoLectureContent>;
    series: Record<string, BotafogoExercise[]>;
    unpublished?: Set<string>;
  }): ContentDraft {
    const unpublished = o.unpublished ?? new Set<string>();
    // Titre complet de chaque section du polycopié, par identifiant `m_…`.
    const sectionTitles = new Map<string, string>();
    for (const chapter of o.handout) {
      for (const section of chapter.children) {
        const parts = section.path.split("/");
        const target = parts[parts.length - 1]?.toLowerCase();
        if (target !== undefined && target.startsWith("m_")) sectionTitles.set(target, section.title);
      }
    }

    const sections: ContentDraftSection[] = [];
    const placed = new Set<string>();
    const dayFormatter = new Intl.DateTimeFormat("fr-CH", { weekday: "long", day: "numeric", month: "short" });

    for (const week of o.program.filter((w) => w.type === "week")) {
      const number = week.meta("number") !== null ? swiftInt(week.meta("number")!) : null;
      if (number === null) continue;
      const items: ContentDraftItem[] = [];
      for (const child of week.children ?? []) {
        switch (child.type) {
          case "lecture":
          case "weekContent":
          case "session": {
            const content = child.url !== null ? (o.lectures[child.url] ?? new BotafogoLectureContent()) : new BotafogoLectureContent();
            if (child.type === "lecture") {
              const date = BotafogoProgram.date(child.meta("date"));
              const nameParts = (child.name ?? "").split(" ").filter((p) => p !== "");
              const index = nameParts.length > 0 ? swiftInt(nameParts[nameParts.length - 1]) : null;
              const videoMeta = child.meta("videoId");
              const videoID = (videoMeta !== null && videoMeta.length > 5 ? videoMeta : null) ?? content.videos[0]?.id ?? null;
              const subtitle = date !== null ? dayFormatter.format(date) : "";
              items.push(new ContentDraftItem({
                kind: "theory",
                number: `C${index ?? items.length + 1}`,
                title: `${child.name ?? "Cours"}${subtitle === "" ? "" : " · " + subtitle}`,
                url: videoID !== null
                  ? `https://${Institution.current.video?.host ?? "mediaspace.epfl.ch"}/media/${videoID}`
                  : BotafogoProgram.pageURL(o.root, child.url ?? ""),
                videoCount: 1,
                seriesNumber: null,
                theoryKind: "video",
                week: number,
              }));
            }
            for (const reference of content.references) {
              const key = reference.target.toLowerCase();
              if (placed.has(key)) continue;
              placed.add(key);
              const full = sectionTitles.get(key) ?? reference.title;
              const clean = ContentDraftBuilder.cleanTitle(full);
              const lead = ContentDraftBuilder.leadingNumber(clean);
              items.push(new ContentDraftItem({
                kind: "theory",
                number: lead?.number ?? reference.target,
                title: lead?.rest ?? clean,
                url: BotafogoProgram.handoutURL(o.root, key),
                videoCount: 0,
                seriesNumber: null,
                theoryKind: "reading",
                week: number,
              }));
            }
            break;
          }
          case "series": {
            const url = child.url;
            const seriesNumber = url !== null ? BotafogoProgram.seriesNumber(url) : null;
            if (url === null || seriesNumber === null) continue;
            const read = o.series[url] ?? [];
            const listed = (child.children ?? []).filter((node) => node.type === "exercise" && !unpublished.has(node.url ?? ""));
            let exercises: ContentExerciseDraft[] = [];
            listed.forEach((node, index) => {
              const fallback = `${seriesNumber}.${index + 1}`;
              const parsed = index < read.length ? read[index] : null;
              exercises.push(contentExerciseDraft({
                number: fallback,
                statement: parsed?.statement ?? "",
                hint: parsed?.hint ?? "",
                solution: parsed?.solution ?? "",
                url: node.url !== null ? BotafogoProgram.pageURL(o.root, node.url) : "",
                questions: parsed?.questions ?? [],
              }));
            });
            if (exercises.length === 0) {
              exercises = read.map((item) => contentExerciseDraft({
                number: item.number,
                statement: item.statement,
                hint: item.hint,
                solution: item.solution,
                questions: item.questions,
              }));
            }
            const item = new ContentDraftItem({
              kind: "series",
              number: String(seriesNumber),
              title: ContentDraftBuilder.cleanTitle(child.name ?? `Série ${seriesNumber}`),
              url: BotafogoProgram.pageURL(o.root, url),
              videoCount: 0,
              seriesNumber,
              theoryKind: "reading",
              week: number,
            });
            item.exercises = exercises;
            item.solutionsAt = BotafogoProgram.date(child.meta("solutionsDate"));
            item.solutionURL = item.url;
            items.push(item);
            break;
          }
          default:
            continue;
        }
      }
      if (items.length === 0) continue;
      const label = [week.name !== null ? ContentDraftBuilder.cleanTitle(week.name) : null, week.meta("dates")]
        .filter((x): x is string => x !== null).join(" · ");
      sections.push(new ContentDraftSection({
        title: `Semaine ${number} · ${label}`,
        week: number,
        weekIsInferred: false,
        isIncluded: true,
        items,
      }));
    }

    // Ce que le programme ne cite pas : proposé à part, décoché.
    const leftovers: ContentDraftItem[] = [];
    for (const chapter of o.handout) {
      const chapterTitle = ContentDraftBuilder.cleanTitle(chapter.title);
      if (ContentDraftBuilder.isFrontMatter(chapterTitle)) continue;
      for (const section of chapter.children) {
        const parts = section.path.split("/");
        const target = parts[parts.length - 1];
        if (target === undefined || !target.startsWith("m_") || placed.has(target.toLowerCase())) continue;
        const clean = ContentDraftBuilder.cleanTitle(section.title);
        const lead = ContentDraftBuilder.leadingNumber(clean);
        leftovers.push(new ContentDraftItem({
          kind: "theory",
          number: lead?.number ?? target,
          title: lead?.rest ?? clean,
          url: BotafogoProgram.handoutURL(o.root, target),
          videoCount: 0,
          seriesNumber: null,
          theoryKind: "reading",
        }));
      }
    }
    if (leftovers.length > 0) {
      sections.push(new ContentDraftSection({
        title: "Polycopié : sections hors du programme hebdomadaire",
        week: 0, weekIsInferred: true, isIncluded: false, items: leftovers,
      }));
    }

    return new ContentDraft({ source: "botafogo", courseTitle: o.title, url: o.root.toString(), sections });
  },
};

// MARK: - Quel site Botafogo pour quel cours

const botafogoStop = new Set(["mon", "ma", "cours", "course", "de", "du", "d", "la", "le", "l", "les", "pour",
                              "for", "polycopie", "the", "my", "et", "and", "a", "of", "version", "ligne",
                              "index", "html", "matiere", "en", "fr", "english", "francais", "french"]);

const isLevel = (word: string): boolean => ["1", "2", "3", "4", "b"].includes(word);

/** Les mots d'un nom, accents et casse retirés ; « I », « II » deviennent « 1 », « 2 ». */
function words(text: string): string[] {
  const romans = new Map([["i", "1"], ["ii", "2"], ["iii", "3"], ["iv", "4"]]);
  return ContentDraftBuilder.fold(text).split(/[^\p{L}\p{N}]+/u).filter((w) => w !== "")
    .map((w) => romans.get(w) ?? w);
}

const significant = (word: string): boolean => {
  if (isLevel(word)) return true;
  return !botafogoStop.has(word) && [...word].length > 1 && ![...word].every((c) => /\p{N}/u.test(c));
};

const entryWords = (text: string): Set<string> => new Set(words(text).filter(significant));

function courseWords(name: string): string[] {
  const bare = name
    .replace(/\([^()]*[A-Z]{2,}-\d{3}[^()]*(\([^()]*\))?[^()]*\)/g, " ")
    .replace(/\b[A-Z]{2,}-\d{3}[A-Za-z]?(\([^()]*\))?/g, " ");
  const seen = new Set<string>();
  return words(bare).filter(significant).filter((word) => {
    if (seen.has(word)) return false;
    seen.add(word);
    return true;
  });
}

export const BotafogoCatalog = {
  /** Un lien Botafogo cité par le cours. */
  site(snapshot: MoodleCourseSnapshot): URL | null {
    const links = snapshot.sections.flatMap((section) => [
      ...section.activities.map((activity) => activity.link),
      ...section.links.map((link) => link.url),
    ]);
    for (const link of links) {
      let url: URL;
      try {
        url = new URL(link);
      } catch {
        continue;
      }
      if (url.hostname.includes("botafogo")) return BotafogoParser.courseRoot(url);
    }
    return null;
  },

  /** L'entrée du catalogue qui correspond au cours, ou `null`. */
  match(courseName: string, catalog: { title: string; url: URL }[]): URL | null {
    const course = courseWords(courseName);
    if (course.length === 0) return null;
    const acronym = course.filter((word) => !isLevel(word)).map((word) => [...word][0] ?? "").join("");
    let best: { url: URL; extra: number } | null = null;
    for (const entry of catalog) {
      const entrySet = new Set([...entryWords(entry.title), ...entryWords(entry.url.pathname)]);
      if (entrySet.size === 0) continue;
      const explained = (acronym.length >= 3 && entrySet.has(acronym))
        || course.every((word) => entrySet.has(word) || (word === "1" && ![...entrySet].some(isLevel)));
      if (!explained) continue;
      // Un niveau dans l'entrée doit être celui du cours.
      const levels = [...entrySet].filter(isLevel);
      if (levels.length > 0 && !levels.some((level) => course.includes(level))
          && !(acronym.length >= 3 && entrySet.has(acronym))) continue;
      const extra = [...entrySet].filter((word) => !course.includes(word)).length;
      if (best === null || extra < best.extra) best = { url: entry.url, extra };
    }
    return best?.url ?? null;
  },
};

// MARK: - Les adresses du site

/** `URLQueryAllowed` : ce que Swift laisse tel quel dans une valeur de requête. */
function encodeQueryValue(value: string): string {
  return encodeURIComponent(value)
    .replace(/%2F/g, "/").replace(/%3A/g, ":").replace(/%40/g, "@");
}

const pathExtension = (pathname: string): string => {
  const last = pathname.split("/").filter((p) => p !== "").pop() ?? "";
  const dot = last.lastIndexOf(".");
  return dot > 0 ? last.slice(dot + 1).toLowerCase() : "";
};

export const BotafogoLinks = {
  coursURL(root: URL, path: string): string {
    return BotafogoLinks.base(root) + "?cours=" + encodeQueryValue(path);
  },

  polycopieURL(root: URL, path: string): string {
    return BotafogoLinks.base(root) + "?polycopie=" + encodeQueryValue(BotafogoLinks.handoutID(path));
  },

  /** `/handout/matiere/m_x` → `matiere/m_x`. */
  handoutID(path: string): string {
    let id = path;
    while (id.startsWith("/")) id = id.slice(1);
    if (id.toLowerCase().startsWith("handout/")) id = id.slice("handout/".length);
    return id;
  },

  base(root: URL): string {
    return root.toString().endsWith("/") ? root.toString() : root.toString() + "/";
  },

  /** Une page du site (série, section), pas un fichier. */
  isPage(address: string): boolean {
    let url: URL;
    try {
      url = new URL(address);
    } catch {
      return false;
    }
    if (!url.hostname.includes("botafogo")) return false;
    return pathExtension(url.pathname) !== "pdf";
  },

  /** `…/?cours=series/AN_serie_03` → `series/AN_serie_03`. */
  coursPath(address: string): string | null {
    if (!BotafogoLinks.isPage(address)) return null;
    let url: URL;
    try {
      url = new URL(address);
    } catch {
      return null;
    }
    const value = url.searchParams.get("cours");
    return value === null || value === "" ? null : value;
  },

  /** Répare une adresse enregistrée par une version précédente de l'app. */
  normalize(url: URL): URL {
    if (!url.hostname.includes("botafogo")) return url;
    const rawQuery = url.search.startsWith("?") ? url.search.slice(1) : url.search;
    if (rawQuery === "") return url;
    const fixed: { name: string; value: string }[] = [];
    for (const item of rawQuery.split("&")) {
      if (item === "") continue;
      const at = item.indexOf("=");
      const rawName = at >= 0 ? item.slice(0, at) : item;
      const rawValue = at >= 0 ? item.slice(at + 1) : "";
      let value: string;
      try {
        value = decodeURIComponent(rawValue.replace(/\+/g, " "));
      } catch {
        value = rawValue;
      }
      if (value === "") continue;
      const name = decodeURIComponent(rawName.replace(/\+/g, " "));
      fixed.push({ name, value: name === "polycopie" ? BotafogoLinks.handoutID(value) : value });
    }
    let pathname = url.pathname;
    const lastPart = pathname.split("/").filter((p) => p !== "").pop() ?? "";
    if (!pathname.endsWith("/") && !lastPart.includes(".")) pathname += "/";
    const query = fixed.map((item) => `${item.name}=${encodeQueryValue(item.value)}`).join("&");
    const authority = url.host;
    const result = `${url.protocol}//${authority}${pathname}${query === "" ? "" : "?" + query}${url.hash}`;
    try {
      return new URL(result);
    } catch {
      return url;
    }
  },
};

/** Les liens enregistrés, réparés avant d'être ouverts. */
export const SiteLinks = {
  normalize(url: URL): URL {
    return MoodleLinks.normalize(BotafogoLinks.normalize(url));
  },
};

// MARK: - Moodle : documents et pages intermédiaires

export interface Anchor {
  href: string;
  text: string;
}

export const MoodleLinks = {
  /** Les activités dont la page n'est qu'un intermédiaire vers un document. */
  activityModules: ["resource", "url", "page", "folder"],

  /** `mod/page/view.php?id=…` → `page` ; `null` hors d'une activité Moodle. */
  activityModule(of: URL): string | null {
    if (!of.hostname.includes("moodle")) return null;
    const parts = of.pathname.split("/").filter((p) => p !== "");
    if (parts.length < 3) return null;
    if (parts[parts.length - 3] !== "mod" || parts[parts.length - 1] !== "view.php") return null;
    const module = parts[parts.length - 2];
    return MoodleLinks.activityModules.includes(module) ? module : null;
  },

  normalize(url: URL): URL {
    const module = MoodleLinks.activityModule(url);
    if (module === null || (module !== "resource" && module !== "url")) return url;
    const items = [...url.searchParams.entries()];
    if (items.some(([name]) => name === "redirect" || name === "forceview")) return url;
    const result = new URL(url.toString());
    result.searchParams.append("redirect", "1");
    return result;
  },

  /** La page « intermédiaire » d'une activité, celle qui porte le lien. */
  workaroundPage(url: URL): URL {
    const module = MoodleLinks.activityModule(url);
    if (module === null) return url;
    const result = new URL(url.toString());
    for (const name of ["redirect", "forceview"]) result.searchParams.delete(name);
    if (module === "resource" || module === "url") result.searchParams.append("forceview", "1");
    return result;
  },

  /** Les liens et documents intégrés d'une page HTML, dans l'ordre. */
  anchors(inHTML: string, baseURL: URL | null): Anchor[] {
    const result: Anchor[] = [];
    const anchor = String.raw`<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>`;
    const embedded = String.raw`<(?:iframe|embed|object)\b[^>]*?\b(?:src|data)\s*=\s*["']([^"']+)["']`;
    for (const [pattern, hasText] of [[anchor, true], [embedded, false]] as [string, boolean][]) {
      const regex = new RegExp(pattern, "gis");
      for (const match of inHTML.matchAll(regex)) {
        const raw = MoodleLinks.decodeEntities(match[1]);
        let absolute: URL;
        try {
          absolute = baseURL === null ? new URL(raw) : new URL(raw, baseURL);
        } catch {
          continue;
        }
        if (!absolute.protocol.startsWith("http")) continue;
        let text = "";
        if (hasText && match[2] !== undefined) {
          text = MoodleLinks.decodeEntities(match[2].replace(/<[^>]+>/g, " "))
            .split(/\s+/u).filter((part) => part !== "").join(" ");
        }
        result.push({ href: absolute.toString(), text });
      }
    }
    return result;
  },

  /** Le document qu'une page d'activité Moodle désigne. */
  statementLink(inHTML: string, baseURL: URL | null): { statement: string | null; solution: string | null } {
    const range = new RegExp(String.raw`class\s*=\s*["'][^"']*\b(url|resource)workaround\b[^"']*["'][^>]*>[\s\S]{0,400}?href\s*=\s*["']([^"']+)["']`, "i").exec(inHTML);
    if (range !== null) {
      const href = /href\s*=\s*["']([^"']+)["']/i.exec(range[0]);
      if (href !== null) {
        const raw = href[1].replace(/^href\s*=\s*["']|["']$/g, "");
        try {
          const url = baseURL === null
            ? new URL(MoodleLinks.decodeEntities(raw))
            : new URL(MoodleLinks.decodeEntities(raw), baseURL);
          return { statement: url.toString(), solution: null };
        } catch {
          // L'adresse illisible : on regarde les autres liens de la page.
        }
      }
    }
    const documents = MoodleLinks.anchors(inHTML, baseURL).filter((anchor) => MoodleLinks.isDocument(anchor.href));
    const solution = documents.find((anchor) => MoodleLinks.isSolution(anchor));
    const statement = documents.find((anchor) => !MoodleLinks.isSolution(anchor));
    return { statement: statement?.href ?? null, solution: solution?.href ?? null };
  },

  /** Un PDF, ou un fichier déposé sur Moodle. */
  isDocument(href: string): boolean {
    let url: URL;
    try {
      url = new URL(href);
    } catch {
      return false;
    }
    return url.pathname.includes("/pluginfile.php/") || pathExtension(url.pathname) === "pdf";
  },

  isSolution(anchor: Anchor): boolean {
    let last = "";
    try {
      const path = new URL(anchor.href).pathname;
      last = path.split("/").filter((p) => p !== "").pop() ?? "";
      try {
        last = decodeURIComponent(last);
      } catch {
        // garde la forme encodée
      }
    } catch {
      last = "";
    }
    const haystack = ContentDraftBuilder.fold(anchor.text + " " + last);
    return icuRegExp(String.raw`(corrig|solution|\bsol\b|_sol\b|-sol\b|loesung|answers?\b|reponses)`).test(haystack);
  },

  decodeEntities(text: string): string {
    return text.split("&amp;").join("&")
      .split("&quot;").join("\"")
      .split("&#39;").join("'")
      .split("&lt;").join("<")
      .split("&gt;").join(">")
      .split("&nbsp;").join(" ");
  },
};
