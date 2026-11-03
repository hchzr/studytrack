import { describe, expect, it, vi } from "vitest";
import { KeepAwakePolicy } from "../../src/domain/keepAwakePolicy.ts";
import { needsUpdate, planKeepAwake, startKeepAwake } from "../../src/native/keepAwake.ts";
import { KIOSK_NOTE, lockStatusLine, startStudyLock } from "../../src/native/studyLock.ts";
import { inactiveMini, miniProgress, miniSeconds, miniSubtitle, type MiniState } from "../../src/native/miniState.ts";
import { enterStudyFullscreen } from "../../src/native/fullscreen.ts";
import { miniWanted } from "../../src/native/miniBridge.ts";

const t0 = new Date("2026-11-02T10:00:00Z");
const running = { studying: true, running: true, onBreak: false, until: new Date(t0.getTime() + 3600_000) };

describe("keep-awake", () => {
  it("tient système puis écran selon le mode, relâche en pause", () => {
    const power = KeepAwakePolicy.plugged;
    expect(planKeepAwake("system", running, power, t0)).toMatchObject({ mode: "system", leaseSeconds: 3600 + 300 });
    expect(planKeepAwake("display", running, power, t0).mode).toBe("display");
    expect(planKeepAwake("display", { ...running, running: false }, power, t0).mode).toBe("off");
    expect(planKeepAwake("display", { ...running, running: false, onBreak: true }, power, t0).mode).toBe("system");
    expect(planKeepAwake("off", running, power, t0).mode).toBe("off");
  });
  it("session sans fin : bail de 2 h", () => {
    expect(planKeepAwake("system", { ...running, until: null }, KeepAwakePolicy.plugged, t0).leaseSeconds).toBe(7200);
  });
  it("n'écrit que si la tenue ou l'échéance change", () => {
    const plan = { mode: "system" as const, leaseSeconds: 600 };
    expect(needsUpdate(null, plan, 0)).toBe(true);
    expect(needsUpdate(null, { mode: "off", leaseSeconds: 0 }, 0)).toBe(false);
    expect(needsUpdate({ mode: "system", expiryMs: 600_000 }, plan, 0)).toBe(false);
    expect(needsUpdate({ mode: "system", expiryMs: 900_000 }, plan, 0)).toBe(true);
    expect(needsUpdate({ mode: "display", expiryMs: 600_000 }, plan, 0)).toBe(true);
  });
  it("s'abonne, n'envoie que les changements et relâche à l'arrêt", async () => {
    let source = { ...running };
    let notify = () => {};
    const sent: string[] = [];
    const stop = startKeepAwake(
      { subscribe: (l) => { notify = l; return () => {}; }, source: () => source },
      () => "system",
      (plan) => { sent.push(plan.mode); },
      () => t0,
    );
    await Promise.resolve(); await Promise.resolve();
    notify(); await Promise.resolve(); await Promise.resolve();
    expect(sent).toEqual(["system"]);
    source = { ...source, running: false };
    notify(); await Promise.resolve(); await Promise.resolve();
    expect(sent).toEqual(["system", "off"]);
    stop();
  });
});

describe("blocage", () => {
  it("démarre et arrête le verrou avec blocks() (no-op hors Tauri)", async () => {
    let blocks = false;
    let notify = () => {};
    const stop = startStudyLock({ subscribe: (l) => { notify = l; return () => {}; }, blocks: () => blocks, until: () => null });
    blocks = true; notify(); await Promise.resolve();
    blocks = false; notify(); await Promise.resolve();
    stop();
  });
  it("appelle study_lock_start puis study_lock_stop, une fois chacun", async () => {
    vi.resetModules();
    const calls: string[] = [];
    vi.doMock("../../src/native/tauri.ts", () => ({
      inNative: () => true,
      callNative: async (command: string) => { calls.push(command); return command === "study_lock_start" ? { supported: true, active: true, keysBlocked: true, note: null } : null; },
    }));
    const lock = await import("../../src/native/studyLock.ts");
    let blocks = true;
    let notify = () => {};
    const stop = lock.startStudyLock({ subscribe: (l) => { notify = l; return () => {}; }, blocks: () => blocks, until: () => null });
    const settle = async () => { for (let i = 0; i < 6; i++) await Promise.resolve(); };
    await settle();
    notify(); await settle(); // déjà tenu : pas de second départ
    expect(calls).toEqual(["study_lock_start"]);
    expect(lock.studyLockStatus.snapshot()?.keysBlocked).toBe(true);
    blocks = false; notify(); await settle();
    expect(calls).toEqual(["study_lock_start", "study_lock_stop"]);
    expect(lock.studyLockStatus.snapshot()).toBeNull();
    stop();
    vi.doUnmock("../../src/native/tauri.ts");
  });
  it("décrit le verrou sans promettre ce qu'il ne tient pas", () => {
    expect(KIOSK_NOTE).toContain("Ctrl+Alt+Suppr");
  });
});

describe("ligne Blocage", () => {
  const report = { supported: true, active: true, keysBlocked: true, note: null };
  it("ne dit rien hors de l'app, dit « désactivé » si le blocage est coupé", () => {
    expect(lockStatusLine(null, true, false)).toBeNull();
    expect(lockStatusLine(null, false, true)).toContain("désactivé");
    expect(lockStatusLine(null, true, true)).toContain("démarrage");
  });
  it("rend compte de ce que Rust tient vraiment", () => {
    expect(lockStatusLine(report, true, true)).toContain("occupe l'écran");
    expect(lockStatusLine({ ...report, keysBlocked: false, note: "les raccourcis du système n'ont pas pu être bloqués" }, true, true))
      .toContain("n'ont pas pu être bloqués");
    expect(lockStatusLine({ ...report, supported: false, active: false, note: "le verrou n'existe que dans l'app Windows" }, true, true))
      .toContain("n'existe que");
  });
});

describe("plein écran du mode étude", () => {
  const fake = (initial: boolean) => {
    const calls: boolean[] = [];
    let full = initial;
    return { calls, win: { isFullscreen: async () => full, setFullscreen: async (v: boolean) => { full = v; calls.push(v); } } };
  };
  const settle = async () => { for (let i = 0; i < 6; i++) await Promise.resolve(); };
  it("entre en plein écran puis rend la fenêtre", async () => {
    const { calls, win } = fake(false);
    const stop = enterStudyFullscreen(win);
    await settle(); stop(); await settle();
    expect(calls).toEqual([true, false]);
  });
  it("laisse en plein écran une fenêtre qui l'était déjà", async () => {
    const { calls, win } = fake(true);
    const stop = enterStudyFullscreen(win);
    await settle(); stop(); await settle();
    expect(calls).toEqual([]);
  });
  it("ne casse rien sans fenêtre ou si l'API refuse", async () => {
    enterStudyFullscreen(null)();
    const stop = enterStudyFullscreen({ isFullscreen: async () => { throw new Error("refusé"); }, setFullscreen: async () => {} });
    await settle(); stop(); await settle();
  });
});

describe("chrono flottant", () => {
  const base: MiniState = {
    ...inactiveMini, active: true, phase: "working", running: true, countdown: true,
    seconds: 90, sentAt: 1_000_000, ringValue: 100, ringLength: 1000, what: "Série 1", courseCode: "MATH-101", status: "Bloc 1",
  };
  it("avance seconde après seconde sans nouveau message", () => {
    expect(miniSeconds(base, 1_000_000)).toBe(90);
    expect(miniSeconds(base, 1_030_500)).toBe(60);
    expect(miniSeconds({ ...base, countdown: false, seconds: 10 }, 1_005_000)).toBe(15);
    expect(miniSeconds(base, 9_000_000)).toBe(0);
    expect(miniProgress(base, 1_100_000)).toBeCloseTo(0.2);
  });
  it("s'arrête en pause", () => {
    const paused = { ...base, running: false };
    expect(miniSeconds(paused, 5_000_000)).toBe(90);
    expect(miniProgress(paused, 5_000_000)).toBeCloseTo(0.1);
  });
  it("sous-titre : statut, mode étude, fin", () => {
    expect(miniSubtitle(base, 0)).toBe("Bloc 1 · Série 1");
    expect(miniSubtitle({ ...base, status: null }, 0)).toBe("MATH-101 · Série 1");
    const study = { ...base, studying: true, studyUntil: 10 * 60_000 };
    expect(miniSubtitle(study, 0)).toBe("Mode étude · reste 10 min");
    expect(miniSubtitle(study, 11 * 60_000)).toBe("Mode étude · temps écoulé");
    expect(miniSubtitle({ ...study, studyUntil: null }, 0)).toBe("Mode étude");
  });
  it("visible seulement avec le réglage et une session", () => {
    expect(miniWanted(true, null)).toBe(false);
    expect(miniWanted(false, {} as never)).toBe(false);
    expect(miniWanted(true, {} as never)).toBe(true);
    // Sous le verrou d'étude, le chrono flottant reste caché.
    expect(miniWanted(true, { studyUntil: new Date(Date.now() + 3600_000) } as never)).toBe(false);
  });
  it("cachée tant que StudyTrack est devant (fin du mode étude, récapitulatif)", () => {
    expect(miniWanted(true, {} as never, true)).toBe(false);
    expect(miniWanted(true, {} as never, false)).toBe(true);
  });
});
