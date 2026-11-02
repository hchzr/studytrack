import { describe, expect, it } from "vitest";
import { KeepAwakePolicy } from "../../src/domain/keepAwakePolicy.ts";
import { needsUpdate, planKeepAwake, startKeepAwake } from "../../src/native/keepAwake.ts";
import { lockNote, sitesToBlock, startStudyLock } from "../../src/native/studyLock.ts";
import { inactiveMini, miniProgress, miniSeconds, miniSubtitle, type MiniState } from "../../src/native/miniState.ts";
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
  it("ne coupe jamais un site que l'étude permet", () => {
    expect(sitesToBlock(["youtube.com", "moodle.epfl.ch", "claude.ai"], ["epfl.ch", "claude.ai"])).toEqual(["youtube.com"]);
  });
  it("dit honnêtement ce qui est tenu", () => {
    expect(lockNote(null, false)).toContain("app Windows");
    expect(lockNote({ supported: true, canBlockSites: false }, true)).toContain("droits administrateur requis");
    expect(lockNote({ supported: true, canBlockSites: true }, true)).not.toContain("droits");
    expect(lockNote({ supported: false, canBlockSites: false }, true)).toContain("pas disponible");
  });
  it("démarre et arrête avec le mode étude (no-op hors Tauri)", async () => {
    let blocks = false;
    let notify = () => {};
    const stop = startStudyLock(
      { subscribe: (l) => { notify = l; return () => {}; }, blocks: () => blocks, until: () => null },
      () => ({ apps: [], sites: [] }),
    );
    blocks = true; notify(); await Promise.resolve();
    blocks = false; notify(); await Promise.resolve();
    stop();
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
  });
});
