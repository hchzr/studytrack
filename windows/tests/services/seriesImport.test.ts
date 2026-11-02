// L'import d'une série depuis un PDF : la recherche d'un exercice dans la mise en
// page (PDFExerciseCrop), les règles de l'écran d'import (SeriesImportSheet) et
// l'appel à la fonction Supabase (SeriesAIExtractor). Aucun de ces comportements
// n'a de check dans Validation/main.swift (PDFKit et URLSession n'y tournent pas) :
// ce sont des tests propres au port.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PDFExerciseCrop } from "../../src/services/pdfExerciseCrop.ts";
import { PDFLayoutLine } from "../../src/domain/seriesLayout.ts";
import { DetectedExercise, DetectedSeries } from "../../src/services/seriesPDFParser.ts";
import { SeriesImportFlow } from "../../src/services/seriesImportFlow.ts";
import {
  ExtractionError, SeriesAIExtractor, SeriesExtractionSource, resetSharedVerdict,
} from "../../src/services/seriesAIExtractor.ts";

const line = (text: string, pageIndex: number, verticalPosition: number) =>
  PDFLayoutLine.make(text, { pageIndex, verticalPosition, fontSize: 12 });

describe("PDFExerciseCrop", () => {
  const exercise = { exerciseNumber: "3.2", title: "Center of mass of a rod", displayNumber: "Exercice 3.2", seriesNumber: 3 };

  it("les mots qui retrouvent un exercice, du plus sûr au moins sûr", () => {
    expect(PDFExerciseCrop.terms(exercise)).toEqual([
      "Ex-03-02", "Exercice 3.2", "Exercice 2", "Exercise 2", "Ex. 2", "Problème 2", "Problem 2",
      "Exercice 3.2", "Center of mass of a rod",
    ]);
  });

  it("un titre trop court ou égal au numéro n'est pas un mot de recherche", () => {
    const short = { ...exercise, title: "Ex" };
    expect(PDFExerciseCrop.terms(short)).not.toContain("Ex");
    const same = { ...exercise, title: "Exercice 3.2" };
    expect(PDFExerciseCrop.terms(same).filter((t) => t === "Exercice 3.2")).toHaveLength(2);
  });

  it("« Exercice 1 » ne trouve pas « Exercice 10 », ni une mention dans un énoncé", () => {
    expect(PDFExerciseCrop.isHeading("Exercice 10", "Exercice 1")).toBe(false);
    expect(PDFExerciseCrop.isHeading("Exercice 1 : Tri", "Exercice 1")).toBe(true);
    expect(PDFExerciseCrop.isHeading("utilise l'Exercise 1 pour conclure", "Exercise 1")).toBe(false);
  });

  it("le numéro de liste « 1. » devant un titre s'ôte", () => {
    expect(PDFExerciseCrop.isHeading("1. Center of mass of a rod", "Center of mass of a rod")).toBe(true);
    expect(PDFExerciseCrop.isHeading("(2) Center of mass", "Center of mass")).toBe(true);
  });

  it("la zone va du titre au titre suivant, page après page", () => {
    const lines = [
      line("Exercice 1", 0, 0.1), line("énoncé", 0, 0.2),
      line("Exercice 2", 0, 0.6), line("suite", 1, 0.2),
      line("Exercice 3", 1, 0.5),
    ];
    const region = PDFExerciseCrop.region(lines, 2, ["Exercice 2"], ["Exercice 3"]);
    expect(region?.parts.map((p) => p.page)).toEqual([0, 1]);
    expect(region?.parts[0].top).toBeCloseTo(0.58);
    expect(region?.parts[0].bottom).toBe(1);
    expect(region?.parts[1].top).toBe(0);
    expect(region?.parts[1].bottom).toBeCloseTo(0.489);
  });

  it("introuvable : pas de zone", () => {
    expect(PDFExerciseCrop.region([line("Exercice 1", 0, 0.1)], 1, ["Exercice 9"], [])).toBeNull();
  });

  it("le dernier exercice court jusqu'à la page suivante au plus", () => {
    const region = PDFExerciseCrop.region([line("Exercice 1", 0, 0.1)], 5, ["Exercice 1"], []);
    expect(region?.parts.map((p) => p.page)).toEqual([0, 1]);
  });

  it("les parties d'un sujet d'examen : la numérotation la plus longue, au moins deux", () => {
    const lines = [line("Question 1", 0, 0.1), line("Question 2", 0, 0.4), line("Question 3", 1, 0.2), line("Exercice 1", 0, 0.05)];
    expect(PDFExerciseCrop.questions(lines)).toEqual(["Question 1", "Question 2", "Question 3"]);
    expect(PDFExerciseCrop.questions([line("Exercice 1", 0, 0.1)])).toEqual([]);
  });
});

describe("SeriesImportFlow", () => {
  const ex = (number: string, labels: string[] = []) => DetectedExercise.make({
    number, title: "", isBonus: false,
    subQuestions: labels.map((label) => ({ label, text: "", kind: "question" as const, children: [], id: label })),
  });
  const series = (...exercises: DetectedExercise[]): DetectedSeries[] => [{ number: 3, title: "", exercises }];

  it("la semaine par défaut : le numéro de la série quand il tient dans le semestre, sinon la semaine en cours", () => {
    expect(SeriesImportFlow.defaultWeek(4, { totalWeeks: 14, currentWeek: 9 })).toBe(4);
    expect(SeriesImportFlow.defaultWeek(20, { totalWeeks: 14, currentWeek: 9 })).toBe(9);
    expect(SeriesImportFlow.defaultWeek(20, { totalWeeks: 14, currentWeek: 0 })).toBe(1);
    expect(SeriesImportFlow.defaultWeek(15, null)).toBe(1);
  });

  it("le résumé dit ce que le modèle a changé", () => {
    const local = series(ex("3.1"), ex("3.2"), ex("3.3"));
    const merged = series(ex("3.1", ["1", "2"]), ex("3.2"));
    expect(SeriesImportFlow.summary(local, merged, "vision"))
      .toBe("2 exercices, 3 cases · questions relues pour 1 · 1 repère douteux écarté — IA StudyTrack · lecture des pages");
    expect(SeriesImportFlow.summary(series(ex("3.1")), series(ex("3.1"), ex("3.2")), "shared"))
      .toBe("2 exercices, 2 cases · 1 ajouté — IA StudyTrack (sans clé)");
  });

  it("la lecture locale : un exercice repéré, au singulier", () => {
    expect(SeriesImportFlow.localSummary(series(ex("3.1")))).toBe("1 exercice repéré");
    expect(SeriesImportFlow.localSummary(series())).toBe("0 exercice repéré");
    expect(SeriesImportFlow.localSummary(series(ex("3.1"), ex("3.2")))).toBe("2 exercices repérés");
  });

  it("l'aperçu d'un exercice s'arrête où commence le suivant, s'il est sur la même page", () => {
    const first = DetectedExercise.make({ number: "3.1", title: "", isBonus: false, pageIndex: 0, verticalPosition: 0.1 });
    const second = DetectedExercise.make({ number: "3.2", title: "", isBonus: false, pageIndex: 0, verticalPosition: 0.5 });
    const third = DetectedExercise.make({ number: "3.3", title: "", isBonus: false, pageIndex: 1, verticalPosition: 0.1 });
    const drafts = SeriesImportFlow.draftsFrom([{ number: 3, title: "", exercises: [first, second, third] }], null);
    expect(drafts[0].exercises.map((e) => e.bottom)).toEqual([0.5, undefined, undefined]);
    expect(drafts[0].plannedWeek).toBe(3);
  });

  it("corriger à la main change l'empreinte des brouillons", () => {
    const drafts = SeriesImportFlow.draftsFrom(series(ex("3.1"), ex("3.2")), null);
    const before = SeriesImportFlow.fingerprint(drafts);
    expect(SeriesImportFlow.fingerprint(SeriesImportFlow.draftsFrom(series(ex("3.1"), ex("3.2")), null))).toBe(before);
    drafts[0].exercises[0].title = "Corrigé";
    expect(SeriesImportFlow.fingerprint(drafts)).not.toBe(before);
  });

  it("un texte collé : une ligne par ligne, sans police", () => {
    const lines = SeriesImportFlow.linesFromText("Série 3\r\nExercice 1\nExercice 2");
    expect(lines.map((l) => l.text)).toEqual(["Série 3", "Exercice 1", "Exercice 2"]);
    expect(lines.every((l) => l.fontSize === 0)).toBe(true);
  });
});

describe("SeriesAIExtractor", () => {
  const answer = JSON.stringify({ series: [{ number: 3, title: "", exercises: [{ number: "3.1", title: "", isBonus: false }] }] });

  beforeEach(() => {
    resetSharedVerdict();
    vi.stubEnv("VITE_SUPABASE_URL", "https://example.supabase.co");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon");
  });
  afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });

  it("la source dit si elle a vu la mise en page", () => {
    expect(SeriesExtractionSource.readsLayout("vision")).toBe(true);
    expect(SeriesExtractionSource.readsLayout("shared")).toBe(false);
    expect(SeriesExtractionSource.label("heuristic")).toBe("détection par motifs");
  });

  it("l'IA désactivée : aucun moteur", async () => {
    expect(SeriesAIExtractor.plannedSource(false)).toBeNull();
    expect(SeriesAIExtractor.plannedSource(true)).toBe("shared");
    await expect(SeriesAIExtractor.extract("texte", { aiExtractionEnabled: false })).rejects.toMatchObject({ kind: "unavailable" });
  });

  it("les pages d'abord : la lecture « vision » l'emporte, avec l'indice de série et la langue", async () => {
    const fetchMock = vi.fn(async () => new Response(answer, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const result = await SeriesAIExtractor.extract("texte", {
      aiExtractionEnabled: true, pageImages: [new Uint8Array([1, 2, 3])], seriesHint: 3, language: "français",
    });
    expect(result.source).toBe("vision");
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://example.supabase.co/functions/v1/extract-series");
    const body = JSON.parse(String(init.body));
    expect(body.images).toEqual(["AQID"]);
    expect(body.seriesHint).toBe(3);
    expect(body.language).toBe("français");
    expect((init.headers as Record<string, string>).apikey).toBe("anon");
  });

  it("sans page : le texte seul, source « shared »", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(answer, { status: 200 })));
    const result = await SeriesAIExtractor.extract("texte", { aiExtractionEnabled: true });
    expect(result.source).toBe("shared");
    expect(result.series[0].exercises[0].number).toBe("3.1");
  });

  it("404 : fonction non déployée, et on n'insiste plus", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("not found", { status: 404 })));
    await expect(SeriesAIExtractor.extract("texte", { aiExtractionEnabled: true }))
      .rejects.toMatchObject({ kind: "sharedNotDeployed", detail: 404 });
    expect(SeriesAIExtractor.sharedIsReachable()).toBe(false);
    expect(SeriesAIExtractor.plannedSource(true)).toBeNull();
  });

  it("une réponse vide : « rien de structuré »", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ series: [] }), { status: 200 })));
    const error = await SeriesAIExtractor.extract("texte", { aiExtractionEnabled: true }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ExtractionError);
    expect((error as ExtractionError).message).toBe("Le modèle n'a rien trouvé de structuré dans ce texte.");
  });

  it("un refus du service est rapporté avec son code", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("quota", { status: 429 })));
    await expect(SeriesAIExtractor.extract("texte", { aiExtractionEnabled: true }))
      .rejects.toThrow("Le service distant a refusé : fonction StudyTrack : HTTP 429 quota");
  });
});
