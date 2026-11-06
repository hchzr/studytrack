// Port de Polymestre/Domain/ClaudeTutor.swift : Claude dans le mode étude,
// **avec l'abonnement Claude** (pas une clé d'API). Ici, ce qui est pur : les
// arguments de `claude`, le message à envoyer, la lecture du flux, la consigne
// du tuteur et la mise en page des réponses (`RichMarkup`).

import { isLetter } from "../models/util.ts";
import { trimWhitespaces, trimWhitespacesAndNewlines } from "./textRepair.ts";
import { TutorFramework, contextClose, contextOpen, type TutorOrigin } from "./tutorFramework.ts";
import { Features, SeriesReview } from "./seriesReview.ts";

export type ClaudeProfile = "isolated" | "project";

export interface ClaudeLaunch {
  profile?: ClaudeProfile;
  /** L'identifiant de la session Claude Code (un UUID). */
  sessionID: string;
  /** La session existe déjà : on la reprend (`--resume`). */
  resume?: boolean;
  systemPrompt: string;
  mcpConfigPath?: string | null;
  allowedTools?: string[];
  /** Projet : les outils chargés (`--tools`). */
  tools?: string[];
  deniedServers?: string[];
  model?: string | null;
}

export interface ClaudeAttachment {
  kind: { type: "pdf" } | { type: "image"; mime: string };
  data: Uint8Array;
  name: string;
  /** Un cahier de tes notes : seules les pages non vues en partent. */
  notebookPath?: string | null;
  /** Ce que c'est, dit à Claude dans l'état du message. */
  origin?: TutorOrigin | null;
}

export interface MCPServerInfo {
  name: string;
  status: string;
}

export interface ClaudeSessionInfoInit {
  sessionID: string;
  model: string;
  permissionMode: string;
  mcpServers?: MCPServerInfo[];
  skills?: string[];
  tools?: string[];
}

export class ClaudeSessionInfo {
  sessionID: string;
  model: string;
  permissionMode: string;
  mcpServers: MCPServerInfo[];
  skills: string[];
  tools: string[];

  constructor(o: ClaudeSessionInfoInit) {
    this.sessionID = o.sessionID;
    this.model = o.model;
    this.permissionMode = o.permissionMode;
    this.mcpServers = o.mcpServers ?? [];
    this.skills = o.skills ?? [];
    this.tools = o.tools ?? [];
  }

  /** La compétence est-elle chargée (« epfl-serie », ou « …:epfl-serie ») ? */
  hasSkill(name: string): boolean {
    return this.skills.some((skill) => skill === name || skill.endsWith(":" + name));
  }
}

export type ClaudeEvent =
  | { kind: "started"; info: ClaudeSessionInfo }
  | { kind: "text"; text: string }
  | { kind: "thinking" }
  | { kind: "tool"; name: string }
  | { kind: "finished"; error: string | null; contextTokens?: number }
  | { kind: "usage"; value: number };

export interface HistoryMessage {
  fromStudent: boolean;
  text: string;
  exercise?: string | null;
}

export interface ClaudeContext {
  courseCode?: string | null;
  courseName?: string | null;
  exercise?: string | null;
  statement?: string | null;
  questions?: string[];
  doneQuestions?: number;
  correction?: string | null;
  hint?: string | null;
}

export interface SeriesContext {
  courseCode?: string | null;
  courseName?: string | null;
  title: string;
  week?: number | null;
  due?: string | null;
  exercises?: { number: string; title?: string; status: string }[];
  pdfAttached?: boolean;
}

export interface ClaudeVerdict {
  exercise: string;
  result: "correct" | "partial" | "wrong";
}

export const ClaudeTutor = {
  contextOpen,
  contextClose,

  /** Les arguments de `claude` pour une conversation de tuteur. */
  arguments(launch: ClaudeLaunch): string[] {
    const args = [
      "-p",
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--verbose",
      "--include-partial-messages",
    ];
    args.push(...(launch.resume ? ["--resume", launch.sessionID] : ["--session-id", launch.sessionID]));
    const profile: ClaudeProfile = launch.profile ?? "isolated";
    if (profile === "isolated") {
      args.push("--tools", "",
        "--safe-mode",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--setting-sources", "",
        "--system-prompt", launch.systemPrompt);
    } else {
      // Les réglages de l'utilisateur·rice se chargent : ce sont eux qui apportent
      // les connecteurs de son compte claude.ai. Ses serveurs locaux sont écartés.
      if ((launch.deniedServers ?? []).length !== 0) {
        const denied = (launch.deniedServers ?? []).map((name) => ({ serverName: name }));
        args.push("--settings", canonicalJSON({ deniedMcpServers: denied }));
      }
      if (launch.mcpConfigPath !== undefined && launch.mcpConfigPath !== null) {
        args.push("--mcp-config", launch.mcpConfigPath);
      }
      // Ni terminal ni web : lire, lancer une compétence, et l'écriture permise.
      const tools = launch.tools ?? ["Read", "Glob", "Skill"];
      args.push("--tools", tools.join(","));
      if ((launch.allowedTools ?? []).length !== 0) args.push("--allowedTools", (launch.allowedTools ?? []).join(","));
      args.push("--permission-mode", "default");
      args.push("--append-system-prompt", launch.systemPrompt);
    }
    if (launch.model !== undefined && launch.model !== null && launch.model !== "") args.push("--model", launch.model);
    return args;
  },

  /** L'identifiant de session d'une série : toujours le même pour une série, un profil et une génération. */
  sessionID(seriesID: string, profile: ClaudeProfile, generation = 0): string {
    const seed = `studytrack.claude.series:${seriesID.toUpperCase()}:${profile}:${generation}`;
    const bytes = Array.from(sha256(new TextEncoder().encode(seed)).slice(0, 16));
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = bytes.map((byte) => byte.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  },

  /** Que faire quand `claude` s'arrête d'emblée sur une session. */
  sessionRecovery(stderr: string): "startFresh" | "resume" | null {
    const text = stderr.toLowerCase();
    if (text.includes("no conversation found") || text.includes("session not found")) return "startFresh";
    if (text.includes("already in use") || text.includes("already exists")) return "resume";
    return null;
  },

  /** Le dossier où Claude Code range les sessions : tout ce qui n'est ni lettre ni chiffre devient « - ». */
  sessionFolderName(workingDirectory: string): string {
    return Array.from(workingDirectory).map((char) => {
      const code = char.codePointAt(0) ?? 0;
      const ascii = code <= 0x7f;
      return ascii && (/[A-Za-z]/.test(char) || /[0-9]/.test(char)) ? char : "-";
    }).join("");
  },

  /** Où chercher `claude` : une app ne voit pas le `PATH` du terminal. */
  candidatePaths(home: string): string[] {
    return [
      home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude", home + "/.npm-global/bin/claude", home + "/.bun/bin/claude",
    ];
  },

  // MARK: Envoyer

  /** La ligne JSON d'un message de l'étudiant·e (`--input-format stream-json`). */
  userLine(text: string, attachments: ClaudeAttachment[] = []): string {
    const content: Record<string, unknown>[] = attachments.map((attachment) => {
      if (attachment.kind.type === "pdf") {
        return {
          type: "document", title: attachment.name,
          source: { type: "base64", media_type: "application/pdf", data: bytesToBase64(attachment.data) },
        };
      }
      return {
        type: "image",
        source: { type: "base64", media_type: attachment.kind.mime, data: bytesToBase64(attachment.data) },
      };
    });
    content.push({ type: "text", text });
    return JSON.stringify({ type: "user", message: { role: "user", content } });
  },

  // MARK: Lire

  /** Une ligne de la sortie de `claude` → ce qu'elle dit, ou `null` (bruit). */
  parse(line: string): ClaudeEvent | null {
    let object: unknown;
    try { object = JSON.parse(line); } catch { return null; }
    if (object === null || typeof object !== "object" || Array.isArray(object)) return null;
    const root = object as Record<string, unknown>;
    const type = root["type"];
    if (typeof type !== "string") return null;
    switch (type) {
      case "system": {
        if (root["subtype"] !== "init" || typeof root["session_id"] !== "string") return null;
        const servers: MCPServerInfo[] = [];
        if (Array.isArray(root["mcp_servers"])) {
          for (const value of root["mcp_servers"] as unknown[]) {
            if (value === null || typeof value !== "object") continue;
            const server = value as Record<string, unknown>;
            if (typeof server["name"] !== "string") continue;
            servers.push({ name: server["name"], status: typeof server["status"] === "string" ? server["status"] : "" });
          }
        }
        return {
          kind: "started",
          info: new ClaudeSessionInfo({
            sessionID: root["session_id"],
            model: typeof root["model"] === "string" ? root["model"] : "",
            permissionMode: typeof root["permissionMode"] === "string" ? root["permissionMode"] : "",
            mcpServers: servers,
            skills: stringArray(root["skills"]),
            tools: stringArray(root["tools"]),
          }),
        };
      }
      case "stream_event": {
        const event = root["event"];
        if (event === null || typeof event !== "object" || Array.isArray(event)) return null;
        const stream = event as Record<string, unknown>;
        if (stream["type"] === "content_block_delta") {
          const delta = stream["delta"];
          if (delta !== null && typeof delta === "object" && !Array.isArray(delta)) {
            const d = delta as Record<string, unknown>;
            if (d["type"] === "text_delta" && typeof d["text"] === "string") return { kind: "text", text: d["text"] };
            if (d["type"] === "thinking_delta") return { kind: "thinking" };
          }
        }
        if (stream["type"] === "content_block_start") {
          const block = stream["content_block"];
          if (block !== null && typeof block === "object" && !Array.isArray(block)) {
            const b = block as Record<string, unknown>;
            if (b["type"] === "thinking") return { kind: "thinking" };
            if (b["type"] === "tool_use" && typeof b["name"] === "string") return { kind: "tool", name: b["name"] };
          }
        }
        return null;
      }
      case "result": {
        let tokens: number | undefined;
        const usage = root["usage"];
        if (usage !== null && typeof usage === "object" && !Array.isArray(usage)) {
          const u = usage as Record<string, unknown>;
          const parts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .map((key) => u[key]).filter((value): value is number => typeof value === "number");
          tokens = parts.length === 0 ? undefined : parts.reduce((sum, value) => sum + value, 0);
        }
        const subtype = root["subtype"];
        const failed = root["is_error"] === true || (typeof subtype === "string" && subtype !== "success");
        if (!failed) return tokens === undefined ? { kind: "finished", error: null } : { kind: "finished", error: null, contextTokens: tokens };
        const message = typeof root["result"] === "string" ? root["result"]
          : typeof root["error"] === "string" ? root["error"]
            : typeof subtype === "string" ? subtype : "erreur";
        return tokens === undefined ? { kind: "finished", error: message } : { kind: "finished", error: message, contextTokens: tokens };
      }
      case "rate_limit_event": {
        const info = root["rate_limit_info"];
        if (info === null || typeof info !== "object") return null;
        const windows = (info as Record<string, unknown>)["unifiedWindows"];
        if (windows === null || typeof windows !== "object") return null;
        const five = (windows as Record<string, unknown>)["five_hour"];
        if (five === null || typeof five !== "object") return null;
        const utilization = (five as Record<string, unknown>)["utilization"];
        return typeof utilization === "number" ? { kind: "usage", value: utilization } : null;
      }
      default:
        return null;
    }
  },

  /** Un outil, dit simplement (« mcp__notion__notion-search » → « Notion »). */
  toolLabel(name: string): string {
    if (name === "Skill") return "compétence";
    if (name === "Read") return "lecture";
    if (name.startsWith("mcp__")) {
      const server = name.slice(5).split("_")[0] || name;
      return server === "polymestre" ? "Polymestre" : server.slice(0, 1).toUpperCase() + server.slice(1);
    }
    return name;
  },

  // MARK: Reprendre l'affichage

  /** Le fichier d'une session Claude Code → les messages à réafficher. */
  history(jsonl: string): HistoryMessage[] {
    const result: HistoryMessage[] = [];
    for (const line of jsonl.split("\n")) {
      if (line === "") continue;
      let object: unknown;
      try { object = JSON.parse(line); } catch { continue; }
      if (object === null || typeof object !== "object" || Array.isArray(object)) continue;
      const root = object as Record<string, unknown>;
      const type = root["type"];
      if (type !== "user" && type !== "assistant") continue;
      if (root["isMeta"] === true || root["isSidechain"] === true) continue;
      const message = root["message"];
      if (message === null || typeof message !== "object" || Array.isArray(message)) continue;
      const content = (message as Record<string, unknown>)["content"];
      let text = "";
      let exercise: string | null = null;
      if (typeof content === "string") {
        text = content;
      } else if (Array.isArray(content)) {
        text = content
          .filter((part): part is Record<string, unknown> => part !== null && typeof part === "object" && !Array.isArray(part))
          .filter((part) => part["type"] === "text" && typeof part["text"] === "string")
          .map((part) => part["text"] as string)
          .join("\n");
      }
      if (type === "user") {
        if (text.includes("<command-name>")) {
          // Une compétence lancée : « <command-message>…<command-name>/epfl-serie … ».
          const between = (open: string, close: string): string => {
            const after = text.split(open).slice(1)[0];
            return after === undefined ? "" : after.split(close)[0];
          };
          const name = between("<command-name>", "</command-name>");
          const question = ClaudeTutor.displayText(between("<command-args>", "</command-args>"));
          text = question === "" ? name : name + " " + question;
        } else if (text.startsWith("<")) {
          continue;
        }
        exercise = TutorFramework.exercise(text);
        text = ClaudeTutor.displayText(text);
      }
      text = trimWhitespacesAndNewlines(text);
      if (text === "") continue;
      const fromStudent = type === "user";
      // Une réponse en plusieurs morceaux (texte, outil, texte) : un seul message.
      const last = result[result.length - 1];
      if (last !== undefined && last.fromStudent === fromStudent && !fromStudent) {
        last.text += "\n\n" + text;
      } else {
        result.push({ fromStudent, text, exercise });
      }
    }
    return result;
  },

  // MARK: La consigne

  /** Le tuteur : socratique d'abord, la solution seulement si on la demande. */
  systemPrompt(mode: "tutor" | "explain", features: Features = new Features()): string {
    const body = systemPromptBody(mode);
    if (!features.hints) return body;
    return body + "\n\n" + SeriesReview.hintInstruction;
  },

  /** Le contexte d'un exercice, avant la question. */
  contextPreamble(context: ClaudeContext): string {
    const lines: string[] = [];
    if (context.courseCode !== undefined && context.courseCode !== null) {
      lines.push(`Cours : ${context.courseCode}${context.courseName !== undefined && context.courseName !== null ? " — " + context.courseName : ""}`);
    }
    if (context.exercise !== undefined && context.exercise !== null) lines.push("Exercice : " + context.exercise);
    if (context.statement !== undefined && context.statement !== null && context.statement !== "") lines.push("Énoncé : " + context.statement);
    if ((context.questions ?? []).length !== 0) {
      lines.push(`Questions (${context.doneQuestions ?? 0}/${(context.questions ?? []).length} faites) :`);
      lines.push(...(context.questions ?? []).map((question) => "- " + question));
    }
    if (context.hint !== undefined && context.hint !== null && context.hint !== "") lines.push("Indication de l'énoncé : " + context.hint);
    if (context.correction !== undefined && context.correction !== null) lines.push("Correction déjà notée : " + context.correction);
    return lines.length === 0 ? "" : wrap(lines);
  },

  /** Une série : ce que Claude sait au début de la conversation. */
  seriesPreamble(series: SeriesContext): string {
    const lines: string[] = [];
    if (series.courseCode !== undefined && series.courseCode !== null) {
      lines.push(`Cours : ${series.courseCode}${series.courseName !== undefined && series.courseName !== null ? " — " + series.courseName : ""}`);
    }
    lines.push(`Série : ${series.title}${series.week !== undefined && series.week !== null ? ` (semaine ${series.week})` : ""}`);
    if (series.due !== undefined && series.due !== null) lines.push("À rendre : " + series.due);
    if (series.pdfAttached === true) lines.push("L'énoncé complet est le PDF joint.");
    if ((series.exercises ?? []).length !== 0) {
      lines.push("Exercices :");
      lines.push(...(series.exercises ?? []).map((exercise) =>
        `- ${exercise.number}${(exercise.title ?? "") === "" ? "" : " — " + exercise.title} : ${exercise.status}`));
    }
    return wrap(lines);
  },

  /** Le premier message de la conversation d'une série. */
  openingMessage(series: SeriesContext, exercise: ClaudeContext | null, skill: string | null): string {
    const intro = `On attaque « ${series.title} »${series.courseCode !== undefined && series.courseCode !== null ? ` (${series.courseCode})` : ""}.`;
    const context = ClaudeTutor.seriesPreamble(series) + (exercise !== null ? ClaudeTutor.contextPreamble(exercise) : "");
    if (skill !== null) return `/${skill} ${intro}\n\n` + context;
    return context + intro;
  },

  /** Quand on change d'exercice dans la même conversation. */
  exerciseSwitch(context: ClaudeContext): string {
    const preamble = ClaudeTutor.contextPreamble(context);
    if (preamble === "") return "";
    return preamble.split(contextOpen + "\n").join(contextOpen + "\nOn passe à un autre exercice.\n");
  },

  /** Ce que l'étudiant·e a écrit, sans le contexte ajouté par l'app. */
  displayText(sent: string): string {
    // Les conversations d'avant le changement de nom portent « [StudyTrack] ».
    let text = sent.split("[StudyTrack]").join(contextOpen).split("[/StudyTrack]").join(contextClose);
    for (;;) {
      const open = text.indexOf(contextOpen);
      if (open < 0) break;
      const close = text.indexOf(contextClose, open + contextOpen.length);
      if (close < 0) break;
      text = text.slice(0, open) + text.slice(close + contextClose.length);
    }
    return text.replace(/\n{3,}/g, "\n\n").replace(/^\s+|\s+$/g, "");
  },

  // MARK: Post-mortem et rapport

  verdictFence: "polymestre",

  verdictInstruction: `Termine par un bloc de code \`\`\`polymestre avec une ligne par exercice corrigé, au format « numéro : juste », « numéro : moyen » ou « numéro : faux » (par exemple « 2 : faux »). Polymestre le propose à l'étudiant·e, qui confirme avant que rien ne soit noté.`,

  /** « Post-mortem de la série » (quand la série est finie). */
  postMortemPrompt(useSkill: boolean, features: Features = new Features()): string {
    return (useSkill
      ? "Post-mortem de la série, comme le prévoit epfl-serie : compare ce que j'ai fait à la correction, exercice par exercice, et remplis le carnet d'erreurs. "
      : "Post-mortem de la série : compare ce que j'ai fait au corrigé, exercice par exercice, et dis où je me suis trompé, avec le type de chaque erreur et la bonne démarche. ")
      + SeriesReview.instruction(features);
  },

  /** « Rapport » : les erreurs et ce qu'il faut revoir. */
  reportPrompt: `Fais-moi le rapport de la série : mes erreurs, regroupées par type, les notions à revoir (avec où les revoir dans le cours), et les exercices à refaire. Court, en listes.`,

  /** Les verdicts du bloc ```polymestre d'une réponse. */
  verdicts(inText: string): ClaudeVerdict[] {
    const block = verdictBlock(inText);
    if (block === null) return [];
    const result: ClaudeVerdict[] = [];
    for (const line of block.text.split("\n")) {
      const parts = splitFirst(line, ":").map((part) => trimWhitespaces(part));
      if (parts.length !== 2 || parts[0] === "") continue;
      const word = parts[1].toLowerCase().normalize("NFD").replace(/\p{M}/gu, "");
      let value: ClaudeVerdict["result"];
      if (word.startsWith("juste") || word.startsWith("correct")) value = "correct";
      else if (word.startsWith("moy") || word.startsWith("partiel")) value = "partial";
      else if (word.startsWith("faux") || word.startsWith("fausse")) value = "wrong";
      else continue;
      let number = parts[0];
      for (const prefix of ["exercice", "ex.", "ex"]) {
        if (number.toLowerCase().startsWith(prefix)) {
          number = trimWhitespaces(number.slice(prefix.length));
          break;
        }
      }
      result.push({ exercise: number, result: value });
    }
    return result;
  },

  /** La réponse sans son bloc de verdicts (il s'affiche en carte à part). */
  withoutVerdicts(text: string): string {
    const block = verdictBlock(text);
    if (block === null) return text;
    return trimWhitespacesAndNewlines(text.slice(0, block.start) + text.slice(block.end));
  },

  /** L'exercice que désigne un verdict (« 2 », « 1.3 », « Ex 2 ») parmi les numéros de la série. */
  matchExercise(label: string, numbers: string[]): number | null {
    const key = (text: string): string => {
      const folded = Array.from(text.toLowerCase())
        .filter((char) => /\p{N}/u.test(char) || char === "." || isLetter(char))
        .join("")
        .split("exercice").join("")
        .replace(/^\.+|\.+$/g, "");
      return folded;
    };
    const wanted = key(label);
    if (wanted === "") return null;
    const exact = numbers.map((_, index) => index).filter((index) => key(numbers[index]) === wanted);
    if (exact.length === 1) return exact[0];
    // « 3 » pour « Ex-03-03 » : le dernier nombre.
    const wantedNumber = integerString(wanted);
    const tail = numbers.map((_, index) => index).filter((index) => {
      const parts = numbers[index].split(/[^0-9]+/).filter((part) => part !== "");
      const last = parts[parts.length - 1];
      const value = last === undefined ? -1 : (integerString(last) ?? -1);
      return value === (wantedNumber ?? -2);
    });
    return tail.length === 1 ? tail[0] : null;
  },

  quickActions: {
    hint: { label: "Un indice", icon: "lightbulb", prompt: "Donne-moi un indice pour avancer, sans la solution." },
    check: { label: "Vérifie-moi", icon: "checkmark.circle", prompt: "Voici où j'en suis. Vérifie mon raisonnement et dis-moi où est la première erreur, s'il y en a une." },
    explain: { label: "La notion", icon: "book", prompt: "Explique-moi la notion clé derrière cet exercice, avec un exemple simple." },
    nextStep: { label: "Étape suivante", icon: "arrow.right.circle", prompt: "Quelle est l'étape suivante ? Seulement celle-là." },
    solution: { label: "La solution", icon: "eye", prompt: "Donne-moi la solution complète et rédigée, puis les points où on se trompe souvent." },
  } as Record<string, { label: string; icon: string; prompt: string }>,
};

function systemPromptBody(mode: "tutor" | "explain"): string {
  const common = `Tu es le tuteur d'un·e étudiant·e de première année à l'EPFL, dans l'app Polymestre, en mode étude. Réponds en français, tutoie. Écris les mathématiques en LaTeX léger entre dollars ($x_n = \\frac{1}{n}$, $\\sum_{k=1}^n k$) ; une formule importante seule sur sa ligne entre $$…$$. Utilise le Markdown simple : paragraphes courts, listes, **gras** pour l'idée clé. La conversation couvre toute une série d'exercices ; l'app ajoute le contexte entre [Polymestre] et [/Polymestre] (la série, l'exercice, ce qui a déjà été donné, les pièces jointes). Appuie-toi dessus et sur le PDF de la série, et dis-le si une information te manque plutôt que de l'inventer.`;
  return common + "\n\n" + TutorFramework.contract + "\n\n" + (mode === "tutor" ? TutorFramework.tutor : TutorFramework.explain);
}

function wrap(lines: string[]): string {
  return [contextOpen, ...lines, contextClose].join("\n") + "\n\n";
}

function stringArray(value: unknown): string[] {
  // `as? [String]` : une liste mixte ne se convertit pas du tout (liste vide).
  return Array.isArray(value) && value.every((item) => typeof item === "string") ? value as string[] : [];
}

/** `components(separatedBy:).first` et le reste : `split(separator: ":", maxSplits: 1)`. */
function splitFirst(text: string, separator: string): string[] {
  const at = text.indexOf(separator);
  return at < 0 ? [text] : [text.slice(0, at), text.slice(at + separator.length)];
}

/** `Int(text)` : `null` si ce n'est pas un entier. */
function integerString(text: string): number | null {
  return /^[+-]?\d+$/.test(text) ? Number(text) : null;
}

function verdictBlock(original: string): { start: number; end: number; text: string } | null {
  // ```studytrack (avant le changement de nom) se lit comme ```polymestre — même longueur.
  const text = original.split("```studytrack").join("```" + ClaudeTutor.verdictFence);
  const open = text.indexOf("```" + ClaudeTutor.verdictFence);
  if (open < 0) return null;
  const afterOpen = open + 3 + ClaudeTutor.verdictFence.length;
  const close = text.indexOf("```", afterOpen);
  const inner = text.slice(afterOpen, close < 0 ? text.length : close);
  return { start: open, end: close < 0 ? text.length : close + 3, text: inner };
}

// MARK: - Mise en page des réponses

export type RichBlock =
  | { kind: "heading"; text: string; level: number }
  | { kind: "paragraph"; text: string }
  | { kind: "bullet"; text: string; depth: number }
  | { kind: "numbered"; text: string; number: number }
  | { kind: "math"; text: string }
  | { kind: "code"; text: string }
  | { kind: "rule" };

export type RichInline =
  | { kind: "text"; text: string }
  | { kind: "bold"; text: string }
  | { kind: "italic"; text: string }
  | { kind: "code"; text: string }
  | { kind: "math"; text: string }
  | { kind: "link"; text: string; url: string };

export const RichMarkup = {
  blocks(text: string): RichBlock[] {
    const source = RichMarkup.isolatingDisplayMath(text);
    const result: RichBlock[] = [];
    let paragraph: string[] = [];
    let code: string[] | null = null;
    let math: string[] | null = null;

    const flush = (): void => {
      const joined = trimWhitespaces(paragraph.join(" "));
      if (joined !== "") result.push({ kind: "paragraph", text: joined });
      paragraph = [];
    };

    for (const rawLine of source.split("\n")) {
      const line = trimWhitespaces(rawLine);
      if (code !== null) {
        if (line.startsWith("```")) {
          result.push({ kind: "code", text: code.join("\n") });
          code = null;
        } else {
          code.push(rawLine);
        }
        continue;
      }
      if (math !== null) {
        if (line.endsWith("$$") || line.endsWith("\\]")) {
          const last = line.split("$$").join("").split("\\]").join("");
          if (last !== "") math.push(last);
          result.push({ kind: "math", text: math.join(" ") });
          math = null;
        } else {
          math.push(line);
        }
        continue;
      }
      if (line.startsWith("```")) { flush(); code = []; continue; }
      if (line.startsWith("$$") || line.startsWith("\\[")) {
        flush();
        const inner = line.slice(2);
        if ((inner.endsWith("$$") || inner.endsWith("\\]")) && inner.length >= 2) {
          result.push({ kind: "math", text: trimWhitespaces(inner.slice(0, -2)) });
        } else {
          math = inner === "" ? [] : [inner];
        }
        continue;
      }
      if (line === "") { flush(); continue; }
      if (line === "---" || line === "***") { flush(); result.push({ kind: "rule" }); continue; }
      if (line.startsWith("#")) {
        const level = line.length - line.replace(/^#+/, "").length;
        if (level <= 6 && line.slice(level, level + 1) === " ") {
          flush();
          result.push({ kind: "heading", text: line.slice(level + 1), level });
          continue;
        }
      }
      if (line.startsWith("- ") || line.startsWith("* ") || line.startsWith("• ")) {
        flush();
        const indent = rawLine.length - rawLine.replace(/^ +/, "").length;
        result.push({ kind: "bullet", text: line.slice(2), depth: indent >= 2 ? 1 : 0 });
        continue;
      }
      const dot = Array.from(line).findIndex((char) => char === "." || char === ")");
      if (dot >= 0) {
        const chars = Array.from(line);
        const number = integerString(chars.slice(0, dot).join(""));
        if (number !== null && chars[dot + 1] === " ") {
          flush();
          result.push({ kind: "numbered", text: chars.slice(dot + 2).join(""), number });
          continue;
        }
      }
      paragraph.push(line);
    }
    flush();
    if (code !== null) result.push({ kind: "code", text: code.join("\n") });
    if (math !== null) result.push({ kind: "math", text: math.join(" ") });
    return result;
  },

  /**
   * Une formule isolée au milieu d'une ligne, ou un environnement `\begin{align}`
   * hors de tout délimiteur, passe sur sa propre ligne, entre `$$`.
   */
  isolatingDisplayMath(text: string): string {
    if (!text.includes("\\[") && !text.includes("$$") && !text.includes("\\begin{")) return text;
    const chars = Array.from(text);
    let out = "";
    let i = 0;
    let inCode = false;
    let lineStart = true;
    const starts = (marker: string, at: number): boolean => {
      const m = Array.from(marker);
      if (at + m.length > chars.length) return false;
      return m.every((char, index) => chars[at + index] === char);
    };
    const find = (marker: string, from: number): number | null => {
      for (let j = from; j < chars.length; j++) if (starts(marker, j)) return j;
      return null;
    };
    const emit = (formula: string): void => {
      const flat = trimWhitespaces(formula.split(/\r?\n/).map((line) => trimWhitespaces(line)).join(" "));
      if (flat === "") return;
      while (out.endsWith(" ")) out = out.slice(0, -1);
      if (out !== "" && !out.endsWith("\n")) out += "\n";
      out += "$$" + flat + "$$\n";
    };
    while (i < chars.length) {
      if (lineStart && starts("```", i)) inCode = !inCode;
      lineStart = chars[i] === "\n";
      if (inCode) { out += chars[i]; i += 1; continue; }
      if (chars[i] === "\\" && i + 1 < chars.length && chars[i + 1] === "$") { out += "\\$"; i += 2; continue; }
      if (starts("\\[", i) && (i === 0 || chars[i - 1] !== "\\")) {
        const end = find("\\]", i + 2);
        if (end !== null) {
          emit(chars.slice(i + 2, end).join(""));
          i = end + 2;
          while (i < chars.length && chars[i] === " ") i += 1;
          continue;
        }
      }
      if (starts("$$", i)) {
        const end = find("$$", i + 2);
        if (end !== null) {
          emit(chars.slice(i + 2, end).join(""));
          i = end + 2;
          while (i < chars.length && chars[i] === " ") i += 1;
          continue;
        }
      }
      if (starts("\\begin{", i)) {
        const close = find("}", i + 7);
        if (close !== null) {
          const name = chars.slice(i + 7, close).join("");
          const environments = ["equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*",
            "eqnarray", "eqnarray*", "displaymath", "flalign", "flalign*"];
          const end = find("\\end{" + name + "}", close);
          if (environments.includes(name) && end !== null) {
            emit(chars.slice(i, end + 6 + name.length).join(""));
            i = end + 6 + name.length;
            while (i < chars.length && chars[i] === " ") i += 1;
            continue;
          }
        }
      }
      out += chars[i];
      i += 1;
    }
    return out;
  },

  /** `Le **point** est $x_n$ et `code`` → morceaux. */
  inlines(text: string): RichInline[] {
    const result: RichInline[] = [];
    let buffer = "";
    const chars = Array.from(text);
    let i = 0;
    const flush = (): void => {
      if (buffer !== "") { result.push({ kind: "text", text: buffer }); buffer = ""; }
    };
    const closing = (marker: string, from: number): number | null => {
      const m = Array.from(marker);
      for (let j = from; j + m.length <= chars.length; j++) {
        if (m.every((char, index) => chars[j + index] === char)) return j;
      }
      return null;
    };
    while (i < chars.length) {
      const c = chars[i];
      if (c === "\\" && i + 1 < chars.length && chars[i + 1] === "$") { buffer += "$"; i += 2; continue; }
      if (c === "*" && i + 1 < chars.length && chars[i + 1] === "*") {
        const end = closing("**", i + 2);
        if (end !== null && end > i + 2) {
          flush();
          result.push({ kind: "bold", text: chars.slice(i + 2, end).join("") });
          i = end + 2;
          continue;
        }
      }
      if (c === "`") {
        const end = closing("`", i + 1);
        if (end !== null && end > i + 1) {
          flush();
          result.push({ kind: "code", text: chars.slice(i + 1, end).join("") });
          i = end + 1;
          continue;
        }
      }
      if (c === "$") {
        const end = closing("$", i + 1);
        if (end !== null && end > i + 1) {
          flush();
          result.push({ kind: "math", text: chars.slice(i + 1, end).join("") });
          i = end + 1;
          continue;
        }
      }
      if (c === "\\" && i + 1 < chars.length && chars[i + 1] === "(") {
        const end = closing("\\)", i + 2);
        if (end !== null) {
          flush();
          result.push({ kind: "math", text: chars.slice(i + 2, end).join("") });
          i = end + 2;
          continue;
        }
      }
      // [titre](https://…) : un lien, comme en Markdown.
      if (c === "[") {
        const close = closing("](", i + 1);
        if (close !== null && close > i + 1) {
          const end = closing(")", close + 2);
          if (end !== null && end > close + 2) {
            const url = chars.slice(close + 2, end).join("");
            // Toute adresse à schéma ou chemin.
            if ((url.startsWith("/") || /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(url)) && !url.includes(" ")) {
              flush();
              result.push({ kind: "link", text: chars.slice(i + 1, close).join(""), url });
              i = end + 1;
              continue;
            }
          }
        }
      }
      if ((c === "*" || c === "_") && i + 1 < chars.length && chars[i + 1] !== " ") {
        const end = closing(c, i + 1);
        if (end !== null && end > i + 1 && chars[end - 1] !== " ") {
          // `_` au milieu d'un mot (nom_de_variable) n'est pas de l'italique.
          if (c === "_" && i > 0 && isLetter(chars[i - 1])) { buffer += c; i += 1; continue; }
          flush();
          result.push({ kind: "italic", text: chars.slice(i + 1, end).join("") });
          i = end + 1;
          continue;
        }
      }
      buffer += c;
      i += 1;
    }
    flush();
    return result;
  },
};

// MARK: - Encodages (SHA-256 et base64), sans dépendre de Node

/** Un SHA-256 synchrone : `sessionID` doit rendre le même UUID sur toutes les plateformes. */
function sha256(data: Uint8Array): Uint8Array {
  const k = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]);
  const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const rotr = (x: number, n: number): number => (x >>> n) | (x << (32 - n));
  const bitLength = data.length * 8;
  const padded = new Uint8Array((((data.length + 9) + 63) >> 6) << 6);
  padded.set(data);
  padded[data.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor(bitLength / 0x100000000));
  view.setUint32(padded.length - 4, bitLength >>> 0);
  const w = new Uint32Array(64);
  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let t = 0; t < 16; t++) w[t] = view.getUint32(offset + t * 4);
    for (let t = 16; t < 64; t++) {
      const s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
      const s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) >>> 0;
    }
    let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (let t = 0; t < 64; t++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (hh + S1 + ch + k[t] + w[t]) >>> 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) >>> 0;
      hh = g; g = f; f = e; e = (d + temp1) >>> 0;
      d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0; h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0; h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
  }
  const out = new Uint8Array(32);
  const outView = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i]);
  return out;
}

function bytesToBase64(bytes: Uint8Array): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += alphabet[a >> 2];
    out += alphabet[((a & 3) << 4) | (b >> 4)];
    out += i + 1 < bytes.length ? alphabet[((b & 15) << 2) | (c >> 6)] : "=";
    out += i + 2 < bytes.length ? alphabet[c & 63] : "=";
  }
  return out;
}

/** `JSONSerialization` avec `.sortedKeys` (pour `--settings`). */
function canonicalJSON(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "number") return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(canonicalJSON).join(",") + "]";
  const object = value as Record<string, unknown>;
  return "{" + Object.keys(object).sort().map((key) => JSON.stringify(key) + ":" + canonicalJSON(object[key])).join(",") + "}";
}
