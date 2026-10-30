// Ce que l'iPhone envoie au bureau du Mac pendant une session
// (StudyTrack/Domain/DeskDrop.swift) : la photo de ta copie, un « je bloque »,
// une question dictée. Par le lien du chrono, chiffré de la même clé ; rien
// n'est gardé par le relais.

import { newId } from "../models/relations.ts";
import { TimerLink } from "./timerLink.ts";

export type DeskDropIntent = "copy" | "stuck" | "ask";

export const DeskDropIntent = {
  allCases: ["copy", "stuck", "ask"] as readonly DeskDropIntent[],
};

export interface DeskDropInit {
  id?: string;
  from: string;
  intent: DeskDropIntent;
  /** Un PDF (une numérisation) ou une image JPEG. */
  document?: Uint8Array | null;
  isPDF?: boolean;
  question?: string | null;
  /** L'exercice que l'iPhone avait sous les yeux. */
  exerciseID?: string | null;
  sentAt: Date;
}

export class DeskDrop {
  id: string;
  from: string;
  intent: DeskDropIntent;
  document: Uint8Array | null;
  isPDF: boolean;
  question: string | null;
  exerciseID: string | null;
  sentAt: Date;

  /** Le relais refuse au-delà (un message WebSocket < 1 Mo, chiffré et en base64). */
  static readonly maxDocumentBytes = 640_000;
  static readonly Intent = DeskDropIntent;

  static seal(drop: DeskDrop, key: CryptoKey): Promise<string | null> {
    return seal(drop, key);
  }

  static open(text: string, key: CryptoKey): Promise<DeskDrop | null> {
    return open(text, key);
  }

  constructor(o: DeskDropInit) {
    this.id = o.id ?? newId();
    this.from = o.from;
    this.intent = o.intent;
    this.document = o.document ?? null;
    this.isPDF = o.isPDF ?? false;
    this.question = o.question ?? null;
    this.exerciseID = o.exerciseID ?? null;
    this.sentAt = o.sentAt;
  }
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(text: string): Uint8Array | null {
  try {
    const binary = atob(text);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

function referenceSeconds(date: Date): number {
  return date.getTime() / 1000 - 978_307_200;
}

function encode(drop: DeskDrop): string {
  const object: Record<string, unknown> = {
    id: drop.id,
    from: drop.from,
    intent: drop.intent,
    isPDF: drop.isPDF,
    sentAt: referenceSeconds(drop.sentAt),
  };
  if (drop.document !== null) object.document = toBase64(drop.document);
  if (drop.question !== null) object.question = drop.question;
  if (drop.exerciseID !== null) object.exerciseID = drop.exerciseID;
  return JSON.stringify(object);
}

function decode(text: string): DeskDrop | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.id !== "string" || typeof o.from !== "string") return null;
  if (o.intent !== "copy" && o.intent !== "stuck" && o.intent !== "ask") return null;
  if (typeof o.sentAt !== "number" || typeof o.isPDF !== "boolean") return null;
  let document: Uint8Array | null = null;
  if (o.document !== undefined) {
    if (typeof o.document !== "string") return null;
    document = fromBase64(o.document);
    if (document === null) return null;
  }
  const stringOrNull = (value: unknown): string | null | undefined =>
    value === undefined || value === null ? null : typeof value === "string" ? value : undefined;
  const question = stringOrNull(o.question);
  const exerciseID = stringOrNull(o.exerciseID);
  if (question === undefined || exerciseID === undefined) return null;
  return new DeskDrop({
    id: o.id,
    from: o.from,
    intent: o.intent,
    document,
    isPDF: o.isPDF,
    question,
    exerciseID,
    sentAt: new Date((o.sentAt + 978_307_200) * 1000),
  });
}

/** Scelle une chute ; `null` si le document dépasse la limite ou si le codage échoue. */
export async function seal(drop: DeskDrop, key: CryptoKey): Promise<string | null> {
  if ((drop.document?.length ?? 0) > DeskDrop.maxDocumentBytes) return null;
  try {
    return await TimerLink.sealText(encode(drop), key);
  } catch {
    return null;
  }
}

/** Relit une chute ; `null` si le texte est illisible ou mal formé. */
export async function open(text: string, key: CryptoKey): Promise<DeskDrop | null> {
  const plain = await TimerLink.openText(text, key);
  if (plain === null) return null;
  return decode(plain);
}

export const DeskDropCodec = { seal, open, decode };
