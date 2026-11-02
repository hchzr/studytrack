// Les tâches liées : un fournisseur externe, et leur synchronisation vers le modèle local
// (StudyTrack/Services/TaskService.swift).
//
// Rappels (EventKit) et Things 3 (schéma d'URL) n'existent pas sur Windows : restent
// Todoist, Notion, Google Tasks, TickTick (lecture + écriture) et le webhook (écriture).
// Les appels passent par `nativeFetch` (plugin HTTP : ni CORS, ni jeton dans la page).

import { LinkedTask } from "../models/linkedTask.ts";
import type { Course } from "../models/course.ts";
import type { TaskProvider } from "../models/enums.ts";
import type { ModelStore } from "../models/store.ts";
import { DateUtils } from "../domain/dateUtils.ts";
import { readConnection } from "../native/settings.ts";
import { nativeFetch } from "../native/http.ts";
import { CalendarSync } from "./calendarService.ts";

export interface ExternalTask {
  identifier: string;
  title: string;
  notes: string;
  dueDate: Date | null;
  isDone: boolean;
  priority: number;
  listName: string;
}

/** Abstraction d'un fournisseur de tâches. */
export interface TaskService {
  readonly provider: TaskProvider;
  readonly isConfigured: boolean;
  requestAccess(): Promise<boolean>;
  fetchTasks(): Promise<ExternalTask[]>;
  createTask(title: string, notes: string, dueDate: Date | null, priority: number): Promise<ExternalTask | null>;
  setCompleted(identifier: string, completed: boolean): Promise<boolean>;
  deleteTask(identifier: string): Promise<boolean>;
}

export type Fetcher = (url: string, init?: RequestInit) => Promise<Response>;

/** `ISO8601DateFormatter().string(from:)` : « 2026-11-03T10:00:00Z », sans fraction. */
function iso(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Une requête JSON : le corps de la réponse (texte), ou `null` en cas d'échec — jamais d'exception. */
async function send(fetcher: Fetcher, url: string, o: { method?: string; headers: Record<string, string>; body?: unknown; timeout?: number }): Promise<string | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), (o.timeout ?? 30) * 1000);
  try {
    const response = await fetcher(url, {
      method: o.method ?? "GET",
      headers: { "Content-Type": "application/json", ...o.headers },
      body: o.body === undefined ? undefined : JSON.stringify(o.body),
      signal: controller.signal,
    });
    if (!(response.status >= 200 && response.status < 300)) return null;
    return await response.text();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function parseJSON(text: string | null): any {
  if (text === null || text === "") return null;
  try { return JSON.parse(text); } catch { return null; }
}

// MARK: - Todoist

export class TodoistTaskService implements TaskService {
  readonly provider: TaskProvider = "todoist";
  private readonly token: string;
  private readonly baseURL = "https://api.todoist.com/api/v1";

  constructor(token: string, private readonly fetcher: Fetcher = nativeFetch) {
    this.token = token.trim();
  }

  get isConfigured(): boolean { return this.token !== ""; }
  async requestAccess(): Promise<boolean> { return this.isConfigured; }

  private send(path: string, method = "GET", body?: unknown): Promise<string | null> {
    return send(this.fetcher, `${this.baseURL}/${path}`, { method, headers: { Authorization: `Bearer ${this.token}` }, body });
  }

  async fetchTasks(): Promise<ExternalTask[]> {
    if (!this.isConfigured) return [];
    const json = parseJSON(await this.send("tasks"));
    const items: any[] = Array.isArray(json) ? json : Array.isArray(json?.results) ? json.results : [];
    return items.map((item) => ({
      identifier: String(item.id),
      title: String(item.content ?? ""),
      notes: item.description ?? "",
      dueDate: TodoistTaskService.parseDue(item.due),
      isDone: item.is_completed ?? false,
      priority: item.priority ?? 1,
      listName: item.project_id ?? "",
    }));
  }

  async createTask(title: string, notes: string, dueDate: Date | null, priority: number): Promise<ExternalTask | null> {
    if (!this.isConfigured) return null;
    const body: Record<string, unknown> = { content: title };
    if (notes !== "") body.description = notes;
    if (priority > 1) body.priority = priority;
    if (dueDate) body.due_datetime = iso(dueDate);
    const task = parseJSON(await this.send("tasks", "POST", body));
    if (!task?.id) return null;
    return { identifier: String(task.id), title: task.content, notes: task.description ?? "", dueDate, isDone: false, priority: task.priority ?? 1, listName: "" };
  }

  async setCompleted(identifier: string, completed: boolean): Promise<boolean> {
    if (!this.isConfigured) return false;
    return (await this.send(`tasks/${identifier}/${completed ? "close" : "reopen"}`, "POST")) !== null;
  }

  async deleteTask(identifier: string): Promise<boolean> {
    if (!this.isConfigured) return false;
    return (await this.send(`tasks/${identifier}`, "DELETE")) !== null;
  }

  static parseDue(due: { date?: string; datetime?: string } | null | undefined): Date | null {
    if (!due) return null;
    if (due.datetime) { const date = DateUtils.parse(due.datetime); if (date) return date; }
    if (due.date) return DateUtils.parse(due.date);
    return null;
  }
}

// MARK: - Notion

export class NotionTaskService implements TaskService {
  readonly provider: TaskProvider = "notion";
  private readonly token: string;
  private readonly databaseID: string;

  constructor(token: string, databaseID: string, private readonly fetcher: Fetcher = nativeFetch) {
    this.token = token.trim();
    this.databaseID = databaseID.trim();
  }

  get isConfigured(): boolean { return this.token !== "" && this.databaseID !== ""; }
  async requestAccess(): Promise<boolean> { return this.isConfigured; }

  private send(path: string, method = "GET", body?: unknown): Promise<string | null> {
    return send(this.fetcher, `https://api.notion.com/v1/${path}`, {
      method, body, headers: { Authorization: `Bearer ${this.token}`, "Notion-Version": "2022-06-28" },
    });
  }

  /** Convention : propriétés `Name` (titre), `Done` (case à cocher), `Due` (date). */
  async fetchTasks(): Promise<ExternalTask[]> {
    if (!this.isConfigured) return [];
    const json = parseJSON(await this.send(`databases/${this.databaseID}/query`, "POST", { page_size: 50 }));
    const results: any[] = Array.isArray(json?.results) ? json.results : [];
    const tasks: ExternalTask[] = [];
    for (const page of results) {
      if (typeof page.id !== "string") continue;
      if (page.archived === true) continue;
      const properties = page.properties ?? {};
      tasks.push({
        identifier: page.id,
        title: NotionTaskService.title(properties.Name) ?? "Sans titre",
        notes: "",
        dueDate: NotionTaskService.date(properties.Due),
        isDone: properties.Done?.checkbox ?? false,
        priority: 1,
        listName: "Notion",
      });
    }
    return tasks;
  }

  async createTask(title: string, notes: string, dueDate: Date | null, priority: number): Promise<ExternalTask | null> {
    if (!this.isConfigured) return null;
    const properties: Record<string, unknown> = {
      Name: { title: [{ text: { content: title } }] },
      Done: { checkbox: false },
    };
    if (dueDate) properties.Due = { date: { start: iso(dueDate) } };
    const json = parseJSON(await this.send("pages", "POST", { parent: { database_id: this.databaseID }, properties }));
    if (typeof json?.id !== "string") return null;
    return { identifier: json.id, title, notes, dueDate, isDone: false, priority, listName: "Notion" };
  }

  async setCompleted(identifier: string, completed: boolean): Promise<boolean> {
    if (!this.isConfigured) return false;
    return (await this.send(`pages/${identifier}`, "PATCH", { properties: { Done: { checkbox: completed } } })) !== null;
  }

  async deleteTask(identifier: string): Promise<boolean> {
    if (!this.isConfigured) return false;
    return (await this.send(`pages/${identifier}`, "PATCH", { archived: true })) !== null;
  }

  static title(property: any): string | null {
    if (!property || !Array.isArray(property.title)) return null;
    return property.title.map((t: any) => t.plain_text).filter((t: unknown) => typeof t === "string").join("");
  }

  static date(property: any): Date | null {
    const start = property?.date?.start;
    return typeof start === "string" ? DateUtils.parse(start) : null;
  }
}

// MARK: - Webhook générique

/** Envoie un JSON à une URL : compatible Raccourcis, Home Assistant, Zapier, n8n… */
export class WebhookTaskService implements TaskService {
  readonly provider: TaskProvider = "webhook";
  private readonly urlString: string;

  constructor(urlString: string, private readonly fetcher: Fetcher = nativeFetch) {
    this.urlString = urlString.trim();
  }

  get isConfigured(): boolean {
    try { new URL(this.urlString); return this.urlString !== ""; } catch { return false; }
  }
  async requestAccess(): Promise<boolean> { return this.isConfigured; }
  async fetchTasks(): Promise<ExternalTask[]> { return []; }

  async createTask(title: string, notes: string, dueDate: Date | null, priority: number): Promise<ExternalTask | null> {
    if (!this.isConfigured) return null;
    const payload: Record<string, unknown> = { event: "task.created", source: "StudyTrack", title, notes, priority };
    if (dueDate) payload.dueDate = iso(dueDate);
    if (!(await this.post(payload))) return null;
    return { identifier: `webhook-${crypto.randomUUID().toUpperCase()}`, title, notes, dueDate, isDone: false, priority, listName: "Webhook" };
  }

  setCompleted(identifier: string, completed: boolean): Promise<boolean> {
    return this.post({ event: completed ? "task.completed" : "task.reopened", source: "StudyTrack", identifier });
  }

  deleteTask(identifier: string): Promise<boolean> {
    return this.post({ event: "task.deleted", source: "StudyTrack", identifier });
  }

  private async post(payload: Record<string, unknown>): Promise<boolean> {
    return (await send(this.fetcher, this.urlString, { method: "POST", headers: {}, body: payload, timeout: 20 })) !== null;
  }
}

// MARK: - Google Tasks

/**
 * Tâches Google via l'API Tasks. Les jetons d'accès Google ne vivent qu'une heure : on garde
 * le refresh token et on redemande un jeton à la demande, en mémoire seulement.
 */
export class GoogleTasksTaskService implements TaskService {
  readonly provider: TaskProvider = "googleTasks";
  private readonly clientID: string;
  private readonly clientSecret: string;
  private readonly refreshToken: string;
  private accessToken: string | null = null;
  private accessTokenExpiry = 0;
  private listID: string | null = null;

  constructor(clientID: string, clientSecret: string, refreshToken: string, private readonly fetcher: Fetcher = nativeFetch) {
    this.clientID = clientID.trim();
    this.clientSecret = clientSecret.trim();
    this.refreshToken = refreshToken.trim();
  }

  /** Un client « natif » n'a pas de secret : l'identifiant et le jeton de renouvellement suffisent. */
  get isConfigured(): boolean { return this.clientID !== "" && this.refreshToken !== ""; }
  async requestAccess(): Promise<boolean> { return (await this.token()) !== null; }

  private async token(): Promise<string | null> {
    if (this.accessToken !== null && Date.now() < this.accessTokenExpiry) return this.accessToken;
    const fields: Record<string, string> = { client_id: this.clientID, refresh_token: this.refreshToken, grant_type: "refresh_token" };
    if (this.clientSecret !== "") fields.client_secret = this.clientSecret;
    const body = Object.entries(fields).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
    let text: string | null = null;
    try {
      const response = await this.fetcher("https://oauth2.googleapis.com/token", {
        method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
      });
      if (response.status >= 200 && response.status < 300) text = await response.text();
    } catch { text = null; }
    const payload = parseJSON(text);
    if (typeof payload?.access_token !== "string") return null;
    this.accessToken = payload.access_token;
    // Marge d'une minute : on ne veut pas présenter un jeton qui expire pendant l'appel.
    this.accessTokenExpiry = Date.now() + Math.max(Number(payload.expires_in) - 60, 30) * 1000;
    return this.accessToken;
  }

  private async send(path: string, method = "GET", body?: unknown): Promise<string | null> {
    const token = await this.token();
    if (token === null) return null;
    return send(this.fetcher, `https://tasks.googleapis.com/tasks/v1/${path}`, { method, body, headers: { Authorization: `Bearer ${token}` } });
  }

  private async resolvedListID(): Promise<string | null> {
    if (this.listID !== null) return this.listID;
    const page = parseJSON(await this.send("users/@me/lists"));
    const first = page?.items?.[0];
    if (!first?.id) return null;
    this.listID = first.id;
    return this.listID;
  }

  async fetchTasks(): Promise<ExternalTask[]> {
    const list = this.isConfigured ? await this.resolvedListID() : null;
    if (list === null) return [];
    const page = parseJSON(await this.send(`lists/${list}/tasks?showCompleted=true`));
    if (page === null) return [];
    return ((page.items ?? []) as any[]).map((task) => ({
      identifier: task.id, title: task.title ?? "", notes: task.notes ?? "",
      dueDate: typeof task.due === "string" ? DateUtils.parse(task.due) : null,
      isDone: task.status === "completed", priority: 1, listName: "Tasks",
    }));
  }

  async createTask(title: string, notes: string, dueDate: Date | null, priority: number): Promise<ExternalTask | null> {
    const list = this.isConfigured ? await this.resolvedListID() : null;
    if (list === null) return null;
    const body: Record<string, unknown> = { title };
    if (notes !== "") body.notes = notes;
    if (dueDate) body.due = iso(dueDate);
    const task = parseJSON(await this.send(`lists/${list}/tasks`, "POST", body));
    if (!task?.id) return null;
    return { identifier: task.id, title: task.title ?? title, notes, dueDate, isDone: false, priority, listName: "Tasks" };
  }

  async setCompleted(identifier: string, completed: boolean): Promise<boolean> {
    const list = this.isConfigured ? await this.resolvedListID() : null;
    if (list === null) return false;
    return (await this.send(`lists/${list}/tasks/${identifier}`, "PATCH", { status: completed ? "completed" : "needsAction" })) !== null;
  }

  async deleteTask(identifier: string): Promise<boolean> {
    const list = this.isConfigured ? await this.resolvedListID() : null;
    if (list === null) return false;
    return (await this.send(`lists/${list}/tasks/${identifier}`, "DELETE")) !== null;
  }
}

// MARK: - TickTick

/** Tâches TickTick via son API ouverte (OAuth2). */
export class TickTickTaskService implements TaskService {
  readonly provider: TaskProvider = "tickTick";
  private readonly token: string;
  private projectID: string | null = null;

  constructor(token: string, private readonly fetcher: Fetcher = nativeFetch) {
    this.token = token.trim();
  }

  get isConfigured(): boolean { return this.token !== ""; }
  async requestAccess(): Promise<boolean> { return this.isConfigured; }

  private send(path: string, method = "GET", body?: unknown): Promise<string | null> {
    return send(this.fetcher, `https://api.ticktick.com/open/v1/${path}`, { method, body, headers: { Authorization: `Bearer ${this.token}` } });
  }

  private async resolvedProjectID(): Promise<string | null> {
    if (this.projectID !== null) return this.projectID;
    const projects = parseJSON(await this.send("project"));
    const first = Array.isArray(projects) ? projects[0] : null;
    if (!first?.id) return null;
    this.projectID = first.id;
    return this.projectID;
  }

  async fetchTasks(): Promise<ExternalTask[]> {
    const project = this.isConfigured ? await this.resolvedProjectID() : null;
    if (project === null) return [];
    const payload = parseJSON(await this.send(`project/${project}/data`));
    if (payload === null) return [];
    return ((payload.tasks ?? []) as any[]).map((task) => ({
      identifier: task.id, title: task.title ?? "", notes: task.content ?? "",
      dueDate: typeof task.dueDate === "string" ? DateUtils.parse(task.dueDate) : null,
      isDone: (task.status ?? 0) === 2, priority: task.priority ?? 0, listName: payload.project?.name ?? "TickTick",
    }));
  }

  async createTask(title: string, notes: string, dueDate: Date | null, priority: number): Promise<ExternalTask | null> {
    const project = this.isConfigured ? await this.resolvedProjectID() : null;
    if (project === null) return null;
    const body: Record<string, unknown> = { title, projectId: project };
    if (notes !== "") body.content = notes;
    if (dueDate) body.dueDate = iso(dueDate);
    if (priority > 0) body.priority = priority;
    const task = parseJSON(await this.send("task", "POST", body));
    if (!task?.id) return null;
    return { identifier: task.id, title: task.title ?? title, notes, dueDate, isDone: false, priority, listName: "TickTick" };
  }

  async setCompleted(identifier: string, completed: boolean): Promise<boolean> {
    const project = this.isConfigured ? await this.resolvedProjectID() : null;
    if (project === null) return false;
    return (await this.send(`project/${project}/task/${identifier}/${completed ? "complete" : "uncomplete"}`, "POST")) !== null;
  }

  async deleteTask(identifier: string): Promise<boolean> {
    const project = this.isConfigured ? await this.resolvedProjectID() : null;
    if (project === null) return false;
    return (await this.send(`project/${project}/task/${identifier}`, "DELETE")) !== null;
  }
}

// MARK: - Fabrique de services

/** Les fournisseurs disponibles sur Windows (Rappels et Things 3 sont propres à Apple). */
export const windowsProviders: readonly TaskProvider[] = ["todoist", "notion", "webhook", "googleTasks", "tickTick"];

/** Le service d'un fournisseur, d'après les réglages de connexion — `null` s'il n'est pas configuré. */
export function service(provider: TaskProvider, fetcher: Fetcher = nativeFetch,
  settings: (key: Parameters<typeof readConnection>[0]) => string = readConnection): TaskService | null {
  switch (provider) {
    case "todoist": {
      const token = settings("todoistToken");
      return token === "" ? null : new TodoistTaskService(token, fetcher);
    }
    case "notion": {
      const token = settings("notionToken");
      const database = settings("notionDatabaseID");
      return token === "" || database === "" ? null : new NotionTaskService(token, database, fetcher);
    }
    case "webhook": {
      const url = settings("webhookURL");
      return url === "" ? null : new WebhookTaskService(url, fetcher);
    }
    case "googleTasks": {
      const id = settings("googleClientID");
      const refresh = settings("googleRefreshToken");
      return id === "" || refresh === "" ? null : new GoogleTasksTaskService(id, settings("googleClientSecret"), refresh, fetcher);
    }
    case "tickTick": {
      const token = settings("tickTickToken");
      return token === "" ? null : new TickTickTaskService(token, fetcher);
    }
    default:
      return null;
  }
}

/** Fournisseurs réellement configurés, dans l'ordre d'affichage. */
export function configuredServices(fetcher?: Fetcher, settings?: Parameters<typeof service>[2]): TaskService[] {
  return windowsProviders.map((p) => service(p, fetcher, settings)).filter((s): s is TaskService => s !== null);
}

/** Fournisseurs lisibles (donc synchronisables) uniquement. */
export function readableServices(fetcher?: Fetcher, settings?: Parameters<typeof service>[2]): TaskService[] {
  return configuredServices(fetcher, settings).filter((s) => s.provider !== "webhook");
}

// MARK: - Synchronisation vers le modèle local

export interface TaskSyncResult {
  fetched: number;
  created: number;
  updated: number;
  removed: number;
  providers: string[];
}

export async function syncTasks(store: ModelStore, services: TaskService[] = readableServices(),
  providerLabel: (p: TaskProvider) => string = (p) => p): Promise<TaskSyncResult> {
  const result: TaskSyncResult = { fetched: 0, created: 0, updated: 0, removed: 0, providers: [] };
  let existing = [...store.fetch(LinkedTask)];
  for (const svc of services) {
    const tasks = await svc.fetchTasks();
    if (tasks.length === 0) continue;
    result.providers.push(providerLabel(svc.provider));
    result.fetched += tasks.length;
    // Une tâche supprimée chez le fournisseur restait ici pour toujours : le fournisseur a
    // répondu, donc son absence dans la liste est une vraie absence.
    const remote = new Set(tasks.map((t) => t.identifier));
    const stale = existing.filter((t) => t.providerRaw === svc.provider && t.externalID !== null && !remote.has(t.externalID));
    for (const task of stale) { store.delete(task); result.removed++; }
    existing = existing.filter((t) => !stale.includes(t));
    for (const task of tasks) {
      const match = existing.find((t) => t.providerRaw === svc.provider && t.externalID === task.identifier);
      if (match) {
        match.title = task.title;
        match.note = task.notes;
        match.dueDate = task.dueDate;
        match.isDone = task.isDone;
        match.priority = task.priority;
        match.updatedAt = new Date();
        match.lastSyncedAt = new Date();
        result.updated++;
        continue;
      }
      const linked = new LinkedTask({
        provider: svc.provider, externalID: task.identifier, title: task.title, note: task.notes,
        dueDate: task.dueDate, isDone: task.isDone, priority: task.priority,
      });
      linked.lastSyncedAt = new Date();
      store.insert(linked);
      existing.push(linked);
      result.created++;
    }
  }
  return result;
}

/** Coche (ou décoche) une tâche ici **et** chez son fournisseur. */
export async function setDone(task: LinkedTask, done: boolean, svc: TaskService | null = service(task.provider)): Promise<void> {
  task.isDone = done;
  task.updatedAt = new Date();
  if (task.externalID === null || svc === null) return;
  await svc.setCompleted(task.externalID, done);
}

/** Rattache automatiquement une tâche à un cours dont le code apparaît dans le titre. */
export function autoLink(tasks: LinkedTask[], courses: Course[]): void {
  for (const task of tasks) {
    if (task.course !== null) continue;
    const course = CalendarSync.matchCourse(task.title, courses);
    if (course) task.course = course;
  }
}

export const TaskSync = { sync: syncTasks, setDone, autoLink };
export const TaskServiceFactory = { service, configuredServices, readableServices };
