/// Le chiffrement de bout en bout de la synchronisation, **pur** : aucune clé
/// n'est rangée ici, aucun réseau. Le pendant octet pour octet de
/// `Polymestre/Domain/SyncCrypto.swift` (CryptoKit) ; `supabase/e2ee-vectors.json`
/// est lu par les deux suites de tests. Voir docs/sync-e2ee.md.
///
///   • `AK`, la clé du compte : 32 octets aléatoires, jamais envoyés au serveur ;
///   • `dataKey` et `keyId` en sont dérivés par HKDF-SHA256 (sel vide) ;
///   • une ligne = AES-256-GCM(dataKey, nonce aléatoire de 12 octets, JSON des
///     champs, AAD « <table>/<id>/v1 »), rangée nonce ‖ chiffré ‖ étiquette ;
///   • l'appairage d'un appareil : X25519 éphémère + un secret court `S`
///     (le code), mêlés par HKDF — voir `pairKey`.

import { base64Decode, base64Encode, x25519 } from "./groupCrypto.ts";

export class SyncCryptoError extends Error {
  readonly kind: "malformed" | "wrongKey";
  constructor(kind: "malformed" | "wrongKey") {
    super(kind);
    this.kind = kind;
    this.name = "SyncCryptoError";
  }
}

const subtle = (): SubtleCrypto => globalThis.crypto.subtle;
const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);
const buf = (bytes: Uint8Array): ArrayBuffer =>
  bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
export const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) { out.set(p, offset); offset += p.length; }
  return out;
};
export const toHex = (bytes: Uint8Array): string =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
export function fromHex(text: string): Uint8Array | null {
  if (text.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(text)) return null;
  const out = new Uint8Array(text.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(text.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export const infoDataKey = "studytrack/sync/data/v1";
export const infoKeyId = "studytrack/sync/key-id/v1";
export const infoPairChannel = "studytrack/pair/channel/v1";
export const infoPairKey = "studytrack/pair/key/v1";
export const aadPairAK = "studytrack/pair/ak/v1";
export const aadPairOk = "studytrack/pair/ok/v1";
const recoveryChecksumTag = "studytrack/recovery/v1";

/** HKDF-SHA256, sel vide (RFC 5869 : HashLen zéros). */
export async function hkdf(ikm: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  const key = await subtle().importKey("raw", buf(ikm), "HKDF", false, ["deriveBits"]);
  const bits = await subtle().deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: buf(new Uint8Array(0)), info: buf(info) }, key, length * 8);
  return new Uint8Array(bits);
}

// MARK: Clé du compte

export function newAccountKey(): Uint8Array {
  return globalThis.crypto.getRandomValues(new Uint8Array(32));
}

export interface DerivedKeys { dataKey: Uint8Array; keyId: string }

export async function deriveKeys(ak: Uint8Array): Promise<DerivedKeys> {
  if (ak.length !== 32) throw new SyncCryptoError("malformed");
  const dataKey = await hkdf(ak, utf8(infoDataKey), 32);
  const keyId = toHex(await hkdf(ak, utf8(infoKeyId), 16));
  return { dataKey, keyId };
}

// MARK: AES-GCM (nonce ‖ chiffré ‖ étiquette)

async function aesKey(raw: Uint8Array, usage: KeyUsage): Promise<CryptoKey> {
  return subtle().importKey("raw", buf(raw), "AES-GCM", false, [usage]);
}

/// `nonce` : pour les vecteurs de test seulement ; en usage réel, aléatoire.
export async function gcmSeal(plain: Uint8Array, key: Uint8Array, aad: Uint8Array, nonce?: Uint8Array): Promise<Uint8Array> {
  const iv = nonce ?? globalThis.crypto.getRandomValues(new Uint8Array(12));
  if (iv.length !== 12) throw new SyncCryptoError("malformed");
  const sealed = new Uint8Array(await subtle().encrypt(
    { name: "AES-GCM", iv: buf(iv), tagLength: 128, additionalData: buf(aad) }, await aesKey(key, "encrypt"), buf(plain)));
  return concat(iv, sealed);
}

/// Lève `wrongKey` si l'étiquette ne passe pas (mauvaise clé, AAD différentes, octet modifié).
export async function gcmOpen(box: Uint8Array, key: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
  if (box.length < 28) throw new SyncCryptoError("malformed");
  try {
    return new Uint8Array(await subtle().decrypt(
      { name: "AES-GCM", iv: buf(box.slice(0, 12)), tagLength: 128, additionalData: buf(aad) },
      await aesKey(key, "decrypt"), buf(box.slice(12))));
  } catch {
    throw new SyncCryptoError("wrongKey");
  }
}

// MARK: Lignes

/// Les données associées : une ligne ne se recolle pas dans un autre id ni une autre table.
export const rowAAD = (table: string, id: string): Uint8Array => utf8(`${table}/${id.toLowerCase()}/v1`);

/// JSON compact, clés triées : le même texte sur toutes les plateformes pour des valeurs simples.
export function canonicalJSON(fields: Record<string, unknown>): string {
  const sorted: Record<string, unknown> = {};
  for (const key of Object.keys(fields).sort()) sorted[key] = fields[key];
  return JSON.stringify(sorted);
}

export async function sealRow(
  dataKey: Uint8Array, table: string, id: string, fields: Record<string, unknown>, nonce?: Uint8Array,
): Promise<Uint8Array> {
  return gcmSeal(utf8(canonicalJSON(fields)), dataKey, rowAAD(table, id), nonce);
}

export async function openRow(dataKey: Uint8Array, table: string, id: string, box: Uint8Array): Promise<Record<string, unknown>> {
  const plain = await gcmOpen(box, dataKey, rowAAD(table, id));
  try {
    const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain));
    if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("not an object");
    return value as Record<string, unknown>;
  } catch {
    throw new SyncCryptoError("malformed");
  }
}

/// `bytea` sur PostgREST : « \x » puis de l'hexadécimal.
export const toBytea = (bytes: Uint8Array): string => "\\x" + toHex(bytes);
export function fromBytea(text: unknown): Uint8Array | null {
  if (typeof text !== "string" || !text.startsWith("\\x")) return null;
  return fromHex(text.slice(2));
}

// MARK: Base32 de Crockford

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Les bits en tête-bêche : le dernier symbole est complété de zéros.
export function crockfordEncode(bytes: Uint8Array): string {
  let out = "";
  let acc = 0, bits = 0;
  for (const b of bytes) {
    acc = (acc << 8) | b; bits += 8;
    while (bits >= 5) { out += ALPHABET[(acc >> (bits - 5)) & 31]; bits -= 5; }
    acc &= (1 << bits) - 1;
  }
  if (bits > 0) out += ALPHABET[(acc << (5 - bits)) & 31];
  return out;
}

/// Tolère minuscules, tirets, espaces, et les confusions O→0, I/L→1. `null` si invalide
/// ou si les bits de remplissage ne sont pas nuls.
export function crockfordDecode(text: string, byteLength: number): Uint8Array | null {
  const clean = text.toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  if (clean.length !== Math.ceil(byteLength * 8 / 5)) return null;
  const out = new Uint8Array(byteLength);
  let acc = 0, bits = 0, index = 0;
  for (const ch of clean) {
    const v = ALPHABET.indexOf(ch);
    if (v < 0) return null;
    acc = (acc << 5) | v; bits += 5;
    if (bits >= 8) {
      if (index >= byteLength) return null;
      out[index++] = (acc >> (bits - 8)) & 255; bits -= 8;
    }
    acc &= (1 << bits) - 1;
  }
  if (acc !== 0) return null; // remplissage non nul
  return out;
}

const group = (text: string): string => text.match(/.{1,4}/g)!.join("-");

// MARK: Code d'appairage (S, 16 octets → 26 caractères)

export const pairingCodeBytes = 16;
export const newPairingSecret = (): Uint8Array => globalThis.crypto.getRandomValues(new Uint8Array(pairingCodeBytes));
export const encodePairingCode = (s: Uint8Array): string => group(crockfordEncode(s));
export const decodePairingCode = (text: string): Uint8Array | null => crockfordDecode(text, pairingCodeBytes);
export const pairingQRText = (s: Uint8Array): string => `polymestre-pair:${encodePairingCode(s)}`;
/// Le texte d'un QR (« polymestre-pair:… », ou « studytrack-pair:… » d'un appareil pas
/// encore à jour) ou un code nu.
export function parsePairingInput(text: string): Uint8Array | null {
  const trimmed = text.trim();
  const prefix = ["polymestre-pair:", "studytrack-pair:"].find((p) => trimmed.toLowerCase().startsWith(p));
  const body = prefix ? trimmed.slice(prefix.length) : trimmed;
  return decodePairingCode(body);
}

// MARK: Clé de secours (AK, 32 octets → 52 caractères + 2 de contrôle)

export class RecoveryKeyError extends Error {
  readonly kind: "format" | "checksum";
  constructor(kind: "format" | "checksum") {
    super(kind);
    this.kind = kind;
    this.name = "RecoveryKeyError";
  }
}

/// Deux symboles (10 bits) : les 10 premiers bits de SHA-256(« studytrack/recovery/v1 » ‖ AK).
async function recoveryChecksum(ak: Uint8Array): Promise<string> {
  const d = new Uint8Array(await subtle().digest("SHA-256", buf(concat(utf8(recoveryChecksumTag), ak))));
  const v = ((d[0] << 8) | d[1]) >> 6;
  return ALPHABET[v >> 5] + ALPHABET[v & 31];
}

export async function encodeRecoveryKey(ak: Uint8Array): Promise<string> {
  return group(crockfordEncode(ak) + await recoveryChecksum(ak));
}

export async function decodeRecoveryKey(text: string): Promise<Uint8Array> {
  const clean = text.toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  if (clean.length !== 54) throw new RecoveryKeyError("format");
  const ak = crockfordDecode(clean.slice(0, 52), 32);
  if (!ak) throw new RecoveryKeyError("format");
  if (clean.slice(52) !== await recoveryChecksum(ak)) throw new RecoveryKeyError("checksum");
  return ak;
}

// MARK: Appairage

export interface Ephemeral { privateKey: Uint8Array; publicKey: Uint8Array }

export async function newEphemeral(privateKey?: Uint8Array): Promise<Ephemeral> {
  const priv = privateKey ?? globalThis.crypto.getRandomValues(new Uint8Array(32));
  const base = new Uint8Array(32); base[0] = 9;
  return { privateKey: priv, publicKey: await x25519(priv, base) };
}

/// « pair-<32 hex> » : le nom du canal du relais, déduit du secret.
export async function pairChannel(s: Uint8Array): Promise<string> {
  return "pair-" + toHex(await hkdf(s, utf8(infoPairChannel), 16));
}

/// k = HKDF(ECDH(moi, lui) ‖ S, « studytrack/pair/key/v1 » ‖ pubA ‖ pubB, 32).
/// Le secret court `S` entre dans la clé : sans lui, voir les deux clés publiques ne suffit pas.
export async function pairKey(mine: Uint8Array, theirPublic: Uint8Array, s: Uint8Array, pubA: Uint8Array, pubB: Uint8Array): Promise<Uint8Array> {
  const shared = await x25519(mine, theirPublic);
  return hkdf(concat(shared, s), concat(utf8(infoPairKey), pubA, pubB), 32);
}

export const sealAccountKey = (k: Uint8Array, ak: Uint8Array, nonce?: Uint8Array) => gcmSeal(ak, k, utf8(aadPairAK), nonce);
export async function openAccountKey(k: Uint8Array, box: Uint8Array): Promise<Uint8Array> {
  const ak = await gcmOpen(box, k, utf8(aadPairAK));
  if (ak.length !== 32) throw new SyncCryptoError("malformed");
  return ak;
}
export const sealOk = (k: Uint8Array, nonce?: Uint8Array) => gcmSeal(utf8("ok"), k, utf8(aadPairOk), nonce);
export async function openOk(k: Uint8Array, box: Uint8Array): Promise<boolean> {
  try {
    return new TextDecoder().decode(await gcmOpen(box, k, utf8(aadPairOk))) === "ok";
  } catch {
    return false;
  }
}

export { base64Encode, base64Decode };
