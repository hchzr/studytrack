// Un document Botafogo, lu comme le site le montre (Polymestre/Domain/BotafogoPage.swift).
//
// Un morceau d'un document Botafogo (Nuxt Content, « minimark »), prêt à dessiner :
// texte avec ses formules et ses liens, listes (en colonnes comme sur le site),
// formules isolées, images, vidéos, figures, théorèmes encadrés, exercices,
// indications et solutions repliées, quiz.
//
// **Les emplacements.** Les composants du site rangent leur titre dans un
// `template` marqué `#title` et leur contenu dans `#default` (un choix de quiz,
// dans `#text`).

import { MathMarkup } from "./mathMarkup.ts";
import { characters, isNumber, isWhitespace } from "./textRepair.ts";

export type BotafogoBlock =
  | { type: "paragraph"; text: string }
  | { type: "heading"; text: string; level: number }
  /** `columns` > 1 quand le site la pose en colonnes (`multicols`). */
  | { type: "list"; items: BotafogoBlock[][]; ordered: boolean; columns: number }
  | { type: "math"; tex: string }
  | { type: "image"; source: string; width: number | null }
  | { type: "kaltura"; id: string; title: string }
  | { type: "video"; source: string; poster: string | null; title: string }
  | { type: "figure"; script: string; width: number | null; height: number | null }
  | { type: "animation"; source: string; title: string }
  | { type: "theorem"; kind: BotafogoTheoremKind; title: string; content: BotafogoBlock[] }
  | { type: "aside"; title: string; content: BotafogoBlock[] }
  | { type: "exercise"; label: string; content: BotafogoBlock[] }
  | { type: "folded"; fold: BotafogoFold; title: string; content: BotafogoBlock[] }
  | { type: "quiz"; title: string; prompt: BotafogoBlock[]; choices: BotafogoQuizChoice[]; columns: number };

export type BotafogoFold = "solution" | "hint" | "proof" | "aside";

export const BotafogoFold = {
  allCases: ["solution", "hint", "proof", "aside"] as readonly BotafogoFold[],
};

export type BotafogoTheoremKind = "theorem" | "definition" | "proposition" | "lemma" | "corollary" | "remark" | "example" | "other";

export const BotafogoTheoremKind = {
  allCases: ["theorem", "definition", "proposition", "lemma", "corollary", "remark", "example", "other"] as readonly BotafogoTheoremKind[],

  /** `amsthm-theo`, `amsthm-def`… → le genre. */
  fromClasses(classes: string[]): BotafogoTheoremKind {
    const joined = classes.join(" ").toLowerCase();
    if (joined.includes("amsthm-theo") || joined.includes("amsthm-thm")) return "theorem";
    if (joined.includes("amsthm-def")) return "definition";
    if (joined.includes("amsthm-prop")) return "proposition";
    if (joined.includes("amsthm-lem")) return "lemma";
    if (joined.includes("amsthm-cor")) return "corollary";
    if (joined.includes("amsthm-rem") || joined.includes("amsthm-remark")) return "remark";
    if (joined.includes("amsthm-ex")) return "example";
    return "other";
  },
};

export interface BotafogoQuizChoice {
  text: string;
  correct: boolean;
  explanation: string | null;
}

export type BotafogoJSONNode = Record<string, any>;

export const BotafogoPage = {
  /** Le schéma des liens vers une section du polycopié, interceptés par l'app. */
  polyScheme: "polymestre-poly",

  /** `m_suites_Cauchy` → `/handout/matiere/m_suites_cauchy` (les chemins du site sont en minuscules). */
  handoutPath(target: string): string {
    return "/handout/matiere/" + target.toLowerCase();
  },

  /** L'adresse d'un lien vers le polycopié : `polymestre-poly:///handout/matiere/m_…`. */
  polyLink(target: string): string {
    return BotafogoPage.polyScheme + "://" + BotafogoPage.handoutPath(target);
  },

  /** Le chemin du polycopié derrière un lien de l'app, s'il en est un. */
  handoutPathFromLink(link: URL): string | null {
    // `studytrack-poly:` : les liens écrits avant le changement de nom (fiches, réponses gardées).
    if (link.protocol !== BotafogoPage.polyScheme + ":" && link.protocol !== "studytrack-poly:") return null;
    const path = link.pathname === "" ? (link.hostname !== "" ? "/" + link.hostname : "") : link.pathname;
    return path.startsWith("/handout/") ? path : null;
  },

  // MARK: Lire

  blocksFromNodeJSON(data: string | Uint8Array): BotafogoBlock[] {
    const body = BotafogoDocumentBody(data);
    if (body === null) return [];
    return BotafogoPage.blocks(body);
  },

  /** L'arbre (`body` du nœud) → les blocs. */
  blocks(node: BotafogoJSONNode): BotafogoBlock[] {
    const reader = new Reader();
    reader.readNodes(BotafogoPage.children(node));
    return BotafogoPage.groupingExercises(reader.finish());
  },

  /** Dans une séance, un exercice n'est pas un composant : un paragraphe « **Exercice.** (3) … ». */
  groupingExercises(blocks: BotafogoBlock[]): BotafogoBlock[] {
    const result: BotafogoBlock[] = [];
    let current: { label: string; blocks: BotafogoBlock[] } | null = null;
    const close = () => {
      if (current !== null) result.push({ type: "exercise", label: current.label, content: current.blocks });
      current = null;
    };
    for (const block of blocks) {
      if (block.type === "paragraph") {
        const lead = BotafogoPage.exerciseLead(block.text);
        if (lead !== null) {
          close();
          current = { label: lead[0], blocks: lead[1] === "" ? [] : [{ type: "paragraph", text: lead[1] }] };
          continue;
        }
      }
      if (block.type === "heading") {
        close();
        result.push(block);
      } else if (current !== null) {
        current.blocks.push(block);
      } else {
        result.push(block);
      }
    }
    close();
    return result;
  },

  /** Un calcul aligné écrit entre `$…$` au fil du texte : on le sort en formule isolée. */
  liftingDisplayMath(text: string): BotafogoBlock[] {
    const pattern = String.raw`\$(\\begin\{(?:align|aligned|alignat|gather|gathered|eqnarray|multline|equation|split|flalign)\*?\}[^$]*)\$`;
    const regex = new RegExp(pattern, "g");
    const result: BotafogoBlock[] = [];
    let cursor = 0;
    for (const match of text.matchAll(regex)) {
      const location = match.index ?? 0;
      const before = BotafogoPage.tidy(text.slice(cursor, location));
      if (before !== "") result.push({ type: "paragraph", text: before });
      result.push({ type: "math", tex: match[1] });
      cursor = location + match[0].length;
    }
    if (result.length === 0) return [{ type: "paragraph", text }];
    const after = BotafogoPage.tidy(text.slice(cursor));
    // « , » ou « . » qui suivait la formule : il reste avec elle.
    if (after !== "" && characters(after).length > 2) result.push({ type: "paragraph", text: after });
    return result;
  },

  /** « **Exercice.** (3) (Théorème…) Expliquer… » → (« Exercice 3 », le reste). */
  exerciseLead(text: string): [string, string] | null {
    const lead = /^\*\*Exercice\.?\*\*\s*/.exec(text);
    if (lead === null) return null;
    let rest = text.slice(lead[0].length);
    let label = "Exercice";
    const number = /^\((\d+)\)\s*/.exec(rest);
    if (number !== null) {
      label += " " + characters(number[0]).filter(isNumber).join("");
      rest = rest.slice(number[0].length);
    }
    return [label, rest];
  },

  /** Les exercices d'une série, dans l'ordre. */
  exercises(blocks: BotafogoBlock[]): { label: string; blocks: BotafogoBlock[] }[] {
    const result: { label: string; blocks: BotafogoBlock[] }[] = [];
    for (const block of blocks) {
      if (block.type === "exercise") result.push({ label: block.label, blocks: block.content });
    }
    return result;
  },

  /** Les sections du polycopié citées par un document, sans doublon, dans l'ordre. */
  references(node: BotafogoJSONNode): { target: string; title: string }[] {
    const found: { target: string; title: string }[] = [];
    const seen = new Set<string>();
    const walk = (current: BotafogoJSONNode) => {
      if (BotafogoPage.tag(current) === "latex-ref" && typeof BotafogoPage.properties(current)["target"] === "string") {
        const target = BotafogoPage.properties(current)["target"] as string;
        const key = target.toLowerCase();
        if (!seen.has(key)) {
          seen.add(key);
          found.push({ target, title: BotafogoPage.clean(BotafogoPage.plain(current)) });
        }
        return;
      }
      for (const child of BotafogoPage.children(current)) walk(child);
    };
    walk(node);
    return found;
  },

  // MARK: Outils

  blocksFromSlots(nodes: BotafogoJSONNode[]): BotafogoBlock[] {
    const reader = new Reader();
    reader.readNodes(nodes);
    return reader.finish();
  },

  tag(node: BotafogoJSONNode): string {
    return typeof node["tagName"] === "string" ? node["tagName"] : "";
  },

  properties(node: BotafogoJSONNode): Record<string, any> {
    return node["properties"] !== null && typeof node["properties"] === "object" && !Array.isArray(node["properties"])
      ? node["properties"] as Record<string, any> : {};
  },

  classes(node: BotafogoJSONNode): string[] {
    const value = BotafogoPage.properties(node)["className"];
    if (Array.isArray(value)) return value.filter((x): x is string => typeof x === "string");
    if (typeof value === "string") return value.split(" ").filter((x) => x !== "");
    return [];
  },

  double(value: unknown): number | null {
    if (typeof value === "number") return value;
    if (typeof value === "string") {
      const n = Number(value);
      return Number.isFinite(n) ? n : null;
    }
    return null;
  },

  int(value: unknown): number | null {
    if (typeof value === "number" && Number.isInteger(value)) return value;
    if (typeof value === "string" && /^[+-]?\d+$/.test(value.trim())) return Number(value.trim());
    if (typeof value === "number") return Math.trunc(value);
    return null;
  },

  /** Les enfants d'un élément ; ceux d'un `template` sont dans `content`. */
  children(node: BotafogoJSONNode): BotafogoJSONNode[] {
    const result: BotafogoJSONNode[] = Array.isArray(node["children"]) ? node["children"] : [];
    if (node["content"] !== null && typeof node["content"] === "object" && !Array.isArray(node["content"])) {
      const content = node["content"] as BotafogoJSONNode;
      result.push(...(Array.isArray(content["children"]) ? content["children"] : []));
    }
    return result;
  },

  /** Le contenu d'un emplacement nommé (`#default`, `#title`, `#text`). */
  slot(node: BotafogoJSONNode, name: string): BotafogoJSONNode[] {
    const direct: BotafogoJSONNode[] = Array.isArray(node["children"]) ? node["children"] : [];
    const templates = direct.filter((child) => BotafogoPage.tag(child) === "template");
    const match = templates.find((child) => BotafogoPage.properties(child)["#" + name] !== undefined);
    if (match) return BotafogoPage.children(match);
    if (name !== "default") return [];
    if (templates.length === 0) return BotafogoPage.children(node);
    // Des gabarits sans nom reconnu : tout sauf le titre.
    return templates.filter((child) => BotafogoPage.properties(child)["#title"] === undefined)
      .flatMap((child) => BotafogoPage.children(child))
      .concat(direct.filter((child) => BotafogoPage.tag(child) !== "template"));
  },

  /** Le titre d'un composant : son emplacement `#title`, sinon sa propriété. */
  title(node: BotafogoJSONNode): string | null {
    const fromSlot = BotafogoPage.tidy(BotafogoPage.slot(node, "title").map((child) => BotafogoPage.inline(child)).join(""))
      .split("**").join("");
    if (fromSlot !== "") return fromSlot;
    const property = BotafogoPage.properties(node)["title"];
    if (typeof property !== "string") return null;
    const cleaned = BotafogoPage.tidy(property);
    return cleaned === "" ? null : cleaned;
  },

  /** Un exercice ou un théorème commence par son étiquette en gras : on la sépare. */
  labelled(nodes: BotafogoJSONNode[]): [string, BotafogoBlock[]] {
    const rest = [...nodes];
    while (rest.length > 0 && BotafogoPage.isBlank(rest[0])) rest.shift();
    if (rest.length === 0 || !["b", "strong"].includes(BotafogoPage.tag(rest[0]))) {
      return ["", BotafogoPage.blocksFromSlots(nodes)];
    }
    const first = rest.shift()!;
    let label = BotafogoPage.tidy(BotafogoPage.inline(first)).split("**").join("");
    while (label.endsWith(":") || label.endsWith(".")) label = label.slice(0, -1);
    // « Théorème 3.4. » puis le texte : le point qui suit l'étiquette part avec elle.
    if (rest.length > 0 && rest[0]["type"] === "text" && typeof rest[0]["value"] === "string") {
      let trimmed = trimWhitespaces(rest[0]["value"]);
      if (trimmed.startsWith(".")) {
        trimmed = trimmed.slice(1);
        rest[0]["value"] = trimmed;
      }
    }
    return [trimWhitespaces(label), BotafogoPage.blocksFromSlots(rest)];
  },

  /** Le texte d'un élément dans la phrase (gras, italique, formules, liens). */
  inline(node: BotafogoJSONNode): string {
    return BotafogoPage.inlineChildren(BotafogoPage.children(node));
  },

  inlineSlot(node: BotafogoJSONNode, name: string): string {
    return BotafogoPage.inlineChildren(BotafogoPage.slot(node, name));
  },

  inlineChildren(nodes: BotafogoJSONNode[]): string {
    const reader = new Reader();
    for (const node of nodes) reader.read(node);
    // Une phrase : les blocs éventuels sont remis bout à bout.
    const blocks = reader.finish();
    return blocks.map((block) => {
      switch (block.type) {
        case "paragraph": return block.text;
        case "math": return "$" + block.tex + "$";
        case "heading": return block.text;
        default: return "";
      }
    }).filter((text) => text !== "").join(" ");
  },

  plain(node: BotafogoJSONNode): string {
    if (node["type"] === "text") return typeof node["value"] === "string" ? node["value"] : "";
    return BotafogoPage.children(node).map((child) => BotafogoPage.plain(child)).join("");
  },

  isBlank(node: BotafogoJSONNode): boolean {
    return node["type"] === "text"
      && (typeof node["value"] === "string" ? node["value"] : "").trim() === "";
  },

  wrap(text: string, marker: string): string {
    const trimmed = trimWhitespaces(text);
    if (trimmed === "") return text;
    // Les espaces restent dehors : `**gras** suite`, pas `** gras**`.
    const leading = text.startsWith(" ") ? " " : "";
    const trailing = text.endsWith(" ") ? " " : "";
    return leading + marker + trimmed + marker + trailing;
  },

  clean(text: string): string { return BotafogoPage.tidy(text); },

  /** Les espaces du HTML ramenés à un seul. */
  tidy(text: string): string {
    return trimWhitespaces(text.replace(/[ \t\r\n]+/g, " "));
  },

  // MARK: En texte, pour Claude

  /** Un document en Markdown léger (formules entre `$…$` et `$$…$$`), pour le contexte de Claude. */
  text(blocks: BotafogoBlock[]): string {
    const lines: string[] = [];
    const walk = (current: BotafogoBlock[], indent: string) => {
      for (const block of current) {
        switch (block.type) {
          case "paragraph":
            lines.push(indent + block.text);
            break;
          case "heading":
            lines.push(indent + "## " + block.text);
            break;
          case "math":
            lines.push(indent + "$$" + block.tex + "$$");
            break;
          case "list":
            block.items.forEach((item, index) => {
              const marker = block.ordered ? `${index + 1}. ` : "- ";
              const saved = [...lines];
              lines.length = 0;
              walk(item, "");
              const sub = [...lines];
              lines.length = 0;
              lines.push(...saved);
              if (sub.length > 0) lines.push(indent + marker + sub[0]);
              lines.push(...sub.slice(1).map((line) => indent + "   " + line));
            });
            break;
          case "image":
            lines.push(indent + "[figure]");
            break;
          case "figure":
            lines.push(indent + "[figure interactive]");
            break;
          case "video":
          case "kaltura":
            lines.push(indent + `[vidéo : ${block.title}]`);
            break;
          case "animation":
            lines.push(indent + `[animation : ${block.title}]`);
            break;
          case "theorem":
          case "aside":
            if (block.title !== "") lines.push(indent + "**" + block.title + "**");
            walk(block.content, indent);
            break;
          case "exercise":
            lines.push(indent + "**" + block.label + "**");
            walk(block.content, indent);
            break;
          case "folded": {
            let tag: string;
            switch (block.fold) {
              case "solution": tag = "Solution officielle (ne pas révéler en mode tuteur)"; break;
              case "hint": tag = "Indication du site"; break;
              case "proof": tag = block.title === "" ? "Preuve" : block.title; break;
              case "aside": tag = block.title === "" ? "Remarque" : block.title; break;
            }
            lines.push(indent + "<" + tag + ">");
            walk(block.content, indent + "  ");
            lines.push(indent + "</" + tag + ">");
            break;
          }
          case "quiz":
            lines.push(indent + "**" + (block.title === "" ? "Quiz" : block.title) + "**");
            walk(block.prompt, indent);
            for (const choice of block.choices) {
              lines.push(indent + "- " + choice.text + (choice.correct ? " (juste)" : ""));
            }
            break;
        }
      }
    };
    walk(blocks, "");
    return lines.join("\n");
  },

  /** Un quiz d'un document, avec ce qui le précède dans son exercice. */
  quizzes(blocks: BotafogoBlock[]): { title: string; prompt: BotafogoBlock[]; choices: BotafogoQuizChoice[]; columns: number }[] {
    const result: { title: string; prompt: BotafogoBlock[]; choices: BotafogoQuizChoice[]; columns: number }[] = [];
    const walk = (current: BotafogoBlock[]) => {
      for (const block of current) {
        switch (block.type) {
          case "quiz":
            if (block.choices.length > 0) {
              result.push({ title: block.title, prompt: block.prompt, choices: block.choices, columns: block.columns });
            }
            break;
          case "exercise":
          case "theorem":
          case "aside":
            walk(block.content);
            break;
          case "folded":
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
    walk(blocks);
    return result;
  },
};

/// Le corps d'une réponse `/api/content/node` (`BotafogoDocument.body`).
function BotafogoDocumentBody(data: string | Uint8Array): BotafogoJSONNode | null {
  let text: string;
  if (typeof data === "string") {
    text = data;
  } else {
    text = new TextDecoder().decode(data);
  }
  try {
    const object = JSON.parse(text);
    if (object === null || typeof object !== "object" || Array.isArray(object)) return null;
    if (object["body"] !== null && typeof object["body"] === "object" && !Array.isArray(object["body"])) {
      return object["body"] as BotafogoJSONNode;
    }
    if (typeof object["body"] === "string") {
      try {
        const body = JSON.parse(object["body"]);
        return body !== null && typeof body === "object" && !Array.isArray(body) ? body as BotafogoJSONNode : null;
      } catch {
        return null;
      }
    }
    return null;
  } catch {
    return null;
  }
}

class Reader {
  blocks: BotafogoBlock[] = [];
  paragraph = "";

  flush(): void {
    const text = BotafogoPage.tidy(this.paragraph);
    if (text !== "") this.blocks.push(...BotafogoPage.liftingDisplayMath(text));
    this.paragraph = "";
  }

  finish(): BotafogoBlock[] {
    this.flush();
    return this.blocks;
  }

  append(block: BotafogoBlock): void {
    this.flush();
    this.blocks.push(block);
  }

  appendContents(more: BotafogoBlock[]): void {
    this.flush();
    this.blocks.push(...more);
  }

  readNodes(nodes: BotafogoJSONNode[]): void {
    for (const node of nodes) this.read(node);
  }

  read(node: BotafogoJSONNode): void {
    if (node["type"] === "text") {
      this.paragraph += typeof node["value"] === "string" ? node["value"] : "";
      return;
    }
    const tag = BotafogoPage.tag(node);
    const props = BotafogoPage.properties(node);
    switch (tag) {
      // Dans la phrase.
      case "katex-renderer": {
        const tex = typeof props["content"] === "string" ? props["content"] : "";
        if ("displayMode" in props || "display" in props) {
          // `displayMode: ""` : la présence vaut « oui » (ce n'est pas un booléen).
          this.append({ type: "math", tex });
        } else {
          this.paragraph += "$" + tex + "$";
        }
        break;
      }
      case "b":
      case "strong":
        this.paragraph += BotafogoPage.wrap(BotafogoPage.inline(node), "**");
        break;
      case "em":
      case "i":
        this.paragraph += BotafogoPage.wrap(BotafogoPage.inline(node), "*");
        break;
      case "code":
        this.paragraph += BotafogoPage.wrap(BotafogoPage.inline(node), "`");
        break;
      case "a": {
        const text = BotafogoPage.inline(node);
        const href = typeof props["href"] === "string" ? props["href"] : "";
        if (href !== "") this.paragraph += "[" + (text === "" ? href : text) + "](" + href + ")";
        else this.paragraph += text;
        break;
      }
      case "latex-ref": {
        const text = BotafogoPage.inline(node);
        const target = typeof props["target"] === "string" ? props["target"] : "";
        if (target !== "") {
          this.paragraph += "[" + (text === "" ? "voir le polycopié" : text) + "]("
            + BotafogoPage.polyLink(target) + ")";
        } else {
          this.paragraph += text;
        }
        break;
      }
      case "span":
      case "u":
      case "small":
      case "sup":
      case "sub":
        this.paragraph += BotafogoPage.inline(node);
        break;
      case "br":
        this.flush();
        break;

      // Des blocs.
      case "p":
        this.flush();
        this.readNodes(BotafogoPage.children(node));
        this.flush();
        break;
      case "h1":
      case "h2":
      case "h3":
      case "h4":
      case "h5": {
        const level = BotafogoPage.int(tag.slice(1)) ?? 3;
        this.append({ type: "heading", text: BotafogoPage.tidy(BotafogoPage.inline(node)), level });
        break;
      }
      case "ul":
      case "ol":
        this.append(this.list(node, tag === "ol", 1));
        break;
      case "multicols": {
        // Des sous-questions courtes, posées en colonnes.
        const columns = BotafogoPage.int(props["cols"]) ?? 2;
        const inner = BotafogoPage.slot(node, "default");
        const lists = inner.filter((child) => ["ul", "ol"].includes(BotafogoPage.tag(child)));
        if (lists.length === 1) {
          const listNode = lists[0];
          const rest = inner.filter((child) => !["ul", "ol"].includes(BotafogoPage.tag(child)));
          this.readNodes(rest.filter((child) => !BotafogoPage.isBlank(child)));
          this.append(this.list(listNode, BotafogoPage.tag(listNode) === "ol", columns));
        } else {
          this.readNodes(inner);
        }
        break;
      }
      case "img": {
        const source = props["src"];
        if (typeof source === "string") {
          const width = typeof props["dataDisplayWidth"] === "string"
            ? BotafogoPage.double(props["dataDisplayWidth"].replace(/px/g, "")) : null;
          this.append({ type: "image", source, width });
        }
        break;
      }
      case "videokaltura": {
        const id = props["entryId"];
        if (typeof id === "string") {
          this.append({ type: "kaltura", id, title: typeof props["title"] === "string" ? props["title"] : "Vidéo" });
        }
        break;
      }
      case "video-player": {
        const source = props["videoSrc"];
        if (typeof source === "string") {
          this.append({
            type: "video", source,
            poster: typeof props["thumbnailSrc"] === "string" ? props["thumbnailSrc"] : null,
            title: typeof props["title"] === "string" ? props["title"] : "Vidéo",
          });
        }
        break;
      }
      case "animation": {
        const source = props["src"];
        if (typeof source === "string") {
          this.append({ type: "animation", source: source + ".mp4", title: typeof props["title"] === "string" ? props["title"] : "Animation" });
        }
        this.readNodes(BotafogoPage.slot(node, "default"));
        break;
      }
      case "jsxgraph": {
        const script = props["url"];
        if (typeof script === "string") {
          this.append({ type: "figure", script, width: BotafogoPage.double(props["width"]), height: BotafogoPage.double(props["height"]) });
        }
        break;
      }
      case "exercise": {
        const [label, content] = BotafogoPage.labelled(BotafogoPage.slot(node, "default"));
        this.append({ type: "exercise", label, content });
        break;
      }
      case "solution":
        this.append({ type: "folded", fold: "solution", title: "Solution",
                      content: BotafogoPage.blocksFromSlots(BotafogoPage.slot(node, "default")) });
        break;
      case "indication":
        this.append({ type: "folded", fold: "hint", title: "Indication",
                      content: BotafogoPage.blocksFromSlots(BotafogoPage.slot(node, "default")) });
        break;
      case "proof":
      case "preuve": {
        const title = BotafogoPage.title(node) ?? "Preuve";
        this.append({ type: "folded", fold: "proof", title: title === "Proof" ? "Preuve" : title,
                      content: BotafogoPage.blocksFromSlots(BotafogoPage.slot(node, "default")) });
        break;
      }
      case "reveal":
        this.append({ type: "folded", fold: "solution", title: BotafogoPage.title(node) ?? "Solution",
                      content: BotafogoPage.blocksFromSlots(BotafogoPage.slot(node, "default")) });
        break;
      case "inline-popover":
        this.append({ type: "folded", fold: "aside", title: BotafogoPage.title(node) ?? "En savoir plus",
                      content: BotafogoPage.blocksFromSlots(BotafogoPage.slot(node, "default")) });
        break;
      case "info":
        this.append({ type: "aside", title: BotafogoPage.title(node) ?? "",
                      content: BotafogoPage.blocksFromSlots(BotafogoPage.slot(node, "default")) });
        break;
      case "quiz":
        this.append(this.quiz(node));
        break;
      case "div": {
        const classes = BotafogoPage.classes(node);
        if (classes.some((name) => name.startsWith("amsthm"))) {
          const [title, content] = BotafogoPage.labelled(BotafogoPage.children(node));
          // Un quiz posé dans un environnement sans titre : le quiz seul.
          if (title === "" && content.some((block) => block.type === "quiz")) {
            this.appendContents(content);
          } else {
            this.append({ type: "theorem", kind: BotafogoTheoremKind.fromClasses(classes), title, content });
          }
        } else {
          this.readNodes(BotafogoPage.children(node));
        }
        break;
      }
      default:
        // Un conteneur (template, askable, mdframed…) : on lit dedans.
        this.readNodes(BotafogoPage.slot(node, "default"));
        break;
    }
  }

  list(node: BotafogoJSONNode, ordered: boolean, columns: number): BotafogoBlock {
    const items = BotafogoPage.children(node)
      .filter((child) => BotafogoPage.tag(child) === "li")
      .map((child) => BotafogoPage.blocksFromSlots(BotafogoPage.children(child)));
    return { type: "list", items, ordered, columns };
  }

  quiz(node: BotafogoJSONNode): BotafogoBlock {
    const title = BotafogoPage.title(node) ?? "Quiz";
    const body = BotafogoPage.slot(node, "default");
    const choices: BotafogoQuizChoice[] = [];
    let columns = 1;
    const promptNodes: BotafogoJSONNode[] = [];
    const collect = (nodes: BotafogoJSONNode[]) => {
      for (const child of nodes) {
        switch (BotafogoPage.tag(child)) {
          case "choices":
            columns = BotafogoPage.int(BotafogoPage.properties(child)["cols"]) ?? 1;
            collect(BotafogoPage.slot(child, "default"));
            break;
          case "correct-choice":
          case "wrong-choice": {
            const text = BotafogoPage.tidy(BotafogoPage.inlineSlot(child, "text"));
            const fallback = typeof BotafogoPage.properties(child)["text"] === "string"
              ? BotafogoPage.properties(child)["text"] : "";
            choices.push({ text: text === "" ? fallback : text, correct: BotafogoPage.tag(child) === "correct-choice", explanation: null });
            break;
          }
          case "explanation": {
            // L'explication suit le choix qu'elle commente.
            const text = BotafogoPage.tidy(BotafogoPage.inlineSlot(child, "text"));
            if (choices.length > 0 && text !== "") choices[choices.length - 1].explanation = text;
            break;
          }
          case "template":
            collect(BotafogoPage.slot(child, "default"));
            break;
          default:
            if (choices.length === 0) promptNodes.push(child);
            break;
        }
      }
    };
    collect(body);
    return { type: "quiz", title, prompt: BotafogoPage.blocksFromSlots(promptNodes), choices, columns };
  }
}

/// `trimmingCharacters(in: .whitespaces)` local (évite un import circulaire).
function trimWhitespaces(text: string): string {
  let start = 0;
  let end = text.length;
  while (start < end && isWhitespace(text[start])) start += 1;
  while (end > start && isWhitespace(text[end - 1])) end -= 1;
  return text.slice(start, end);
}

/// `MathMarkup.plain` est utilisé par `BotafogoNavigation.plainTitle`.
export const BotafogoPlainTitle = (title: string): string => MathMarkup.plain(title);
