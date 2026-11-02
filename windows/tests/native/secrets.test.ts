import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { appStorage, isSecretKey, resetSecretsForTests, SECRET_KEYS } from "../../src/native/secrets.ts";

// Un `localStorage` en mémoire : Node n'en a pas.
function memoryStorage(): Storage {
  const table = new Map<string, string>();
  return {
    get length() { return table.size; },
    clear: () => table.clear(),
    getItem: (k) => table.get(k) ?? null,
    key: (i) => [...table.keys()][i] ?? null,
    removeItem: (k) => { table.delete(k); },
    setItem: (k, v) => { table.set(k, String(v)); },
  };
}

describe("secrets", () => {
  let previous: PropertyDescriptor | undefined;
  beforeEach(() => {
    previous = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
    Object.defineProperty(globalThis, "localStorage", { value: memoryStorage(), configurable: true });
  });
  afterEach(() => {
    resetSecretsForTests();
    if (previous) Object.defineProperty(globalThis, "localStorage", previous);
    else delete (globalThis as { localStorage?: Storage }).localStorage;
  });

  it("les jetons et la session sont secrets, pas les réglages ordinaires", () => {
    expect(isSecretKey("settings.todoistToken")).toBe(true);
    expect(isSecretKey("ankiweb.hostKey")).toBe(true);
    expect(isSecretKey("studytrack.supabase.session")).toBe(true);
    expect(isSecretKey("settings.timetableURLString")).toBe(false);
    expect(isSecretKey("ankiweb.username")).toBe(false);
    expect(new Set(SECRET_KEYS).size).toBe(SECRET_KEYS.length);
  });

  it("hors de l'app (coffre non chargé) : tout passe par localStorage", () => {
    appStorage.setItem("settings.todoistToken", "abc");
    expect(globalThis.localStorage.getItem("settings.todoistToken")).toBe("abc");
    expect(appStorage.getItem("settings.todoistToken")).toBe("abc");
  });

  it("coffre chargé : un secret ne touche jamais localStorage, un réglage ordinaire si", () => {
    resetSecretsForTests(new Map());
    appStorage.setItem("settings.notionToken", "secret");
    appStorage.setItem("settings.notionDatabaseID", "db");
    expect(globalThis.localStorage.getItem("settings.notionToken")).toBeNull();
    expect(appStorage.getItem("settings.notionToken")).toBe("secret");
    expect(globalThis.localStorage.getItem("settings.notionDatabaseID")).toBe("db");
  });

  it("coffre chargé : une chaîne vide ou un retrait efface le secret", () => {
    resetSecretsForTests(new Map([["ankiweb.hostKey", "k"], ["settings.tickTickToken", "t"]]));
    appStorage.setItem("ankiweb.hostKey", "");
    appStorage.removeItem("settings.tickTickToken");
    expect(appStorage.getItem("ankiweb.hostKey")).toBeNull();
    expect(appStorage.getItem("settings.tickTickToken")).toBeNull();
  });
});
