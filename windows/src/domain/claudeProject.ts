// Port de StudyTrack/Domain/ClaudeProject.swift : le « projet EPFL » de Claude
// Code — un dossier à soi, un CLAUDE.md qui dit où on en est, et seulement les
// serveurs MCP dont les compétences ont besoin. Ici, ce qui est pur.

import { ClaudeTutor } from "./claudeTutor.ts";
import { Features, SeriesReview } from "./seriesReview.ts";

export type CommandScope = "series" | "system";

export interface ClaudeServerInit {
  type?: string;
  url?: string | null;
  command?: string | null;
  args?: string[] | null;
}

export class ClaudeServer {
  type: string;
  url: string | null;
  command: string | null;
  args: string[] | null;

  constructor(o: ClaudeServerInit = {}) {
    this.type = o.type ?? (o.command !== undefined && o.command !== null ? "stdio" : "http");
    this.url = o.url ?? null;
    this.command = o.command ?? null;
    this.args = o.args ?? null;
  }

  toJSON(): Record<string, unknown> {
    return {
      type: this.type,
      ...(this.url !== null ? { url: this.url } : {}),
      ...(this.command !== null ? { command: this.command } : {}),
      ...(this.args !== null ? { args: this.args } : {}),
    };
  }

  static fromJSON(value: unknown): ClaudeServer | null {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
    const object = value as Record<string, unknown>;
    const command = typeof object["command"] === "string" ? object["command"] : null;
    return new ClaudeServer({
      command,
      args: Array.isArray(object["args"]) ? (object["args"] as unknown[]).filter((a): a is string => typeof a === "string") : null,
      url: typeof object["url"] === "string" ? object["url"] : null,
      type: typeof object["type"] === "string" ? object["type"] : (command === null ? "http" : "stdio"),
    });
  }
}

export interface ClaudeCommandInit {
  id: string;
  label?: string;
  icon?: string;
  prompt?: string;
  scope?: CommandScope;
  model?: string | null;
  capture?: boolean | null;
  attach?: boolean | null;
  verdicts?: boolean | null;
}

export class ClaudeCommand {
  id: string;
  label: string;
  icon: string;
  /** Ce qui est envoyé. `{code}`, `{cours}`, `{serie}`, `{titre}`, `{exercice}` sont remplacés. */
  prompt: string;
  scope: CommandScope;
  model: string | null;
  capture: boolean | null;
  attach: boolean | null;
  verdicts: boolean | null;

  constructor(o: ClaudeCommandInit) {
    this.id = o.id;
    this.label = o.label ?? o.id;
    this.icon = o.icon ?? "sparkle";
    this.prompt = o.prompt ?? o.id;
    this.scope = o.scope ?? "system";
    this.model = o.model ?? null;
    this.capture = o.capture ?? null;
    this.attach = o.attach ?? null;
    this.verdicts = o.verdicts ?? null;
  }

  toJSON(): Record<string, unknown> {
    return {
      id: this.id,
      label: this.label,
      icon: this.icon,
      prompt: this.prompt,
      scope: this.scope,
      ...(this.model !== null ? { model: this.model } : {}),
      ...(this.capture !== null ? { capture: this.capture } : {}),
      ...(this.attach !== null ? { attach: this.attach } : {}),
      ...(this.verdicts !== null ? { verdicts: this.verdicts } : {}),
    };
  }

  static fromJSON(value: unknown): ClaudeCommand | null {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
    const object = value as Record<string, unknown>;
    if (typeof object["id"] !== "string") return null;
    const scope = object["scope"] === "series" ? "series" : "system";
    return new ClaudeCommand({
      id: object["id"],
      label: typeof object["label"] === "string" ? object["label"] : object["id"],
      icon: typeof object["icon"] === "string" ? object["icon"] : "sparkle",
      prompt: typeof object["prompt"] === "string" ? object["prompt"] : object["id"],
      scope,
      model: typeof object["model"] === "string" ? object["model"] : null,
      capture: typeof object["capture"] === "boolean" ? object["capture"] : null,
      attach: typeof object["attach"] === "boolean" ? object["attach"] : null,
      verdicts: typeof object["verdicts"] === "boolean" ? object["verdicts"] : null,
    });
  }
}

export class ClaudeModels {
  /** Les indices, la conversation d'une série. */
  tutor: string | null;
  /** Le système : post-mortem, brief, plan, revue, synchronisation. */
  system: string | null;

  constructor(o: { tutor?: string | null; system?: string | null } = {}) {
    this.tutor = o.tutor ?? null;
    this.system = o.system ?? null;
  }

  static fromJSON(value: unknown): ClaudeModels {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return new ClaudeModels();
    const object = value as Record<string, unknown>;
    return new ClaudeModels({
      tutor: typeof object["tutor"] === "string" ? object["tutor"] : null,
      system: typeof object["system"] === "string" ? object["system"] : null,
    });
  }
}

export interface ClaudeFileInit {
  skills?: string[];
  seriesSkill?: string | null;
  models?: ClaudeModels;
  mcpServers?: Record<string, ClaudeServer>;
  allowedTools?: string[];
  commands?: ClaudeCommand[];
}

/** `studytrack.json` : la façon de travailler de l'étudiant·e, pas celle de l'app. */
export class ClaudeProjectFile {
  /** Les compétences à relier depuis `~/.claude/skills/synced/…`. */
  skills: string[];
  /** La compétence lancée au premier message d'une série. */
  seriesSkill: string | null;
  models: ClaudeModels;
  mcpServers: Record<string, ClaudeServer>;
  /** En plus de la lecture et des compétences (`Read`, `Glob`, `Skill`). */
  allowedTools: string[];
  commands: ClaudeCommand[];
  /** La file de reprise de l'étudiant·e (paliers, plafonds) — gardée telle quelle. */
  redo: unknown = null;

  constructor(o: ClaudeFileInit = {}) {
    this.skills = o.skills ?? [];
    this.seriesSkill = o.seriesSkill ?? null;
    this.models = o.models ?? new ClaudeModels();
    this.mcpServers = o.mcpServers ?? {};
    this.allowedTools = o.allowedTools ?? [];
    this.commands = o.commands ?? [];
  }

  static decode(data: string): ClaudeProjectFile | null {
    if (data === "") return null;
    let value: unknown;
    try { value = JSON.parse(data); } catch { return null; }
    if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
    const object = value as Record<string, unknown>;
    const file = new ClaudeProjectFile({
      skills: Array.isArray(object["skills"])
        ? (object["skills"] as unknown[]).filter((s): s is string => typeof s === "string") : [],
      seriesSkill: typeof object["seriesSkill"] === "string" ? object["seriesSkill"] : null,
      models: ClaudeModels.fromJSON(object["models"]),
      allowedTools: Array.isArray(object["allowedTools"])
        ? (object["allowedTools"] as unknown[]).filter((s): s is string => typeof s === "string") : [],
    });
    if (object["mcpServers"] !== undefined) {
      if (object["mcpServers"] === null || typeof object["mcpServers"] !== "object" || Array.isArray(object["mcpServers"])) return null;
      for (const [name, server] of Object.entries(object["mcpServers"] as Record<string, unknown>)) {
        const parsed = ClaudeServer.fromJSON(server);
        if (parsed === null) return null;
        file.mcpServers[name] = parsed;
      }
    }
    if (object["commands"] !== undefined) {
      if (!Array.isArray(object["commands"])) return null;
      for (const command of object["commands"] as unknown[]) {
        const parsed = ClaudeCommand.fromJSON(command);
        if (parsed === null) return null;
        file.commands.push(parsed);
      }
    }
    file.redo = object["redo"] ?? null;
    return file;
  }

  encodedObject(): Record<string, unknown> {
    const servers: Record<string, unknown> = {};
    for (const [name, server] of Object.entries(this.mcpServers)) servers[name] = server.toJSON();
    return {
      skills: this.skills,
      ...(this.seriesSkill !== null ? { seriesSkill: this.seriesSkill } : {}),
      models: { tutor: this.models.tutor, system: this.models.system },
      mcpServers: servers,
      allowedTools: this.allowedTools,
      commands: this.commands.map((command) => command.toJSON()),
    };
  }

  /** `==` de Swift pour le modèle vide (le fichier créé depuis les Réglages). */
  equals(other: ClaudeProjectFile): boolean {
    return JSON.stringify(this.encodedObject()) === JSON.stringify(other.encodedObject());
  }

  commandsFor(scope: CommandScope): ClaudeCommand[] {
    return this.commands.filter((command) => command.scope === scope);
  }

  /** Le modèle d'un bouton : `tutor` / `system` renvoient aux modèles du fichier. */
  modelFor(command: ClaudeCommand | null, scope: CommandScope): string | null {
    const name = command?.model ?? (scope === "series" ? "tutor" : "system");
    switch (name) {
      case "tutor": return this.models.tutor;
      case "system": return this.models.system;
      default: return name;
    }
  }
}

/**
 * `JSONSerialization` avec `.prettyPrinted, .sortedKeys` — les deux espaces autour
 * des deux-points comptent : un fichier relu à la main reste lisible.
 */
function foundationJSON(value: unknown, indent = 0): string {
  const pad = "  ".repeat(indent);
  if (value === null || value === undefined) return "null";
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    if (value.length === 0) return "[\n\n" + pad + "]";
    const inner = value.map((item) => "  ".repeat(indent + 1) + foundationJSON(item, indent + 1));
    return "[\n" + inner.join(",\n") + "\n" + pad + "]";
  }
  const object = value as Record<string, unknown>;
  const keys = Object.keys(object).filter((key) => object[key] !== undefined).sort();
  if (keys.length === 0) return "{\n\n" + pad + "}";
  const inner = keys.map((key) =>
    "  ".repeat(indent + 1) + JSON.stringify(key) + " : " + foundationJSON(object[key], indent + 1));
  return "{\n" + inner.join(",\n") + "\n" + pad + "}";
}

export const ClaudeProject = {
  beginMarker: "<!-- studytrack:début -->",
  endMarker: "<!-- studytrack:fin -->",

  File: ClaudeProjectFile,
  Server: ClaudeServer,
  Command: ClaudeCommand,
  Models: ClaudeModels,

  /** Le contexte que StudyTrack tient à jour dans le `CLAUDE.md`. */
  context(courses: { code: string; name: string; week?: number | null; progress?: string | null }[],
          week: number | null, date: string,
          redo: { code: string; exercise: string; step: string; due?: string | null; why: string }[] = [],
          features: Features | null = null): string {
    const lines = [
      `## StudyTrack (mis à jour par l'app, le ${date})`,
      "",
      "Étudiant en première année à l'EPFL. StudyTrack range chaque cours en semaines : la théorie (vidéos, chapitres), les séries d'exercices (questions cochées, correction juste / moyen / faux), le temps d'étude. Dans le mode étude, une conversation suit une série ; le contexte envoyé par l'app est entre [StudyTrack] et [/StudyTrack].",
    ];
    if (week !== null) lines.push("", `Semaine du semestre : ${week}.`);
    if (courses.length !== 0) {
      lines.push("", "Cours suivis :");
      for (const course of courses) {
        let line = `- ${course.code} — ${course.name}`;
        if (course.week !== undefined && course.week !== null) line += ` (semaine ${course.week})`;
        if (course.progress !== undefined && course.progress !== null) line += " · " + course.progress;
        lines.push(line);
      }
    }
    if (redo.length !== 0) {
      lines.push("", "File de reprise de StudyTrack (à refaire sur papier ; l'amorce reste dans l'app, à montrer seulement après une tentative) :");
      for (const line of redo) {
        lines.push(`- ${line.code} ${line.exercise} · ${line.step}${line.due !== undefined && line.due !== null ? ` · le ${line.due}` : ""} · ${line.why}`);
      }
    }
    if (features !== null) {
      lines.push("", "Après une série (post-mortem) ou un indice, StudyTrack lit le bloc de fin de ta réponse :",
        SeriesReview.instruction(features));
      if (features.hints) lines.push(SeriesReview.hintInstruction);
      lines.push("Si ta compétence tient aussi un carnet ailleurs (Notion…), fais-le comme d'habitude : le bloc est en plus.");
    }
    lines.push("", "Ne modifie rien dans StudyTrack toi-même : propose, l'étudiant confirme dans l'app.");
    return lines.join("\n");
  },

  /** Le `CLAUDE.md` avec la partie de StudyTrack à jour : remplacée si elle existe, ajoutée sinon. */
  claudeMD(existing: string | null, context: string): string {
    const block = ClaudeProject.beginMarker + "\n" + context + "\n" + ClaudeProject.endMarker;
    if (existing === null || existing === "") return block + "\n";
    const begin = existing.indexOf(ClaudeProject.beginMarker);
    if (begin >= 0) {
      const end = existing.indexOf(ClaudeProject.endMarker, begin + ClaudeProject.beginMarker.length);
      if (end >= 0) {
        return existing.slice(0, begin) + block + existing.slice(end + ClaudeProject.endMarker.length);
      }
    }
    return existing + (existing.endsWith("\n") ? "\n" : "\n\n") + block + "\n";
  },

  /** Les boutons et les modèles réécrits : le reste du fichier — et toute clé inconnue — est gardé. */
  updating(json: string | null, commands: ClaudeCommand[], models: ClaudeModels): string | null {
    let object: Record<string, unknown> = {};
    if (json !== null && json !== "") {
      let existing: unknown;
      try { existing = JSON.parse(json); } catch { return null; }
      if (existing === null || typeof existing !== "object" || Array.isArray(existing)) return null;
      object = existing as Record<string, unknown>;
    }
    object["commands"] = commands.map((command) => command.toJSON());
    object["models"] = { tutor: models.tutor, system: models.system };
    return foundationJSON(object);
  },

  /** Un identifiant de bouton tiré de son libellé (« Où j'en suis » → `ou-j-en-suis`), unique parmi `taken`. */
  commandID(forLabel: string, taken: string[]): string {
    const folded = forLabel.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
    const base = folded.split(/[^\p{L}\p{N}]+/u).filter((part) => part !== "").join("-");
    const root = base === "" ? "bouton" : base;
    let candidate = root;
    let index = 2;
    while (taken.includes(candidate)) { candidate = `${root}-${index}`; index += 1; }
    return candidate;
  },

  /** Le fichier qu'on crée depuis les Réglages : la forme, sans rien dedans. */
  emptyFileTemplate: `{
  "skills": [],
  "seriesSkill": null,
  "models": { "tutor": null, "system": null },
  "mcpServers": {},
  "allowedTools": [],
  "commands": []
}
`,

  /** `claude mcp list` → les connecteurs du compte et les serveurs locaux. */
  servers(mcpList: string): { connectors: string[]; local: string[] } {
    const connectors: string[] = [];
    const local: string[] = [];
    for (const line of mcpList.split(/\r?\n/)) {
      const colon = line.indexOf(": ");
      if (colon < 0 || !line.includes(" - ")) continue;
      const name = line.slice(0, colon).replace(/^\s+|\s+$/g, "");
      if (name === "" || name.includes("…")) continue;
      if (name.startsWith("claude.ai ")) connectors.push(name); else local.push(name);
    }
    return { connectors, local };
  },

  /** Le préfixe des outils d'un serveur : « claude.ai Claude Docs » → `mcp__claude_ai_Claude_Docs`. */
  toolPrefix(server: string): string {
    return "mcp__" + Array.from(server).map((char) => (/^\p{L}$/u.test(char) || /^\p{N}$/u.test(char) || char === "-" ? char : "_")).join("");
  },

  /** Les outils toujours là en projet : lire et lancer une compétence. */
  baseTools: ["Read", "Glob", "Skill"],

  /** Les outils que Claude Code charge (`--tools`) : la base, plus ceux que les règles nomment. */
  tools(file: ClaudeProjectFile): string[] {
    const result = [...ClaudeProject.baseTools];
    for (const rule of file.allowedTools) {
      if (rule.startsWith("mcp__")) continue;
      const name = rule.split("(")[0];
      if (!result.includes(name)) result.push(name);
    }
    return result;
  },

  /** Les règles `--allowedTools` : la base, les connecteurs, les serveurs du fichier, ses règles. */
  allowedTools(file: ClaudeProjectFile, studyTrack: boolean, connectors: string[] = [], localFiles = false): string[] {
    const result: string[] = [
      ...ClaudeProject.baseTools,
      ...connectors.map((server) => ClaudeProject.toolPrefix(server)),
      ...Object.keys(file.mcpServers).sort().map((name) => "mcp__" + name),
      ...(studyTrack ? ["mcp__studytrack"] : []),
      ...(localFiles ? ["mcp__studytrack-files"] : []),
    ];
    for (const rule of file.allowedTools) if (!result.includes(rule)) result.push(rule);
    return result;
  },

  /** Le fichier `--mcp-config` : les serveurs du fichier, et StudyTrack s'il est relié. */
  mcpConfig(file: ClaudeProjectFile, studyTrackURL: string | null, localFilesURL: string | null = null): string {
    const servers: Record<string, unknown> = {};
    for (const [name, server] of Object.entries(file.mcpServers)) {
      const entry: Record<string, unknown> = { type: server.type };
      if (server.url !== null) entry["url"] = server.url;
      if (server.command !== null) entry["command"] = server.command;
      if (server.args !== null) entry["args"] = server.args;
      servers[name] = entry;
    }
    const address = studyTrackURL?.replace(/^\s+|\s+$/g, "");
    if (address !== undefined && address.startsWith("https://")) {
      servers["studytrack"] = { type: "http", url: address };
    }
    // Le serveur local des fichiers : seulement sur la boucle locale, jamais une autre adresse.
    const local = localFilesURL?.replace(/^\s+|\s+$/g, "");
    if (local !== undefined && local.startsWith("http://127.0.0.1:")) {
      servers["studytrack-files"] = { type: "http", url: local };
    }
    return foundationJSON({ mcpServers: servers });
  },

  /** Ce que Claude a le droit de faire, en clair. */
  permissionSummary(file: ClaudeProjectFile, studyTrack: boolean, connectors: string[] = [], localFiles = false): string {
    const parts = ["lecture", "compétences"];
    if (file.allowedTools.some((rule) => rule.startsWith("Write") || rule.startsWith("Edit"))) parts.push("écriture limitée");
    parts.push(...connectors.map((server) => server.slice("claude.ai ".length)));
    parts.push(...Object.keys(file.mcpServers).sort().map((name) => ClaudeTutor.toolLabel("mcp__" + name)));
    if (studyTrack) parts.push("StudyTrack");
    if (localFiles) parts.push("fichiers du Mac");
    return parts.join(", ");
  },

  /** Un bouton → le message, avec la session en cours. */
  expand(prompt: string, values: { code?: string; course?: string; seriesNumber?: string; seriesTitle?: string; exercise?: string }): string {
    let text = prompt;
    for (const [key, value] of [
      ["{code}", values.code ?? ""], ["{cours}", values.course ?? ""], ["{serie}", values.seriesNumber ?? ""],
      ["{titre}", values.seriesTitle ?? ""], ["{exercice}", values.exercise ?? ""],
    ]) text = text.split(key).join(value);
    return text.replace(/\s{2,}/g, " ").replace(/^\s+|\s+$/g, "");
  },

  /** Le nom court d'un cours pour une commande (« Analyse I classe inversée » → « analyse »). */
  shortCourseName(name: string): string {
    const first = name.split(" ")[0] ?? name;
    return first.toLowerCase().normalize("NFD").replace(/\p{M}/gu, "");
  },
};
