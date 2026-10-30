/// Le chiffrement de bout en bout de l'entraide d'un groupe, **pur** : aucune
/// clé n'est lue ni rangée ici (c'est `GroupKeyStore`), aucun réseau (c'est
/// `SocialService`). Ce qui reste est ce qui doit être juste — et se teste.
///
/// Le schéma (octet pour octet celui de `GroupCrypto.swift`, CryptoKit) :
///   • une **clé de groupe** symétrique (AES-256) chiffre les messages ;
///   • chaque appareil a une **identité** Curve25519 (X25519) ; sa clé publique
///     est sur le serveur (`member_keys`), la privée ne quitte pas l'appareil ;
///   • pour donner la clé du groupe à un membre, on la **scelle** avec le secret
///     partagé ECDH(ma privée, sa publique), dérivé par HKDF-SHA256 et lié au
///     groupe. Le serveur ne voit que des clés publiques et des enveloppes.
///
/// Format des boîtes AES-GCM : celui de `AES.GCM.SealedBox.combined` de
/// CryptoKit, soit nonce (12 octets) ‖ chiffré ‖ étiquette (16 octets) — ce que
/// WebCrypto rend sans le nonce, qu'on préfixe donc ici.
///
/// Limite assumée : le serveur distribue les clés publiques. Un serveur
/// malveillant pourrait substituer la sienne à celle d'un nouveau membre — la
/// protection vaut contre une fuite de la base, pas contre Supabase lui-même.
///
/// Les clés sont des `Uint8Array` de 32 octets (la clé de groupe, et chaque
/// moitié d'une identité).

export type CryptoErrorKind = "malformed" | "wrongKey";

export class CryptoError extends Error {
  readonly kind: CryptoErrorKind;
  constructor(kind: CryptoErrorKind) {
    super(kind);
    this.kind = kind;
    this.name = "CryptoError";
  }
}

/// Préfixe des messages chiffrés : une version, pour pouvoir changer
/// d'algorithme sans casser la lecture des anciens.
export const messagePrefix = "v1:";

const subtle = (): SubtleCrypto => globalThis.crypto.subtle;
const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);
/// Les BufferSource de WebCrypto veulent un `ArrayBuffer` ordinaire.
const buf = (bytes: Uint8Array): ArrayBuffer =>
  bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;

// MARK: Base64 (strict, comme `Data(base64Encoded:)`)

export function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

export function base64Decode(text: string): Uint8Array | null {
  if (text.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return null;
  try {
    const binary = atob(text);
    return Uint8Array.from(binary, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) { out.set(p, offset); offset += p.length; }
  return out;
};

const hex = (bytes: Uint8Array): string =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

// MARK: Clé de groupe

export function newGroupKey(): Uint8Array {
  return globalThis.crypto.getRandomValues(new Uint8Array(32));
}

/// L'identifiant public d'une clé : les huit premiers octets de son
/// empreinte. Permet de savoir **quelle** clé a chiffré un message sans
/// rien révéler de la clé.
export async function keyID(key: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await subtle().digest("SHA-256", buf(concat(key, utf8("studytrack-key-id")))));
  return hex(digest.slice(0, 8));
}

export function encode(key: Uint8Array): string {
  return base64Encode(key);
}

export function decodeKey(text: string): Uint8Array | null {
  const data = base64Decode(text);
  return data && data.length === 32 ? data : null;
}

// MARK: AES-GCM « combined »

async function aesKey(raw: Uint8Array, usage: KeyUsage): Promise<CryptoKey> {
  return subtle().importKey("raw", buf(raw), "AES-GCM", false, [usage]);
}

async function gcmSeal(plain: Uint8Array, key: Uint8Array, aad?: Uint8Array): Promise<Uint8Array> {
  const nonce = globalThis.crypto.getRandomValues(new Uint8Array(12));
  const params: AesGcmParams = { name: "AES-GCM", iv: buf(nonce), tagLength: 128 };
  if (aad) params.additionalData = buf(aad);
  const sealed = new Uint8Array(await subtle().encrypt(params, await aesKey(key, "encrypt"), buf(plain)));
  return concat(nonce, sealed);
}

/// `null` si l'étiquette ne passe pas (mauvaise clé, données associées différentes).
async function gcmOpen(combined: Uint8Array, key: Uint8Array, aad?: Uint8Array): Promise<Uint8Array | null> {
  const params: AesGcmParams = { name: "AES-GCM", iv: buf(combined.slice(0, 12)), tagLength: 128 };
  if (aad) params.additionalData = buf(aad);
  try {
    return new Uint8Array(await subtle().decrypt(params, await aesKey(key, "decrypt"), buf(combined.slice(12))));
  } catch {
    return null;
  }
}

/// Nonce 12 octets + étiquette 16 octets au minimum, comme `SealedBox(combined:)`.
const isCombined = (data: Uint8Array | null): data is Uint8Array => data !== null && data.length >= 28;

// MARK: Messages

/// Les données associées : un message chiffré pour un groupe ne se recolle
/// pas dans un autre, ni sous le nom d'un autre auteur.
function context(groupID: string, authorID: string): Uint8Array {
  return utf8(`studytrack-post|${groupID.toLowerCase()}|${authorID.toLowerCase()}`);
}

export async function seal(text: string, key: Uint8Array, groupID: string, authorID: string): Promise<string> {
  return messagePrefix + base64Encode(await gcmSeal(utf8(text), key, context(groupID, authorID)));
}

export async function open(sealed: string, key: Uint8Array, groupID: string, authorID: string): Promise<string> {
  if (!sealed.startsWith(messagePrefix)) throw new CryptoError("malformed");
  const data = base64Decode(sealed.slice(messagePrefix.length));
  if (!isCombined(data)) throw new CryptoError("malformed");
  const plain = await gcmOpen(data, key, context(groupID, authorID));
  if (!plain) throw new CryptoError("wrongKey");
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(plain);
  } catch {
    throw new CryptoError("wrongKey");
  }
}

// MARK: X25519

/// L'identité d'un appareil : les 32 octets bruts de chaque moitié, comme
/// `rawRepresentation` de CryptoKit.
export interface Identity { privateKey: Uint8Array; publicKey: Uint8Array }

const PKCS8_X25519_PREFIX = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20]);

export async function newIdentity(): Promise<Identity> {
  const privateKey = globalThis.crypto.getRandomValues(new Uint8Array(32));
  return { privateKey, publicKey: await x25519(privateKey, X25519_BASE) };
}

export function publicKeyString(key: Uint8Array): string {
  return base64Encode(key);
}

export function publicKey(text: string): Uint8Array | null {
  const data = base64Decode(text);
  return data && data.length === 32 ? data : null;
}

const X25519_BASE = (() => { const b = new Uint8Array(32); b[0] = 9; return b; })();

/// Le secret ECDH, par WebCrypto uniquement.
///
/// Pas de calcul de secours écrit à la main : il ne serait pas en temps constant,
/// et le WebView2 de Windows (Edge, mis à jour tout seul) a X25519 depuis 2025.
/// Un moteur trop ancien reçoit un message clair plutôt qu'un chiffrement affaibli.
export async function x25519(privateKey: Uint8Array, peerPublic: Uint8Array): Promise<Uint8Array> {
  let result: Uint8Array;
  try {
    const priv = await subtle().importKey("pkcs8", buf(concat(PKCS8_X25519_PREFIX, privateKey)),
      { name: "X25519" }, false, ["deriveBits"]);
    const pub = await subtle().importKey("raw", buf(peerPublic), { name: "X25519" }, false, []);
    result = new Uint8Array(await subtle().deriveBits({ name: "X25519", public: pub }, priv, 256));
  } catch (error) {
    if (error instanceof Error && error.name === "NotSupportedError") {
      throw new Error("Le chiffrement des groupes demande un moteur web plus récent : mets à jour Windows (Microsoft Edge WebView2).");
    }
    // Un point d'ordre faible (secret nul) : CryptoKit refuse aussi.
    throw error;
  }
  if (result.every((b) => b === 0)) throw new CryptoError("wrongKey");
  return result;
}

// MARK: Enveloppes (clé de groupe scellée pour un membre)

/// La clé d'enveloppe entre deux identités, pour **ce** groupe : la même
/// des deux côtés (ECDH est symétrique), différente pour chaque groupe.
async function wrappingKey(mine: Uint8Array, theirs: Uint8Array, groupID: string): Promise<Uint8Array> {
  const secret = await x25519(mine, theirs);
  const hkdf = await subtle().importKey("raw", buf(secret), "HKDF", false, ["deriveBits"]);
  const bits = await subtle().deriveBits({
    name: "HKDF", hash: "SHA-256",
    salt: buf(utf8(groupID.toLowerCase())),
    info: buf(utf8("studytrack-group-key-v1")),
  }, hkdf, 256);
  return new Uint8Array(bits);
}

export async function wrap(groupKey: Uint8Array, sender: Uint8Array, recipient: Uint8Array, groupID: string): Promise<string> {
  const wrapping = await wrappingKey(sender, recipient, groupID);
  return base64Encode(await gcmSeal(groupKey, wrapping));
}

export async function unwrap(sealed: string, recipient: Uint8Array, sender: Uint8Array, groupID: string): Promise<Uint8Array> {
  const data = base64Decode(sealed);
  if (!isCombined(data)) throw new CryptoError("malformed");
  const wrapping = await wrappingKey(recipient, sender, groupID);
  const raw = await gcmOpen(data, wrapping);
  if (!raw || raw.length !== 32) throw new CryptoError("wrongKey");
  return raw;
}

// MARK: Distribution

/// Les clés publiques de membres à qui il manque une enveloppe pour la clé
/// `keyID` — ce qu'un membre qui détient la clé doit sceller.
///
/// Pur, pour être testé : un membre sans clé publique n'est pas servi (il
/// n'a pas encore ouvert l'app), une clé déjà servie ne l'est pas deux fois,
/// et un ancien membre n'est jamais servi.
export function missingRecipients(
  memberIDs: Set<string>,
  publicKeys: { userID: string; key: string }[],
  servedKeys: Set<string>,
): { userID: string; key: string }[] {
  const seen = new Set<string>();
  return publicKeys.filter((entry) => {
    if (!memberIDs.has(entry.userID) || servedKeys.has(entry.key) || seen.has(entry.key)) return false;
    seen.add(entry.key);
    return true;
  });
}

export const GroupCrypto = {
  CryptoError, messagePrefix, newGroupKey, keyID, encode, decodeKey, seal, open, newIdentity,
  publicKeyString, publicKey, wrap, unwrap, missingRecipients,
};
