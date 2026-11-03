import { describe, expect, it } from "vitest";
import { countsEvent, countsSession, isCheckable, standardCounting, toggleChecked, type CountableEvent } from "../../src/domain/studyCounting.ts";

// Les mêmes règles que Validation/main.swift (StudyTime.Counting).
const at = (m: number) => new Date(Date.UTC(2026, 9, 5, 8) + m * 60_000);
const lecture = (patch: Partial<CountableEvent> = {}): CountableEvent => ({
  kind: "lecture", isSkipped: false, isAttended: false, durationSeconds: 105 * 60,
  startsAt: at(0), endsAt: at(105), course: { isTracked: true }, ...patch,
});
const later = at(500);

describe("ce qui compte", () => {
  it("un amphi fini compte tout seul, pas manqué, cours suivi", () => {
    expect(countsEvent(standardCounting, lecture(), later)).toBe(true);
    expect(countsEvent(standardCounting, lecture({ isSkipped: true }), later)).toBe(false);
    expect(countsEvent(standardCounting, lecture({ course: { isTracked: false } }), later)).toBe(false);
    expect(countsEvent(standardCounting, lecture({ course: null }), later)).toBe(false);
  });
  it("si confirmés : seulement « J'y étais »", () => {
    const c = { ...standardCounting, lectures: "confirmed" as const };
    const e = lecture();
    expect(countsEvent(c, e, later)).toBe(false);
    toggleChecked(c, e, later);
    expect(e.isAttended && countsEvent(c, e, later)).toBe(true);
  });
  it("séances d'exercices au choix", () => {
    const e = lecture({ kind: "exerciseSession" });
    expect(countsEvent(standardCounting, e, later)).toBe(false);
    expect(isCheckable(standardCounting, e, later)).toBe(false);
    expect(countsEvent({ ...standardCounting, exerciseSessions: true }, e, later)).toBe(true);
  });
  it("sessions par source", () => {
    const c = { ...standardCounting, timer: false, lectures: "off" as const };
    expect(countsSession(c, { taskTypeRaw: "theory", isManual: true, isFromAnki: false })).toBe(true);
    expect(countsSession(c, { taskTypeRaw: "theory", isManual: false, isFromAnki: false })).toBe(false);
    expect(countsSession(c, { taskTypeRaw: "lecture", isManual: true, isFromAnki: false })).toBe(false);
    expect(countsSession(c, { taskTypeRaw: "flashcards", isManual: false, isFromAnki: true })).toBe(true);
  });
  it("manqué puis compté de nouveau", () => {
    const e = lecture();
    toggleChecked(standardCounting, e, later);
    expect(e.isSkipped).toBe(true);
    toggleChecked(standardCounting, e, later);
    expect(countsEvent(standardCounting, e, later)).toBe(true);
  });
});
