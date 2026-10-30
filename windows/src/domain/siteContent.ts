// Les sites du cours lus **en natif** dans le mode étude : une page Moodle, un
// texte de Courseware, une vidéo MediaSpace (StudyTrack/Domain/SiteContent.swift).
//
// Ici, ce qui est pur — le HTML découpé en blocs, l'aiguillage d'un lien,
// l'adresse d'une vidéo Kaltura ou edX, les réponses des scripts Moodle.

import { Institution } from "./institution.ts";
import { BotafogoParser } from "./courseContentImport.ts";
import { CoursewareTranscripts } from "./coursewareTranscripts.ts";
import { MoocReference } from "./moodleCourseAnalyzer.ts";
import { RichMarkup } from "./claudeTutor.ts";
import { icuRegExp } from "./icuRegExp.ts";

// MARK: - Blocs

/** Un morceau de page à afficher. */
export type SiteBlock =
  | { type: "markdown"; text: string }
  | { type: "image"; url: string }
  | { type: "file"; title: string; url: string }
  | { type: "video"; title: string; url: string }
  | { type: "link"; title: string; url: string };

export const SiteBlock = {
  markdown(text: string): SiteBlock { return { type: "markdown", text }; },
  image(url: string): SiteBlock { return { type: "image", url }; },
  file(title: string, url: string): SiteBlock { return { type: "file", title, url }; },
  video(title: string, url: string): SiteBlock { return { type: "video", title, url }; },
  link(title: string, url: string): SiteBlock { return { type: "link", title, url }; },
};

const safeURL = (text: string): URL | null => {
  try {
    return new URL(text);
  } catch {
    return null;
  }
};

export const SiteHTML = {
  /** Un texte brut qui est du Markdown. */
  looksLikeMarkdown(text: string): boolean {
    if (!text.includes("\n")) return false;
    const lines = text.split("\n").map((line) => line.trim()).filter((line) => line !== "");
    if (lines.length < 2) return false;
    const structural = lines.filter((line) => /^(#{1,6} |[-*+] |\d+[.)] |```|> )/.test(line));
    return structural.length > 0;
  },

  /** Retire l'indentation commune. */
  dedent(text: string): string {
    const lines = text.split("\n");
    const indents = lines.filter((line) => line.trim() !== "")
      .map((line) => {
        let count = 0;
        while (count < line.length && (line[count] === " " || line[count] === "\t")) count += 1;
        return count;
      });
    const common = indents.length === 0 ? 0 : Math.min(...indents);
    return lines.map((line) => {
      let leading = 0;
      while (leading < line.length && (line[leading] === " " || line[leading] === "\t")) leading += 1;
      return line.slice(Math.min(common, leading));
    }).join("\n").replace(/^\n+|\n+$/g, "");
  },

  /** Une page HTML → des blocs. `base` résout les adresses relatives. */
  blocks(html: string, base: URL | null = null): SiteBlock[] {
    const parser = new Parser(base);
    parser.run(html);
    return parser.finish();
  },
};

class Parser {
  base: URL | null;
  blocks: SiteBlock[] = [];
  paragraph = "";
  /** Les éléments ouverts dont on ignore le contenu (script, style…). */
  skipping: string[] = [];
  lists: { ordered: boolean; count: number }[] = [];
  link: { href: string; text: string } | null = null;
  pendingLinks: SiteBlock[] = [];
  pre: string | null = null;
  cells: string[] | null = null;
  cell: string | null = null;
  heading: number | null = null;

  constructor(base: URL | null) { this.base = base; }

  run(html: string): void {
    let index = 0;
    while (index < html.length) {
      if (html[index] === "<") {
        // Commentaire.
        if (html.startsWith("<!--", index)) {
          const end = html.indexOf("-->", index);
          if (end < 0) break;
          index = end + 3;
          continue;
        }
        const close = html.indexOf(">", index);
        if (close < 0) {
          this.text(html.slice(index));
          break;
        }
        this.tag(html.slice(index + 1, close));
        index = close + 1;
      } else {
        const next = html.indexOf("<", index);
        const end = next < 0 ? html.length : next;
        this.text(html.slice(index, end));
        index = end;
      }
    }
  }

  finish(): SiteBlock[] {
    this.flush();
    return this.blocks;
  }

  // MARK: Texte

  text(raw: string): void {
    if (this.skipping.length > 0) return;
    const decoded = BotafogoParser.decode(raw);
    if (this.pre !== null) { this.pre += decoded; return; }
    // Un texte écrit en Markdown garde ses retours à la ligne.
    if (this.cell === null && this.link === null && this.heading === null && SiteHTML.looksLikeMarkdown(decoded)) {
      this.flush();
      this.blocks.push(SiteBlock.markdown(SiteHTML.dedent(decoded)));
      return;
    }
    const collapsed = decoded.replace(/\s+/g, " ");
    if (this.cell !== null) { this.cell += collapsed; return; }
    if (this.link !== null) this.link.text += collapsed;
    this.append(collapsed);
  }

  append(piece: string): void {
    if (this.paragraph === "" || this.paragraph.endsWith(" ") || this.paragraph.endsWith("\n")) {
      this.paragraph += piece.replace(/^ +/, "");
    } else {
      this.paragraph += piece;
    }
  }

  /** Le paragraphe en cours devient un bloc (avec ses liens, après lui). */
  flush(): void {
    // Les balises vides ne laissent ni « #### » ni « **** » à l'écran.
    const lines = this.paragraph.split("\n")
      .map((line) => line.split("****").join("").trim())
      .filter((line) => line !== "" && !/^[#*_\s]+$/.test(line));
    if (lines.length > 0) {
      const text = lines.join("\n");
      const last = this.blocks[this.blocks.length - 1];
      if (last !== undefined && last.type === "markdown" && isListLine(last.text) && isListLine(text)) {
        this.blocks[this.blocks.length - 1] = SiteBlock.markdown(last.text + "\n" + text);
      } else {
        this.blocks.push(SiteBlock.markdown(text));
      }
    }
    this.paragraph = "";
    this.blocks.push(...this.pendingLinks);
    this.pendingLinks = [];
  }

  // MARK: Balises

  tag(raw: string): void {
    const closing = raw.startsWith("/");
    const body = closing ? raw.slice(1) : raw;
    let name = "";
    for (const char of body) {
      if (/\s/.test(char) || char === "/" || char === ">") break;
      name += char;
    }
    name = name.toLowerCase();
    if (name === "") return;
    const attributes = closing ? new Map<string, string>() : Parser.attributes(body);
    const ignored = new Set(["script", "style", "head", "noscript", "button", "select", "textarea", "svg", "nav"]);
    if (name === "a" && closing && this.skipping[this.skipping.length - 1] === "a") {
      this.skipping.pop();
      return;
    }
    if (ignored.has(name)) {
      if (closing) {
        const last = this.skipping.lastIndexOf(name);
        if (last >= 0) this.skipping.splice(last, 1);
      } else if (!raw.endsWith("/")) {
        this.skipping.push(name);
      }
      return;
    }
    if (this.skipping.length > 0) return;
    // Les formules MathJax rendues : on garde le TeX de la balise script, déjà ignorée.
    if (!closing && ((attributes.get("class") ?? "").includes("MathJax") || attributes.get("aria-hidden") === "true")) {
      return;
    }
    switch (name) {
      case "p":
      case "div":
      case "section":
      case "article":
      case "blockquote":
      case "dl":
      case "dt":
      case "dd":
      case "figure":
      case "figcaption":
      case "center":
      case "main":
      case "header":
      case "footer":
        // `<li><p>texte</p></li>` : la puce attend son texte.
        if (this.cell === null && !isBareListMarker(this.paragraph.trim())) this.flush();
        break;
      case "br":
        if (this.pre !== null) this.pre += "\n";
        else if (this.cell !== null) this.cell += " ";
        else this.paragraph += "\n";
        break;
      case "h1":
      case "h2":
      case "h3":
      case "h4":
      case "h5":
      case "h6":
        this.flush();
        if (!closing) {
          const level = Math.min(4, (Number(name.slice(1)) || 2) + 1);
          this.paragraph = "#".repeat(level) + " ";
          this.heading = level;
        } else {
          this.heading = null;
          this.flush();
        }
        break;
      case "strong":
      case "b":
        if (this.heading === null && this.cell === null) this.paragraph += "**";
        break;
      case "em":
      case "i":
        if (this.heading === null && this.cell === null
            && !(attributes.get("class") ?? "").includes("icon")
            && !(attributes.get("class") ?? "").includes("fa")) {
          this.paragraph += "*";
        }
        break;
      case "ul":
      case "ol":
        this.flush();
        if (closing) this.lists.pop();
        else this.lists.push({ ordered: name === "ol", count: 0 });
        break;
      case "li":
        this.flush();
        if (!closing && this.lists.length > 0) {
          const current = this.lists[this.lists.length - 1];
          current.count += 1;
          this.paragraph = "  ".repeat(Math.max(0, this.lists.length - 1))
            + (current.ordered ? `${current.count}. ` : "- ");
        }
        break;
      case "a":
        if (closing) {
          if (this.link !== null) this.finishLink(this.link);
          this.link = null;
        } else {
          const href = attributes.get("href");
          if (href !== undefined) {
            // « Passer au contenu principal » et autres ancres de la page.
            if (href.startsWith("#") || (attributes.get("class") ?? "").includes("skip")) {
              this.skipping.push("a");
              return;
            }
            this.link = { href, text: "" };
          }
        }
        break;
      case "img": {
        if (closing) break;
        const source = attributes.get("src");
        const resolved = source !== undefined ? this.resolve(source) : null;
        if (resolved === null) break;
        if ((attributes.get("class") ?? "").includes("icon") || resolved.includes("/theme/image.php")) break;
        this.flush();
        this.blocks.push(SiteBlock.image(resolved));
        break;
      }
      case "iframe":
      case "video":
      case "source":
      case "embed": {
        if (closing) break;
        const source = attributes.get("src");
        const resolved = source !== undefined ? this.resolve(source) : null;
        if (resolved === null) break;
        const route = SiteRouter.route(resolved);
        this.flush();
        if (["mediaspace", "youtube", "video"].includes(route.type)) {
          this.blocks.push(SiteBlock.video(attributes.get("title") ?? "Vidéo", resolved));
        } else {
          this.blocks.push(SiteBlock.link(attributes.get("title") ?? "Contenu intégré", resolved));
        }
        break;
      }
      case "pre":
        if (closing) {
          const code = (this.pre ?? "").replace(/^\n+|\n+$/g, "");
          this.pre = null;
          if (code !== "") {
            this.flush();
            this.blocks.push(SiteBlock.markdown("```\n" + code + "\n```"));
          }
        } else {
          this.flush();
          this.pre = "";
        }
        break;
      case "tr":
        if (closing) {
          if (this.cells !== null && this.cells.length > 0) {
            this.flush();
            const line = "- " + this.cells.join(" · ");
            const last = this.blocks[this.blocks.length - 1];
            if (last !== undefined && last.type === "markdown" && last.text.startsWith("- ")) {
              this.blocks[this.blocks.length - 1] = SiteBlock.markdown(last.text + "\n" + line);
            } else {
              this.blocks.push(SiteBlock.markdown(line));
            }
          }
          this.cells = null;
        } else {
          this.flush();
          this.cells = [];
        }
        break;
      case "td":
      case "th":
        if (closing) {
          const value = (this.cell ?? "").trim();
          if (value !== "") this.cells?.push(value);
          this.cell = null;
        } else {
          this.cell = "";
        }
        break;
      default:
        break;
    }
  }

  finishLink(open: { href: string; text: string }): void {
    const url = this.resolve(open.href);
    if (url === null) return;
    const title = open.text.trim();
    const route = SiteRouter.route(url);
    switch (route.type) {
      case "pdf":
      case "file":
        this.pendingLinks.push(SiteBlock.file(title === "" ? "Document" : title, url));
        break;
      case "mediaspace":
      case "youtube":
      case "video":
        this.pendingLinks.push(SiteBlock.video(title === "" ? "Vidéo" : title, url));
        break;
      case "web":
        if (title === "") break;
        this.pendingLinks.push(SiteBlock.link(title, url));
        break;
      default:
        this.pendingLinks.push(SiteBlock.link(title === "" ? url : title, url));
        break;
    }
  }

  resolve(raw: string): string | null {
    const value = BotafogoParser.decode(raw.trim());
    if (value === "" || value.startsWith("#") || value.toLowerCase().startsWith("javascript:")
        || value.toLowerCase().startsWith("mailto:") || value.startsWith("data:")) return null;
    try {
      if (this.base !== null) return new URL(value, this.base).toString();
      return new URL(value).toString();
    } catch {
      return null;
    }
  }

  static attributes(body: string): Map<string, string> {
    const result = new Map<string, string>();
    const regex = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
    for (const match of body.matchAll(regex)) {
      const value = match[2] ?? match[3] ?? match[4] ?? "";
      result.set(match[1].toLowerCase(), value);
    }
    return result;
  }
}

/** « - » ou « 3. » seuls : une puce sans encore de texte. */
function isBareListMarker(text: string): boolean {
  return text === "-" || /^\d+\.$/.test(text);
}

function isListLine(text: string): boolean {
  const first = text.trim();
  return first.startsWith("- ") || /^\d+\. /.test(first);
}

// MARK: - Aiguillage

export type SiteDestination =
  | { type: "pdf" }
  | { type: "file" }
  | { type: "moodle"; module: string; id: number }
  | { type: "botafogo" }
  | { type: "mediaspace"; entryID: string }
  | { type: "courseware"; courseKey: string }
  | { type: "youtube"; id: string }
  | { type: "video" }
  | { type: "geogebra" }
  | { type: "web" };

export const SiteRouter = {
  /** Où mène un lien, pour l'ouvrir en natif. */
  route(address: string): SiteDestination {
    const url = safeURL(address);
    if (url === null || url.hostname === "") return { type: "web" };
    const host = url.hostname.toLowerCase();
    const path = url.pathname.toLowerCase();
    if (path.endsWith(".pdf")) return { type: "pdf" };
    if (path.endsWith(".mp4") || path.endsWith(".m3u8") || path.endsWith(".mov") || path.endsWith(".webm")) return { type: "video" };
    const school = Institution.current;
    if (school.moodleHost !== null && host.endsWith(school.moodleHost)) {
      if (path.includes("/pluginfile.php/")) {
        return path.endsWith(".pdf") || !path.includes(".") ? { type: "pdf" } : { type: "file" };
      }
      const moduleMatch = /\/mod\/([a-z]+)\/view\.php/.exec(path);
      const idText = url.searchParams.get("id");
      if (moduleMatch !== null && idText !== null && /^[+-]?\d+$/.test(idText)) {
        const module = moduleMatch[1];
        const id = Number(idText);
        return module === "resource" ? { type: "pdf" } : { type: "moodle", module, id };
      }
      return { type: "web" };
    }
    const botafogo = school.extras["botafogo"] !== undefined ? safeURL(school.extras["botafogo"])?.hostname ?? null : null;
    if (botafogo !== null && host.endsWith(botafogo)) return { type: "botafogo" };
    const videoHosts: string[] = [];
    const schoolVideo = school.video;
    if (schoolVideo !== null) {
      videoHosts.push(schoolVideo.host);
      const apiHost = safeURL(schoolVideo.kalturaAPI)?.hostname;
      if (apiHost !== undefined) videoHosts.push(apiHost);
    }
    if (videoHosts.some((v) => host.endsWith(v)) || host.includes("kaltura") || host.endsWith("cast.switch.ch")) {
      const id = SiteRouter.kalturaEntry(address);
      return id !== null ? { type: "mediaspace", entryID: id } : { type: "web" };
    }
    if ((school.coursewareHost !== null && host.endsWith(school.coursewareHost)) || host.endsWith("learning.edx.org")) {
      const key = MoocReference.courseKey(address);
      return key !== null ? { type: "courseware", courseKey: key } : { type: "web" };
    }
    if (host.endsWith("youtube.com") || host === "youtu.be" || host.endsWith("youtube-nocookie.com")) {
      const id = SiteRouter.youTubeID(url);
      return id !== null ? { type: "youtube", id } : { type: "web" };
    }
    if (host.endsWith("geogebra.org")) return { type: "geogebra" };
    const documents = [".pptx", ".ppt", ".docx", ".doc", ".xlsx", ".zip", ".ipynb", ".py", ".m", ".txt", ".csv", ".key", ".pages"];
    if (documents.some((suffix) => path.endsWith(suffix))) return { type: "file" };
    return { type: "web" };
  },

  /** L'identifiant Kaltura d'une adresse (« 0_6y8w1d2s »), le dernier trouvé. */
  kalturaEntry(link: string): string | null {
    let decoded: string;
    try {
      decoded = decodeURIComponent(link);
    } catch {
      decoded = link;
    }
    const regex = /(?:[\/=]|entry_?id[\/=])([01]_[a-z0-9]{8})(?=[\/?#&]|$)/gi;
    let last: string | null = null;
    for (const match of decoded.matchAll(regex)) last = match[1];
    return last;
  },

  youTubeID(url: URL): string | null {
    if (url.hostname === "youtu.be") {
      return url.pathname.split("/").filter((p) => p !== "")[0] ?? null;
    }
    const v = url.searchParams.get("v");
    if (v !== null) return v;
    const parts = url.pathname.split("/").filter((p) => p !== "");
    const index = parts.findIndex((part) => part === "embed" || part === "shorts" || part === "v");
    if (index >= 0 && index + 1 < parts.length) return parts[index + 1];
    return null;
  },
};

// MARK: - Kaltura (MediaSpace)

export const Kaltura: {
  readonly defaultPartner: number;
  readonly host: string;
  manifestURL(entryID: string, partnerID?: number, ks?: string | null): URL | null;
  config(html: string): { partnerID: number | null; ks: string | null };
  isPlayableManifest(text: string): boolean;
} = {
  /** Le partenaire et l'API de l'école (EPFL : 113 chez SWITCH). */
  get defaultPartner(): number { return Institution.current.video?.kalturaPartner ?? 113; },
  get host(): string { return Institution.current.video?.kalturaAPI ?? "https://api.cast.switch.ch"; },

  manifestURL(entryID: string, partnerID: number = Institution.current.video?.kalturaPartner ?? 113, ks: string | null = null): URL | null {
    let path = `${Institution.current.video?.kalturaAPI ?? "https://api.cast.switch.ch"}/p/${partnerID}/sp/${partnerID}00/playManifest/entryId/${entryID}/format/applehttp/protocol/https`;
    if (ks !== null && ks !== "") path += `/ks/${ks}`;
    return safeURL(path + "/a.m3u8");
  },

  /** Le partenaire et la clé de session d'une page MediaSpace. */
  config(html: string): { partnerID: number | null; ks: string | null } {
    const first = (pattern: string): string | null => {
      const match = icuRegExp(pattern).exec(html);
      return match && match[1] !== undefined ? match[1] : null;
    };
    const partner = first(String.raw`"partnerId"\s*:\s*"?(\d+)"`)
      ?? first(String.raw`partnerId=(\d+)`)
      ?? first(String.raw`/p/(\d+)/`);
    const ks = first(String.raw`"ks"\s*:\s*"([A-Za-z0-9_\-=]{20,})"`);
    return {
      partnerID: partner !== null && /^[+-]?\d+$/.test(partner) ? Number(partner) : null,
      ks,
    };
  },

  /** Un manifeste HLS lisible (et pas une page d'erreur). */
  isPlayableManifest(text: string): boolean {
    return text.startsWith("#EXTM3U") && text.includes("#EXT-X-");
  },
};

// MARK: - Courseware (Open edX)

export type EdXBlockKind = "video" | "html" | "problem" | `other:${string}`;

export interface EdXBlock {
  id: string;
  title: string;
  kind: EdXBlockKind;
  /** Le contenu seul du bloc (`student_view_url`). */
  viewURL: string | null;
  /** Vidéo : la meilleure source (HLS, puis mp4), ou YouTube. */
  videoURL: string | null;
  youTubeID: string | null;
  transcripts: string[];
  duration: number | null;
}

export interface EdXUnit {
  id: string;
  title: string;
  blocks: EdXBlock[];
  completed: boolean;
}

export interface EdXSequence {
  id: string;
  title: string;
  units: EdXUnit[];
}

export interface EdXChapter {
  id: string;
  title: string;
  sequences: EdXSequence[];
}

export class EdXOutline {
  chapters: EdXChapter[];

  constructor(chapters: EdXChapter[]) { this.chapters = chapters; }

  /** Toutes les unités, dans l'ordre du cours. */
  get units(): EdXUnit[] {
    return this.chapters.flatMap((chapter) => chapter.sequences.flatMap((sequence) => sequence.units));
  }

  /** Où se trouve une unité : son chapitre et sa séquence. */
  place(ofUnitID: string): { chapter: EdXChapter; sequence: EdXSequence } | null {
    for (const chapter of this.chapters) {
      for (const sequence of chapter.sequences) {
        if (sequence.units.some((unit) => unit.id === ofUnitID)) return { chapter, sequence };
      }
    }
    return null;
  }

  /** Où reprendre : la première unité non faite **après** la dernière faite. */
  get resumeUnit(): EdXUnit | null {
    const all = this.units;
    const last = all.map((unit) => unit.completed).lastIndexOf(true);
    if (last < 0) return all[0] ?? null;
    return all.slice(last + 1).find((unit) => !unit.completed)
      ?? all.find((unit) => !unit.completed) ?? all[all.length - 1] ?? null;
  }

  static parse(json: string | Uint8Array): EdXOutline | null {
    let text: string;
    if (typeof json === "string") text = json;
    else text = new TextDecoder().decode(json);
    let object: Record<string, any>;
    try {
      const parsed = JSON.parse(text);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null;
      object = parsed as Record<string, any>;
    } catch {
      return null;
    }
    const root = object["root"];
    const blocks = object["blocks"];
    if (typeof root !== "string" || blocks === null || typeof blocks !== "object" || Array.isArray(blocks)) return null;
    const table = blocks as Record<string, Record<string, any> | undefined>;
    const children = (id: string): string[] => {
      const list = table[id]?.["children"];
      return Array.isArray(list) ? list.filter((x): x is string => typeof x === "string") : [];
    };
    const title = (id: string): string => BotafogoParser.decode(
      typeof table[id]?.["display_name"] === "string" ? table[id]!["display_name"] : "");
    const block = (id: string): EdXBlock => {
      const raw = table[id] ?? {};
      const type = typeof raw["type"] === "string" ? raw["type"] : "";
      const kind: EdXBlockKind = type === "video" ? "video" : type === "html" ? "html" : type === "problem" ? "problem" : `other:${type}`;
      let video: string | null = null;
      let youTube: string | null = null;
      let transcripts: string[] = [];
      let duration: number | null = null;
      const data = raw["student_view_data"];
      if (data !== null && typeof data === "object" && !Array.isArray(data)) {
        const view = data as Record<string, any>;
        video = EdXOutline.bestVideo(view);
        transcripts = CoursewareTranscripts.transcriptURLs(view);
        duration = typeof view["duration"] === "number" && view["duration"] > 0 ? view["duration"] : null;
        const encoded = view["encoded_videos"];
        if (encoded !== null && typeof encoded === "object" && !Array.isArray(encoded)) {
          const youtube = (encoded as Record<string, any>)["youtube"];
          const url = youtube !== null && typeof youtube === "object" ? youtube["url"] : undefined;
          const parsed = typeof url === "string" ? safeURL(url) : null;
          youTube = parsed !== null ? SiteRouter.youTubeID(parsed) : null;
        }
      }
      return {
        id, title: title(id), kind,
        viewURL: typeof raw["student_view_url"] === "string" ? raw["student_view_url"] : null,
        videoURL: video, youTubeID: youTube, transcripts, duration,
      };
    };
    const chapters = children(root).map((chapterID) => ({
      id: chapterID,
      title: title(chapterID),
      sequences: children(chapterID).map((sequenceID) => ({
        id: sequenceID,
        title: title(sequenceID),
        units: children(sequenceID).map((unitID) => ({
          id: unitID,
          title: title(unitID),
          blocks: children(unitID).map(block),
          completed: (typeof table[unitID]?.["completion"] === "number" ? table[unitID]!["completion"] as number : 0) >= 1,
        })),
      })),
    }));
    return new EdXOutline(chapters);
  }

  /** HLS d'abord (qualité adaptée), puis le mp4 le plus grand, puis le reste. */
  static bestVideo(data: Record<string, any>): string | null {
    const encoded = data["encoded_videos"];
    const table = encoded !== null && typeof encoded === "object" && !Array.isArray(encoded)
      ? encoded as Record<string, any> : {};
    for (const key of ["hls", "desktop_mp4", "fallback", "mobile_high", "mobile_low"]) {
      const value = table[key];
      const url = value !== null && typeof value === "object" ? value["url"] : undefined;
      if (typeof url === "string" && url !== "") return url;
    }
    const sources = Array.isArray(data["all_sources"])
      ? data["all_sources"].filter((x: unknown): x is string => typeof x === "string") : [];
    return sources.find((source) => source.includes(".m3u8"))
      ?? sources.find((source) => source.includes(".mp4")) ?? sources[0] ?? null;
  }
}

// MARK: - Moodle

/** Ce que les scripts de lecture d'une activité Moodle rendent (JSON). */
export interface MoodleActivityFile { name: string; url: string }
export interface MoodleActivityPost { subject: string; author: string; date: string; html: string }
export interface MoodleActivityDiscussion { id: number; title: string; author: string; date: string }

export class MoodleActivityContent {
  module = "";
  title = "";
  html = "";
  files: MoodleActivityFile[] = [];
  dates: string[] = [];
  status: string[] = [];
  target: string | null = null;
  discussions: MoodleActivityDiscussion[] = [];
  posts: MoodleActivityPost[] = [];
  needsLogin = false;
  unavailable = false;
  notice: string | null = null;

  static decode(json: string): MoodleActivityContent | null {
    let raw: Record<string, any>;
    try {
      const parsed = JSON.parse(json);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null;
      raw = parsed as Record<string, any>;
    } catch {
      return null;
    }
    const result = new MoodleActivityContent();
    result.module = typeof raw["module"] === "string" ? raw["module"] : "";
    result.title = BotafogoParser.decode(typeof raw["title"] === "string" ? raw["title"] : "");
    result.html = typeof raw["html"] === "string" ? raw["html"] : "";
    result.files = Array.isArray(raw["files"]) ? raw["files"].filter((f: unknown) => f !== null && typeof f === "object")
      .map((f: Record<string, any>) => ({ name: typeof f["name"] === "string" ? f["name"] : "", url: typeof f["url"] === "string" ? f["url"] : "" })) : [];
    result.dates = Array.isArray(raw["dates"]) ? raw["dates"].filter((x: unknown): x is string => typeof x === "string") : [];
    result.status = Array.isArray(raw["status"]) ? raw["status"].filter((x: unknown): x is string => typeof x === "string") : [];
    result.target = typeof raw["target"] === "string" ? raw["target"] : null;
    result.discussions = Array.isArray(raw["discussions"]) ? raw["discussions"]
      .filter((d: unknown) => d !== null && typeof d === "object")
      .map((d: Record<string, any>) => ({
        id: typeof d["id"] === "number" ? Math.trunc(d["id"]) : 0,
        title: typeof d["title"] === "string" ? d["title"] : "",
        author: typeof d["author"] === "string" ? d["author"] : "",
        date: typeof d["date"] === "string" ? d["date"] : "",
      })) : [];
    result.posts = Array.isArray(raw["posts"]) ? raw["posts"]
      .filter((p: unknown) => p !== null && typeof p === "object")
      .map((p: Record<string, any>) => ({
        subject: typeof p["subject"] === "string" ? p["subject"] : "",
        author: typeof p["author"] === "string" ? p["author"] : "",
        date: typeof p["date"] === "string" ? p["date"] : "",
        html: typeof p["html"] === "string" ? p["html"] : "",
      })) : [];
    result.needsLogin = raw["needsLogin"] === true;
    result.unavailable = raw["unavailable"] === true;
    const notice = typeof raw["notice"] === "string" && raw["notice"] !== "" ? BotafogoParser.decode(raw["notice"]) : null;
    result.notice = notice;
    return result;
  }
}

// MARK: - Botafogo

/** Les figures interactives de Botafogo (JSXGraph) : le site publie une image fixe à côté. */
export const BotafogoFigure = {
  imagePath(script: string): string {
    const trimmed = script.split("?")[0] ?? script;
    if (!trimmed.toLowerCase().endsWith(".js")) return trimmed + ".png";
    return trimmed.slice(0, -3) + ".png";
  },
};

// MARK: - Ed Discussion

export interface EdCourse { id: number; code: string; name: string }

export interface EdThread {
  id: number;
  number: number | null;
  title: string;
  category: string | null;
  type: string | null;
  isPinned: boolean | null;
  isAnswered: boolean | null;
  replyCount: number | null;
  createdAt: string | null;
  document: string | null;
}

export interface EdPost {
  id: number;
  author: string;
  date: string;
  content: string;
  isAnswer: boolean;
  isEndorsed: boolean;
  replies: EdPost[];
}

export class EdPoll {
  id: number;
  question: string;
  options: string[];
  counts: number[];
  multipleChoice: boolean;
  isClosed: boolean;
  voters: number;
  chosen: number[] | null;
  revealVotes: string;

  constructor(o: Partial<EdPoll> & { id: number }) {
    this.id = o.id;
    this.question = o.question ?? "";
    this.options = o.options ?? [];
    this.counts = o.counts ?? [];
    this.multipleChoice = o.multipleChoice ?? false;
    this.isClosed = o.isClosed ?? false;
    this.voters = o.voters ?? 0;
    this.chosen = o.chosen ?? null;
    this.revealVotes = o.revealVotes ?? "after_response";
  }

  /** Ed ne montre les votes qu'après sa propre réponse (ou selon le réglage). */
  get showsResults(): boolean {
    if (this.counts.length !== this.options.length || this.voters <= 0) return false;
    switch (this.revealVotes) {
      case "never": return false;
      case "always": return true;
      case "after_close": return this.isClosed;
      default: return this.chosen !== null || this.isClosed;
    }
  }

  /** La part des votants qui ont coché une option (0…1). */
  share(index: number): number {
    if (index < 0 || index >= this.counts.length || this.voters <= 0) return 0;
    return Math.min(1, this.counts[index] / this.voters);
  }
}

export interface EdLesson { id: number; title: string; module: string | null; status: string | null }
export interface EdSlide { id: number; type: string; title: string; content: string; isCompleted: boolean }
export type EdQuestionKind = "choice-multiple" | "choice-single" | "text" | "number" | `other:${string}`;
export interface EdQuestion { id: number; kind: EdQuestionKind; content: string; answers: string[] }

export const EdDiscussion = {
  /** `GET /api/user` → les cours où l'on est inscrit·e. */
  courses(userJSON: string | Uint8Array): EdCourse[] {
    const object = parseJSONObject(userJSON);
    if (object === null || !Array.isArray(object["courses"])) return [];
    const result: EdCourse[] = [];
    for (const row of object["courses"]) {
      if (row === null || typeof row !== "object" || Array.isArray(row)) continue;
      const course = row["course"] !== null && typeof row["course"] === "object" ? row["course"] : row;
      if (typeof course["id"] !== "number" || !Number.isFinite(course["id"])) continue;
      result.push({
        id: Math.trunc(course["id"]),
        code: typeof course["code"] === "string" ? course["code"] : "",
        name: typeof course["name"] === "string" ? course["name"] : "",
      });
    }
    return result;
  },

  /** `GET /api/courses/<id>/threads` → les fils. */
  threads(json: string | Uint8Array): EdThread[] {
    const object = parseJSONObject(json);
    if (object === null || !Array.isArray(object["threads"])) return [];
    return object["threads"].filter((t: unknown) => t !== null && typeof t === "object").map((t: Record<string, any>) => ({
      id: typeof t["id"] === "number" ? Math.trunc(t["id"]) : 0,
      number: typeof t["number"] === "number" ? Math.trunc(t["number"]) : null,
      title: typeof t["title"] === "string" ? t["title"] : "",
      category: typeof t["category"] === "string" ? t["category"] : null,
      type: typeof t["type"] === "string" ? t["type"] : null,
      isPinned: typeof t["is_pinned"] === "boolean" ? t["is_pinned"] : null,
      isAnswered: typeof t["is_answered"] === "boolean" ? t["is_answered"] : null,
      replyCount: typeof t["reply_count"] === "number" ? Math.trunc(t["reply_count"]) : null,
      createdAt: typeof t["created_at"] === "string" ? t["created_at"] : null,
      document: typeof t["document"] === "string" ? t["document"] : null,
    }));
  },

  /** `GET /api/threads/<id>?view=1` → le fil, ses réponses et leurs commentaires. */
  thread(json: string | Uint8Array): EdPost | null {
    const object = parseJSONObject(json);
    if (object === null) return null;
    const thread = object["thread"];
    if (thread === null || typeof thread !== "object" || Array.isArray(thread)) return null;
    const names = new Map<number, string>();
    for (const user of Array.isArray(object["users"]) ? object["users"] : []) {
      if (user !== null && typeof user === "object" && typeof user["id"] === "number") {
        names.set(Math.trunc(user["id"]), typeof user["name"] === "string" ? user["name"] : "");
      }
    }
    const post = (raw: Record<string, any>, answer: boolean): EdPost => {
      const userId = typeof raw["user_id"] === "number" ? Math.trunc(raw["user_id"]) : null;
      const named = userId !== null ? names.get(userId) : undefined;
      const author = named !== undefined ? named
        : (raw["is_anonymous"] === true ? "Anonyme" : "");
      const replies = Array.isArray(raw["comments"]) ? raw["comments"]
        .filter((c: unknown) => c !== null && typeof c === "object")
        .map((c: Record<string, any>) => post(c, false)) : [];
      return {
        id: typeof raw["id"] === "number" ? Math.trunc(raw["id"]) : 0,
        author: author === "" ? "Anonyme" : author,
        date: typeof raw["created_at"] === "string" ? raw["created_at"] : "",
        content: typeof raw["content"] === "string" ? raw["content"] : "",
        isAnswer: answer,
        isEndorsed: raw["is_endorsed"] === true,
        replies,
      };
    };
    const root = post(thread, false);
    const answers = Array.isArray(thread["answers"]) ? thread["answers"]
      .filter((a: unknown) => a !== null && typeof a === "object")
      .map((a: Record<string, any>) => post(a, true)) : [];
    root.replies = [...answers, ...root.replies];
    return root;
  },

  // MARK: Sondages

  /** Les sondages d'un message, dans l'ordre. */
  pollIDs(inDocument: string): number[] {
    const result: number[] = [];
    for (const match of inDocument.matchAll(/<poll\b[^>]*\bid="(\d+)"/g)) {
      const value = Number(match[1]);
      if (Number.isInteger(value)) result.push(value);
    }
    return result;
  },

  poll(json: string | Uint8Array): EdPoll | null {
    const object = parseJSONObject(json);
    if (object === null) return null;
    const poll = object["poll"];
    if (poll === null || typeof poll !== "object" || Array.isArray(poll) || typeof poll["id"] !== "number") return null;
    const data = poll["data"] !== null && typeof poll["data"] === "object" ? poll["data"] as Record<string, any> : {};
    const options = Array.isArray(data["options"]) ? data["options"] : [];
    const counts = options.map((option: Record<string, any>) =>
      typeof option["response_count"] === "number" ? Math.trunc(option["response_count"]) : null);
    const response = poll["response"] !== null && typeof poll["response"] === "object"
      ? (poll["response"]["data"] as Record<string, any> | undefined) : undefined;
    return new EdPoll({
      id: Math.trunc(poll["id"]),
      question: typeof poll["content"] === "string" ? poll["content"] : "",
      options: options.map((option: Record<string, any>) => typeof option["content"] === "string" ? option["content"] : ""),
      counts: counts.every((c: number | null) => c !== null) ? counts as number[] : [],
      multipleChoice: data["multiple_choice"] === true,
      isClosed: poll["is_closed"] === true,
      voters: typeof poll["response_count"] === "number" ? Math.trunc(poll["response_count"]) : 0,
      chosen: Array.isArray(response?.["option_indices"])
        ? response!["option_indices"].filter((x: unknown): x is number => typeof x === "number") : null,
      revealVotes: typeof poll["reveal_votes"] === "string" ? poll["reveal_votes"] : "after_response",
    });
  },

  /** Le cours Ed d'un cours de l'app : le code (« CS-101 ») dans le code Ed, le plus récent. */
  match(code: string, courses: EdCourse[]): EdCourse | null {
    const key = (text: string): string => text.toLowerCase().split("").filter((c) => /\p{L}|\p{N}/u.test(c)).join("");
    const firstParen = code.indexOf("(");
    const base = key(firstParen >= 0 ? code.slice(0, firstParen) : code);
    if (base === "") return null;
    const hits = courses.filter((course) => key(course.code).startsWith(base) || key(course.name).includes(base));
    if (hits.length === 0) return null;
    return hits.reduce((best, course) => course.id > best.id ? course : best);
  },

  /** Le format des messages d'Ed → des blocs, par le même chemin que le HTML. */
  blocks(document: string): SiteBlock[] {
    let text = document;
    // Les formules d'abord : leur contenu ne doit pas passer pour des balises.
    text = EdDiscussion.replace(text, String.raw`<math>(.*?)</math>`, (groups) => "\\(" + groups[1] + "\\)");
    text = EdDiscussion.replace(text, String.raw`<heading level="(\d)">`, (groups) => `<h${groups[1]}>`);
    text = EdDiscussion.replace(text, String.raw`</heading>`, () => "</h3>");
    text = EdDiscussion.replace(text, String.raw`<list style="number"[^>]*>`, () => "<ol>");
    text = EdDiscussion.replace(text, String.raw`<list(\s[^>]*)?>`, () => "<ul>");
    text = EdDiscussion.replace(text, String.raw`</list>`, () => "</ul>");
    text = EdDiscussion.replace(text, String.raw`<snippet[^>]*>`, () => "<pre>");
    text = EdDiscussion.replace(text, String.raw`</snippet>`, () => "</pre>");
    text = EdDiscussion.replace(text, String.raw`<web-snippet[^>]*>.*?</web-snippet>`, () => "");
    text = EdDiscussion.replace(text, String.raw`<poll\b[^>]*/>`, () => "");
    text = EdDiscussion.replace(text, String.raw`<link(\s[^>]*)>`, (groups) => `<a${groups[1]}>`);
    text = text.split("</link>").join("</a>");
    const tags: [string, string][] = [["paragraph", "p"], ["bold", "b"], ["italic", "i"], ["underline", "span"],
                                      ["list-item", "li"], ["callout", "blockquote"], ["spoiler", "div"],
                                      ["document", "div"], ["pre", "pre"]];
    for (const [ed, html] of tags) {
      text = EdDiscussion.replace(text, `<${ed}(\\s[^>]*)?>`, () => `<${html}>`);
      text = text.split(`</${ed}>`).join(`</${html}>`);
    }
    return SiteHTML.blocks(text, new URL("https://edstem.org/"));
  },

  // MARK: Écrire sur Ed

  /** Ce qu'on tape (Markdown léger, formules entre `$…$`) → le document d'Ed. */
  document(fromMarkdown: string): string {
    const escape = (s: string): string =>
      s.split("&").join("&amp;").split("<").join("&lt;").split(">").join("&gt;");
    const inline = (s: string): string => {
      let out = "";
      for (const piece of RichMarkup.inlines(s)) {
        switch (piece.kind) {
          case "text": out += escape(piece.text); break;
          case "bold": out += "<bold>" + escape(piece.text) + "</bold>"; break;
          case "italic": out += "<italic>" + escape(piece.text) + "</italic>"; break;
          case "code": out += "<code>" + escape(piece.text) + "</code>"; break;
          case "math": out += "<math>" + escape(piece.text) + "</math>"; break;
          case "link": out += "<link href=\"" + escape(piece.url) + "\">" + escape(piece.text) + "</link>"; break;
        }
      }
      return out;
    };
    let body = "";
    let list: { ordered: boolean; items: string[] } | null = null;
    const closeList = () => {
      if (list === null) return;
      const style = list.ordered ? "number" : "bullet";
      body += `<list style="${style}">` + list.items.map((item) => `<list-item><paragraph>${item}</paragraph></list-item>`).join("") + "</list>";
      list = null;
    };
    for (const block of RichMarkup.blocks(fromMarkdown)) {
      switch (block.kind) {
        case "bullet":
          if (list !== null && list.ordered) closeList();
          if (list === null) list = { ordered: false, items: [] };
          list.items.push(inline(block.text));
          break;
        case "numbered":
          if (list !== null && !list.ordered) closeList();
          if (list === null) list = { ordered: true, items: [] };
          list.items.push(inline(block.text));
          break;
        default:
          closeList();
          switch (block.kind) {
            case "heading":
              body += `<heading level="${Math.min(Math.max(block.level, 1), 3)}">` + inline(block.text) + "</heading>";
              break;
            case "paragraph":
              body += "<paragraph>" + inline(block.text) + "</paragraph>";
              break;
            case "math":
              body += "<paragraph><math>" + escape(block.text) + "</math></paragraph>";
              break;
            case "code":
              body += "<snippet language=\"none\" runnable=\"false\" line-numbers=\"true\">" + escape(block.text) + "</snippet>";
              break;
            case "rule":
              body += "<paragraph>—</paragraph>";
              break;
            default:
              break;
          }
          break;
      }
    }
    closeList();
    return "<document version=\"2.0\">" + body + "</document>";
  },

  /** Les catégories du forum d'un cours. */
  categories(courseJSON: string | Uint8Array): string[] {
    const object = parseJSONObject(courseJSON);
    const course = object?.["course"];
    if (course === null || course === undefined || typeof course !== "object") return [];
    const settings = (course as Record<string, any>)["settings"];
    if (settings === null || typeof settings !== "object") return [];
    const discussion = (settings as Record<string, any>)["discussion"];
    if (discussion === null || typeof discussion !== "object") return [];
    const categories = (discussion as Record<string, any>)["categories"];
    if (!Array.isArray(categories)) return [];
    return categories.filter((c: unknown) => c !== null && typeof c === "object")
      .map((c: Record<string, any>) => typeof c["name"] === "string" ? c["name"] : "")
      .filter((name: string) => name !== "");
  },

  // MARK: Leçons et quiz

  lessons(json: string | Uint8Array): EdLesson[] {
    const object = parseJSONObject(json);
    if (object === null) return [];
    const modules = new Map<number, string>();
    for (const module of Array.isArray(object["modules"]) ? object["modules"] : []) {
      if (module !== null && typeof module === "object" && typeof module["id"] === "number") {
        modules.set(Math.trunc(module["id"]), typeof module["name"] === "string" ? module["name"] : "");
      }
    }
    const result: EdLesson[] = [];
    for (const raw of Array.isArray(object["lessons"]) ? object["lessons"] : []) {
      if (raw === null || typeof raw !== "object" || typeof raw["id"] !== "number") continue;
      result.push({
        id: Math.trunc(raw["id"]),
        title: typeof raw["title"] === "string" ? raw["title"] : "Leçon",
        module: typeof raw["module_id"] === "number" ? modules.get(Math.trunc(raw["module_id"])) ?? null : null,
        status: typeof raw["status"] === "string" ? raw["status"] : null,
      });
    }
    return result;
  },

  slides(lessonJSON: string | Uint8Array): EdSlide[] {
    const object = parseJSONObject(lessonJSON);
    const lesson = object?.["lesson"];
    if (lesson === null || lesson === undefined || typeof lesson !== "object" || Array.isArray(lesson)) return [];
    const slides = (lesson as Record<string, any>)["slides"];
    if (!Array.isArray(slides)) return [];
    const result: EdSlide[] = [];
    for (const raw of slides) {
      if (raw === null || typeof raw !== "object" || typeof raw["id"] !== "number") continue;
      result.push({
        id: Math.trunc(raw["id"]),
        type: typeof raw["type"] === "string" ? raw["type"] : "",
        title: typeof raw["title"] === "string" ? raw["title"] : "",
        content: typeof raw["content"] === "string" ? raw["content"] : "",
        isCompleted: raw["status"] === "completed",
      });
    }
    return result;
  },

  questions(json: string | Uint8Array): EdQuestion[] {
    const object = parseJSONObject(json);
    if (object === null || !Array.isArray(object["questions"])) return [];
    const result: EdQuestion[] = [];
    for (const raw of object["questions"]) {
      if (raw === null || typeof raw !== "object" || typeof raw["id"] !== "number") continue;
      const data = raw["data"] !== null && typeof raw["data"] === "object" ? raw["data"] as Record<string, any> : raw;
      const type = typeof data["type"] === "string" ? data["type"]
        : typeof raw["type"] === "string" ? raw["type"] : "";
      let kind: EdQuestionKind;
      switch (type) {
        case "multiple-choice": kind = data["multiple_selection"] === true ? "choice-multiple" : "choice-single"; break;
        case "true-false": kind = "choice-single"; break;
        case "short-answer": kind = "text"; break;
        case "numerical": kind = "number"; break;
        default: kind = `other:${type}`; break;
      }
      const answers = (Array.isArray(data["answers"]) ? data["answers"] : []).map((answer: unknown) =>
        typeof answer === "string" ? answer
          : (answer !== null && typeof answer === "object" && typeof (answer as Record<string, any>)["content"] === "string"
            ? (answer as Record<string, any>)["content"] : ""));
      result.push({
        id: Math.trunc(raw["id"]), kind, content: typeof data["content"] === "string" ? data["content"] : "",
        answers: type === "true-false" && answers.length === 0 ? ["Vrai", "Faux"] : answers,
      });
    }
    return result;
  },

  /** La réponse à envoyer : les indices choisis pour un choix, le texte sinon. */
  response(choices: Set<number> | number[], text: string, forKind: EdQuestionKind): unknown {
    if (forKind === "choice-multiple" || forKind === "choice-single") return [...choices].sort((a, b) => a - b);
    if (forKind === "number") {
      const raw = text.split(",").join(".");
      const value = Number(raw);
      return raw.trim() !== "" && Number.isFinite(value) ? value : text;
    }
    return text;
  },

  replace(text: string, pattern: string, transform: (groups: string[]) => string): string {
    const regex = new RegExp(pattern, "gs");
    let result = "";
    let cursor = 0;
    for (const match of text.matchAll(regex)) {
      const location = match.index ?? 0;
      result += text.slice(cursor, location);
      const groups = Array.from({ length: match.length + 1 }, (_, i) => match[i] ?? "");
      result += transform(groups);
      cursor = location + match[0].length;
    }
    return result + text.slice(cursor);
  },
};

function parseJSONObject(data: string | Uint8Array): Record<string, any> | null {
  let text: string;
  if (typeof data === "string") text = data;
  else text = new TextDecoder().decode(data);
  try {
    const parsed = JSON.parse(text);
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, any> : null;
  } catch {
    return null;
  }
}

// MARK: - Moodle : la page du cours

export class MoodleCoursePageActivity {
  id: number;
  module: string;
  name: string;
  url: string;
  html: string;
  dates: string[];
  completed: boolean;

  constructor(o: { id: number; module: string; name: string; url: string; html?: string; dates?: string[]; completed?: boolean }) {
    this.id = o.id;
    this.module = o.module;
    this.name = o.name;
    this.url = o.url;
    this.html = o.html ?? "";
    this.dates = o.dates ?? [];
    this.completed = o.completed ?? false;
  }

  /** Ce qu'on montre sous le nom (« PDF », « Vidéo », « Devoir »…). */
  get kindLabel(): string {
    switch (this.module) {
      case "resource": return "Document";
      case "folder": return "Dossier";
      case "url": return "Lien";
      case "page": return "Page";
      case "assign": return "Devoir";
      case "forum": return "Forum";
      case "quiz": return "Quiz";
      case "lti": return "Outil externe";
      case "label": return "";
      default: return this.module.charAt(0).toUpperCase() + this.module.slice(1);
    }
  }

  /** Une série d'exercices (ou son corrigé), d'après le nom. */
  get isSeries(): boolean {
    const n = foldDiacritics(this.name);
    return ["serie", "series", "problem set", "exercice", "exercise", "corrige", "solution"].some((s) => n.includes(s));
  }

  get isVideo(): boolean {
    const n = this.name.toLowerCase();
    return n.includes("recording") || n.includes("vidéo") || n.includes("video") || n.includes("enregistrement")
      || this.url.includes("mediaspace") || this.url.includes("kaltura");
  }
}

export class MoodleCoursePageSection {
  number: number;
  title: string;
  summary: string;
  isCurrent: boolean;
  activities: MoodleCoursePageActivity[];

  constructor(o: { number: number; title: string; summary?: string; isCurrent?: boolean; activities?: MoodleCoursePageActivity[] }) {
    this.number = o.number;
    this.title = o.title;
    this.summary = o.summary ?? "";
    this.isCurrent = o.isCurrent ?? false;
    this.activities = o.activities ?? [];
  }
}

export class MoodleCoursePage {
  title: string;
  sections: MoodleCoursePageSection[];

  constructor(o: { title: string; sections: MoodleCoursePageSection[] }) {
    this.title = o.title;
    this.sections = o.sections;
  }

  static decode(json: string): MoodleCoursePage | null {
    let raw: Record<string, any>;
    try {
      const parsed = JSON.parse(json);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null;
      raw = parsed as Record<string, any>;
    } catch {
      return null;
    }
    if (typeof raw["title"] !== "string" || !Array.isArray(raw["sections"]) || raw["sections"].length === 0) return null;
    const sections: MoodleCoursePageSection[] = [];
    for (const value of raw["sections"]) {
      if (value === null || typeof value !== "object") return null;
      const o = value as Record<string, any>;
      if (!Array.isArray(o["activities"])) o["activities"] = [];
      const activities: MoodleCoursePageActivity[] = [];
      for (const activity of o["activities"]) {
        if (activity === null || typeof activity !== "object" || typeof activity["id"] !== "number") return null;
        activities.push(new MoodleCoursePageActivity({
          id: Math.trunc(activity["id"]),
          module: typeof activity["module"] === "string" ? activity["module"] : "",
          name: BotafogoParser.decode(typeof activity["name"] === "string" ? activity["name"] : ""),
          url: typeof activity["url"] === "string" ? activity["url"] : "",
          html: typeof activity["html"] === "string" ? activity["html"] : "",
          dates: Array.isArray(activity["dates"]) ? activity["dates"].filter((x: unknown): x is string => typeof x === "string") : [],
          completed: activity["completed"] === true,
        }));
      }
      sections.push(new MoodleCoursePageSection({
        number: typeof o["number"] === "number" ? Math.trunc(o["number"]) : 0,
        title: BotafogoParser.decode(typeof o["title"] === "string" ? o["title"] : ""),
        summary: typeof o["summary"] === "string" ? o["summary"] : "",
        isCurrent: o["isCurrent"] === true,
        activities,
      }));
    }
    return new MoodleCoursePage({ title: raw["title"], sections });
  }

  /** La section à ouvrir d'abord. */
  currentSection(today: Date = new Date()): MoodleCoursePageSection | null {
    const marked = this.sections.find((section) => section.isCurrent);
    if (marked !== undefined) return marked;
    const year = today.getFullYear();
    const dated = this.sections.find((section) => {
      const range = MoodleCoursePage.range(section.title, year);
      return range !== null && today.getTime() >= range.start.getTime() && today.getTime() <= range.end.getTime();
    });
    if (dated !== undefined) return dated;
    return this.sections.find((section) => section.activities.length > 0) ?? null;
  }

  /** « 12 October- 18 October », « 7 septembre - 13 septembre » → l'intervalle. */
  static range(ofTitle: string, year: number): { start: Date; end: Date } | null {
    const months = new Map<string, number>(Object.entries({
      january: 1, february: 2, march: 3, april: 4, may: 5, june: 6, july: 7, august: 8,
      september: 9, october: 10, november: 11, december: 12,
      janvier: 1, fevrier: 2, mars: 3, avril: 4, mai: 5, juin: 6, juillet: 7, aout: 8,
      septembre: 9, octobre: 10, novembre: 11, decembre: 12,
    }));
    const text = foldDiacritics(ofTitle);
    const found: { year: number; month: number; day: number }[] = [];
    for (const match of text.matchAll(/(\d{1,2})\s*([a-z]+)/g)) {
      const day = Number(match[1]);
      const month = months.get(match[2]);
      if (month === undefined || !Number.isInteger(day)) continue;
      found.push({ year, month, day });
    }
    if (found.length < 2) return null;
    const start = new Date(found[0].year, found[0].month - 1, found[0].day);
    let end = new Date(found[1].year, found[1].month - 1, found[1].day);
    if (end.getTime() < start.getTime()) end = new Date(end.getFullYear() + 1, end.getMonth(), end.getDate());
    end = new Date(end.getTime() + 86_400_000 - 1);
    return { start, end };
  }
}

function foldDiacritics(text: string): string {
  return text.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
}

// MARK: - Courseware : un problème

export interface EdXProblemOption { value: string; label: string; checked: boolean | null }
export interface EdXProblemGroup {
  name: string;
  type: string;
  options: EdXProblemOption[];
  value: string | null;
}

export class EdXProblem {
  url: string;
  title: string;
  prompt: string;
  groups: EdXProblemGroup[];
  score: number;
  total: number;
  attempts: number;

  constructor(o: Partial<EdXProblem> & { url: string }) {
    this.url = o.url;
    this.title = o.title ?? "";
    this.prompt = o.prompt ?? "";
    this.groups = o.groups ?? [];
    this.score = o.score ?? 0;
    this.total = o.total ?? 0;
    this.attempts = o.attempts ?? 0;
  }

  static decode(json: string): EdXProblem | null {
    try {
      const parsed = JSON.parse(json);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null;
      const o = parsed as Record<string, any>;
      if (typeof o["url"] !== "string") return null;
      return new EdXProblem({
        url: o["url"],
        title: typeof o["title"] === "string" ? o["title"] : "",
        prompt: typeof o["prompt"] === "string" ? o["prompt"] : "",
        groups: Array.isArray(o["groups"]) ? o["groups"].filter((g: unknown) => g !== null && typeof g === "object")
          .map((g: Record<string, any>) => ({
            name: typeof g["name"] === "string" ? g["name"] : "",
            type: typeof g["type"] === "string" ? g["type"] : "",
            options: Array.isArray(g["options"]) ? g["options"].filter((op: unknown) => op !== null && typeof op === "object")
              .map((op: Record<string, any>) => ({
                value: typeof op["value"] === "string" ? op["value"] : "",
                label: typeof op["label"] === "string" ? op["label"] : "",
                checked: typeof op["checked"] === "boolean" ? op["checked"] : null,
              })) : [],
            value: typeof g["value"] === "string" ? g["value"] : null,
          })) : [],
        score: typeof o["score"] === "number" ? o["score"] : 0,
        total: typeof o["total"] === "number" ? o["total"] : 0,
        attempts: typeof o["attempts"] === "number" ? Math.trunc(o["attempts"]) : 0,
      });
    } catch {
      return null;
    }
  }

  /** Le corps du formulaire envoyé : chaque groupe, une ou plusieurs valeurs. */
  static formBody(answers: Record<string, string[]>): string {
    const encode = (text: string): string =>
      encodeURIComponent(text).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
    const names = Object.keys(answers).sort();
    return names.flatMap((name) => (answers[name] ?? []).map((value) => encode(name) + "=" + encode(value)))
      .join("&");
  }

  /** La réponse de `problem_check` : « correct », « incorrect », « partially-correct ». */
  static result(json: string | Uint8Array): EdXProblemResult | null {
    const object = parseJSONObject(json);
    if (object === null) return null;
    const verdict = typeof object["success"] === "string" ? object["success"]
      : object["success"] === true ? "correct" : "incorrect";
    return {
      verdict,
      score: typeof object["current_score"] === "number" ? object["current_score"] : null,
      total: typeof object["total_possible"] === "number" ? object["total_possible"] : null,
      isCorrect: verdict === "correct",
    };
  }
}

export interface EdXProblemResult {
  verdict: string;
  score: number | null;
  total: number | null;
  isCorrect: boolean;
}
