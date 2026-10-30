/** La voie **instantanée** du chrono partagé : le relais (`relay/`) entre les
 * appareils ouverts du même compte. Seule la partie **pure** est ici — le canal,
 * la clé, le chiffrement du contenu, la décision de réveil ; la WebSocket, les
 * jetons APNs et la reconnexion sont de l'hôte (Tauri), pas du domaine.
 *
 * - Le canal se déduit de l'identité du compte (la même sur ses appareils,
 *   opaque) : rien à appairer.
 * - Le contenu est chiffré (AES-GCM, clé déduite de la même identité) : le
 *   relais transporte des octets illisibles.
 *
 * WebCrypto est asynchrone : tout ce qui hache ou chiffre rend une promesse.
 */

const encoder = new TextEncoder();

async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function fromBase64(text: string): Uint8Array | null {
  try {
    const binary = atob(text);
    return Uint8Array.from(binary, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

export const TimerLink = {
  /** Le nom du canal : une empreinte de l'identité, rien de lisible. */
  async channel(identity: string): Promise<string> {
    const digest = await sha256(`studytrack.timer.channel.v1:${identity}`);
    return "st-timer-" + hex(digest.slice(0, 16));
  },

  /** La clé du compte : le SHA-256 d'une chaîne dérivée de l'identité (AES-256-GCM). */
  async key(identity: string): Promise<CryptoKey> {
    const material = await sha256(`studytrack.timer.key.v1:${identity}`);
    return crypto.subtle.importKey("raw", material as BufferSource, "AES-GCM", false, ["encrypt", "decrypt"]);
  },

  // MARK: Chiffrement (pur, testé)

  /** Chiffre un texte : base64 de `nonce (12) + chiffré + étiquette (16)`, comme `AES.GCM.SealedBox.combined`. */
  async sealText(plain: string, key: CryptoKey): Promise<string> {
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, encoder.encode(plain)));
    const combined = new Uint8Array(nonce.length + sealed.length);
    combined.set(nonce);
    combined.set(sealed, nonce.length);
    return toBase64(combined);
  },

  /** Déchiffre ; `null` si le texte est illisible ou si la clé n'est pas la bonne. */
  async openText(text: string, key: CryptoKey): Promise<string | null> {
    const combined = fromBase64(text);
    if (!combined || combined.length < 12 + 16) return null;
    try {
      const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: combined.slice(0, 12) }, key, combined.slice(12));
      return new TextDecoder().decode(plain);
    } catch {
      return null;
    }
  },

  /** Chiffre un contenu JSON (l'instantané du chrono). Les dates sont à la charge de l'appelant. */
  async seal(value: unknown, key: CryptoKey): Promise<string | null> {
    try {
      return await TimerLink.sealText(JSON.stringify(value), key);
    } catch {
      return null;
    }
  },

  async open<T = unknown>(text: string, key: CryptoKey): Promise<T | null> {
    const plain = await TimerLink.openText(text, key);
    if (plain === null) return null;
    try {
      return JSON.parse(plain) as T;
    } catch {
      return null;
    }
  },

  /** Réveiller les autres appareils : quand le verrou change (pas au premier
   * état, sauf s'il verrouille). */
  shouldWake(previous: boolean | null | undefined, now: boolean): boolean {
    if (previous === null || previous === undefined) return now;
    return previous !== now;
  },
};
