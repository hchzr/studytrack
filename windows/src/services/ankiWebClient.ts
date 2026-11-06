// Le protocole de synchronisation d'AnkiWeb, côté client (Polymestre/Services/AnkiWeb/
// AnkiWebClient.swift) — **connexion, métadonnées, téléchargement**.
//
// Version **10** du protocole (formulaire `multipart`, JSON non compressé) : le serveur de
// référence d'Anki l'accepte toujours (`SYNC_VERSION_MIN = 8`), et elle évite le zstd de la
// version 11. Pas porté : la synchronisation normale (`start`, `applyChanges`, `chunk`,
// `sanityCheck2`…) et donc l'envoi de notes ; Windows **lit** seulement (temps de révision).
// L'app n'écrase jamais la collection d'AnkiWeb.

import { nativeFetch } from "../native/http.ts";
import { ZstdFrame } from "../domain/zstdFrame.ts";

export type Fetcher = (url: string, init?: RequestInit & { maxRedirections?: number }) => Promise<Response>;

export const syncVersion = 10;
/**
 * L'identifiant de client, **au format d'Anki** : `anki,<version> (<build>),<plateforme>`.
 * AnkiWeb lit la version dans cet identifiant et refuse (400, sans message) tout ce qui n'en
 * a pas la forme ou qui est trop ancien.
 */
export const clientVersion = "anki,25.02.7 (6ddc22e5),win";
/** La forme courte, celle de l'en-tête `anki-sync`. */
export const shortClientVersion = "25.02.7,6ddc22e5,win";
export const defaultEndpoint = "https://sync.ankiweb.net/";

export class AnkiFailure extends Error {
  constructor(readonly kind: "badCredentials" | "server" | "decoding" | "unsupported", message: string, readonly code = 0) {
    super(message);
  }

  static badCredentials(): AnkiFailure { return new AnkiFailure("badCredentials", "Identifiant ou mot de passe AnkiWeb incorrect."); }

  static server(code: number, body: string, method = ""): AnkiFailure {
    const step = method === "" ? "" : ` (étape « ${method} »)`;
    const detail = body.trim();
    return new AnkiFailure("server", `AnkiWeb a répondu ${code}${step}${detail === "" || detail === String(code) ? "" : ` : ${detail.slice(0, 160)}`}.`, code);
  }

  static decoding(what: string): AnkiFailure { return new AnkiFailure("decoding", `Réponse d'AnkiWeb illisible (${what}).`); }
  static unsupported(message: string): AnkiFailure { return new AnkiFailure("unsupported", message); }
}

export interface AnkiMeta {
  modified: number;
  schema: number;
  usn: number;
  hostNumber: number;
  message: string;
  shouldContinue: boolean;
  empty: boolean;
}

export function randomKey(length: number): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return [...bytes].map((b) => alphabet[b % alphabet.length]).join("");
}

/**
 * La racine d'un serveur, lue dans une redirection : `Location` peut être la racine
 * (`https://sync3.ankiweb.net/`) ou l'adresse complète de la méthode (`…/sync/meta`) ; on
 * garde ce qui précède `/sync/`.
 */
export function endpointFromRedirect(location: string, base: string | null): string | null {
  let url: URL;
  try { url = new URL(location.trim(), base ?? undefined); } catch { return null; }
  if (!url.protocol.startsWith("http")) return null;
  let path = url.pathname;
  const index = path.indexOf("/sync/");
  if (index >= 0) path = path.slice(0, index);
  if (!path.endsWith("/")) path += "/";
  url.pathname = path;
  url.search = "";
  url.hash = "";
  return url.href;
}

export class AnkiWebClient {
  endpoint: string;
  private readonly sessionKey = randomKey(8);

  constructor(public hostKey = "", endpoint: string | null = null, private readonly fetcher: Fetcher = nativeFetch) {
    this.endpoint = endpoint ?? defaultEndpoint;
  }

  // MARK: Transport

  /** Une requête : `c=0` (pas de gzip), `k` (clé d'hôte), `s` (session), `data`. */
  async call(method: string, json: unknown = {}, timeout = 60): Promise<Uint8Array> {
    return this.post(method, new TextEncoder().encode(JSON.stringify(json)), timeout, 0);
  }

  private async post(method: string, data: Uint8Array, timeout: number, redirects: number): Promise<Uint8Array> {
    const boundary = `Polymestre-${randomKey(16)}`;
    const encoder = new TextEncoder();
    const parts: Uint8Array[] = [];
    const field = (name: string, value: Uint8Array, file = false) => {
      parts.push(encoder.encode(`--${boundary}\r\n`));
      parts.push(encoder.encode(file
        ? `Content-Disposition: form-data; name="${name}"; filename="data"\r\nContent-Type: application/octet-stream\r\n\r\n`
        : `Content-Disposition: form-data; name="${name}"\r\n\r\n`));
      parts.push(value);
      parts.push(encoder.encode("\r\n"));
    };
    field("c", encoder.encode("0"));
    if (this.hostKey !== "") field("k", encoder.encode(this.hostKey));
    field("s", encoder.encode(this.sessionKey));
    field("data", data, true);
    parts.push(encoder.encode(`--${boundary}--\r\n`));
    const body = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
    let offset = 0;
    for (const part of parts) { body.set(part, offset); offset += part.length; }

    const url = new URL(`sync/${method}`, this.endpoint).href;
    // Les redirections sont suivies **à la main** : AnkiWeb renvoie un compte vers son
    // serveur par un 308 dont l'adresse est la **racine** du serveur. Laissé faire, le client
    // y renverrait le formulaire sur la racine, pas sur `/sync/<méthode>` — et AnkiWeb
    // répondrait 400.
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout * 1000);
    let response: Response;
    try {
      response = await this.fetcher(url, {
        method: "POST", headers: { "Content-Type": `multipart/form-data; boundary=${boundary}` },
        body: body as BodyInit, signal: controller.signal, maxRedirections: 0,
      });
    } finally {
      clearTimeout(timer);
    }
    const payload = new Uint8Array(await response.arrayBuffer());
    const status = response.status;
    if (status >= 200 && status < 300) return payload;
    if ([301, 302, 303, 307, 308].includes(status)) {
      const location = response.headers.get("Location") ?? new TextDecoder().decode(payload);
      const target = redirects < 3 ? endpointFromRedirect(location, url) : null;
      if (target === null) throw AnkiFailure.server(status, "redirection sans adresse", method);
      // Le compte vit sur un autre serveur : on y passe, et on rejoue.
      this.endpoint = target;
      return this.post(method, data, timeout, redirects + 1);
    }
    if (status === 403) throw AnkiFailure.badCredentials();
    if (status === 501) throw AnkiFailure.unsupported("AnkiWeb n'accepte plus ce protocole de synchronisation.");
    throw AnkiFailure.server(status, new TextDecoder().decode(payload), method);
  }

  private object(data: Uint8Array, what: string): Record<string, any> {
    try {
      const value = JSON.parse(new TextDecoder().decode(data));
      if (value !== null && typeof value === "object" && !Array.isArray(value)) return value;
    } catch { /* illisible */ }
    throw AnkiFailure.decoding(what);
  }

  // MARK: Connexion et métadonnées

  /** Échange identifiant et mot de passe contre une clé d'hôte, seule gardée. */
  async login(username: string, password: string): Promise<string> {
    const reply = this.object(await this.call("hostKey", { u: username, p: password }), "hostKey");
    if (typeof reply.key !== "string" || reply.key === "") throw AnkiFailure.badCredentials();
    this.hostKey = reply.key;
    return reply.key;
  }

  async meta(): Promise<AnkiMeta> {
    let data: Uint8Array;
    try {
      data = await this.call("meta", { v: syncVersion, cv: clientVersion }, 30);
    } catch (error) {
      // Le serveur principal répond 400 à l'ancien format quand le compte vit ailleurs, au
      // lieu de rediriger. Le format récent, lui, reçoit la redirection : on s'en sert pour
      // trouver le serveur du compte, puis on rejoue.
      if (error instanceof AnkiFailure && error.code === 400 && this.endpoint === defaultEndpoint) {
        const home = await this.discoverServer();
        if (home === null) throw AnkiFailure.server(400, "", "meta");
        this.endpoint = home;
        data = await this.call("meta", { v: syncVersion, cv: clientVersion }, 30);
      } else {
        throw error;
      }
    }
    const reply = this.object(data, "meta");
    const meta: AnkiMeta = {
      modified: Number(reply.mod ?? 0), schema: Number(reply.scm ?? 0), usn: Number(reply.usn ?? 0),
      hostNumber: Number(reply.hostNum ?? 0), message: reply.msg ?? "", shouldContinue: reply.cont ?? true, empty: reply.empty ?? false,
    };
    // Anciens clients : le numéro d'hôte désigne le serveur du compte. Les serveurs actuels
    // redirigent eux-mêmes : si celui-ci refuse la clé, on reste sur le serveur qui a répondu.
    if (meta.hostNumber > 0 && this.endpoint === defaultEndpoint) {
      this.endpoint = `https://sync${meta.hostNumber}.ankiweb.net/`;
      try { return await this.meta(); } catch { this.endpoint = defaultEndpoint; }
    }
    if (!meta.shouldContinue) throw AnkiFailure.unsupported(meta.message === "" ? "AnkiWeb refuse la synchronisation." : meta.message);
    return meta;
  }

  /**
   * Le serveur du compte, lu dans la redirection que le format récent du protocole (en-tête
   * `anki-sync`, corps zstd) reçoit du serveur principal. Seul le code et l'en-tête
   * `Location` servent : la réponse (zstd) n'est pas lue.
   */
  async discoverServer(): Promise<string | null> {
    const body = new TextEncoder().encode(JSON.stringify({ v: 11, cv: clientVersion }));
    const url = new URL("sync/meta", defaultEndpoint).href;
    const header = JSON.stringify({ v: 11, k: this.hostKey, c: shortClientVersion, s: this.sessionKey });
    const response = await this.fetcher(url, {
      method: "POST", headers: { "anki-sync": header, "Content-Type": "application/octet-stream" },
      body: ZstdFrame.stored(body) as BodyInit, maxRedirections: 0,
    });
    const location = response.headers.get("Location");
    if (![301, 302, 307, 308].includes(response.status) || location === null) return null;
    return endpointFromRedirect(location, url);
  }

  /** La collection entière, un fichier SQLite (schéma 11). */
  async download(): Promise<Uint8Array> {
    const data = await this.call("download", {}, 300);
    const magic = new TextEncoder().encode("SQLite format 3");
    if (!magic.every((byte, index) => data[index] === byte)) {
      throw AnkiFailure.decoding(new TextDecoder().decode(data.slice(0, 80)) || "download");
    }
    return data;
  }
}
