// Le chrono relié (TimerLink.swift) : le chrono de l'iPhone, du Mac et de ce PC est le même, en
// direct, par le relais (`relay/`). Le canal et la clé se déduisent de l'identité du compte —
// celle d'iCloud sur les appareils Apple ; Windows la lit dans `sync_device_link`, chiffrée avec
// la clé de la synchronisation. Le relais ne voit que des octets illisibles.
//
// Format : celui du Mac, à l'octet près — `{"t":"timer","d":<AES-GCM base64>,"u":<s>}`, le
// contenu étant un `CloudRelay.TimerSnapshot` encodé par `JSONEncoder` (dates en secondes depuis
// 2001). Ce qui arrive suit la règle commune (`CloudRelay.decide`) : même session → l'appareil qui
// a agi en dernier ; jamais deux sessions différentes écrasées.

import { TimerLink } from "../domain/timerLink.ts";
import { TimerSnapshot, decide, noteAdopted, noteShared, sharedSession } from "../domain/cloudRelay.ts";
import { decodeFocusTimerState, type FocusTimerState } from "../domain/focusTimerState.ts";
import { installID } from "../native/settings.ts";
import { timerController } from "../ui/timerController.ts";

const IDENTITY_KEY = "timerLink.identity";
const REFERENCE = 978_307_200;

/** Une date au format par défaut de `JSONEncoder` (secondes depuis le 1er janvier 2001). */
const swiftDate = (date: Date) => date.getTime() / 1000 - REFERENCE;

/** JSON avec les dates comme Swift les attend. */
export function swiftJSON(value: unknown): string {
  return JSON.stringify(value, function (this: Record<string, unknown>, key: string, v: unknown) {
    const original = this[key];
    return original instanceof Date ? swiftDate(original) : v;
  });
}

export function decodeSnapshot(raw: Record<string, unknown>): TimerSnapshot | null {
  const toDate = (v: unknown) => (typeof v === "number" ? new Date(Math.round((v + REFERENCE) * 1000)) : null);
  const updatedAt = toDate(raw.updatedAt);
  if (!updatedAt || typeof raw.device !== "string") return null;
  const state = raw.state && typeof raw.state === "object" ? decodeFocusTimerState(JSON.stringify(raw.state)) : null;
  return new TimerSnapshot({
    state, updatedAt, device: raw.device,
    endedSession: toDate(raw.endedSession),
    endedSessions: Array.isArray(raw.endedSessions) ? raw.endedSessions.map(toDate).filter((d): d is Date => d !== null) : null,
  });
}

export function storedTimerIdentity(): string | null {
  try { return localStorage.getItem(IDENTITY_KEY); } catch { return null; }
}

class TimerLinkClient {
  private socket: WebSocket | null = null;
  private key: CryptoKey | null = null;
  private url: string | null = null;
  private attempts = 0;
  private retry: ReturnType<typeof setTimeout> | null = null;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private lastApplied: Date | null = null;
  private applying = false;
  private previous: FocusTimerState | null = null;
  private endedSessions: Date[] = [];
  private offTimer: (() => void) | null = null;
  readonly device = installID();
  connected = false;

  /** Démarre (ou change d'identité). Sans relais configuré : rien. */
  async start(host: string, identity: string): Promise<void> {
    const channel = await TimerLink.channel(identity);
    const url = `wss://${host}/v1/${channel}?device=${encodeURIComponent(this.device)}`;
    try { localStorage.setItem(IDENTITY_KEY, identity); } catch { /* pour la session */ }
    if (url === this.url && this.socket) return;
    this.stop();
    this.url = url;
    this.key = await TimerLink.key(identity);
    this.previous = timerController.snapshot().state;
    this.offTimer = timerController.subscribe(() => this.localChanged());
    this.connect();
  }

  stop(): void {
    this.offTimer?.();
    this.offTimer = null;
    if (this.retry) clearTimeout(this.retry);
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.socket?.close();
    this.socket = null;
    this.connected = false;
  }

  private connect(): void {
    if (!this.url) return;
    const socket = new WebSocket(this.url);
    this.socket = socket;
    socket.onopen = () => {
      this.connected = true;
      this.attempts = 0;
      // « ping » texte : le relais répond « pong » sans se réveiller.
      this.heartbeat = setInterval(() => { if (socket.readyState === WebSocket.OPEN) socket.send("ping"); }, 30_000);
    };
    socket.onmessage = (event) => { void this.receive(String(event.data)); };
    socket.onclose = () => {
      if (this.socket !== socket) return;
      this.connected = false;
      if (this.heartbeat) clearInterval(this.heartbeat);
      this.attempts += 1;
      const delay = Math.min(30, 2 ** Math.min(this.attempts, 5)) * 1000;
      this.retry = setTimeout(() => this.connect(), delay);
    };
  }

  private async receive(text: string): Promise<void> {
    if (text === "pong" || !this.key) return;
    let message: { t?: string; d?: string };
    try { message = JSON.parse(text) as { t?: string; d?: string }; } catch { return; }
    if (message.t !== "timer" || typeof message.d !== "string") return;
    const raw = await TimerLink.open<Record<string, unknown>>(message.d, this.key);
    const snapshot = raw ? decodeSnapshot(raw) : null;
    if (!snapshot) return;
    const local = timerController.snapshot().state;
    const decision = decide(local, snapshot, this.lastApplied, this.device, sharedSession());
    if (snapshot.state) noteShared(local, snapshot, this.device);
    if (decision.kind === "ignore") return;
    this.lastApplied = snapshot.updatedAt;
    this.applying = true;
    try {
      if (decision.kind === "adopt") {
        noteAdopted(decision.state);
        timerController.adoptRemote(decision.state);
      } else {
        timerController.closeRemote();
      }
    } finally {
      this.applying = false;
      this.previous = timerController.snapshot().state;
    }
  }

  /** Un geste ici : l'état part aux autres appareils (pas ce qui vient d'en arriver). */
  private localChanged(): void {
    const state = timerController.snapshot().state;
    if (state === this.previous) return;
    const before = this.previous;
    this.previous = state;
    if (this.applying) return;
    let endedSession: Date | null = null;
    if (!state && before) {
      endedSession = before.sessionStartedAt;
      this.endedSessions = [before.sessionStartedAt, ...this.endedSessions].slice(0, 5);
    }
    void this.publish({ state, endedSession, updatedAt: new Date(), device: this.device, endedSessions: this.endedSessions });
  }

  private async publish(snapshot: { state: FocusTimerState | null; endedSession: Date | null; updatedAt: Date; device: string; endedSessions: Date[] }): Promise<void> {
    if (!this.key || !this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    const body: Record<string, unknown> = { updatedAt: snapshot.updatedAt, device: snapshot.device };
    if (snapshot.state) body.state = snapshot.state;
    if (snapshot.endedSession) body.endedSession = snapshot.endedSession;
    if (snapshot.endedSessions.length > 0) body.endedSessions = snapshot.endedSessions;
    const sealed = await TimerLink.sealText(swiftJSON(body), this.key);
    this.socket.send(JSON.stringify({ t: "timer", d: sealed, u: snapshot.updatedAt.getTime() / 1000 }));
  }
}

export const timerLink = new TimerLinkClient();
