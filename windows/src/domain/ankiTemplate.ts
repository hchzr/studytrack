/// Le rendu d'une carte Anki : son modèle (`qfmt`/`afmt`) rempli avec les
/// champs de la note — ce que montre Anki, en HTML.
///
/// Couvre ce qu'utilisent les types de notes courants : `{{Champ}}`,
/// `{{FrontSide}}`, les sections `{{#Champ}}…{{/Champ}}` et
/// `{{^Champ}}…{{/Champ}}`, les filtres `text:`, `hint:`, `cloze:`, `type:`,
/// et les trous `{{c1::réponse::indice}}`. Un filtre inconnu laisse le champ
/// tel quel.

export interface AnkiTemplateContext {
  fields: Record<string, string>;
  /** Numéro du modèle (0…) ; pour une note à trous, le trou est `ord + 1`. */
  ordinal: number;
  isCloze: boolean;
  tags?: string;
  deck?: string;
  cardName?: string;
}

/// `trimmingCharacters(in: .whitespaces)` : espaces et tabulations, pas les sauts de ligne.
const trimSpaces = (s: string): string => s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");
const trimAll = (s: string): string => s.trim();

export function question(template: string, context: AnkiTemplateContext): string {
  return render(template, context, false, "");
}

export function answer(template: string, front: string, context: AnkiTemplateContext): string {
  return render(template, context, true, front);
}

// MARK: Rendu

function render(template: string, context: AnkiTemplateContext, isAnswer: boolean, frontSide: string): string {
  const sectioned = sections(template, context);
  let output = "";
  let cursor = 0;
  for (const match of sectioned.matchAll(/\{\{([^{}]+)\}\}/g)) {
    const index = match.index!;
    output += sectioned.slice(cursor, index);
    output += replacement(trimSpaces(match[1]), context, isAnswer, frontSide);
    cursor = index + match[0].length;
  }
  output += sectioned.slice(cursor);
  return output;
}

/// `{{#Champ}}…{{/Champ}}` gardé si le champ est rempli ; `{{^Champ}}` l'inverse.
function sections(template: string, context: AnkiTemplateContext): string {
  let text = template;
  // Les sections imbriquées se résolvent de l'intérieur : on repasse
  // tant qu'il en reste.
  for (let pass = 0; pass < 8; pass++) {
    const matches = [...text.matchAll(/\{\{([#^])([^{}]+)\}\}(.*?)\{\{\/\2\}\}/gs)];
    if (matches.length === 0) break;
    for (const match of matches.reverse()) {
      const index = match.index!;
      const field = trimSpaces(match[2]);
      const filled = isFilled(field, context);
      const keep = match[1] === "#" ? filled : !filled;
      text = text.slice(0, index) + (keep ? match[3] : "") + text.slice(index + match[0].length);
    }
  }
  return text;
}

function isFilled(name: string, context: AnkiTemplateContext): boolean {
  const field = name.split(":").filter((p) => p.length > 0).pop() ?? name;
  if (field.startsWith("c") && context.isCloze && /^[+-]?\d+$/.test(field.slice(1))) {
    return Number(field.slice(1)) === context.ordinal + 1;
  }
  return trimAll(stripHTML(context.fields[field] ?? "")).length > 0;
}

function replacement(tag: string, context: AnkiTemplateContext, isAnswer: boolean, frontSide: string): string {
  if (tag === "FrontSide") return frontSide;
  // Les commentaires et balises spéciales d'Anki (`{{!…}}`, `{{=…=}}`).
  if (tag.startsWith("!") || tag.startsWith("=")) return "";
  const parts = tag.split(":");
  const name = parts[parts.length - 1];
  const filters = parts.slice(0, -1).map((f) => trimSpaces(f).toLowerCase());
  let value: string;
  switch (name) {
    case "Tags": value = trimSpaces(context.tags ?? ""); break;
    case "Deck": value = context.deck ?? ""; break;
    case "Subdeck": {
      const deck = context.deck ?? "";
      value = deck.split("::").pop() ?? deck;
      break;
    }
    case "Card": value = context.cardName ?? ""; break;
    default: value = context.fields[name] ?? "";
  }
  // Les filtres s'appliquent de droite à gauche (« text:cloze:Texte »).
  for (const filter of [...filters].reverse()) {
    switch (filter) {
      case "cloze": value = cloze(value, context.ordinal + 1, isAnswer); break;
      case "text": value = stripHTML(value); break;
      case "hint":
        value = value === "" ? "" : `<details class="hint"><summary>Indice</summary>${value}</details>`;
        break;
      case "type":
        // Saisie de la réponse : sur l'app, on la montre au verso.
        value = isAnswer ? `<div class="typed">${value}</div>` : "";
        break;
      default: break;
    }
  }
  return value;
}

/// Les trous : le trou demandé masqué (recto) ou surligné (verso), les autres
/// en clair.
export function cloze(text: string, number: number, isAnswer: boolean): string {
  let output = "";
  let cursor = 0;
  for (const match of text.matchAll(/\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}/gs)) {
    output += text.slice(cursor, match.index!);
    const content = match[2];
    const hint = match[3];
    if (Number(match[1]) === number) {
      output += isAnswer
        ? `<span class="cloze">${content}</span>`
        : `<span class="cloze">[${hint ?? "…"}]</span>`;
    } else {
      output += content;
    }
    cursor = match.index! + match[0].length;
  }
  output += text.slice(cursor);
  return output;
}

/// Le texte d'un champ HTML : balises retirées, entités courantes décodées.
export function stripHTML(html: string): string {
  let text = html.replace(/<br\s*\/?>|<\/div>|<\/p>/gi, "\n");
  text = text.replace(/<[^>]+>/g, "");
  // `&amp;` en dernier : Swift parcourt un dictionnaire (ordre indéfini) ; ici
  // « &amp;lt; » donne « &lt; » et non « < ».
  for (const [entity, value] of [["&nbsp;", " "], ["&lt;", "<"], ["&gt;", ">"], ["&quot;", '"'], ["&#39;", "'"], ["&amp;", "&"]]) {
    text = text.split(entity).join(value);
  }
  return trimAll(text);
}

/// Le champ de tri et la somme de contrôle d'une note (`sfld`, `csum`) :
/// les huit premiers chiffres hexadécimaux du SHA-1 du premier champ, sans HTML.
export function checksum(sha1Hex: string): number {
  const head = sha1Hex.slice(0, 8);
  return /^[+-]?[0-9a-fA-F]+$/.test(head) ? parseInt(head, 16) : 0;
}

export const AnkiTemplate = { question, answer, cloze, stripHTML, checksum };
