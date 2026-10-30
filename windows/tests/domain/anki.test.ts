// Port des sections « Trame zstd sans compression (AnkiWeb) », « Anki : planification
// des révisions » et « Anki : rendu des cartes » de Validation/main.swift.
// S'y ajoute « Temps Anki relevé automatiquement » (AnkiReviewImport).
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import {
  AnkiClock, AnkiScheduler, FSRS, cardState, defaultDeckOptions, deckOptionsFromJSON, ankiRatings,
} from "../../src/domain/ankiScheduler.ts";
import { AnkiReviewImport, type AnkiReview } from "../../src/domain/ankiReviewImport.ts";
import { AnkiTemplate } from "../../src/domain/ankiTemplate.ts";
import { clozeNumbers, guid } from "../../src/domain/ankiNoteTools.ts";
import { ZstdFrame } from "../../src/domain/zstdFrame.ts";

describe("Trame zstd sans compression (AnkiWeb)", () => {
  const small = new TextEncoder().encode('{"v":11,"cv":"anki,25.02.7 (6ddc22e5),ios"}');
  const large = Uint8Array.from({ length: 300_000 }, (_, i) => i % 251);
  const frame = ZstdFrame.stored(small);

  it("la trame commence par le nombre magique zstd", () => {
    expect(Array.from(frame.slice(0, 4))).toEqual([...ZstdFrame.magic]);
  });
  it("en-tête + un bloc brut", () => {
    expect(frame.length).toBe(small.length + 4 + 1 + 4 + 3);
  });

  // Le vrai décodeur, quand il est installé, relit exactement le contenu.
  const tool = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].find((p) => existsSync(p));
  for (const [label, payload] of [["petit", small], ["300 ko, plusieurs blocs", large]] as const) {
    it.skipIf(!tool)(`zstd relit la trame (${label})`, () => {
      const dir = mkdtempSync(join(tmpdir(), "zst-"));
      try {
        const input = join(dir, "frame.zst");
        writeFileSync(input, ZstdFrame.stored(payload));
        const output = execFileSync(tool!, ["-q", "-d", "-c", input], { maxBuffer: 10_000_000 });
        expect(Array.from(output)).toEqual(Array.from(payload));
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });
  }
});

describe("Anki : planification des révisions", () => {
  // Zurich (tests/setup.ts), comme le calendrier de Validation.
  const creation = new Date(2026, 8, 1, 5);
  const now = new Date(2026, 8, 11, 14);
  const clock = new AnkiClock(now, creation, 4);
  const options = defaultDeckOptions();
  const fresh = cardState();
  const answer = (card: ReturnType<typeof cardState>, rating: 1 | 2 | 3 | 4, opts = options, fsrs = false) =>
    AnkiScheduler.answer(card, rating, opts, clock, fsrs);

  it("jour d'Anki : 10 jours après la création", () => {
    expect(clock.today).toBe(10);
  });
  it("avant 4 h, c'est encore la veille", () => {
    const early = new AnkiClock(new Date(2026, 8, 11, 3), creation, 4);
    expect(early.today).toBe(9);
  });

  const step1 = answer(fresh, 3);
  it("nouvelle carte, « bien » : deuxième étape, 10 min", () => {
    expect(step1.card.type === 1 && step1.card.queue === 1 && step1.card.due === clock.seconds + 600 && step1.card.left === 1).toBe(true);
  });
  it("historique : apprentissage", () => {
    expect(step1.reviewType === 0 && step1.lastInterval === 0).toBe(true);
  });
  it("dernière étape, « bien » : révision dans 1 jour, facilité 250 %", () => {
    const graduated = answer(step1.card, 3);
    expect(graduated.card.type === 2 && graduated.card.ivl === 1 && graduated.card.due === 11 && graduated.card.factor === 2500).toBe(true);
  });
  it("« facile » d'emblée : 4 jours", () => {
    const easy = answer(fresh, 4);
    expect(easy.card.ivl === 4 && easy.card.due === 14).toBe(true);
  });
  it("« à revoir » : retour à la première étape", () => {
    const again = answer(step1.card, 1);
    expect(again.card.left === 2 && again.card.due === clock.seconds + 60).toBe(true);
  });
  it("« difficile » à la première étape : moyenne des deux étapes (5,5 min)", () => {
    expect(answer(fresh, 2).card.due).toBe(clock.seconds + 330);
  });

  const review = cardState({ type: 2, queue: 2, due: 10, ivl: 10, factor: 2500, reps: 5 });
  const r = ankiRatings.map((rating) => answer(review, rating));
  it("révision « difficile » : 10 × 1,2 = 12 j, facilité −15 %", () => {
    expect(r[1].card.ivl === 12 && r[1].card.factor === 2350).toBe(true);
  });
  it("révision « bien » : 10 × 2,5 = 25 j", () => {
    expect(r[2].card.ivl === 25 && r[2].card.factor === 2500).toBe(true);
  });
  it("révision « facile » : 10 × 2,5 × 1,3 = 33 j, +15 %", () => {
    expect(r[3].card.ivl === 33 && r[3].card.factor === 2650).toBe(true);
  });
  it("révision « à revoir » : réapprentissage, oubli compté, facilité −20 %", () => {
    expect(r[0].card.type === 3 && r[0].card.queue === 1 && r[0].card.lapses === 1 && r[0].card.factor === 2300 && r[0].card.ivl === 1).toBe(true);
  });
  it("historique d'une révision", () => {
    expect(r[0].reviewType === 1 && r[0].lastInterval === 10).toBe(true);
  });
  it("réapprentissage terminé : de retour en révision", () => {
    const relearned = answer(r[0].card, 3);
    expect(relearned.card.type === 2 && relearned.card.ivl === 1 && relearned.card.due === 11 && relearned.reviewType === 2).toBe(true);
  });
  it("4 jours de retard comptent à moitié pour « bien » : (10 + 2) × 2,5 = 30 j", () => {
    const late = cardState({ type: 2, queue: 2, due: 6, ivl: 10, factor: 2500 });
    expect(answer(late, 3).card.ivl).toBe(30);
  });
  it("intervalle maximum du paquet respecté", () => {
    const capped = { ...options, maximumInterval: 20 };
    expect(answer(review, 4, capped).card.ivl).toBe(20);
  });

  const fsrsNew = answer(fresh, 3, options, true);
  it("FSRS : stabilité initiale de « bien »", () => {
    const memory = AnkiScheduler.memory(fsrsNew.card);
    expect(memory !== null && Math.abs(memory.s - 3.173) < 0.001).toBe(true);
  });
  const fsrsReview = cardState({ type: 2, queue: 2, due: 10, ivl: 10, factor: 2500, data: '{"s":10,"d":5}' });
  const f = ankiRatings.map((rating) => answer(fsrsReview, rating, options, true).card);
  it("FSRS : difficile < bien < facile", () => {
    expect(f[1].ivl < f[2].ivl && f[2].ivl < f[3].ivl).toBe(true);
  });
  it("FSRS : un oubli fait baisser la stabilité", () => {
    expect(AnkiScheduler.memory(f[0])?.s ?? 99).toBeLessThan(10);
  });
  it("FSRS : à 90 % de rétention, l'intervalle vaut la stabilité", () => {
    expect(Math.abs(new FSRS([]).interval(10, 0.9) - 10)).toBeLessThan(0.01);
  });
  it("options du paquet lues dans le JSON", () => {
    const parsed = deckOptionsFromJSON({
      new: { delays: [1, 10], ints: [2, 5, 0], initialFactor: 2300, perDay: 15 },
      rev: { ease4: 1.4, maxIvl: 3650, hardFactor: 1.1 }, desiredRetention: 0.85,
    });
    expect(parsed.graduatingInterval === 2 && parsed.easyInterval === 5 && parsed.startingEase === 2300 && parsed.newPerDay === 15
      && parsed.easyBonus === 1.4 && parsed.maximumInterval === 3650 && parsed.desiredRetention === 0.85).toBe(true);
  });
  it("libellés des intervalles", () => {
    expect(AnkiScheduler.dayLabel(3) === "3 j" && AnkiScheduler.dayLabel(61) === "2,0 mois").toBe(true);
  });
});

describe("Anki : rendu des cartes", () => {
  const basic = { fields: { Front: "Capitale <b>de la Suisse</b> ?", Back: "Berne", Extra: "" }, ordinal: 0, isCloze: false };
  const front = AnkiTemplate.question("{{Front}}{{#Extra}}<i>{{Extra}}</i>{{/Extra}}", basic);

  it("recto : champ inséré, section vide retirée", () => {
    expect(front).toBe("Capitale <b>de la Suisse</b> ?");
  });
  it("verso : FrontSide et section inverse", () => {
    expect(AnkiTemplate.answer("{{FrontSide}}<hr id=answer>{{Back}}{{^Extra}} (sans note){{/Extra}}", front, basic))
      .toBe("Capitale <b>de la Suisse</b> ?<hr id=answer>Berne (sans note)");
  });
  it("filtre text: retire le HTML", () => {
    expect(AnkiTemplate.question("{{text:Front}}", basic)).toBe("Capitale de la Suisse ?");
  });
  const cloze = { fields: { Text: "La dérivée de {{c1::x²}} est {{c2::2x::linéaire}}." }, ordinal: 1, isCloze: true };
  it("trou 2 au recto : masqué avec son indice, le trou 1 en clair", () => {
    expect(AnkiTemplate.question("{{cloze:Text}}", cloze)).toBe('La dérivée de x² est <span class="cloze">[linéaire]</span>.');
  });
  it("trou 2 au verso : la réponse surlignée", () => {
    expect(AnkiTemplate.answer("{{cloze:Text}}", "", cloze)).toBe('La dérivée de x² est <span class="cloze">2x</span>.');
  });
  it("texte d'un champ HTML", () => {
    expect(AnkiTemplate.stripHTML("a<br>b&nbsp;&amp;")).toBe("a\nb &");
  });
  it("somme de contrôle : 8 premiers chiffres hexadécimaux", () => {
    expect(AnkiTemplate.checksum("1a2b3c4d5e6f")).toBe(0x1a2b3c4d);
  });
});

// Pas de section dédiée dans Validation pour AnkiNoteTools : deux garde-fous maison.
describe("AnkiNoteTools", () => {
  it("numéros des trous : uniques, positifs, triés", () => {
    expect(clozeNumbers("{{c2::a}} {{c1::b}} {{c2::c}} {{c0::d}}")).toEqual([1, 2]);
  });
  it("identifiant global : base 91, jamais vide", () => {
    for (let i = 0; i < 50; i++) expect(guid()).toMatch(/^[a-zA-Z0-9!#$%&()*+,\-./:;<=>?@[\]^_`{|}~]{1,10}$/);
  });
});

describe("Temps Anki relevé automatiquement", () => {
  const deck = "EPFL::MATH-101 Analyse I";
  const parsed: AnkiReview[] = [
    { id: 1727510000000, durationMs: 20000, deck },
    { id: 1727510060000, durationMs: 45000, deck },
    { id: 1727513000000, durationMs: 70000, deck },
  ];
  const drafts = AnkiReviewImport.sessions(parsed);

  it("deux sessions : 49 min d'écart coupent la série", () => {
    expect(drafts.length).toBe(2);
  });
  it("le temps est la somme des réponses, pas l'écart entre cartes", () => {
    expect(drafts[0]?.seconds === 65 && drafts[0]?.reviewCount === 2).toBe(true);
  });
  it("une session d'une carte longue reste comptée", () => {
    expect(drafts[drafts.length - 1]?.seconds).toBe(70);
  });
  it("une carte de 8 s n'est pas une session", () => {
    expect(AnkiReviewImport.sessions([{ id: 1, durationMs: 8000, deck: "X" }])).toEqual([]);
  });
  it("une révision vue dans le paquet parent n'est comptée qu'une fois, au sous-paquet", () => {
    const dup = [...parsed, ...parsed.map((r) => ({ id: r.id, durationMs: r.durationMs, deck: "EPFL" }))];
    expect(AnkiReviewImport.sessions(dup).every((d) => d.deck === deck)).toBe(true);
  });

  const keys = [
    { code: "MATH-101", shortName: "Ana I", name: "Analyse I" },
    { code: "CS-250", shortName: "", name: "Algorithms I" },
  ];
  it("paquet rattaché par code", () => {
    expect(AnkiReviewImport.courseIndex("EPFL::MATH-101 Analyse I", keys)).toBe(0);
  });
  it("paquet rattaché par nom", () => {
    expect(AnkiReviewImport.courseIndex("Algorithms I", keys)).toBe(1);
  });
  it("paquet sans cours : pas d'attribution au hasard", () => {
    expect(AnkiReviewImport.courseIndex("Japonais", keys)).toBeNull();
  });
});
