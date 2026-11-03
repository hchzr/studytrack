// Le site Botafogo d'un cours, lu dans l'app (StudyKit/BotafogoViews.swift › BotafogoBook) :
// le programme (semaines, séances, séries, infos), le sommaire du polycopié, et chaque
// document, lu une fois puis gardé. Un livre par site, partagé par tout l'écran.
//
// Le programme n'est ni dans le HTML ni dans une API : il est écrit dans un des fichiers
// `_nuxt/*.js` du site. On cherche le bon (huit à la fois), et on retient lequel c'était.
// Les requêtes passent par Rust (`nativeFetch`) : le site n'envoie pas d'en-têtes CORS.

import { BotafogoNode, BotafogoProgram, BotafogoSite, BotafogoDocument, type Chapter, type ChapterSection } from "../domain/botafogoProgram.ts";
import { BotafogoPage, type BotafogoBlock } from "../domain/botafogoPage.ts";
import { BotafogoParser } from "../domain/courseContentImport.ts";
import { nativeFetch } from "../native/http.ts";

export type BookState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "ready" }
  | { kind: "failed"; message: string };

const CHUNK_KEY = "botafogo.programChunk.";
const TIMEOUT_MS = 20_000;

async function text(url: string): Promise<string> {
  const response = await nativeFetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!response.ok) throw new Error(`le serveur a répondu ${response.status}`);
  return response.text();
}

/** Le site Botafogo d'une adresse de cours (`https://botafogo.epfl.ch/analyse-1-GM/…`). */
export function isBotafogo(address: string): boolean {
  try {
    return new URL(address).hostname.toLowerCase().includes("botafogo");
  } catch {
    return false;
  }
}

/** Les adresses `_nuxt/*.js` citées par la page, sous la racine du site. */
export function nuxtChunks(html: string, root: URL): string[] {
  const base = root.pathname.endsWith("/") ? root.pathname : root.pathname + "/";
  const escaped = base.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const found = html.match(new RegExp(escaped + String.raw`_nuxt/[A-Za-z0-9_-]+\.js`, "g")) ?? [];
  return [...new Set(found)].sort();
}

/**
 * Les adresses d'un document, la plus récente d'abord : `api/content/node/<collection><chemin>.json`
 * (le site depuis l'automne 2026), puis l'ancienne `api/content/node?collection=…&path=…`.
 */
export function nodeAddresses(root: URL, collection: "content" | "handout", path: string): string[] {
  const base = root.toString().endsWith("/") ? root.toString() : root.toString() + "/";
  const slashed = path.startsWith("/") ? path : "/" + path;
  const encoded = slashed.split("/").map(encodeURIComponent).join("/");
  return [
    `${base}api/content/node/${collection}${encoded}.json`,
    `${base}api/content/node?collection=${collection}&path=${encodeURIComponent(slashed)}`,
  ];
}

export class BotafogoBook {
  state: BookState = { kind: "idle" };
  root: URL | null = null;
  /** Les semaines du programme. */
  weeks: BotafogoNode[] = [];
  /** Les infos générales (`sect`) : présentation, forum, enregistrements. */
  infos: BotafogoNode[] = [];
  /** Le sommaire du polycopié (vide si le site n'en a pas). */
  chapters: Chapter[] = [];

  private bodies = new Map<string, Record<string, unknown>>();
  private pages = new Map<string, BotafogoBlock[]>();
  private loading: Promise<void> | null = null;
  private listeners = new Set<() => void>();

  constructor(readonly site: URL) {}

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed(): void {
    for (const listener of this.listeners) listener();
  }

  load(): Promise<void> {
    if (this.state.kind === "ready") return Promise.resolve();
    this.loading ??= this.fetch().finally(() => { this.loading = null; });
    return this.loading;
  }

  retry(): Promise<void> {
    this.state = { kind: "idle" };
    return this.load();
  }

  private async fetch(): Promise<void> {
    this.state = { kind: "loading" };
    this.changed();
    try {
      let address = this.site;
      let html = await text(address.toString());
      for (let i = 0; i < 2; i++) {
        const next = BotafogoParser.metaRefresh(html, address);
        if (next === null) break;
        address = next;
        html = await text(address.toString());
      }
      const root = BotafogoParser.siteRoot(html, address);
      this.root = root;
      const [program, chapters] = await Promise.all([BotafogoBook.program(html, root), BotafogoBook.handout(html, root)]);
      if (program === null || program.length === 0) {
        this.state = { kind: "failed", message: "Programme introuvable sur ce site." };
      } else {
        this.infos = program.filter((node) => node.type === "sect");
        this.weeks = program.filter((node) => node.type === "week");
        this.chapters = chapters;
        this.state = { kind: "ready" };
      }
    } catch (error) {
      this.state = { kind: "failed", message: error instanceof Error ? error.message : "Le site ne répond pas." };
    }
    this.changed();
  }

  /** Le fichier qui porte le programme : celui retenu la dernière fois d'abord, puis huit à la fois. */
  static async program(html: string, root: URL): Promise<BotafogoNode[] | null> {
    const paths = nuxtChunks(html, root);
    if (paths.length === 0) return null;
    const key = CHUNK_KEY + root.toString();
    let cached: string | null = null;
    try { cached = localStorage.getItem(key); } catch { /* sans mémoire */ }
    const read = async (path: string): Promise<BotafogoNode[] | null> => {
      try {
        const script = await text(new URL(path, root).toString());
        if (!script.includes("type:`week`")) return null;
        return BotafogoProgram.extract(script);
      } catch {
        return null;
      }
    };
    if (cached !== null && paths.includes(cached)) {
      const hit = await read(cached);
      if (hit) return hit;
    }
    const queue = [...paths];
    let found: BotafogoNode[] | null = null;
    const worker = async () => {
      while (found === null) {
        const path = queue.shift();
        if (path === undefined) return;
        const program = await read(path);
        if (program && found === null) {
          found = program;
          try { localStorage.setItem(key, path); } catch { /* idem */ }
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(8, paths.length) }, worker));
    return found;
  }

  private static async handout(html: string, root: URL): Promise<Chapter[]> {
    const collection = BotafogoSite.handoutCollection(html);
    if (collection === null) return [];
    try {
      const json = await text(root.toString() + "api/content/nav?collection=handout&path=" + encodeURIComponent(collection));
      return BotafogoSite.chapters(json);
    } catch {
      return [];
    }
  }

  /** Le corps brut d'un document (du cours, ou du polycopié). */
  async body(url: string): Promise<Record<string, unknown> | null> {
    const cached = this.bodies.get(url);
    if (cached) return cached;
    if (this.root === null) return null;
    const handout = BotafogoSite.isHandout(url);
    const raw = handout ? url : BotafogoProgram.contentPath(url);
    for (const address of nodeAddresses(this.root, handout ? "handout" : "content", raw)) {
      try {
        const body = BotafogoDocument.body(await text(address));
        if (!body) continue;
        this.bodies.set(url, body);
        return body;
      } catch {
        // l'autre forme d'adresse
      }
    }
    return null;
  }

  /** Un document prêt à dessiner ; `null` : illisible. */
  async page(url: string): Promise<BotafogoBlock[] | null> {
    const cached = this.pages.get(url);
    if (cached) return cached;
    const body = await this.body(url);
    if (!body) return null;
    const blocks = BotafogoPage.blocks(body);
    this.pages.set(url, blocks);
    return blocks;
  }

  /** Les sections du polycopié qu'une semaine fait lire (citées par sa page). */
  async readings(weekContent: string): Promise<ChapterSection[]> {
    const body = await this.body(weekContent);
    if (!body) return [];
    return BotafogoPage.references(body).map((reference) => {
      const path = BotafogoPage.handoutPath(reference.target);
      return { title: this.section(path)?.title ?? reference.title, path };
    });
  }

  section(path: string): ChapterSection | null {
    for (const chapter of this.chapters) {
      const hit = chapter.sections.find((section) => section.path === path);
      if (hit) return hit;
    }
    return null;
  }

  chapter(path: string): Chapter | null {
    return this.chapters.find((chapter) => chapter.sections.some((section) => section.path === path)) ?? null;
  }

  /** La semaine où se trouve cet élément du programme (une série, une séance). */
  week(containing: string): BotafogoNode | null {
    return this.weeks.find((week) => (week.children ?? []).some((child) =>
      child.url === containing || (child.children ?? []).some((inner) => inner.url === containing))) ?? null;
  }

  /** « /media/… » est relatif au site du cours (`…/analyse-1-GM/`). */
  assetURL(source: string): string | null {
    if (/^https?:/i.test(source)) return source;
    if (this.root === null) return null;
    return this.root.toString() + (source.startsWith("/") ? source.slice(1) : source);
  }
}

/** Un livre par site (la racine du cours) : le programme ne se charge qu'une fois. */
const books = new Map<string, BotafogoBook>();

export function botafogoBook(site: string): BotafogoBook {
  const url = new URL(site);
  const key = BotafogoParser.courseRoot(url).toString();
  let book = books.get(key);
  if (!book) {
    book = new BotafogoBook(url);
    books.set(key, book);
  }
  return book;
}
