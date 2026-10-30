/// Répare les accents d'un texte venu d'ailleurs, **avant** qu'il ne soit rangé.
///
/// Trois sources les abîmaient, chacune à sa façon :
///   • un PDF compilé par LaTeX (police Type 1) dessine « é » comme un « e »
///     plus un accent posé dessus : on obtient « e´ » ou « ´e », parfois avec
///     une espace — « s´erie », « ´equation » ;
///   • une page Moodle encode certains caractères en entités (`&eacute;`,
///     `&#233;`, `&#039;`) que le décodage d'origine ne connaissait pas toutes ;
///   • un texte UTF-8 relu comme Latin-1 en route (« SÃ©rie », « Ã  rendre »).
///
/// Pur et testé. Idempotent : un texte propre ressort intact.

// MARK: Caractères à la façon de Swift

// Un `Character` Swift est un graphème, pas un point de code : « e + accent
// combinant » compte pour un. Les moteurs de texte portés parcourent donc des
// graphèmes (`characters`), et testent leur premier scalaire comme Swift.
// `Intl.Segmenter` n'est pas dans la lib ES2020 du projet : on le tape à la main.
type GraphemeSegmenter = { segment(text: string): Iterable<{ segment: string }> };
const segmenter: GraphemeSegmenter = new (
  Intl as unknown as { Segmenter: new (locale: undefined, options: { granularity: "grapheme" }) => GraphemeSegmenter }
).Segmenter(undefined, { granularity: "grapheme" });

/// `Array(string)` de Swift : les graphèmes d'une chaîne.
export function characters(text: string): string[] {
  const result: string[] = [];
  for (const part of segmenter.segment(text)) result.push(part.segment);
  return result;
}

/// `Character.isLetter` : le premier scalaire est alphabétique.
export function isLetter(char: string): boolean {
  return /^\p{Alphabetic}/u.test(char);
}

/// `Character.isNumber` : le premier scalaire a un type numérique (chiffres, `²`, `½`…).
export function isNumber(char: string): boolean {
  return /^\p{N}/u.test(char);
}

/// `Character.isWhitespace`.
export function isWhitespace(char: string): boolean {
  return /^\p{White_Space}/u.test(char);
}

/// `trimmingCharacters(in: .whitespaces)` : espaces et tabulations, pas les retours à la ligne.
export function trimWhitespaces(text: string): string {
  return text.replace(/^[\p{Zs}\t]+/u, "").replace(/[\p{Zs}\t]+$/u, "");
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`.
export function trimWhitespacesAndNewlines(text: string): string {
  return text.replace(/^[\p{Z}\t\n\u000B\f\r\u0085]+/u, "").replace(/[\p{Z}\t\n\u000B\f\r\u0085]+$/u, "");
}

/// `precomposedStringWithCanonicalMapping`.
export function precomposed(text: string): string {
  return text.normalize("NFC");
}

// MARK: Entités HTML

const named = new Map<string, string>(Object.entries({
  amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ",
  rsquo: "’", lsquo: "‘", rdquo: "”", ldquo: "“", laquo: "«", raquo: "»",
  ndash: "–", mdash: "—", hellip: "…", middot: "·", deg: "°", euro: "€",
  eacute: "é", egrave: "è", ecirc: "ê", euml: "ë", Eacute: "É", Egrave: "È", Ecirc: "Ê",
  agrave: "à", acirc: "â", auml: "ä", Agrave: "À", Acirc: "Â",
  icirc: "î", iuml: "ï", ocirc: "ô", ouml: "ö", Ocirc: "Ô",
  ugrave: "ù", ucirc: "û", uuml: "ü", Uuml: "Ü", ccedil: "ç", Ccedil: "Ç",
  oelig: "œ", OElig: "Œ", aelig: "æ", szlig: "ß", ntilde: "ñ", times: "×",
}));

export function decodeEntities(text: string): string {
  if (!text.includes("&")) return text;
  return text.replace(/&(#[xX]?[0-9A-Fa-f]{1,6}|[A-Za-z]{2,8});/g, (whole, body: string) => {
    if (body.startsWith("#")) {
      const hex = body[1] === "x" || body[1] === "X";
      const digits = body.slice(hex ? 2 : 1);
      // `UInt32(digits, radix:)` refuse une lettre en décimal ; `Unicode.Scalar` refuse un substitut.
      if (!(hex ? /^[0-9A-Fa-f]+$/ : /^[0-9]+$/).test(digits)) return whole;
      const value = parseInt(digits, hex ? 16 : 10);
      if (value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return whole;
      return String.fromCodePoint(value);
    }
    return named.get(body) ?? whole;
  });
}

// MARK: Double encodage

/// Windows-1252, octets 0x80–0x9F : ce que ces octets dessinent (hors Latin-1).
const cp1252High = new Map<number, number>([
  [0x20ac, 0x80], [0x201a, 0x82], [0x0192, 0x83], [0x201e, 0x84], [0x2026, 0x85], [0x2020, 0x86],
  [0x2021, 0x87], [0x02c6, 0x88], [0x2030, 0x89], [0x0160, 0x8a], [0x2039, 0x8b], [0x0152, 0x8c],
  [0x017d, 0x8e], [0x2018, 0x91], [0x2019, 0x92], [0x201c, 0x93], [0x201d, 0x94], [0x2022, 0x95],
  [0x2013, 0x96], [0x2014, 0x97], [0x02dc, 0x98], [0x2122, 0x99], [0x0161, 0x9a], [0x203a, 0x9b],
  [0x0153, 0x9c], [0x017e, 0x9e], [0x0178, 0x9f],
]);

/// `text.data(using:)` sans perte : `null` si un caractère n'a pas d'octet.
function encode(text: string, windows: boolean): Uint8Array | null {
  const bytes: number[] = [];
  for (const char of text) {
    const code = char.codePointAt(0)!;
    if (code < 0x100) {
      bytes.push(code);
    } else if (windows && cp1252High.has(code)) {
      bytes.push(cp1252High.get(code)!);
    } else {
      return null;
    }
  }
  return Uint8Array.from(bytes);
}

/// « SÃ©rie » → « Série ». Ne touche qu'un texte qui en porte la marque
/// (« Ã » ou « Â » suivi d'un caractère de continuation), et seulement si
/// la relecture en UTF-8 réussit : « Ãle » (rare, mais français) reste.
export function fixMojibake(text: string): string {
  if (!/[ÃÂ][\u0080-¿‘-„†-…ŒœŠšŸŽžˆ˜‰‹›€™]/.test(text)) return text;
  for (const windows of [true, false]) {
    const bytes = encode(text, windows);
    if (!bytes) continue;
    try {
      return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
    } catch {
      // octets qui ne sont pas de l'UTF-8 : on essaie l'encodage suivant
    }
  }
  return text;
}

// MARK: Accents détachés (PDF LaTeX)

/// Accent d'espacement → accent combinant : le même signe, posé sur la lettre.
// Pas de `^` : dans un énoncé, `x^y` et `ℝ^n` sont des exposants. Un
// PDF LaTeX rend le circonflexe en « ˆ » (U+02C6), lui sans ambiguïté.
const combining = new Map<string, string>([
  ["´", "́"], ["`", "̀"], ["ˆ", "̂"],
  ["¨", "̈"], ["˜", "̃"], ["¸", "̧"], ["ˇ", "̌"],
]);
/// Les lettres qui portent ces accents en français (et en allemand).
const carriers = new Set([..."aeiouyAEIOUYcCnN"]);

/// « s´erie » → « série », « ´equation » → « équation », « e´te´ » → « été ».
///
/// LaTeX dessine l'accent **avant** la lettre dans le flux du PDF ; certains
/// extracteurs le rendent après. On l'attache à la lettre qui suit, sinon à
/// celle qui précède. `` ` `` n'est touché qu'entre deux lettres : ailleurs,
/// c'est un guillemet de code.
export function composeAccents(text: string): string {
  const chars = characters(text);
  if (!chars.some((c) => combining.has(c))) return text;
  const out: string[] = [];
  const append = (value: string) => out.push(...characters(value));
  let index = 0;
  while (index < chars.length) {
    const char = chars[index];
    const mark = combining.get(char);
    if (mark === undefined) {
      out.push(char);
      index += 1;
      continue;
    }
    const isAmbiguous = char === "`";
    // La cédille ne va que sous un « c » : celui d'avant (« garc¸on »),
    // sinon celui d'après (« ¸c »).
    if (char === "¸") {
      const last = out.length > 0 ? out[out.length - 1] : undefined;
      if (last !== undefined && "cC".includes(last)) {
        out.pop();
        append(precomposed(last + mark));
      } else if (index + 1 < chars.length && "cC".includes(chars[index + 1])) {
        append(precomposed(chars[index + 1] + mark));
        index += 1;
      } else {
        out.push(char);
      }
      index += 1;
      continue;
    }
    // « l´analyse », « qu´il » : l'accent aigu tapé pour une apostrophe.
    // Jamais devant un « e » : en français l'aigu n'existe que sur lui,
    // et « s´erie », « d´efinition » sont des « é » de PDF LaTeX.
    if (char === "´" && index + 1 < chars.length && isLetter(chars[index + 1])
        && !"eE".includes(chars[index + 1]) && isElision(out)) {
      out.push("’");
      index += 1;
      continue;
    }
    // Une espace parasite entre l'accent et sa lettre : « ´ e ».
    let next = index + 1;
    if (next < chars.length && chars[next] === " " && !isAmbiguous) next += 1;
    const previousIsLetter = out.length > 0 ? isLetter(out[out.length - 1]) : false;
    if (next < chars.length && carriers.has(chars[next]) && (!isAmbiguous || previousIsLetter)) {
      append(precomposed(chars[next] + mark));
      index = next + 1;
      continue;
    }
    const last = out.length > 0 ? out[out.length - 1] : undefined;
    if (!isAmbiguous && last !== undefined && carriers.has(last)) {
      // « e´ » en fin de mot : l'accent va sur la lettre d'avant.
      out.pop();
      append(precomposed(last + mark));
      index += 1;
      continue;
    }
    out.push(char);
    index += 1;
  }
  return out.join("");
}

/// Le texte se termine-t-il par un mot élidé (« l », « d », « qu », « jusqu ») ?
function isElision(out: string[]): boolean {
  const word: string[] = [];
  for (let i = out.length - 1; i >= 0; i--) {
    if (!isLetter(out[i])) break;
    word.unshift(out[i]);
  }
  return ["l", "d", "j", "n", "s", "c", "m", "t", "qu", "jusqu", "lorsqu", "puisqu", "quoiqu"].includes(word.join("").toLowerCase());
}

/// Tout, dans l'ordre : entités, double encodage, accents détachés, forme
/// composée (NFC — « é » en un seul caractère, comme le clavier le tape).
export function clean(text: string): string {
  if (text === "") return text;
  let result = decodeEntities(text);
  result = fixMojibake(result);
  result = composeAccents(result);
  return precomposed(result);
}

export const TextRepair = { clean, decodeEntities, fixMojibake, composeAccents };
