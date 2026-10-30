// Port de StudyTrack/Domain/NotebookLMWire.swift : le protocole de NotebookLM,
// sans réseau. Son site parle à Google par `batchexecute` (tableaux JSON
// imbriqués, identifiés par un code court). Les formes peuvent changer sans
// préavis : tout ce qui en dépend est ici, isolé et testé.

/** Les deux hôtes connus du site (Google l'a déplacé). */
const hosts = ["https://notebook.google.com", "https://notebooklm.google.com"];

export type NotebookRPC =
  | "wXbhsf"  // listNotebooks
  | "CCqFvf"  // createNotebook
  | "izAoDd"  // addSource
  | "R7cb6c"  // createArtifact
  | "gArtLc"  // listArtifacts
  | "WWINqb"; // deleteNotebook

export type AudioFormat = 1 | 2 | 3 | 4;
export type AudioLength = 1 | 2 | 3;

/** Les valeurs numériques de `enums.ts` ne dépendent pas de ce module : on les garde ici. */
export const NotebookAudio = {
  format: { deepDive: 1, brief: 2, critique: 3, debate: 4 } as Record<string, AudioFormat>,
  length: { short: 1, standard: 2, long: 3 } as Record<string, AudioLength>,
};

export type ArtifactState = "waiting" | "working" | "ready" | "failed";

export interface NotebookArtifact {
  id: string;
  title: string;
  /** 1 = résumé audio. */
  type: number;
  state: ArtifactState;
  audioURL: URL | null;
}

/** L'erreur de lecture d'une réponse : la page de connexion, ou un refus de Google. */
export class NotebookParseError extends Error {
  readonly kind: "notAnswer" | "refused";
  readonly code: number | null;

  private constructor(kind: "notAnswer" | "refused", code: number | null) {
    super(kind === "notAnswer" ? "notAnswer" : `refused(${code ?? "?"})`);
    this.name = "NotebookParseError";
    this.kind = kind;
    this.code = code;
  }

  static notAnswer(): NotebookParseError { return new NotebookParseError("notAnswer", null); }
  static refused(code: number | null): NotebookParseError { return new NotebookParseError("refused", code); }
}

/** `URL(string:)` : `null` pour une adresse invalide (absolue). */
function makeURL(text: string): URL | null {
  try { return new URL(text); } catch { return null; }
}

export const NotebookLMWire = {
  hosts,

  /** L'app elle-même — pas la page de connexion de Google, ni la vitrine. */
  isApp(host: string): boolean {
    return hosts.some((address) => makeURL(address)?.host === host);
  },

  /** Les cookies qui n'existent qu'une fois connecté·e à Google. */
  isSignedIn(cookieNames: string[]): boolean {
    const signedIn = new Set(["SID", "SAPISID", "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID"]);
    return cookieNames.some((name) => signedIn.has(name));
  },

  rpc: {
    listNotebooks: "wXbhsf",
    createNotebook: "CCqFvf",
    addSource: "izAoDd",
    createArtifact: "R7cb6c",
    listArtifacts: "gArtLc",
    deleteNotebook: "WWINqb",
  } as Record<string, NotebookRPC>,

  // MARK: Requête

  /** Le bloc d'options que toutes les requêtes d'écriture portent. */
  options(): unknown[] {
    return [2, null, null, [1, null, null, null, null, null, null, null, null, null, [1]]];
  },

  createNotebookParams(title: string): unknown[] {
    return [title, null, null, NotebookLMWire.options()];
  },

  /** Un texte comme source (les fichiers Markdown de `NotebookExport`). */
  addTextSourceParams(notebookID: string, title: string, text: string): unknown[] {
    return [[[null, [title, text], null, 2, null, null, null, null, null, null, 1]], notebookID, NotebookLMWire.options()];
  },

  /** Le résumé audio (« podcast ») : les sources, la consigne, la langue, le format. */
  createAudioParams(notebookID: string, sourceIDs: string[], instructions: string,
                    language: string, format: AudioFormat, length: AudioLength): unknown[] {
    const triple: unknown[] = sourceIDs.map((id) => [[id]]);
    const double: unknown[] = sourceIDs.map((id) => [id]);
    const config: unknown[] = [null, [instructions, length, null, double, language, null, format]];
    const descriptor: unknown[] = [null, null, 1, triple];
    while (descriptor.length < 6) descriptor.push(null);
    descriptor.push(config);
    return [NotebookLMWire.options(), notebookID, descriptor];
  },

  listArtifactsParams(notebookID: string): unknown[] {
    return [[2], notebookID, 'NOT artifact.status = "ARTIFACT_STATUS_SUGGESTED"'];
  },

  deleteNotebookParams(notebookID: string): unknown[] {
    return [[notebookID], [2]];
  },

  /** `f.req=` + `at=` : le corps d'une requête (le jeton `at` vient de la page). */
  body(rpc: NotebookRPC, params: unknown[], token: string): string {
    const inner: unknown[] = [rpc, json(params), null, "generic"];
    return `f.req=${percentEncode(json([inner]))}&at=${percentEncode(token)}&`;
  },

  /** L'adresse d'un appel (les « / » d'un chemin restent lisibles, comme URLComponents). */
  url(host: string, rpc: NotebookRPC, sourcePath: string, session: string, language = "fr"): URL | null {
    const query = [
      ["rpcids", rpc],
      ["source-path", sourcePath],
      ["f.sid", session],
      ["hl", language],
      ["rt", "c"],
    ].map(([name, value]) => `${name}=${queryEncode(value)}`).join("&");
    return makeURL(`${host}/_/LabsTailwindUi/data/batchexecute?${query}`);
  },

  // MARK: Réponse

  /**
   * Le résultat d'un appel : la réponse est `)]}'`, puis des blocs `<longueur>\n<json>` ;
   * celui qui porte `wrb.fr` et notre code a le résultat, en texte JSON, à l'indice 2.
   */
  result(of: string, rpc: NotebookRPC): unknown {
    let text = of;
    if (text.startsWith(")]}'")) text = text.slice(4);
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "");
      if (!trimmed.startsWith("[")) continue;
      let blocks: unknown;
      try { blocks = JSON.parse(trimmed); } catch { continue; }
      if (!Array.isArray(blocks)) continue;
      for (const block of blocks) {
        if (!Array.isArray(block) || block.length < 3) continue;
        if (block[0] !== "wrb.fr" || block[1] !== rpc) continue;
        const payload = block[2];
        if (typeof payload === "string") {
          try { return JSON.parse(payload); } catch { return null; }
        }
        // Pas de résultat : un code d'erreur à l'indice 5.
        if (block.length > 5 && Array.isArray(block[5]) && typeof block[5][0] === "number") {
          throw NotebookParseError.refused(block[5][0]);
        }
        return null;
      }
    }
    throw NotebookParseError.notAnswer();
  },

  // MARK: Lire les formes

  /** Les jetons de la page du site : `"SNlM0e":"…"` (jeton `at`) et `"FdrFJe":"…"` (session). */
  field(key: string, inPage: string): string | null {
    const escaped = escapeRegExp(key);
    const patterns = [
      `"${escaped}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"`,
      `&quot;${escaped}&quot;\\s*:\\s*&quot;((?:(?!&quot;).)*)&quot;`,
    ];
    for (const pattern of patterns) {
      const match = new RegExp(pattern).exec(inPage);
      if (match === null || match[1] === undefined) continue;
      const value = match[1].replace(/\\u003d/g, "=").replace(/\\\//g, "/");
      if (value !== "") return value;
    }
    return null;
  },

  /** Le premier identifiant (UUID) trouvé dans une réponse. */
  firstID(value: unknown): string | null {
    return NotebookLMWire.ids(value)[0] ?? null;
  },

  ids(value: unknown): string[] {
    const out: string[] = [];
    const walk = (node: unknown): void => {
      if (typeof node === "string") {
        if (isUUID(node)) out.push(node);
      } else if (Array.isArray(node)) {
        node.forEach(walk);
      }
    };
    walk(value);
    return out;
  },

  /** L'identifiant d'un carnet dans son adresse : `…/notebook/<uuid>`. */
  notebookID(fromURL: string): string | null {
    const url = makeURL(fromURL);
    if (!url) return null;
    const parts = url.pathname.split("/").filter((p) => p !== "");
    const index = parts.indexOf("notebook");
    if (index < 0 || index + 1 >= parts.length) return null;
    return isUUID(parts[index + 1]) ? parts[index + 1] : null;
  },

  notebookURL(id: string, host: string = hosts[0]): string {
    return `${host}/notebook/${id}`;
  },

  /** Les lignes d'une réponse `gArtLc` : `[[ [id, titre, type, …, état, …, [… audio …]], … ]]`. */
  artifacts(from: unknown): NotebookArtifact[] {
    let rows: unknown[];
    if (Array.isArray(from)) rows = from; else return [];
    // Enveloppé (`[[ligne, ligne]]`) ou déjà à plat.
    const first = rows[0];
    if (Array.isArray(first) && Array.isArray(first[0])) rows = first;
    const result: NotebookArtifact[] = [];
    for (const item of rows) {
      if (!Array.isArray(item) || item.length <= 4 || typeof item[0] !== "string") continue;
      const rawState = item[4];
      const state: ArtifactState = rawState === 3 ? "ready" : rawState === 4 ? "failed" : rawState === 2 ? "working" : "waiting";
      result.push({
        id: item[0],
        title: typeof item[1] === "string" ? item[1] : "",
        type: typeof item[2] === "number" ? item[2] : 0,
        state,
        audioURL: audioURL(item),
      });
    }
    return result;
  },

  /** La consigne du podcast : en français, centrée sur les liens et les prérequis. */
  podcastInstructions(courseName: string): string {
    return `Un podcast en français pour réviser « ${courseName} ». Concentre-toi sur les liens entre les notions et sur ce qu'il faut comprendre avant chaque résultat. Explique d'abord l'intuition, puis l'énoncé ; signale les pièges et les confusions fréquentes.`;
  },
};

/** `row[6][5]` : la liste des médias, `[url, …, "audio/mp4"]` ; on préfère `audio/mp4`. */
function audioURL(row: unknown[]): URL | null {
  if (row.length <= 6) return null;
  const block = row[6];
  if (!Array.isArray(block) || block.length <= 5 || !Array.isArray(block[5])) return null;
  let fallback: URL | null = null;
  for (const item of block[5]) {
    if (!Array.isArray(item) || typeof item[0] !== "string" || !item[0].startsWith("http")) continue;
    const url = makeURL(item[0]);
    if (!url) continue;
    if (fallback === null) fallback = url;
    if (item.length > 2 && item[2] === "audio/mp4") return url;
  }
  return fallback;
}

function isUUID(text: string): boolean {
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(text);
}

function json(value: unknown): string {
  return JSON.stringify(value);
}

/** `addingPercentEncoding(withAllowedCharacters: alphanumerics + "-._~")`. */
function percentEncode(text: string): string {
  let out = "";
  for (const byte of new TextEncoder().encode(text)) {
    const char = String.fromCharCode(byte);
    if (/[A-Za-z0-9\-._~]/.test(char)) out += char;
    else out += "%" + byte.toString(16).toUpperCase().padStart(2, "0");
  }
  return out;
}

/** Une valeur de requête : garde le « / » d'un chemin, encode le reste. */
function queryEncode(text: string): string {
  let out = "";
  for (const byte of new TextEncoder().encode(text)) {
    const char = String.fromCharCode(byte);
    if (/[A-Za-z0-9\-._~/:@!$'()*+,;?]/.test(char)) out += char;
    else out += "%" + byte.toString(16).toUpperCase().padStart(2, "0");
  }
  return out;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
