import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Les moteurs comptent en heure locale, comme `Calendar.current` côté Swift ;
    // Validation/main.swift tourne à Zurich, les tests aussi (CI Windows comprise).
    setupFiles: ["tests/setup.ts"],
  },
});
