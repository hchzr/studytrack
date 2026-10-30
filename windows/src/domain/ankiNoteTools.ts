/// Petits outils des notes Anki, purs : numéros des trous, identifiant global.

/// Les numéros de trous `{{cN::` d'un texte, uniques, positifs, croissants.
export function clozeNumbers(text: string): number[] {
  const numbers = [...text.matchAll(/\{\{c(\d+)::/g)].map((m) => Number(m[1]));
  return [...new Set(numbers)].filter((n) => n > 0).sort((a, b) => a - b);
}

const guidAlphabet = [..."abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~"];

/// Un identifiant global de note, comme Anki (base 91, dix caractères).
export function guid(): string {
  const buffer = new BigUint64Array(1);
  let value = 0n;
  // Tirage dans 1…UInt64.max : on retire le zéro.
  while (value === 0n) {
    globalThis.crypto.getRandomValues(buffer);
    value = buffer[0];
  }
  const base = BigInt(guidAlphabet.length);
  let result = "";
  while (value > 0n) {
    result += guidAlphabet[Number(value % base)];
    value /= base;
  }
  return result;
}

export const AnkiNoteTools = { clozeNumbers, guid };
