// Lit la charge `__NUXT_DATA__` d'une page Nuxt — ce que servent cinq des six
// polycopiés de Botafogo (StudyTrack/Domain/NuxtPayload.swift).
//
// La table des matières n'est pas dans le HTML sous une forme lisible : elle est
// dans un bloc JSON au format **devalue**, un tableau plat où chaque objet ne
// contient que des **indices** vers d'autres cases et où les chaînes répétées ne
// figurent qu'une fois. On suit les indices.

export interface NavNode {
  title: string;
  path: string;
  children: NavNode[];
}

export const NavNode = {
  make(title: string, path: string, children: NavNode[] = []): NavNode {
    return { title, path, children };
  },
};

export interface Navigation {
  /** Le nom du polycopié (« Analyse B (MAN) »), quand un nœud racine le porte. */
  title: string | null;
  chapters: NavNode[];
}

type JSONValue = unknown;

export class NuxtPayload {
  readonly values: JSONValue[];

  /** Extrait et décode le bloc depuis le HTML ; `null` si la page n'en a pas. */
  static fromHTML(html: string): NuxtPayload | null {
    const start = html.indexOf('id="__NUXT_DATA__"');
    if (start < 0) return null;
    const open = html.indexOf(">", start + 'id="__NUXT_DATA__"'.length);
    if (open < 0) return null;
    const close = html.indexOf("</script>", open + 1);
    if (close < 0) return null;
    const json = html.slice(open + 1, close);
    try {
      const array = JSON.parse(json);
      if (!Array.isArray(array) || array.length === 0) return null;
      return new NuxtPayload(array);
    } catch {
      return null;
    }
  }

  constructor(values: JSONValue[]) {
    this.values = values;
  }

  /// Les enveloppes de devalue autour d'une valeur (`["ShallowReactive", 3]`).
  private static readonly wrappers = new Set(["Reactive", "ShallowReactive", "Ref", "ShallowRef",
                                              "EmptyRef", "EmptyShallowRef", "NuxtError"]);

  /** La valeur de la case `index`, débarrassée de ses enveloppes. */
  raw(index: number): JSONValue | null {
    if (!Number.isInteger(index) || index < 0 || index >= this.values.length) return null;
    let value = this.values[index];
    let hops = 0;
    while (Array.isArray(value) && typeof value[0] === "string"
           && NuxtPayload.wrappers.has(value[0]) && value.length > 1 && typeof value[1] === "number"
           && Number.isInteger(value[1]) && value[1] >= 0 && value[1] < this.values.length && hops < 8) {
      value = this.values[value[1]];
      hops += 1;
    }
    return value;
  }

  string(index: unknown): string | null {
    if (typeof index !== "number" || !Number.isInteger(index)) return null;
    const value = this.raw(index);
    return typeof value === "string" ? value : null;
  }

  object(index: unknown): Record<string, JSONValue> | null {
    if (typeof index !== "number" || !Number.isInteger(index)) return null;
    const value = this.raw(index);
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, JSONValue>) : null;
  }

  /** Les cases d'un tableau (des indices), ou `null`. */
  list(index: unknown): number[] | null {
    if (typeof index !== "number" || !Number.isInteger(index)) return null;
    const array = this.raw(index);
    if (!Array.isArray(array)) return null;
    if (typeof array[0] === "string" && array[0].length > 0) return null;
    return array.filter((x): x is number => typeof x === "number" && Number.isInteger(x));
  }

  /**
   * Le sommaire : la liste de nœuds `{title, path, children}` qui contient le
   * plus de **sections** (enfants sans enfants).
   *
   * Compter les sections et non les nœuds : un site enveloppe parfois ses
   * chapitres dans un nœud racine, et un chapitre pas encore publié n'a pas de
   * sections — il ne doit pas disqualifier la liste.
   */
  navigation(): Navigation {
    let best: { index: number; nodes: NavNode[]; score: number } | null = null;
    for (let index = 0; index < this.values.length; index += 1) {
      const array = this.values[index];
      if (!Array.isArray(array) || array.length === 0 || typeof array[0] === "string") continue;
      const items = array.filter((x): x is number => typeof x === "number" && Number.isInteger(x));
      if (items.length !== array.length) continue;
      const nodes = items.map((i) => this.node(i, 0)).filter((n): n is NavNode => n !== null);
      if (nodes.length !== items.length) continue;
      const score = nodes.reduce((total, node) => total + node.children.filter((c) => c.children.length === 0).length, 0);
      if (!(score > 0) || score <= (best?.score ?? 0)) continue;
      best = { index, nodes, score };
    }
    if (best === null) return { title: null, chapters: [] };
    // Le nœud qui porte cette liste, s'il existe, nomme le polycopié.
    const owner = this.values
      .filter((v): v is Record<string, JSONValue> => v !== null && typeof v === "object" && !Array.isArray(v))
      .find((object) => (typeof object["children"] === "number" ? this.unwrapIndex(object["children"]) === best.index : false));
    // Analyse I GM nomme sa racine comme son premier chapitre (« I Préface ») :
    // un titre de chapitre n'est pas un nom de polycopié.
    const rawTitle = owner ? this.string(owner["title"]) : null;
    const title = rawTitle !== null && best.nodes.some((n) => n.title === rawTitle) ? null : rawTitle;
    return { title, chapters: best.nodes };
  }

  /** L'indice réel derrière une enveloppe (`["ShallowReactive", 5]` → 5). */
  private unwrapIndex(index: number): number {
    let current = index;
    let hops = 0;
    while (current >= 0 && current < this.values.length) {
      const array = this.values[current];
      if (!Array.isArray(array) || typeof array[0] !== "string" || !NuxtPayload.wrappers.has(array[0])
          || array.length <= 1 || typeof array[1] !== "number" || !Number.isInteger(array[1])
          || array[1] < 0 || array[1] >= this.values.length || hops >= 8) break;
      current = array[1];
      hops += 1;
    }
    return current;
  }

  private node(index: number, depth: number): NavNode | null {
    if (depth >= 3) return null;
    const object = this.object(index);
    if (object === null) return null;
    const title = this.string(object["title"]);
    const path = this.string(object["path"]);
    if (title === null || path === null) return null;
    const children = (this.list(object["children"]) ?? [])
      .map((i) => this.node(i, depth + 1))
      .filter((n): n is NavNode => n !== null);
    return { title, path, children };
  }

  /** Les chaînes, dans l'ordre du tableau (pour les listes de vidéos). */
  get strings(): string[] {
    return this.values.filter((v): v is string => typeof v === "string");
  }
}
