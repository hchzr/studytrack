/** Le sélecteur d'étude (Alt+Tab dans le bureau) : l'ordre des outils et des apps,
 * le dernier utilisé d'abord, comme le sélecteur du système qu'il remplace.
 *
 * Pur et testé. Les entrées sont des identifiants (`pane:exercise`,
 * `app:com.goodnotesapp.x`, `claude`) ; ce qu'elles ouvrent est dans l'app.
 */
export class StudySwitcherModel {
  static readonly memory = 24;

  /** Les plus récents d'abord, sans doublon. */
  private _recent: string[] = [];

  get recent(): readonly string[] {
    return this._recent;
  }

  touch(id: string): void {
    this._recent = this._recent.filter((entry) => entry !== id);
    this._recent.unshift(id);
    if (this._recent.length > StudySwitcherModel.memory) {
      this._recent.splice(StudySwitcherModel.memory);
    }
  }

  /** Les entrées disponibles, le plus récemment utilisé en tête ; celles
   * jamais utilisées suivent dans l'ordre donné. */
  order(available: string[]): string[] {
    const known = this._recent.filter((id) => available.includes(id));
    return [...known, ...available.filter((id) => !known.includes(id))];
  }

  /** Où tombe la sélection après `step` appuis (Maj : en arrière), en boucle. */
  static move(index: number, step: number, count: number): number {
    if (!(count > 0)) return 0;
    return (((index + step) % count) + count) % count;
  }
}

/** Les noms que le moteur de calcul connaît ; tout autre mot de deux lettres
 * ou plus est du texte, pas une expression. */
const known = ["sin", "cos", "tan", "asin", "acos", "atan", "exp", "ln", "log", "sqrt",
  "abs", "det", "inv", "rref", "transpose", "rank", "trace", "solve",
  "pi", "int", "root", "re", "im", "conj", "arg", "sinh", "cosh", "tanh"];

/** D'où vient un résultat, pour les ranger : un calcul d'abord, puis l'outil dont le
 * nom commence par ce qu'on tape, puis le contenu du cours, les autres outils, les
 * actions, ce qu'on a gardé, les sites. Les valeurs suivent l'ordre. */
export const StudySearchGroup = {
  math: 0,
  toolPrefix: 1,
  content: 2,
  tool: 3,
  action: 4,
  kept: 5,
  site: 6,
} as const;
export type StudySearchGroup = (typeof StudySearchGroup)[keyof typeof StudySearchGroup];

/** Les blancs de `CharacterSet.whitespaces` (espaces et tabulations, pas les retours). */
const trimBlanks = (text: string) => text.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");

/** Sans accents ni casse, comme `folding(options: [.diacriticInsensitive, .caseInsensitive])`. */
function fold(text: string): string {
  return trimBlanks(text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase());
}

/** La recherche d'étude (Ctrl+Espace) : ce qui ressemble à un calcul est calculé. */
export const StudySearchQuery = {
  Group: StudySearchGroup,

  /** Le groupe d'un résultat : un outil ou une app dont le titre **commence** par la
   * requête passe avant le contenu ; un autre outil après. */
  group(base: StudySearchGroup, title: string, needle: string): StudySearchGroup {
    if (base !== StudySearchGroup.tool) return base;
    return fold(title).startsWith(fold(needle)) ? StudySearchGroup.toolPrefix : StudySearchGroup.tool;
  },

  /** Une question à Claude : ce que l'étudiant·e a tapé, si c'est une phrase (au moins
   * deux mots, ou un point d'interrogation) et pas un nom d'outil. */
  claudeQuestion(query: string): string | null {
    const text = query.trim();
    if (text === "") return null;
    const words = text.split(/\s+/).filter((word) => word !== "");
    return words.length >= 2 || text.endsWith("?") ? text : null;
  },

  /** L'expression à calculer, ou `null` si la requête est une recherche.
   * `=` en tête force le calcul ; sinon il faut un chiffre, un opérateur, et
   * aucun mot (« série 3 », « PHYS-101 » restent des recherches). */
  mathExpression(query: string): string | null {
    let text = trimBlanks(query);
    const forced = text.startsWith("=");
    if (forced) text = text.slice(1);
    text = trimBlanks(text);
    if (text === "") return null;
    let rest = text.toLowerCase();
    const names = [...known].sort((a, b) => b.length - a.length);
    for (const name of names) rest = rest.split(name).join(" ");
    const words = rest.split(/[^\p{L}]+/u).filter((word) => word !== "");
    if (words.some((word) => [...word].length >= 2)) return null;
    if (forced) return text;
    const hasDigit = /\p{N}/u.test(text);
    const hasOperator = [...text].some((ch) => "+-*/^()".includes(ch));
    return hasDigit && hasOperator ? text : null;
  },
};
