// Les tâches liées : chaque fournisseur parle à son API (réponses simulées), et la
// synchronisation vers le modèle local reflète le fournisseur. Aucun check de
// Validation/main.swift ne touche TaskService (réseau, EventKit) : tests propres au port.

import { describe, expect, it } from "vitest";
import {
  GoogleTasksTaskService, NotionTaskService, TickTickTaskService, TodoistTaskService, WebhookTaskService,
  autoLink, readableServices, service, setDone, syncTasks, type ExternalTask, type Fetcher, type TaskService,
} from "../../src/services/taskService.ts";
import { ModelStore } from "../../src/models/store.ts";
import { Course } from "../../src/models/course.ts";
import { LinkedTask } from "../../src/models/linkedTask.ts";

function recorder(replies: Record<string, unknown>): { fetcher: Fetcher; calls: { url: string; method: string; body: unknown }[] } {
  const calls: { url: string; method: string; body: unknown }[] = [];
  const fetcher: Fetcher = async (url, init) => {
    let body: unknown;
    try { body = init?.body ? JSON.parse(String(init.body)) : undefined; } catch { body = String(init?.body); }
    calls.push({ url, method: init?.method ?? "GET", body });
    const key = Object.keys(replies).find((k) => url.includes(k));
    return key === undefined ? new Response("", { status: 404 }) : new Response(JSON.stringify(replies[key]), { status: 200 });
  };
  return { fetcher, calls };
}

describe("Todoist", () => {
  it("lit les tâches (liste simple ou page), échéance datée ou non", async () => {
    const { fetcher } = recorder({ "/tasks": { results: [
      { id: "1", content: "Série 3", description: "d", priority: 4, project_id: "p", is_completed: false, due: { datetime: "2026-11-03T10:00:00Z" } },
      { id: "2", content: "Rendu", due: { date: "2026-11-05" } },
    ] } });
    const tasks = await new TodoistTaskService("tok", fetcher).fetchTasks();
    expect(tasks.map((t) => [t.identifier, t.title, t.priority, t.isDone])).toEqual([["1", "Série 3", 4, false], ["2", "Rendu", 1, false]]);
    expect(tasks[0].dueDate?.toISOString()).toBe("2026-11-03T10:00:00.000Z");
    expect(tasks[1].dueDate).not.toBeNull();
  });

  it("crée (priorité au-dessus de 1, échéance ISO), coche et supprime", async () => {
    const { fetcher, calls } = recorder({ "/tasks": { id: "9", content: "Nouvelle" } });
    const svc = new TodoistTaskService("tok", fetcher);
    const created = await svc.createTask("Nouvelle", "n", new Date("2026-11-03T10:00:00.123Z"), 3);
    expect(created?.identifier).toBe("9");
    expect(calls[0].body).toEqual({ content: "Nouvelle", description: "n", priority: 3, due_datetime: "2026-11-03T10:00:00Z" });
    expect(await svc.setCompleted("9", true)).toBe(true);
    expect(calls[1].url).toBe("https://api.todoist.com/api/v1/tasks/9/close");
    expect(await svc.setCompleted("9", false)).toBe(true);
    expect(calls[2].url).toContain("/reopen");
    expect(await svc.deleteTask("9")).toBe(true);
    expect(calls[3].method).toBe("DELETE");
  });

  it("sans jeton : rien ne part", async () => {
    const { fetcher, calls } = recorder({});
    const svc = new TodoistTaskService("  ", fetcher);
    expect(svc.isConfigured).toBe(false);
    expect(await svc.fetchTasks()).toEqual([]);
    expect(await svc.setCompleted("1", true)).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("un échec réseau ou HTTP : liste vide, jamais d'exception", async () => {
    const svc = new TodoistTaskService("tok", async () => { throw new Error("hors ligne"); });
    expect(await svc.fetchTasks()).toEqual([]);
    expect(await new TodoistTaskService("tok", async () => new Response("", { status: 500 })).createTask("x", "", null, 1)).toBeNull();
  });
});

describe("Notion", () => {
  it("lit Name / Done / Due et ignore les pages archivées", async () => {
    const { fetcher, calls } = recorder({ "/query": { results: [
      { id: "a", properties: { Name: { title: [{ plain_text: "Rendre " }, { plain_text: "la série" }] }, Done: { checkbox: true }, Due: { date: { start: "2026-11-04" } } } },
      { id: "b", archived: true, properties: {} },
      { id: "c", properties: {} },
    ] } });
    const tasks = await new NotionTaskService("t", "db", fetcher).fetchTasks();
    expect(tasks.map((t) => [t.identifier, t.title, t.isDone])).toEqual([["a", "Rendre la série", true], ["c", "Sans titre", false]]);
    expect(calls[0].body).toEqual({ page_size: 50 });
  });

  it("supprimer archive la page", async () => {
    const { fetcher, calls } = recorder({ "/pages/": {} });
    expect(await new NotionTaskService("t", "db", fetcher).deleteTask("p1")).toBe(true);
    expect(calls[0]).toMatchObject({ method: "PATCH", body: { archived: true } });
  });
});

describe("Webhook, Google Tasks, TickTick", () => {
  it("le webhook envoie l'évènement et n'a rien à lire", async () => {
    const { fetcher, calls } = recorder({ "hooks.example": {} });
    const svc = new WebhookTaskService("https://hooks.example/x", fetcher);
    expect(await svc.fetchTasks()).toEqual([]);
    const task = await svc.createTask("T", "", null, 2);
    expect(task?.identifier.startsWith("webhook-")).toBe(true);
    expect(calls[0].body).toMatchObject({ event: "task.created", source: "StudyTrack", title: "T", priority: 2 });
    await svc.setCompleted("i", true);
    expect(calls[1].body).toEqual({ event: "task.completed", source: "StudyTrack", identifier: "i" });
    expect(new WebhookTaskService("pas une url", fetcher).isConfigured).toBe(false);
  });

  it("Google : jeton renouvelé une fois, première liste, tâches terminées lues", async () => {
    const { fetcher, calls } = recorder({
      "oauth2.googleapis.com/token": { access_token: "at", expires_in: 3600 },
      "users/@me/lists": { items: [{ id: "L1" }] },
      "lists/L1/tasks": { items: [{ id: "g1", title: "Lire", status: "completed", due: "2026-11-04T00:00:00Z" }] },
    });
    const svc = new GoogleTasksTaskService("client", "", "refresh", fetcher);
    const tasks = await svc.fetchTasks();
    expect(tasks[0]).toMatchObject({ identifier: "g1", isDone: true });
    await svc.setCompleted("g1", false);
    expect(calls.filter((c) => c.url.includes("oauth2")).length).toBe(1);
    expect(calls.at(-1)).toMatchObject({ method: "PATCH", body: { status: "needsAction" } });
  });

  it("TickTick : projet, tâches terminées (status 2), cocher par projet", async () => {
    const { fetcher, calls } = recorder({
      "/open/v1/project/P1/data": { project: { name: "Etudes" }, tasks: [{ id: "t1", title: "TP", status: 2, priority: 3 }] },
      "/open/v1/project": [{ id: "P1" }],
    });
    const svc = new TickTickTaskService("tok", fetcher);
    const tasks = await svc.fetchTasks();
    expect(tasks[0]).toMatchObject({ identifier: "t1", isDone: true, priority: 3, listName: "Etudes" });
    await svc.setCompleted("t1", true);
    expect(calls.at(-1)?.url).toBe("https://api.ticktick.com/open/v1/project/P1/task/t1/complete");
  });
});

describe("Fabrique et synchronisation", () => {
  const settings = (values: Record<string, string>) => (key: string) => values[key] ?? "";

  it("seuls les fournisseurs configurés existent ; le webhook ne se lit pas", () => {
    const s = settings({ todoistToken: "x", webhookURL: "https://h.example/x" }) as never;
    expect(service("todoist", undefined, s)?.provider).toBe("todoist");
    expect(service("notion", undefined, s)).toBeNull();
    expect(service("reminders", undefined, s)).toBeNull();
    expect(readableServices(undefined, s).map((x) => x.provider)).toEqual(["todoist"]);
  });

  function fake(provider: "todoist", tasks: ExternalTask[]): TaskService {
    return {
      provider, isConfigured: true, requestAccess: async () => true, fetchTasks: async () => tasks,
      createTask: async () => null, setCompleted: async () => true, deleteTask: async () => true,
    };
  }
  const external = (id: string, title: string, isDone = false): ExternalTask =>
    ({ identifier: id, title, notes: "", dueDate: null, isDone, priority: 1, listName: "" });

  it("crée, met à jour, et retire ce que le fournisseur a retiré", async () => {
    const store = new ModelStore();
    const first = await syncTasks(store, [fake("todoist", [external("1", "A"), external("2", "B")])]);
    expect(first).toMatchObject({ fetched: 2, created: 2, updated: 0, removed: 0 });
    const second = await syncTasks(store, [fake("todoist", [external("1", "A bis", true)])]);
    expect(second).toMatchObject({ created: 0, updated: 1, removed: 1 });
    const left = store.fetch(LinkedTask);
    expect(left).toHaveLength(1);
    expect(left[0]).toMatchObject({ title: "A bis", isDone: true });
  });

  it("une réponse vide du fournisseur ne vide pas la liste locale", async () => {
    const store = new ModelStore();
    await syncTasks(store, [fake("todoist", [external("1", "A")])]);
    const result = await syncTasks(store, [fake("todoist", [])]);
    expect(result.removed).toBe(0);
    expect(store.fetch(LinkedTask)).toHaveLength(1);
  });

  it("cocher une tâche la coche aussi chez le fournisseur ; le code du cours la rattache", async () => {
    const store = new ModelStore();
    const course = new Course({ code: "CS-250", name: "Algorithms I" });
    store.insert(course);
    const task = new LinkedTask({ provider: "todoist", externalID: "1", title: "Série CS-250" });
    store.insert(task);
    const asked: [string, boolean][] = [];
    const svc = { ...fake("todoist", []), setCompleted: async (id: string, done: boolean) => { asked.push([id, done]); return true; } };
    await setDone(task, true, svc);
    expect(task.isDone).toBe(true);
    expect(asked).toEqual([["1", true]]);
    autoLink([task], [course]);
    expect(task.course).toBe(course);
  });
});
