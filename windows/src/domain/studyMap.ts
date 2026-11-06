// Port de Polymestre/Domain/StudyMap.swift : ce qui rend une fiche
// **compréhensible** et pas seulement un dictionnaire — les liens entre les
// notions, où l'on en est, une phrase en clair, des schémas, une question.
// Séparé de `RevisionSheet` exprès : la fiche est écrite et peut être refaite ;
// ce qui est à l'étudiant·e (liens, maîtrise, notes, nœuds, place) survit.

import { canonicalJSON } from "./revisionSheet.ts";
import { Diagram, type DiagramKind } from "./studyMapGraph.ts";

/** Ce qui relie deux notions : `A relation B` se lit « A <relation> B ». */
export type StudyRelation = "needs" | "implies" | "uses" | "contrast" | "example";

export const StudyRelation = {
  allCases: ["needs", "implies", "uses", "contrast", "example"] as readonly StudyRelation[],

  fromRaw(raw: string | null | undefined): StudyRelation | undefined {
    return raw != null && (StudyRelation.allCases as readonly string[]).includes(raw) ? (raw as StudyRelation) : undefined;
  },

  label(relation: StudyRelation): string {
    switch (relation) {
      case "needs": return "a besoin de";
      case "implies": return "implique";
      case "uses": return "se sert de";
      case "contrast": return "à ne pas confondre avec";
      case "example": return "est un exemple de";
    }
  },

  /** Vu de B : ce que B est pour A. */
  inverseLabel(relation: StudyRelation): string {
    switch (relation) {
      case "needs": return "est nécessaire à";
      case "implies": return "découle de";
      case "uses": return "sert à";
      case "contrast": return "à ne pas confondre avec";
      case "example": return "a pour exemple";
    }
  },

  icon(relation: StudyRelation): string {
    switch (relation) {
      case "needs": return "arrow.turn.up.left";
      case "implies": return "arrow.right";
      case "uses": return "wrench.and.screwdriver";
      case "contrast": return "arrow.left.arrow.right";
      case "example": return "lightbulb";
    }
  },
};

/** Où l'on en est sur une notion. Les valeurs brutes sont les entiers de Swift. */
export type StudyMastery = 0 | 1 | 2;

export const StudyMastery = {
  unknown: 0 as StudyMastery,
  shaky: 1 as StudyMastery,
  solid: 2 as StudyMastery,
  allCases: [0, 1, 2] as readonly StudyMastery[],

  label(level: StudyMastery): string {
    switch (level) {
      case 0: return "Pas encore";
      case 1: return "Fragile";
      case 2: return "Solide";
    }
  },
};

export interface StudyProgress {
  level: StudyMastery;
  at: Date;
}

export interface StudyCheck {
  question: string;
  answer: string;
}

/** Ce qu'une notion a de plus que son énoncé : pour la **comprendre**. */
export interface StudyEnrichment {
  gist?: string;
  why?: string;
  example?: string;
  check?: StudyCheck;
}

export interface StudyCustomNode {
  id: string;
  title: string;
  note?: string;
  /** La clé de la notion (ou l'identifiant du chapitre) à laquelle elle est accrochée. */
  parent?: string;
}

export interface StudyPoint {
  x: number;
  y: number;
}

export type StudyResourceKind = "podcast" | "video" | "quiz" | "slides" | "other";

export const StudyResourceKind = {
  allCases: ["podcast", "video", "quiz", "slides", "other"] as readonly StudyResourceKind[],

  fromRaw(raw: string | null | undefined): StudyResourceKind | undefined {
    return raw != null && (StudyResourceKind.allCases as readonly string[]).includes(raw)
      ? (raw as StudyResourceKind) : undefined;
  },

  label(kind: StudyResourceKind): string {
    switch (kind) {
      case "podcast": return "Podcast";
      case "video": return "Vidéo";
      case "quiz": return "Quiz";
      case "slides": return "Diapositives";
      case "other": return "Autre";
    }
  },

  icon(kind: StudyResourceKind): string {
    switch (kind) {
      case "podcast": return "waveform";
      case "video": return "play.rectangle";
      case "quiz": return "questionmark.circle";
      case "slides": return "rectangle.on.rectangle";
      case "other": return "doc";
    }
  },
};

export interface StudyResourceInit {
  id: string;
  kind: StudyResourceKind;
  title: string;
  /** Une adresse (le carnet, une vidéo)… */
  url?: string | null;
  /** …ou un fichier gardé dans l'app (un podcast importé). */
  fileName?: string | null;
  addedAt: Date;
  /** Le chapitre dont il parle (`null` : tout le cours). */
  chapter?: string | null;
}

export class StudyResource {
  id: string;
  kind: StudyResourceKind;
  title: string;
  url: string | null;
  fileName: string | null;
  addedAt: Date;
  chapter: string | null;

  constructor(o: StudyResourceInit) {
    this.id = o.id;
    this.kind = o.kind;
    this.title = o.title;
    this.url = o.url ?? null;
    this.fileName = o.fileName ?? null;
    this.addedAt = o.addedAt;
    this.chapter = o.chapter ?? null;
  }

  static readonly Kind = StudyResourceKind;

  toJSON(): Record<string, unknown> {
    return {
      id: this.id,
      kind: this.kind,
      title: this.title,
      ...(this.url !== null ? { url: this.url } : {}),
      ...(this.fileName !== null ? { fileName: this.fileName } : {}),
      addedAt: this.addedAt.getTime() / 1000,
      ...(this.chapter !== null ? { chapter: this.chapter } : {}),
    };
  }

  static fromJSON(value: unknown): StudyResource | null {
    if (value === null || typeof value !== "object") return null;
    const object = value as Record<string, unknown>;
    const kind = StudyResourceKind.fromRaw(typeof object["kind"] === "string" ? object["kind"] as string : undefined);
    if (kind === undefined || typeof object["id"] !== "string" || typeof object["title"] !== "string"
        || typeof object["addedAt"] !== "number") return null;
    return new StudyResource({
      id: object["id"] as string,
      kind,
      title: object["title"] as string,
      url: typeof object["url"] === "string" ? object["url"] as string : null,
      fileName: typeof object["fileName"] === "string" ? object["fileName"] as string : null,
      addedAt: new Date((object["addedAt"] as number) * 1000),
      chapter: typeof object["chapter"] === "string" ? object["chapter"] as string : null,
    });
  }
}

export interface StudyLinkInit {
  from: string;
  to: string;
  relation: StudyRelation;
  note?: string | null;
  /** Posé à la main (jamais écrasé par une nouvelle lecture du cours). */
  userMade?: boolean;
}

export class StudyLink {
  from: string;
  to: string;
  relation: StudyRelation;
  note: string | null;
  userMade: boolean;

  constructor(o: StudyLinkInit) {
    this.from = o.from;
    this.to = o.to;
    this.relation = o.relation;
    this.note = o.note ?? null;
    this.userMade = o.userMade ?? false;
  }

  get id(): string { return `${this.from}>${this.relation}>${this.to}`; }

  /** La notion qui doit venir **avant** l'autre, si la relation fixe un ordre. */
  get prerequisite(): { before: string; after: string } | null {
    switch (this.relation) {
      case "needs": case "uses": case "example": return { before: this.to, after: this.from };
      case "implies": return { before: this.from, after: this.to };
      case "contrast": return null;
    }
  }

  toJSON(): Record<string, unknown> {
    return {
      from: this.from,
      to: this.to,
      relation: this.relation,
      ...(this.note !== null ? { note: this.note } : {}),
      userMade: this.userMade,
    };
  }

  static fromJSON(value: unknown): StudyLink | null {
    if (value === null || typeof value !== "object") return null;
    const object = value as Record<string, unknown>;
    const relation = StudyRelation.fromRaw(typeof object["relation"] === "string" ? object["relation"] as string : undefined);
    if (relation === undefined || typeof object["from"] !== "string" || typeof object["to"] !== "string") return null;
    return new StudyLink({
      from: object["from"] as string,
      to: object["to"] as string,
      relation,
      note: typeof object["note"] === "string" ? object["note"] as string : null,
      userMade: object["userMade"] === true,
    });
  }
}

export class StudyMap {
  version = 1;

  // Liens
  links: StudyLink[] = [];

  // Où j'en suis
  progress: Record<string, StudyProgress> = {};
  notes: Record<string, string> = {};

  // En clair
  enrichment: Record<string, StudyEnrichment> = {};

  // Carte mentale
  customNodes: StudyCustomNode[] = [];
  layout: Record<string, StudyPoint> = {};
  collapsed: Set<string> = new Set();

  // Schémas
  diagrams: Diagram[] = [];

  // NotebookLM
  notebookURL: string | null = null;
  chapterNotebooks: Record<string, string> | null = null;
  /** Les chapitres que Claude a relus, et quand (`enrichedAt` : le cours entier). */
  enrichedChapters: Record<string, Date> | null = null;
  resources: StudyResource[] = [];

  /** Quand les liens, les phrases en clair et les schémas ont été écrits (par Claude). */
  enrichedAt: Date | null = null;

  static readonly Relation = StudyRelation;
  static readonly Mastery = StudyMastery;
  static readonly Link = StudyLink;
  static readonly Resource = StudyResource;

  get isEmpty(): boolean {
    return this.links.length === 0 && Object.keys(this.progress).length === 0
      && Object.keys(this.enrichment).length === 0 && this.diagrams.length === 0
      && this.customNodes.length === 0 && this.resources.length === 0
      && Object.keys(this.enrichedChapters ?? {}).length === 0;
  }

  mastery(key: string): StudyMastery {
    return this.progress[key]?.level ?? 0;
  }

  /** `StudyMap.decode` : `null` si vide ou illisible. */
  static decode(raw: string): StudyMap | null {
    if (raw === "") return null;
    let value: unknown;
    try { value = JSON.parse(raw); } catch { return null; }
    if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
    return studyMapFromJSON(value as Record<string, unknown>);
  }

  /** `JSONEncoder` avec `.sortedKeys` ; les dates en secondes depuis 1970. */
  encoded(): string {
    const progress: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(this.progress)) {
      progress[key] = { level: item.level, at: item.at.getTime() / 1000 };
    }
    const enrichment: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(this.enrichment)) {
      enrichment[key] = {
        ...(item.gist !== undefined ? { gist: item.gist } : {}),
        ...(item.why !== undefined ? { why: item.why } : {}),
        ...(item.example !== undefined ? { example: item.example } : {}),
        ...(item.check !== undefined ? { check: { question: item.check.question, answer: item.check.answer } } : {}),
      };
    }
    const layout: Record<string, StudyPoint> = {};
    for (const [key, point] of Object.entries(this.layout)) layout[key] = { x: point.x, y: point.y };
    const enrichedChapters: Record<string, number> | null = this.enrichedChapters === null ? null : {};
    if (enrichedChapters !== null && this.enrichedChapters !== null) {
      for (const [key, date] of Object.entries(this.enrichedChapters)) enrichedChapters[key] = date.getTime() / 1000;
    }
    return canonicalJSON({
      version: this.version,
      links: this.links.map((link) => link.toJSON()),
      progress,
      notes: this.notes,
      enrichment,
      customNodes: this.customNodes.map((node) => ({
        id: node.id,
        title: node.title,
        ...(node.note !== undefined ? { note: node.note } : {}),
        ...(node.parent !== undefined ? { parent: node.parent } : {}),
      })),
      layout,
      collapsed: [...this.collapsed].sort(),
      diagrams: this.diagrams.map((diagram) => diagram.toJSON()),
      resources: this.resources.map((resource) => resource.toJSON()),
      ...(this.notebookURL !== null ? { notebookURL: this.notebookURL } : {}),
      ...(this.chapterNotebooks !== null ? { chapterNotebooks: this.chapterNotebooks } : {}),
      ...(enrichedChapters !== null ? { enrichedChapters } : {}),
      ...(this.enrichedAt !== null ? { enrichedAt: this.enrichedAt.getTime() / 1000 } : {}),
    });
  }
}

function studyMapFromJSON(value: Record<string, unknown>): StudyMap {
  const map = new StudyMap();
  if (typeof value["version"] === "number") map.version = value["version"];

  if (Array.isArray(value["links"])) {
    map.links = (value["links"] as unknown[]).map(StudyLink.fromJSON).filter((link): link is StudyLink => link !== null);
  }

  const progress = value["progress"];
  if (progress !== null && typeof progress === "object" && !Array.isArray(progress)) {
    for (const [key, item] of Object.entries(progress as Record<string, unknown>)) {
      if (item === null || typeof item !== "object") continue;
      const object = item as Record<string, unknown>;
      const level = object["level"];
      const at = object["at"];
      if ((level !== 0 && level !== 1 && level !== 2) || typeof at !== "number") continue;
      map.progress[key] = { level, at: new Date(at * 1000) };
    }
  }

  const notes = value["notes"];
  if (notes !== null && typeof notes === "object" && !Array.isArray(notes)) {
    for (const [key, item] of Object.entries(notes as Record<string, unknown>)) {
      if (typeof item === "string") map.notes[key] = item;
    }
  }

  const enrichment = value["enrichment"];
  if (enrichment !== null && typeof enrichment === "object" && !Array.isArray(enrichment)) {
    for (const [key, item] of Object.entries(enrichment as Record<string, unknown>)) {
      if (item === null || typeof item !== "object") continue;
      const object = item as Record<string, unknown>;
      const parsed: StudyEnrichment = {};
      if (typeof object["gist"] === "string") parsed.gist = object["gist"];
      if (typeof object["why"] === "string") parsed.why = object["why"];
      if (typeof object["example"] === "string") parsed.example = object["example"];
      const check = object["check"];
      if (check !== null && typeof check === "object") {
        const c = check as Record<string, unknown>;
        if (typeof c["question"] === "string" && typeof c["answer"] === "string") {
          parsed.check = { question: c["question"], answer: c["answer"] };
        }
      }
      map.enrichment[key] = parsed;
    }
  }

  if (Array.isArray(value["customNodes"])) {
    for (const item of value["customNodes"] as unknown[]) {
      if (item === null || typeof item !== "object") continue;
      const object = item as Record<string, unknown>;
      if (typeof object["id"] !== "string" || typeof object["title"] !== "string") continue;
      map.customNodes.push({
        id: object["id"] as string,
        title: object["title"] as string,
        ...(typeof object["note"] === "string" ? { note: object["note"] as string } : {}),
        ...(typeof object["parent"] === "string" ? { parent: object["parent"] as string } : {}),
      });
    }
  }

  const layout = value["layout"];
  if (layout !== null && typeof layout === "object" && !Array.isArray(layout)) {
    for (const [key, item] of Object.entries(layout as Record<string, unknown>)) {
      if (item === null || typeof item !== "object") continue;
      const point = item as Record<string, unknown>;
      if (typeof point["x"] === "number" && typeof point["y"] === "number") {
        map.layout[key] = { x: point["x"], y: point["y"] };
      }
    }
  }

  if (Array.isArray(value["collapsed"])) {
    map.collapsed = new Set((value["collapsed"] as unknown[]).filter((item): item is string => typeof item === "string"));
  }

  if (Array.isArray(value["diagrams"])) {
    map.diagrams = (value["diagrams"] as unknown[])
      .map((item) => Diagram.fromJSON(item))
      .filter((diagram): diagram is Diagram => diagram !== null);
  }

  if (Array.isArray(value["resources"])) {
    map.resources = (value["resources"] as unknown[])
      .map((item) => StudyResource.fromJSON(item))
      .filter((resource): resource is StudyResource => resource !== null);
  }

  if (typeof value["notebookURL"] === "string") map.notebookURL = value["notebookURL"];
  const chapterNotebooks = value["chapterNotebooks"];
  if (chapterNotebooks !== null && typeof chapterNotebooks === "object" && !Array.isArray(chapterNotebooks)) {
    map.chapterNotebooks = {};
    for (const [key, item] of Object.entries(chapterNotebooks as Record<string, unknown>)) {
      if (typeof item === "string") map.chapterNotebooks[key] = item;
    }
  }
  const enrichedChapters = value["enrichedChapters"];
  if (enrichedChapters !== null && typeof enrichedChapters === "object" && !Array.isArray(enrichedChapters)) {
    map.enrichedChapters = {};
    for (const [key, item] of Object.entries(enrichedChapters as Record<string, unknown>)) {
      if (typeof item === "number") map.enrichedChapters[key] = new Date(item * 1000);
    }
  }
  if (typeof value["enrichedAt"] === "number") map.enrichedAt = new Date((value["enrichedAt"] as number) * 1000);
  return map;
}

/** `Diagram` a besoin du type de chapitre pour son `kind` ; garde l'import visible. */
export type { DiagramKind };
