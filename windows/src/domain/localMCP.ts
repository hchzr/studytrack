// Port de StudyTrack/Domain/LocalMCP.swift : un serveur MCP **local**, HTTP sur
// 127.0.0.1, JSON-RPC, réponses JSON. La couche socket (Network.framework côté
// Mac) n'est pas portable telle quelle : elle est injectée (`LocalMCPHost`), le
// protocole et le contrôle d'accès restent ici, purs et testés.
//
// Sécurité — une page web peut viser 127.0.0.1 : jeton de 256 bits dans
// l'adresse, en-tête `Origin` refusé, `Host` limité à la boucle locale.

export interface LocalMCPProvider {
  serverName: string;
  instructions: string;
  tools: Record<string, unknown>[];
  /** Le résultat d'un outil, au format MCP (`content`, `isError`). */
  call(name: string, args: Record<string, unknown>): Promise<Record<string, unknown>>;
}

export type LocalParseError = "invalid" | "tooLarge" | "chunked";

/** La requête HTTP, lue à la main : une ligne, des en-têtes, un corps. */
export class LocalHTTPRequest {
  method: string;
  path: string;
  /** Clés en minuscules. */
  headers: Record<string, string>;
  body: Uint8Array;

  constructor(o: LocalHTTPRequest) {
    this.method = o.method;
    this.path = o.path;
    this.headers = o.headers;
    this.body = o.body;
  }

  /** `null` tant que la requête n'est pas complète ; une erreur si elle est invalide ou trop grosse. */
  static parse(data: Uint8Array, limit = 8 * 1024 * 1024): { ok: true; request: LocalHTTPRequest } | { ok: false; error: LocalParseError } | null {
    if (data.length > limit) return { ok: false, error: "tooLarge" };
    const separator = indexOfBytes(data, [13, 10, 13, 10]);
    if (separator < 0) return data.length > 64 * 1024 ? { ok: false, error: "invalid" } : null;
    let head: string;
    try { head = new TextDecoder("utf-8", { fatal: true }).decode(data.slice(0, separator)); } catch { return { ok: false, error: "invalid" }; }
    const lines = head.split("\r\n");
    const first = lines.shift()!.split(" ").filter((part) => part !== "");
    if (first.length < 2) return { ok: false, error: "invalid" };
    const headers: Record<string, string> = {};
    for (const line of lines) {
      const colon = line.indexOf(":");
      if (colon < 0) continue;
      headers[line.slice(0, colon).toLowerCase()] = line.slice(colon + 1).replace(/^\s+|\s+$/g, "");
    }
    if ((headers["transfer-encoding"] ?? "").toLowerCase().includes("chunked")) return { ok: false, error: "chunked" };
    const rawLength = headers["content-length"];
    const length = rawLength === undefined ? 0 : /^[+-]?\d+$/.test(rawLength) ? Number(rawLength) : -1;
    if (length < 0) return { ok: false, error: "invalid" };
    if (length > limit) return { ok: false, error: "tooLarge" };
    const bodyStart = separator + 4;
    if (data.length - bodyStart < length) return null;
    return {
      ok: true,
      request: new LocalHTTPRequest({
        method: first[0].toUpperCase(),
        path: first[1],
        headers,
        body: data.slice(bodyStart, bodyStart + length),
      }),
    };
  }
}

export const LocalMCPRPC = {
  protocols: ["2025-06-18", "2025-03-26", "2024-11-05"],

  textResult(value: unknown, isError = false): Record<string, unknown> {
    let text: string;
    if (typeof value === "string") {
      text = value;
    } else {
      try {
        const encoded = JSON.stringify(value);
        text = encoded === undefined ? String(value) : encoded;
      } catch {
        text = String(value);
      }
    }
    const result: Record<string, unknown> = { content: [{ type: "text", text }] };
    if (isError) result["isError"] = true;
    return result;
  },

  /** Une requête JSON-RPC → sa réponse (`null` pour une notification). */
  async handle(message: Record<string, unknown>, provider: LocalMCPProvider): Promise<Record<string, unknown> | null> {
    const id = message["id"];
    if (id === undefined || id === null) return null;
    const reply = (result: unknown): Record<string, unknown> => ({ jsonrpc: "2.0", id, result });
    const fail = (code: number, text: string): Record<string, unknown> => ({
      jsonrpc: "2.0", id, error: { code, message: text },
    });
    const params = message["params"] !== null && typeof message["params"] === "object" && !Array.isArray(message["params"])
      ? message["params"] as Record<string, unknown> : {};
    switch (message["method"]) {
      case "initialize": {
        const asked = typeof params["protocolVersion"] === "string" ? params["protocolVersion"] : "";
        return reply({
          protocolVersion: LocalMCPRPC.protocols.includes(asked) ? asked : LocalMCPRPC.protocols[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: provider.serverName, title: "StudyTrack (fichiers, Mac)", version: "1.0.0" },
          instructions: provider.instructions,
        });
      }
      case "ping": return reply({});
      case "tools/list": return reply({ tools: provider.tools });
      case "resources/list": return reply({ resources: [] });
      case "prompts/list": return reply({ prompts: [] });
      case "tools/call": {
        const name = typeof params["name"] === "string" ? params["name"] : undefined;
        if (name === undefined || !provider.tools.some((tool) => tool["name"] === name)) {
          return fail(-32602, `Outil inconnu : ${name ?? ""}`);
        }
        const args = params["arguments"] !== null && typeof params["arguments"] === "object" && !Array.isArray(params["arguments"])
          ? params["arguments"] as Record<string, unknown> : {};
        return reply(await provider.call(name, args));
      }
      default:
        return fail(-32601, `Méthode inconnue : ${String(message["method"] ?? "")}`);
    }
  },

  /** Un jeton de 256 bits, en base64url. */
  makeToken(): string {
    const bytes = new Uint8Array(32);
    globalThis.crypto.getRandomValues(bytes);
    return bytesToBase64Url(bytes);
  },
};

/** La couche socket, fournie par l'hôte (Node en test, Rust/Network côté app). */
export interface LocalMCPHost {
  /** Ouvre l'écoute (`0` : un port libre) et rend le port choisi. */
  start(port: number, handle: (request: LocalHTTPRequest, boundPort: number) => Promise<Uint8Array>): Promise<number | null>;
  stop(): void;
}

export class LocalMCPServer {
  private readonly token: string;
  private readonly provider: LocalMCPProvider;
  private readonly host: LocalMCPHost;
  private running = false;
  port = 0;

  constructor(token: string, provider: LocalMCPProvider, host: LocalMCPHost) {
    this.token = token;
    this.provider = provider;
    this.host = host;
  }

  get isRunning(): boolean { return this.running; }

  /** L'adresse à donner à un client MCP. */
  get url(): string | null {
    return this.port === 0 ? null : `http://127.0.0.1:${this.port}/${this.token}`;
  }

  /** Démarre l'écoute (`port` 0 : un port libre) ; rend le port choisi, ou `null`. */
  async start(port = 0): Promise<number | null> {
    this.stop();
    const bound = await this.host.start(port, (request, boundPort) => this.respond(request, boundPort));
    if (bound === null) return null;
    this.port = bound;
    this.running = true;
    return bound;
  }

  stop(): void {
    this.host.stop();
    this.running = false;
    this.port = 0;
  }

  /** Le contrôle d'accès puis le JSON-RPC. */
  async respond(request: LocalHTTPRequest, port = this.port): Promise<Uint8Array> {
    // Un navigateur envoie toujours `Origin` ; un client MCP en ligne de commande, jamais.
    if (request.headers["origin"] !== undefined) {
      return LocalMCPServer.http(403, { error: "origine refusée" });
    }
    const host = (request.headers["host"] ?? "").toLowerCase();
    const allowed = [`127.0.0.1:${port}`, `localhost:${port}`, "127.0.0.1", "localhost"];
    if (!allowed.includes(host)) {
      return LocalMCPServer.http(403, { error: "hôte refusé" });
    }
    const path = request.path.split("?")[0];
    const parts = path.split("/").filter((part) => part !== "");
    const last = parts[parts.length - 1] ?? "";
    if (!LocalMCPServer.constantTimeEqual(last, this.token)) {
      return LocalMCPServer.http(401, { error: "adresse incomplète : copie l'adresse complète depuis StudyTrack (Réglages › Claude)." });
    }
    switch (request.method) {
      case "POST": {
        let object: unknown;
        try { object = JSON.parse(new TextDecoder().decode(request.body)); } catch {
          return LocalMCPServer.http(400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "JSON illisible" } });
        }
        if (Array.isArray(object)) {
          const replies: Record<string, unknown>[] = [];
          for (const message of object) {
            if (message === null || typeof message !== "object" || Array.isArray(message)) continue;
            const reply = await LocalMCPRPC.handle(message as Record<string, unknown>, this.provider);
            if (reply !== null) replies.push(reply);
          }
          return replies.length === 0 ? LocalMCPServer.http(202, null) : LocalMCPServer.http(200, replies);
        }
        if (object === null || typeof object !== "object") return LocalMCPServer.http(400, { error: "message invalide" });
        const reply = await LocalMCPRPC.handle(object as Record<string, unknown>, this.provider);
        return reply !== null ? LocalMCPServer.http(200, reply) : LocalMCPServer.http(202, null);
      }
      case "DELETE":
        return LocalMCPServer.http(200, {});
      default:
        return LocalMCPServer.http(405, { error: "ce serveur répond en POST" }, { Allow: "POST, DELETE" });
    }
  }

  static constantTimeEqual(a: string, b: string): boolean {
    const x = new TextEncoder().encode(a);
    const y = new TextEncoder().encode(b);
    if (x.length !== y.length) return false;
    let difference = 0;
    for (let i = 0; i < x.length; i++) difference |= x[i] ^ y[i];
    return difference === 0;
  }

  static http(status: number, body: unknown, extra: Record<string, string> = {}): Uint8Array {
    const reasons: Record<number, string> = {
      200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
      405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large",
    };
    const payload = body === null || body === undefined ? new Uint8Array() : new TextEncoder().encode(JSON.stringify(body));
    let head = `HTTP/1.1 ${status} ${reasons[status] ?? "OK"}\r\nContent-Length: ${payload.length}\r\nConnection: close\r\n`;
    if (payload.length !== 0) head += "Content-Type: application/json\r\n";
    for (const [key, value] of Object.entries(extra)) head += `${key}: ${value}\r\n`;
    const headBytes = new TextEncoder().encode(head + "\r\n");
    const out = new Uint8Array(headBytes.length + payload.length);
    out.set(headBytes);
    out.set(payload, headBytes.length);
    return out;
  }
}

function indexOfBytes(data: Uint8Array, needle: number[]): number {
  outer: for (let i = 0; i + needle.length <= data.length; i++) {
    for (let j = 0; j < needle.length; j++) if (data[i + j] !== needle[j]) continue outer;
    return i;
  }
  return -1;
}

function bytesToBase64Url(bytes: Uint8Array): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += alphabet[a >> 2];
    out += alphabet[((a & 3) << 4) | (b >> 4)];
    if (i + 1 < bytes.length) out += alphabet[((b & 15) << 2) | (c >> 6)];
    if (i + 2 < bytes.length) out += alphabet[c & 63];
  }
  return out;
}
