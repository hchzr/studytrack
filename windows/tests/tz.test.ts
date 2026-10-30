import { expect, it } from "vitest";

it("les tests tournent à l'heure de Zurich", () => {
  expect(new Date("2026-07-01T12:00:00Z").getHours()).toBe(14);
  expect(new Date("2026-01-01T12:00:00Z").getHours()).toBe(13);
});
