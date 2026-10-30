// Des expressions régulières à la façon d'`NSRegularExpression` (ICU).
//
// Différence qui compte pour les motifs de séries : en ICU, `\b` et `\w` sont
// **Unicode** (« é » est une lettre), en JavaScript ils sont ASCII. Sans cette
// traduction, `\bétoile\b` ne se trouverait jamais en début de mot.

const word = String.raw`[\p{L}\p{N}_]`;
const boundary = String.raw`(?:(?<=${word})(?!${word})|(?<!${word})(?=${word}))`;

/// Compile `source` (syntaxe ICU, sans classe contenant `\w`) en `RegExp` Unicode.
export function icuRegExp(source: string, flags = ""): RegExp {
  return new RegExp(source.split(String.raw`\b`).join(boundary).split(String.raw`\w`).join(word), flags + "u");
}
