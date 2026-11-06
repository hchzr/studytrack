// L'appairage d'un appareil à la synchronisation chiffrée, par le relais.
//
//   Appareil A (déjà connecté)            Appareil B (nouveau, même compte)
//   ─────────────────────────             ─────────────────────────────────
//   S = 16 octets aléatoires, montrés     saisit le code (ou lit le QR) → S
//   en code ; canal = pair-<hkdf(S)>      canal = pair-<hkdf(S)>
//                                         ← hello { pubB }
//   offer { pubA, box } →                 k = HKDF(ECDH ‖ S, … pubA ‖ pubB)
//   box = AES-GCM(k, AK)                  AK = ouvrir(box) ; keyId(AK) doit être
//                                         celui du coffre du compte connecté
//                                         ← ok { AES-GCM(k, "ok") }
//
// `S` ne transite jamais : le relais ne voit que deux clés publiques et des
// chiffrés. Une tentative par code : A ignore tout `hello` après le premier.
// La WebSocket n'est ouverte que le temps de l'écran d'appairage.
// Le pendant Swift est `Polymestre/Domain/SyncPairing.swift`.

import {
  base64Decode, base64Encode, deriveKeys, encodePairingCode, newEphemeral, newPairingSecret,
  openAccountKey, openOk, pairChannel, pairKey, pairingQRText, parsePairingInput, sealAccountKey, sealOk,
  type Ephemeral,
} from "../domain/syncCrypto.ts";

/** Une WebSocket vue par l'appairage ; les tests passent un relais en mémoire. */
export interface PairSocket {
  send(text: string): void;
  close(): void;
  onOpen: (() => void) | null;
  onMessage: ((text: string) => void) | null;
  onClose: (() => void) | null;
}
export type SocketFactory = (url: string) => PairSocket;

/** La WebSocket de la webview. */
export const webSocketFactory: SocketFactory = (url) => {
  const ws = new WebSocket(url);
  const socket: PairSocket = {
    send: (text) => ws.send(text),
    close: () => { try { ws.close(); } catch { /* déjà fermée */ } },
    onOpen: null, onMessage: null, onClose: null,
  };
  ws.onopen = () => socket.onOpen?.();
  ws.onmessage = (event) => { if (typeof event.data === "string") socket.onMessage?.(event.data); };
  ws.onclose = () => socket.onClose?.();
  ws.onerror = () => socket.onClose?.();
  return socket;
};

export const pairingTTLMs = 10 * 60_000;
export const joinTimeoutMs = 30_000;
const HELLO_RESEND_MS = 2_000;

export const pairingURL = (host: string, channel: string, device: string): string =>
  `wss://${host}/v1/${channel}?device=${device}`;

interface PairMessage { t: "pair"; step: "hello" | "offer" | "ok"; pub?: string; box?: string }

function parse(text: string): PairMessage | null {
  try {
    const value = JSON.parse(text) as Partial<PairMessage>;
    if (value.t !== "pair" || (value.step !== "hello" && value.step !== "offer" && value.step !== "ok")) return null;
    return value as PairMessage;
  } catch {
    return null;
  }
}

const decode32 = (text: unknown): Uint8Array | null => {
  const bytes = typeof text === "string" ? base64Decode(text) : null;
  return bytes && bytes.length === 32 ? bytes : null;
};

export type HostState = "waiting" | "verifying" | "done" | "failed" | "expired" | "cancelled";

export interface PairingHostInputs {
  accountKey: Uint8Array;
  host: string;
  makeSocket?: SocketFactory;
  /** Pour les tests : secret et clé éphémère imposés. */
  secret?: Uint8Array;
  ephemeral?: Ephemeral;
  ttlMs?: number;
  onState?: (state: HostState, message: string | null) => void;
  setTimer?: (fn: () => void, ms: number) => () => void;
}

const defaultTimer = (fn: () => void, ms: number): (() => void) => {
  const id = setTimeout(fn, ms);
  return () => clearTimeout(id);
};

/** Côté A : montre un code, répond au premier appareil qui le connaît. */
export class PairingHost {
  readonly code: string;
  readonly qr: string;
  state: HostState = "waiting";
  message: string | null = null;

  private socket: PairSocket | null = null;
  private key: Uint8Array | null = null;
  private engaged = false;
  private cancelTimer: (() => void) | null = null;

  private constructor(
    private readonly inputs: PairingHostInputs,
    private readonly secret: Uint8Array,
    private readonly eph: Ephemeral,
    channel: string,
  ) {
    this.code = encodePairingCode(secret);
    this.qr = pairingQRText(secret);
    const make = inputs.makeSocket ?? webSocketFactory;
    const timer = inputs.setTimer ?? defaultTimer;
    this.cancelTimer = timer(() => this.finish("expired", "Le code a expiré : génères-en un autre."), inputs.ttlMs ?? pairingTTLMs);
    const socket = make(pairingURL(inputs.host, channel, globalThis.crypto.randomUUID()));
    socket.onMessage = (text) => { void this.receive(text); };
    socket.onClose = () => {
      if (this.state === "waiting" || this.state === "verifying") this.finish("failed", "La connexion au relais a été coupée.");
    };
    this.socket = socket;
  }

  static async start(inputs: PairingHostInputs): Promise<PairingHost> {
    const secret = inputs.secret ?? newPairingSecret();
    const eph = inputs.ephemeral ?? await newEphemeral();
    return new PairingHost(inputs, secret, eph, await pairChannel(secret));
  }

  cancel(): void {
    if (this.state === "waiting" || this.state === "verifying") this.finish("cancelled", null);
  }

  private finish(state: HostState, message: string | null): void {
    if (this.state === "done" || this.state === "failed" || this.state === "expired" || this.state === "cancelled") return;
    this.state = state;
    this.message = message;
    this.cancelTimer?.();
    this.socket?.close();
    this.socket = null;
    this.key = null;
    this.inputs.onState?.(state, message);
  }

  private async receive(text: string): Promise<void> {
    const message = parse(text);
    if (!message) return;
    try {
      if (message.step === "hello" && !this.engaged && this.state === "waiting") {
        const pubB = decode32(message.pub);
        if (!pubB) return;
        this.engaged = true; // une tentative par code
        this.state = "verifying";
        this.inputs.onState?.("verifying", null);
        const k = await pairKey(this.eph.privateKey, pubB, this.secret, this.eph.publicKey, pubB);
        this.key = k;
        const box = await sealAccountKey(k, this.inputs.accountKey);
        this.socket?.send(JSON.stringify({ t: "pair", step: "offer", pub: base64Encode(this.eph.publicKey), box: base64Encode(box) }));
      } else if (message.step === "ok" && this.state === "verifying" && this.key) {
        const box = typeof message.box === "string" ? base64Decode(message.box) : null;
        if (box && await openOk(this.key, box)) this.finish("done", null);
        else this.finish("failed", "Le code saisi sur l'autre appareil ne correspond pas.");
      }
    } catch {
      this.finish("failed", "L'appairage a échoué.");
    }
  }
}

export class PairingError extends Error {
  readonly kind: "code" | "timeout" | "wrongCode" | "otherAccount" | "relay";
  constructor(kind: PairingError["kind"], message: string) {
    super(message);
    this.kind = kind;
    this.name = "PairingError";
  }
}

export interface JoinInputs {
  /** Ce que l'étudiant·e a saisi ou lu (« polymestre-pair:… » accepté). */
  code: string;
  /** Le `key_id` du coffre du compte connecté. */
  expectedKeyId: string;
  host: string;
  makeSocket?: SocketFactory;
  ephemeral?: Ephemeral;
  timeoutMs?: number;
  signal?: AbortSignal;
}

/** Côté B : rend la clé du compte, vérifiée contre le coffre. */
export async function joinPairing(inputs: JoinInputs): Promise<Uint8Array> {
  const secret = parsePairingInput(inputs.code);
  if (!secret) throw new PairingError("code", "Ce code n'est pas valide : 26 caractères, par groupes de 4.");
  const eph = inputs.ephemeral ?? await newEphemeral();
  const channel = await pairChannel(secret);
  const make = inputs.makeSocket ?? webSocketFactory;

  return new Promise<Uint8Array>((resolve, reject) => {
    const socket = make(pairingURL(inputs.host, channel, globalThis.crypto.randomUUID()));
    let settled = false;
    let resend: ReturnType<typeof setInterval> | null = null;
    const done = (action: () => void) => {
      if (settled) return;
      settled = true;
      if (resend) clearInterval(resend);
      clearTimeout(timer);
      socket.close();
      action();
    };
    const timer = setTimeout(() => done(() => reject(new PairingError("timeout",
      "Aucun appareil n'a répondu. Vérifie le code, et que l'autre appareil affiche toujours « Ajouter un appareil »."))),
    inputs.timeoutMs ?? joinTimeoutMs);
    inputs.signal?.addEventListener("abort", () => done(() => reject(new PairingError("timeout", "Appairage annulé."))));

    const hello = () => socket.send(JSON.stringify({ t: "pair", step: "hello", pub: base64Encode(eph.publicKey) }));
    socket.onOpen = () => { hello(); resend = setInterval(hello, HELLO_RESEND_MS); };
    socket.onClose = () => done(() => reject(new PairingError("relay", "La connexion au relais a été coupée : réessaie.")));
    socket.onMessage = (text) => {
      const message = parse(text);
      if (!message || message.step !== "offer" || settled) return;
      void (async () => {
        try {
          const pubA = decode32(message.pub);
          const boxBytes = typeof message.box === "string" ? base64Decode(message.box) : null;
          if (!pubA || !boxBytes) return;
          const k = await pairKey(eph.privateKey, pubA, secret, pubA, eph.publicKey);
          let ak: Uint8Array;
          try {
            ak = await openAccountKey(k, boxBytes);
          } catch {
            return done(() => reject(new PairingError("wrongCode", "Le code ne correspond pas. Vérifie-le et réessaie.")));
          }
          if ((await deriveKeys(ak)).keyId !== inputs.expectedKeyId) {
            return done(() => reject(new PairingError("otherAccount", "Cet appareil est connecté à un autre compte que celui qui affiche le code.")));
          }
          socket.send(JSON.stringify({ t: "pair", step: "ok", box: base64Encode(await sealOk(k)) }));
          // Laisse partir la confirmation avant de fermer.
          setTimeout(() => done(() => resolve(ak)), 50);
        } catch {
          done(() => reject(new PairingError("relay", "L'appairage a échoué : réessaie.")));
        }
      })();
    };
  });
}
