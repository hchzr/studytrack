import { describe, expect, it } from "vitest";
import { decodeSnapshot, swiftJSON } from "../../src/services/timerLinkClient.ts";
import { newFocusTimerState } from "../../src/domain/focusTimerState.ts";

describe("chrono relié : le format du Mac", () => {
  it("dates en secondes depuis 2001 (JSONEncoder), aller-retour sans perte", () => {
    const started = new Date("2026-11-04T08:00:00Z");
    const state = newFocusTimerState({ sessionStartedAt: started, taskTypeRaw: "exercise", pomodoro: true });
    state.runningSince = new Date("2026-11-04T08:05:00Z");
    const text = swiftJSON({ state, updatedAt: new Date("2026-11-04T08:06:00Z"), device: "A" });
    const raw = JSON.parse(text);
    expect(raw.updatedAt).toBe(new Date("2026-11-04T08:06:00Z").getTime() / 1000 - 978_307_200);
    expect(raw.state.sessionStartedAt).toBe(started.getTime() / 1000 - 978_307_200);
    const back = decodeSnapshot(raw)!;
    expect(back.device).toBe("A");
    expect(back.state?.sessionStartedAt.getTime()).toBe(started.getTime());
    expect(back.state?.runningSince?.getTime()).toBe(state.runningSince.getTime());
    expect(back.state?.pomodoro).toBe(true);
  });
  it("une session terminée ailleurs : pas d'état, la session fermée", () => {
    const ended = new Date("2026-11-04T09:00:00Z");
    const back = decodeSnapshot(JSON.parse(swiftJSON({ endedSession: ended, updatedAt: new Date(), device: "B" })))!;
    expect(back.state).toBeNull();
    expect(back.ended(ended)).toBe(true);
  });
});
