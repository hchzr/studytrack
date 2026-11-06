// Port de Polymestre/Domain/NotesLibrary.swift : les notes de l'étudiant·e, là
// où son app les sauvegarde (GoodNotes, Notability…). Pur : à quel cours va un
// cahier, de quelle semaine est un document, et s'il s'agit d'une série.

export interface NotesDocument {
  /** Le chemin relatif à la racine des notes. */
  path: string;
  notebook: string;
  title: string;
  week: number | null;
  seriesNumber: number | null;
  isSolution: boolean;
  modified: Date;
}

export interface CourseKey {
  code: string;
  name: string;
}

/** La façon de nommer de l'étudiant·e : mots d'une série, d'une semaine, cahiers rangés à la main. */
export class NotesRules {
  seriesWords: string[];
  weekWords: string[];
  /** cahier → code du cours ; une valeur vide écarte le cahier. */
  notebooks: Record<string, string>;

  constructor(o: { seriesWords?: string[]; weekWords?: string[]; notebooks?: Record<string, string> } = {}) {
    this.seriesWords = o.seriesWords ?? ["serie", "ps", "problem set", "exercice", "exercices"];
    this.weekWords = o.weekWords ?? ["semaine", "week", "sem"];
    this.notebooks = o.notebooks ?? {};
  }

  static get standard(): NotesRules { return new NotesRules(); }

  /** `Decodable` avec les valeurs par défaut quand une clé manque. */
  static decode(raw: string): NotesRules | null {
    try {
      const value: unknown = JSON.parse(raw);
      if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
      const object = value as Record<string, unknown>;
      const strings = (key: string, fallback: string[]): string[] =>
        Array.isArray(object[key]) && (object[key] as unknown[]).every((v) => typeof v === "string")
          ? (object[key] as string[]) : fallback;
      const notebooks: Record<string, string> = {};
      const rawNotebooks = object["notebooks"];
      if (rawNotebooks !== undefined) {
        if (rawNotebooks === null || typeof rawNotebooks !== "object" || Array.isArray(rawNotebooks)) return null;
        for (const [key, item] of Object.entries(rawNotebooks as Record<string, unknown>)) {
          if (typeof item !== "string") return null;
          notebooks[key] = item;
        }
      }
      return new NotesRules({
        seriesWords: strings("seriesWords", NotesRules.standard.seriesWords),
        weekWords: strings("weekWords", NotesRules.standard.weekWords),
        notebooks,
      });
    } catch {
      return null;
    }
  }

  encoded(): string {
    return JSON.stringify({ seriesWords: this.seriesWords, weekWords: this.weekWords, notebooks: this.notebooks });
  }

  equals(other: NotesRules): boolean {
    return this.encoded() === other.encoded();
  }
}

/** `NotesLibrary` : les règles pures du dossier de notes. */
export const NotesLibrary = {
  stopwords: new Set([
    "de", "la", "le", "les", "des", "du", "et", "a", "l", "d", "en", "i", "ii", "1", "2",
    "classe", "inversee", "introduction", "generale", "of", "the", "and", "to", "pi", "en",
  ]),

  /** Sans accents ; seuls lettres, chiffres, tiret et espace restent. */
  normalize(text: string): string {
    return Array.from(text.toLowerCase().normalize("NFD").replace(/\p{M}/gu, ""))
      .map((c) => (/[\p{L}\p{N}\- ]/u.test(c) ? c : " "))
      .join("")
      .split(" ")
      .filter((w) => w !== "")
      .join(" ");
  },

  significant(normalized: string): Set<string> {
    return new Set(normalized.split(" ").filter((w) => w.length > 1 && !NotesLibrary.stopwords.has(w) && !w.includes("-")));
  },

  /** « PHYS-101(c) » → « PHYS-101 ». */
  base(code: string): string {
    const at = code.indexOf("(");
    return at < 0 ? code : code.slice(0, at);
  },

  /** Le cours d'un cahier : son code d'abord, sinon les mots du nom, sinon l'acronyme. */
  course(forNotebook: string, among: CourseKey[], rules: NotesRules = NotesRules.standard): CourseKey | null {
    // Un cahier rangé à la main l'emporte.
    if (Object.prototype.hasOwnProperty.call(rules.notebooks, forNotebook)) {
      const code = rules.notebooks[forNotebook];
      return code === "" ? null : among.find((c) => c.code === code) ?? null;
    }
    const folder = NotesLibrary.normalize(forNotebook);
    const compact = folder.replace(/ /g, "");
    const byCode = among.find((course) =>
      compact.includes(NotesLibrary.normalize(NotesLibrary.base(course.code)).replace(/ /g, "")));
    if (byCode) return byCode;

    const words = NotesLibrary.significant(folder);
    if (words.size === 0) return null;
    let best: { course: CourseKey; score: number } | null = null;
    for (const course of among) {
      const name = NotesLibrary.significant(NotesLibrary.normalize(course.name));
      let score = [...words].filter((w) => name.has(w)).length / words.size;
      const initials = NotesLibrary.normalize(course.name).split(" ")
        .filter((w) => !NotesLibrary.stopwords.has(w) && /^\p{L}/u.test(w))
        .map((w) => Array.from(w)[0]);
      const acronym = initials.join("");
      if ([...words].some((w) => w.length >= 3 && acronym.startsWith(w))) score = Math.max(score, 0.9);
      if (score > (best?.score ?? 0)) best = { course, score };
    }
    if (!best || best.score < 0.5) return null;
    // Deux cours à égalité (« Analyse I » et « Analyse II ») : pas de choix au hasard.
    const ties = among.filter((course) =>
      [...words].filter((w) => NotesLibrary.significant(NotesLibrary.normalize(course.name)).has(w)).length / words.size === best!.score);
    return ties.length > 1 && best.score < 0.9
      ? ties.find((c) => c.code.includes("101") || c.code.includes("111")) ?? best.course
      : best.course;
  },

  /** `EPFL BA1/Algèbre Linéaire/Semaine 3/Série 3.pdf` → cahier, semaine, série. */
  document(path: string, modified: Date, rules: NotesRules = NotesRules.standard): NotesDocument | null {
    const parts = path.split("/").filter((p) => p !== "");
    const file = parts[parts.length - 1];
    if (file === undefined || !file.toLowerCase().endsWith(".pdf")) return null;
    const title = file.slice(0, -4);
    const folders = parts.slice(0, -1);
    let week: number | null = null;
    for (let i = folders.length - 1; i >= 0; i--) {
      const found = NotesLibrary.weekNumber(folders[i], rules);
      if (found !== null) { week = found; break; }
    }
    let notebook: string | null = null;
    for (let i = folders.length - 1; i >= 0; i--) {
      if (NotesLibrary.weekNumber(folders[i], rules) === null && NotesLibrary.normalize(folders[i]) !== "s4s") {
        notebook = folders[i];
        break;
      }
    }
    notebook = notebook ?? folders[folders.length - 1] ?? "";
    const lower = NotesLibrary.normalize(title);
    const solution = ["corrige", "solution", "sol "].some((w) => lower.includes(w)) || lower.endsWith(" sol");
    return {
      path,
      notebook,
      title,
      week,
      seriesNumber: NotesLibrary.seriesNumber(title, rules),
      isSolution: solution,
      modified,
    };
  },

  weekNumber(folder: string, rules: NotesRules = NotesRules.standard): number | null {
    const text = NotesLibrary.normalize(folder);
    const words = rules.weekWords.map((w) => escapeRegExp(NotesLibrary.normalize(w))).join("|");
    if (words === "") return null;
    const match = new RegExp(`^(?:${words})\\s*(\\d{1,2})`).exec(text);
    if (match === null) return null;
    const digits = Array.from(match[0]).filter((c) => /[0-9]/.test(c)).join("");
    return digits === "" ? null : Number(digits);
  },

  /** « Série 3 », « Serie 04 », « PS5 », « Problem Set 6 », « Séance et série 4 ». */
  seriesNumber(title: string, rules: NotesRules = NotesRules.standard): number | null {
    const text = NotesLibrary.normalize(title);
    const patterns = rules.seriesWords.map((word) => {
      const escaped = escapeRegExp(NotesLibrary.normalize(word));
      // Un mot court (« ps », « td ») doit commencer un mot : pas « laps 3 ».
      return (Array.from(word).length <= 3 ? "\\b" : "") + escaped + "\\s*0*(\\d{1,2})";
    });
    for (const pattern of patterns) {
      const match = new RegExp(pattern, "u").exec(text);
      if (match !== null && match[1] !== undefined) return parseInt(match[1], 10);
    }
    return null;
  },

  /** La copie de l'étudiant·e pour une série : même numéro, pas un corrigé, la plus récente. */
  copy(seriesNumber: number, week: number | null, documents: NotesDocument[]): NotesDocument | null {
    const own = documents.filter((d) => !d.isSolution);
    const exact = own.filter((d) => d.seriesNumber === seriesNumber)
      .sort((a, b) => a.modified.getTime() - b.modified.getTime());
    if (exact.length !== 0) return exact[exact.length - 1];
    if (week === null) return null;
    const nearby = own.filter((d) => d.week === week && (d.seriesNumber !== null || NotesLibrary.normalize(d.title).includes("serie")))
      .sort((a, b) => a.modified.getTime() - b.modified.getTime());
    return nearby.length === 0 ? null : nearby[nearby.length - 1];
  },
};

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
