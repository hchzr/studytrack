// Port de Polymestre/Domain/StudyMapGraph.swift : les schémas (flow,
// dépendances, arbre, comparaison) et leur disposition, la carte mentale des
// deux côtés de la racine, les liens déduits des citations, et l'ordre dans
// lequel apprendre.

import type { RevisionSheet, KeyedEntry } from "./revisionSheet.ts";
import { StudyLink, type StudyMap, type StudyMastery, type StudyPoint, type StudyRelation } from "./studyMap.ts";

// MARK: - Schémas

export type DiagramKind = "flow" | "dependencies" | "tree" | "comparison";

export const DiagramKind = {
  allCases: ["flow", "dependencies", "tree", "comparison"] as readonly DiagramKind[],

  fromRaw(raw: string | null | undefined): DiagramKind | undefined {
    return raw != null && (DiagramKind.allCases as readonly string[]).includes(raw) ? (raw as DiagramKind) : undefined;
  },

  label(kind: DiagramKind): string {
    switch (kind) {
      case "flow": return "Enchaînement";
      case "dependencies": return "Qui découle de quoi";
      case "tree": return "Que choisir ?";
      case "comparison": return "Comparaison";
    }
  },

  icon(kind: DiagramKind): string {
    switch (kind) {
      case "flow": return "arrow.down.to.line";
      case "dependencies": return "point.3.connected.trianglepath.dotted";
      case "tree": return "arrow.triangle.branch";
      case "comparison": return "tablecells";
    }
  },
};

export interface DiagramNode {
  id: string;
  label: string;
  detail?: string;
  /** La clé de la notion de la fiche (toucher le nœud y mène). */
  entry?: string;
}

export interface DiagramEdge {
  from: string;
  to: string;
  label?: string;
}

export interface DiagramInit {
  id: string;
  title: string;
  summary?: string | null;
  kind: DiagramKind;
  nodes?: DiagramNode[];
  edges?: DiagramEdge[];
  columns?: string[] | null;
  rows?: string[][] | null;
  /** Le chapitre qu'il éclaire (`null` : tout le cours). */
  chapter?: string | null;
}

/** Un schéma pour **comprendre**, dessiné par l'app (jamais une image). */
export class Diagram {
  id: string;
  title: string;
  summary: string | null;
  kind: DiagramKind;
  nodes: DiagramNode[];
  edges: DiagramEdge[];
  columns: string[] | null;
  rows: string[][] | null;
  chapter: string | null;

  constructor(o: DiagramInit) {
    this.id = o.id;
    this.title = o.title;
    this.summary = o.summary ?? null;
    this.kind = o.kind;
    this.nodes = o.nodes ?? [];
    this.edges = o.edges ?? [];
    this.columns = o.columns ?? null;
    this.rows = o.rows ?? null;
    this.chapter = o.chapter ?? null;
  }

  static readonly Kind = DiagramKind;

  toJSON(): Record<string, unknown> {
    return {
      id: this.id,
      title: this.title,
      ...(this.summary !== null ? { summary: this.summary } : {}),
      kind: this.kind,
      nodes: this.nodes.map((node) => ({
        id: node.id,
        label: node.label,
        ...(node.detail !== undefined ? { detail: node.detail } : {}),
        ...(node.entry !== undefined ? { entry: node.entry } : {}),
      })),
      edges: this.edges.map((edge) => ({
        from: edge.from,
        to: edge.to,
        ...(edge.label !== undefined ? { label: edge.label } : {}),
      })),
      ...(this.columns !== null ? { columns: this.columns } : {}),
      ...(this.rows !== null ? { rows: this.rows } : {}),
      ...(this.chapter !== null ? { chapter: this.chapter } : {}),
    };
  }

  static fromJSON(value: unknown): Diagram | null {
    if (value === null || typeof value !== "object") return null;
    const object = value as Record<string, unknown>;
    const kind = DiagramKind.fromRaw(typeof object["kind"] === "string" ? object["kind"] as string : undefined);
    if (kind === undefined || typeof object["id"] !== "string" || typeof object["title"] !== "string") return null;
    const nodes: DiagramNode[] = [];
    if (Array.isArray(object["nodes"])) {
      for (const item of object["nodes"] as unknown[]) {
        if (item === null || typeof item !== "object") continue;
        const node = item as Record<string, unknown>;
        if (typeof node["id"] !== "string" || typeof node["label"] !== "string") continue;
        nodes.push({
          id: node["id"] as string,
          label: node["label"] as string,
          ...(typeof node["detail"] === "string" ? { detail: node["detail"] as string } : {}),
          ...(typeof node["entry"] === "string" ? { entry: node["entry"] as string } : {}),
        });
      }
    }
    const edges: DiagramEdge[] = [];
    if (Array.isArray(object["edges"])) {
      for (const item of object["edges"] as unknown[]) {
        if (item === null || typeof item !== "object") continue;
        const edge = item as Record<string, unknown>;
        if (typeof edge["from"] !== "string" || typeof edge["to"] !== "string") continue;
        edges.push({
          from: edge["from"] as string,
          to: edge["to"] as string,
          ...(typeof edge["label"] === "string" ? { label: edge["label"] as string } : {}),
        });
      }
    }
    const columns = Array.isArray(object["columns"])
      ? (object["columns"] as unknown[]).filter((c): c is string => typeof c === "string") : null;
    const rows = Array.isArray(object["rows"])
      ? (object["rows"] as unknown[]).map((row) =>
          Array.isArray(row) ? row.map((cell) => (typeof cell === "string" ? cell : "")) : [])
      : null;
    return new Diagram({
      id: object["id"] as string,
      title: object["title"] as string,
      summary: typeof object["summary"] === "string" ? object["summary"] as string : null,
      kind,
      nodes,
      edges,
      columns,
      rows,
      chapter: typeof object["chapter"] === "string" ? object["chapter"] as string : null,
    });
  }
}

/** La disposition d'un schéma en couches, de haut en bas. */
export class DiagramLayoutResult {
  /** Le centre de chaque nœud. */
  positions: Record<string, StudyPoint>;
  width: number;
  height: number;
  /** Les couches, dans l'ordre (les identifiants de chaque couche, de gauche à droite). */
  layers: string[][];
  /** Les flèches qui reviennent en arrière (un cycle) : tracées, sans compter pour les couches. */
  backEdges: DiagramEdge[];

  constructor(o: DiagramLayoutResult) {
    this.positions = o.positions;
    this.width = o.width;
    this.height = o.height;
    this.layers = o.layers;
    this.backEdges = o.backEdges;
  }
}

export const DiagramLayout = {
  layered(schema: Diagram, nodeWidth = 170, nodeHeight = 54,
          horizontalGap = 28, verticalGap = 46): DiagramLayoutResult {
    const ids = schema.nodes.map((node) => node.id);
    const known = new Set(ids);
    const edges = schema.edges.filter((edge) =>
      known.has(edge.from) && known.has(edge.to) && edge.from !== edge.to);

    // Cycles : une flèche qui revient sur un nœud encore ouvert ne compte pas pour les couches.
    const outgoing = new Map<string, DiagramEdge[]>();
    for (const edge of edges) {
      const list = outgoing.get(edge.from) ?? [];
      list.push(edge);
      outgoing.set(edge.from, list);
    }
    const state = new Map<string, number>(); // 1 : en cours, 2 : fini
    const back: DiagramEdge[] = [];
    const visit = (id: string): void => {
      state.set(id, 1);
      for (const edge of outgoing.get(id) ?? []) {
        switch (state.get(edge.to)) {
          case 1: back.push(edge); break;
          case undefined: visit(edge.to); break;
          default: break;
        }
      }
      state.set(id, 2);
    };
    for (const id of ids) if (!state.has(id)) visit(id);
    const forward = edges.filter((edge) => !back.includes(edge));

    // Couche = plus long chemin depuis une source.
    const layerOf = new Map<string, number>();
    const incoming = new Map<string, string[]>();
    for (const edge of forward) {
      const list = incoming.get(edge.to) ?? [];
      list.push(edge.from);
      incoming.set(edge.to, list);
    }
    const layer = (id: string): number => {
      const memo = layerOf.get(id);
      if (memo !== undefined) return memo;
      layerOf.set(id, 0);
      const parents = incoming.get(id) ?? [];
      const value = parents.length === 0 ? 0 : Math.max(...parents.map((parent) => layer(parent) + 1));
      layerOf.set(id, value);
      return value;
    };
    for (const id of ids) layer(id);
    const depth = (layerOf.size === 0 ? -1 : Math.max(...layerOf.values())) + 1;
    const layers: string[][] = Array.from({ length: Math.max(depth, 0) }, () => []);
    for (const id of ids) layers[layerOf.get(id) ?? 0].push(id);

    // Ordre dans chaque couche : deux passages au barycentre des voisins.
    const position = new Map<string, number>();
    for (const row of layers) row.forEach((id, index) => position.set(id, index));
    const neighbours = new Map<string, string[]>();
    for (const edge of forward) {
      const from = neighbours.get(edge.from) ?? [];
      from.push(edge.to);
      neighbours.set(edge.from, from);
      const to = neighbours.get(edge.to) ?? [];
      to.push(edge.from);
      neighbours.set(edge.to, to);
    }
    const sweep = (order: number[]): void => {
      for (const index of order) {
        const centre = (id: string): number => {
          const near = (neighbours.get(id) ?? []).filter((other) => layerOf.get(other) !== index);
          if (near.length === 0) return position.get(id) ?? 0;
          return near.reduce((sum, other) => sum + (position.get(other) ?? 0), 0) / near.length;
        };
        const sorted = layers[index]
          .map((id, offset) => ({ id, offset }))
          .sort((a, b) => {
            const ca = centre(a.id), cb = centre(b.id);
            return ca !== cb ? ca - cb : a.offset - b.offset;
          })
          .map((item) => item.id);
        layers[index] = sorted;
        sorted.forEach((id, i) => position.set(id, i));
      }
    };
    if (depth > 1) {
      sweep(Array.from({ length: depth - 1 }, (_, i) => i + 1));
      sweep(Array.from({ length: depth - 1 }, (_, i) => depth - 2 - i));
    }

    const widest = layers.length === 0 ? 0 : Math.max(...layers.map((row) => row.length));
    const totalWidth = widest * nodeWidth + Math.max(0, widest - 1) * horizontalGap;
    const positions: Record<string, StudyPoint> = {};
    layers.forEach((row, rowIndex) => {
      const rowWidth = row.length * nodeWidth + Math.max(0, row.length - 1) * horizontalGap;
      const start = (totalWidth - rowWidth) / 2;
      row.forEach((id, column) => {
        positions[id] = {
          x: start + nodeWidth / 2 + column * (nodeWidth + horizontalGap),
          y: nodeHeight / 2 + rowIndex * (nodeHeight + verticalGap),
        };
      });
    });
    const height = depth === 0 ? 0 : depth * nodeHeight + (depth - 1) * verticalGap;
    return new DiagramLayoutResult({ positions, width: totalWidth, height, layers, backEdges: back });
  },
};

// MARK: - Carte mentale

export type MindRole =
  | { kind: "root" }
  | { kind: "chapter" }
  | { kind: "entry"; entryKind: string }
  | { kind: "custom" };

export interface MindNode {
  id: string;
  title: string;
  role: MindRole;
  parent: string | null;
  depth: number;
}

export const MindGraph = {
  rootID: "root",

  chapterNode(chapterID: string): string { return "chap:" + chapterID; },
  customNode(id: string): string { return "custom:" + id; },

  /**
   * Tous les nœuds : la racine, ses chapitres, leurs notions, puis les idées ajoutées
   * (accrochées à ce qu'on a choisi ; si le parent n'existe plus, à la racine).
   * Avec `chapter` : la carte de ce chapitre seul, lui en racine et ses notions autour.
   */
  nodes(sheet: RevisionSheet, map: StudyMap, courseTitle: string, chapter: string | null = null): MindNode[] {
    const scoped = sheet.chapter(chapter);
    if (chapter !== null && scoped !== null) {
      const result: MindNode[] = [{ id: MindGraph.rootID, title: scoped.title, role: { kind: "root" }, parent: null, depth: 0 }];
      for (const item of sheet.keyedIn(chapter)) {
        result.push({ id: item.key, title: item.entry.title, role: { kind: "entry", entryKind: item.entry.kind }, parent: MindGraph.rootID, depth: 1 });
      }
      // Les idées accrochées à ce chapitre ou à l'une de ses notions.
      for (const custom of map.customNodes) {
        if (custom.parent === undefined) continue;
        const wanted = custom.parent;
        const parent = wanted === MindGraph.chapterNode(chapter) ? MindGraph.rootID : wanted;
        const host = result.find((node) => node.id === parent);
        if (host === undefined) continue;
        result.push({ id: MindGraph.customNode(custom.id), title: custom.title, role: { kind: "custom" }, parent, depth: host.depth + 1 });
      }
      return result;
    }

    const result: MindNode[] = [{ id: MindGraph.rootID, title: courseTitle, role: { kind: "root" }, parent: null, depth: 0 }];
    for (const item of sheet.chapters) {
      if (item.entries.length === 0) continue;
      result.push({ id: MindGraph.chapterNode(item.id), title: item.title, role: { kind: "chapter" }, parent: MindGraph.rootID, depth: 1 });
    }
    for (const item of sheet.keyed) {
      result.push({
        id: item.key, title: item.entry.title, role: { kind: "entry", entryKind: item.entry.kind },
        parent: MindGraph.chapterNode(item.chapterID), depth: 2,
      });
    }
    for (const custom of map.customNodes) {
      const parent = custom.parent !== undefined && result.some((node) => node.id === custom.parent)
        ? custom.parent : MindGraph.rootID;
      const host = result.find((node) => node.id === parent);
      result.push({
        id: MindGraph.customNode(custom.id), title: custom.title, role: { kind: "custom" },
        parent, depth: (host?.depth ?? 0) + 1,
      });
    }
    return result;
  },

  /** Ce qu'on voit : sans les descendants d'un nœud replié. */
  visible(nodes: MindNode[], collapsed: Set<string>): MindNode[] {
    const children = new Map<string, string[]>();
    for (const node of nodes) {
      if (node.parent === null) continue;
      const list = children.get(node.parent) ?? [];
      list.push(node.id);
      children.set(node.parent, list);
    }
    const hidden = new Set<string>();
    const hide = (id: string): void => {
      for (const child of children.get(id) ?? []) {
        hidden.add(child);
        hide(child);
      }
    };
    for (const id of collapsed) hide(id);
    return nodes.filter((node) => !hidden.has(node.id));
  },
};

/** La disposition d'une carte mentale **des deux côtés** de la racine. */
export const MindLayout = {
  columnWidth: 240.0,
  rowHeight: 44.0,

  twoSided(nodes: MindNode[], columnWidth = 240.0, rowHeight = 44.0): Record<string, StudyPoint> {
    const children = new Map<string, MindNode[]>();
    for (const node of nodes) {
      if (node.parent === null) continue;
      const list = children.get(node.parent) ?? [];
      list.push(node);
      children.set(node.parent, list);
    }
    const root = nodes.find((node) => node.parent === null);
    if (root === undefined) return {};

    const leaves = (id: string): number => {
      const list = children.get(id) ?? [];
      return list.length === 0 ? 1 : list.reduce((sum, child) => sum + leaves(child.id), 0);
    };
    // Les chapitres des deux côtés, à peu près autant de lignes de chaque.
    const sides: MindNode[][] = [[], []];
    const weights = [0, 0];
    for (const child of children.get(root.id) ?? []) {
      const side = weights[0] <= weights[1] ? 0 : 1;
      sides[side].push(child);
      weights[side] += leaves(child.id);
    }

    const positions: Record<string, StudyPoint> = { [root.id]: { x: 0, y: 0 } };
    sides.forEach((roots, side) => {
      const direction = side === 0 ? 1.0 : -1.0;
      let row = 0.0;
      const local = new Map<string, number>();
      const place = (node: MindNode): number => {
        const list = children.get(node.id) ?? [];
        if (list.length === 0) {
          const y = row;
          row += 1;
          local.set(node.id, y);
          return y;
        }
        const ys = list.map(place);
        const y = ((ys[0] ?? row) + (ys[ys.length - 1] ?? row)) / 2;
        local.set(node.id, y);
        return y;
      };
      for (const node of roots) place(node);
      const centre = row > 0 ? (row - 1) / 2 : 0;
      const absolute = (node: MindNode, depth: number): void => {
        const y = local.get(node.id);
        if (y !== undefined) {
          positions[node.id] = { x: direction * depth * columnWidth, y: (y - centre) * rowHeight };
        }
        for (const child of children.get(node.id) ?? []) absolute(child, depth + 1);
      };
      for (const node of roots) absolute(node, 1);
    });
    return positions;
  },

  /** Le rectangle qui contient tous les centres (pour centrer et ajuster la vue). */
  bounds(positions: Record<string, StudyPoint>): { minX: number; maxX: number; minY: number; maxY: number } | null {
    const values = Object.values(positions);
    const first = values[0];
    if (first === undefined) return null;
    const box = { minX: first.x, maxX: first.x, minY: first.y, maxY: first.y };
    for (const point of values) {
      box.minX = Math.min(box.minX, point.x);
      box.maxX = Math.max(box.maxX, point.x);
      box.minY = Math.min(box.minY, point.y);
      box.maxY = Math.max(box.maxY, point.y);
    }
    return box;
  },
};

// MARK: - Liens

export interface NeighbourhoodItem {
  key: string;
  relation: StudyRelation;
  note: string | null;
}

export interface Neighbourhood {
  before: NeighbourhoodItem[];
  after: NeighbourhoodItem[];
  aside: NeighbourhoodItem[];
}

export const StudyLinks = {
  /** Ce qui précède et ce qui suit une notion, vu depuis elle. */
  neighbourhood(of: string, inMap: StudyMap, among: Set<string>): Neighbourhood {
    const result: Neighbourhood = { before: [], after: [], aside: [] };
    const add = (list: NeighbourhoodItem[], item: NeighbourhoodItem): void => {
      // Une notion n'apparaît qu'une fois : le lien déduit d'une citation et celui de Claude
      // sur la même paire ne font pas deux lignes (on garde celui qui explique).
      const index = list.findIndex((existing) => existing.key === item.key);
      if (index >= 0) {
        if (list[index].note === null && item.note !== null) list[index] = item;
      } else {
        list.push(item);
      }
    };
    for (const link of inMap.links) {
      if (!among.has(link.from) || !among.has(link.to)) continue;
      if (link.relation === "contrast") {
        if (link.from === of) add(result.aside, { key: link.to, relation: "contrast", note: link.note });
        else if (link.to === of) add(result.aside, { key: link.from, relation: "contrast", note: link.note });
        continue;
      }
      const order = link.prerequisite;
      if (order === null) continue;
      if (order.after === of) add(result.before, { key: order.before, relation: link.relation, note: link.note });
      if (order.before === of) add(result.after, { key: order.after, relation: link.relation, note: link.note });
    }
    return result;
  },

  /**
   * Les liens qu'on déduit **sans IA** : une notion qui en cite une autre
   * (« par le théorème 3.4 ») s'en sert.
   */
  cited(inSheet: RevisionSheet, limitPerEntry = 6): StudyLink[] {
    const items = inSheet.keyed;
    const byNumber = new Map<string, KeyedEntry[]>();
    for (const item of items) {
      const number = textNumber(item.entry.title);
      if (number === null) continue;
      const list = byNumber.get(number) ?? [];
      list.push(item);
      byNumber.set(number, list);
    }
    if (byNumber.size === 0) return [];

    const group = (word: string): Set<string> | null => {
      if (word.startsWith("theo") || word.startsWith("th")) return new Set(["theorem"]);
      if (word.startsWith("prop")) return new Set(["proposition"]);
      if (word.startsWith("lem")) return new Set(["lemma"]);
      if (word.startsWith("cor")) return new Set(["corollary"]);
      if (word.startsWith("def")) return new Set(["definition"]);
      if (word.startsWith("form")) return new Set(["formula"]);
      return null;
    };

    const pattern = /(theoreme|theorem|proposition|prop\.?|lemme|lemma|corollaire|corollary|definition|def\.?|formule|formula|th\.?)\s*(\d+(?:\.\d+)+)/g;
    const links: StudyLink[] = [];
    const seen = new Set<string>();
    for (const item of items) {
      const text = foldText(item.entry.title + " " + item.entry.body);
      let count = 0;
      for (const match of text.matchAll(pattern)) {
        if (count >= limitPerEntry) break;
        if (match[1] === undefined || match[2] === undefined) continue;
        const word = match[1];
        const number = match[2];
        const candidates = byNumber.get(number);
        if (candidates === undefined) continue;
        const wanted = group(word);
        const target = candidates.find((candidate) => wanted?.has(candidate.entry.kind) ?? true)
          ?? (candidates.length === 1 ? candidates[0] : undefined);
        if (target === undefined || target.key === item.key) continue;
        const link = new StudyLink({ from: item.key, to: target.key, relation: "uses" });
        if (!seen.has(link.id)) {
          seen.add(link.id);
          links.push(link);
          count += 1;
        }
      }
    }
    return links;
  },

  /**
   * Les liens d'une nouvelle lecture : ceux posés à la main restent, les autres sont
   * remplacés ; tout lien vers une notion qui n'existe plus tombe.
   */
  merged(existing: StudyLink[], generated: StudyLink[], keys: Set<string>): StudyLink[] {
    const result: StudyLink[] = [];
    const seen = new Set<string>();
    for (const link of existing) {
      if (!link.userMade || !keys.has(link.from) || !keys.has(link.to)) continue;
      if (!seen.has(link.id)) { seen.add(link.id); result.push(link); }
    }
    for (const link of generated) {
      if (!keys.has(link.from) || !keys.has(link.to) || link.from === link.to) continue;
      if (!seen.has(link.id)) { seen.add(link.id); result.push(link); }
    }
    return result;
  },
};

function foldText(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}

function textNumber(title: string): string | null {
  const match = /\d+(?:\.\d+)+/.exec(title);
  return match === null ? null : match[0];
}

// MARK: - Le parcours

export class LearningPathCounts {
  unknown: number;
  shaky: number;
  solid: number;

  constructor(o: { unknown?: number; shaky?: number; solid?: number } = {}) {
    this.unknown = o.unknown ?? 0;
    this.shaky = o.shaky ?? 0;
    this.solid = o.solid ?? 0;
  }

  get total(): number { return this.unknown + this.shaky + this.solid; }
  get fraction(): number { return this.total === 0 ? 0 : this.solid / this.total; }
}

/** Dans quel ordre apprendre, et par où reprendre : ce qui vient avant passe avant. */
export const LearningPath = {
  /** Les notions dans l'ordre où les comprendre : celui de la fiche, sauf qu'une notion ne passe jamais avant ce dont elle a besoin. */
  order(sheet: RevisionSheet, map: StudyMap, chapter: string | null = null): string[] {
    const items = sheet.keyedIn(chapter);
    const keys = items.map((item) => item.key);
    const known = new Set(keys);
    const before = new Map<string, Set<string>>();
    const after = new Map<string, Set<string>>();
    for (const link of map.links) {
      const pair = link.prerequisite;
      if (pair === null || !known.has(pair.before) || !known.has(pair.after) || pair.before === pair.after) continue;
      const b = before.get(pair.after) ?? new Set<string>();
      b.add(pair.before);
      before.set(pair.after, b);
      const a = after.get(pair.before) ?? new Set<string>();
      a.add(pair.after);
      after.set(pair.before, a);
    }
    const done = new Set<string>();
    const result: string[] = [];
    const remaining = [...keys];
    while (remaining.length !== 0) {
      // Le premier, dans l'ordre de la fiche, dont tout ce qu'il faut est déjà passé.
      const index = remaining.findIndex((key) => [...(before.get(key) ?? [])].every((need) => done.has(need)));
      if (index >= 0) {
        const [key] = remaining.splice(index, 1);
        result.push(key);
        done.add(key);
      } else {
        // Un cycle : on coupe à l'ordre de la fiche.
        const key = remaining.shift()!;
        result.push(key);
        done.add(key);
      }
    }
    return result;
  },

  /** Par où continuer : la première notion de l'ordre qui n'est pas encore solide. */
  next(sheet: RevisionSheet, map: StudyMap, chapter: string | null = null): string | null {
    return LearningPath.order(sheet, map, chapter).find((key) => map.mastery(key) !== 2) ?? null;
  },

  counts(sheet: RevisionSheet, map: StudyMap, chapter: string | null = null): LearningPathCounts {
    const result = new LearningPathCounts();
    for (const item of sheet.keyedIn(chapter)) {
      switch (map.mastery(item.key)) {
        case 0: result.unknown += 1; break;
        case 1: result.shaky += 1; break;
        case 2: result.solid += 1; break;
      }
    }
    return result;
  },

  /** Ce qu'il vaut mieux reprendre d'abord : pas solide, et dont d'autres dépendent. */
  weakSpots(sheet: RevisionSheet, map: StudyMap, limit = 5, chapter: string | null = null): string[] {
    const known = new Set(sheet.keyedIn(chapter).map((item) => item.key));
    const dependents = new Map<string, number>();
    for (const link of map.links) {
      const pair = link.prerequisite;
      if (pair === null || !known.has(pair.before) || !known.has(pair.after)) continue;
      dependents.set(pair.before, (dependents.get(pair.before) ?? 0) + 1);
    }
    const scored: { key: string; weight: number; index: number }[] = [];
    for (const item of sheet.keyedIn(chapter)) {
      const level = map.mastery(item.key);
      if (level === 2) continue;
      const weight = (1 + (dependents.get(item.key) ?? 0)) * (level === 0 ? 1.5 : 1);
      scored.push({ key: item.key, weight, index: item.index });
    }
    return scored
      .sort((a, b) => (a.weight !== b.weight ? b.weight - a.weight : a.index - b.index))
      .slice(0, limit)
      .map((item) => item.key);
  },

  /** Les prérequis d'une notion qui ne sont pas encore solides. */
  shakyPrerequisites(of: string, map: StudyMap, among: Set<string>): string[] {
    return StudyLinks.neighbourhood(of, map, among).before
      .map((item) => item.key)
      .filter((key) => map.mastery(key) !== 2);
  },
};

/** Les types de studyMap.ts, réexportés pour les appelants de ce module. */
export type { StudyPoint, StudyMastery };
