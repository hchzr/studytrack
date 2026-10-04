/**
 * Relais du chrono partagé de StudyTrack.
 *
 * Un Durable Object par compte (le nom du canal, déduit de l'identité iCloud
 * dans l'app) : il garde les WebSocket des appareils ouverts et leur relaie
 * chaque geste. Le contenu est chiffré dans l'app (AES-GCM) : le relais ne lit
 * rien de la session, il transporte des octets.
 *
 * - Hibernation : entre deux gestes, l'objet dort ; les connexions restent
 *   ouvertes et ne sont pas facturées. Les « ping » reçoivent « pong » sans le
 *   réveiller (réponse automatique).
 * - Le dernier état (chiffré) est gardé : un appareil qui arrive le reçoit
 *   aussitôt.
 * - Live Activity : un appareil qui publie peut joindre l'état de l'îlot (en
 *   clair : heures, pause, libellés — c'est ce qu'Apple affiche). Le relais
 *   l'envoie par APNs aux iPhone du compte, même app fermée.
 */
import { DurableObject } from "cloudflare:workers";

export interface Env {
  RELAY: DurableObjectNamespace<Relay>;
  APNS_KEY: string; // contenu du .p8 (secret)
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
}

const CHANNEL = /^\/v1\/(st-timer-[0-9a-f]{32})$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") return new Response("ok");
    const match = url.pathname.match(CHANNEL);
    if (!match) return new Response("not found", { status: 404 });
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const device = url.searchParams.get("device") ?? "";
    if (!/^[0-9A-Fa-f-]{36}$/.test(device)) return new Response("bad device", { status: 400 });
    const stub = env.RELAY.get(env.RELAY.idFromName(match[1]));
    return stub.fetch(request);
  },
};

/** Ce qu'un appareil envoie. */
type Inbound =
  | { t: "timer"; d: string; u: number; live?: LivePush }
  | { t: "apns"; kind: "update" | "start"; token: string | null; sandbox: boolean };

/** Ce qu'il faut pousser à l'îlot de l'iPhone. */
interface LivePush {
  event: "update" | "end" | "start";
  state: unknown; // ActivityTimerState, encodé par l'app
  attributes?: unknown; // StudyActivityAttributes, pour « start »
  stale?: number; // secondes depuis 1970
}

interface Tokens {
  update?: string;
  start?: string;
  sandbox: boolean;
}

export class Relay extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const device = new URL(request.url).searchParams.get("device") ?? "";
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [device]);
    const last = await this.ctx.storage.get<string>("last");
    if (last) server.send(last);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    if (typeof raw !== "string" || raw.length > 64_000) return;
    let message: Inbound;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    const device = this.ctx.getTags(ws)[0] ?? "";

    if (message.t === "apns") {
      const key = `tokens:${device}`;
      const tokens = (await this.ctx.storage.get<Tokens>(key)) ?? { sandbox: message.sandbox };
      tokens.sandbox = message.sandbox;
      if (message.kind === "update") tokens.update = message.token ?? undefined;
      else tokens.start = message.token ?? undefined;
      await this.ctx.storage.put(key, tokens);
      return;
    }

    if (message.t !== "timer" || typeof message.d !== "string") return;
    // Un état plus ancien que le dernier gardé ne le remplace pas.
    const lastAt = (await this.ctx.storage.get<number>("lastAt")) ?? 0;
    const outbound = JSON.stringify({ t: "timer", d: message.d, u: message.u, from: device });
    if (message.u >= lastAt) {
      await this.ctx.storage.put({ last: outbound, lastAt: message.u });
    }
    for (const socket of this.ctx.getWebSockets()) {
      if (socket !== ws) {
        try {
          socket.send(outbound);
        } catch {
          // fermée : le système la retire
        }
      }
    }
    if (message.live) {
      this.ctx.waitUntil(this.pushLive(device, message.live));
    }
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    try {
      ws.close(code, "bye");
    } catch {
      // déjà fermée
    }
  }

  // MARK: APNs

  /** Pousse l'îlot vers les iPhone du compte (sauf celui qui a publié). */
  private async pushLive(sender: string, live: LivePush): Promise<void> {
    const entries = await this.ctx.storage.list<Tokens>({ prefix: "tokens:" });
    for (const [key, tokens] of entries) {
      const device = key.slice("tokens:".length);
      if (device === sender) continue;
      // Une activité vivante se met à jour ; sinon on la démarre (iOS 17.2+).
      let token = tokens.update;
      let event = live.event;
      if (!token && live.event !== "end" && tokens.start && live.attributes) {
        token = tokens.start;
        event = "start";
      }
      if (!token) continue;
      const status = await this.sendAPNs(token, tokens.sandbox, event, live);
      console.log(`îlot ${event} → ${device.slice(0, 8)} (${token === tokens.start ? "jeton de démarrage" : "jeton de mise à jour"}) : ${status}`);
      if (status === 410 || status === 400) {
        // Jeton mort (activité terminée, app supprimée) : on l'oublie.
        if (token === tokens.update) tokens.update = undefined;
        if (token === tokens.start) tokens.start = undefined;
        await this.ctx.storage.put(key, tokens);
      } else if (event === "end" && token === tokens.update) {
        // L'activité est finie : son jeton ne sert plus. Garder le jeton
        // envoyait la session suivante à une activité morte — Apple
        // l'accepte (200), l'iPhone l'ignore. La suivante démarrera.
        tokens.update = undefined;
        await this.ctx.storage.put(key, tokens);
      }
    }
  }

  private async sendAPNs(token: string, sandbox: boolean, event: string, live: LivePush): Promise<number> {
    const now = Math.floor(Date.now() / 1000);
    const aps: Record<string, unknown> = { timestamp: now, event, "content-state": live.state };
    if (live.stale) aps["stale-date"] = Math.floor(live.stale);
    if (event === "end") aps["dismissal-date"] = now;
    if (event === "start") {
      aps["attributes-type"] = "StudyActivityAttributes";
      aps["attributes"] = live.attributes;
      aps["alert"] = { title: "Chrono", body: "Session en cours" };
    }
    const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await this.jwt()}`,
        "apns-topic": `${this.env.APNS_BUNDLE_ID}.push-type.liveactivity`,
        "apns-push-type": "liveactivity",
        "apns-priority": "10",
      },
      body: JSON.stringify({ aps }),
    });
    if (response.status !== 200) {
      console.log(`APNs ${response.status} ${await response.text()}`);
    }
    return response.status;
  }

  private cachedJWT?: { token: string; at: number };

  /** Le jeton d'APNs (ES256), refait toutes les 50 minutes. */
  private async jwt(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (this.cachedJWT && now - this.cachedJWT.at < 3000) return this.cachedJWT.token;
    const pem = this.env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
    const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const encode = (value: object) => base64url(new TextEncoder().encode(JSON.stringify(value)));
    const unsigned = `${encode({ alg: "ES256", kid: this.env.APNS_KEY_ID })}.${encode({ iss: this.env.APNS_TEAM_ID, iat: now })}`;
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
    const token = `${unsigned}.${base64url(new Uint8Array(signature))}`;
    this.cachedJWT = { token, at: now };
    return token;
  }
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
