import { defineConfig } from "vitest/config";

export default defineConfig({
  // Les tests ne lisent jamais le `.env` local (clés Supabase du développement) :
  // le service de synchronisation doit s'y dire « non configuré », sur ce Mac
  // comme sur la CI.
  envDir: "tests/env",
  test: {
    // Les moteurs comptent en heure locale, comme `Calendar.current` côté Swift ;
    // Validation/main.swift tourne à Zurich, les tests aussi (CI Windows comprise).
    setupFiles: ["tests/setup.ts"],
  },
});
