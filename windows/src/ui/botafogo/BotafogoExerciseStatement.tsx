// L'énoncé d'un exercice tel que le site Botafogo le montre (BotafogoExerciseStatement du Mac) :
// la page de l'exercice si elle existe, sinon l'exercice à sa place dans la page de la série —
// sous-questions, formules, indications et solutions repliées, liens vers le polycopié.

import { useEffect, useState } from "react";
import type { BotafogoBlock } from "../../domain/botafogoPage.ts";
import { BotafogoPage } from "../../domain/botafogoPage.ts";
import { BotafogoLinks } from "../../domain/botafogoProgram.ts";
import { botafogoBook } from "../../services/botafogoBook.ts";
import { BotafogoBlocks } from "./BotafogoBlocks.tsx";

/** L'exercice vient-il d'une page Botafogo (la série ou son énoncé) ? */
export function hasBotafogoStatement(site: string | null, seriesURL: string, statementURL: string): boolean {
  return site !== null && (BotafogoLinks.isPage(seriesURL) || BotafogoLinks.isPage(statementURL));
}

export function BotafogoExerciseStatement({ site, seriesURL, statementURL, position, tint, openWeb, onEmpty }: {
  site: string;
  seriesURL: string;
  statementURL: string;
  /** La place de l'exercice dans sa série (quand on n'a que la série). */
  position: number;
  tint: string;
  openWeb: (url: string) => void;
  /** Rien de lisible sur le site : l'écran montre son énoncé à lui. */
  onEmpty?: () => void;
}) {
  const book = botafogoBook(site);
  const [blocks, setBlocks] = useState<BotafogoBlock[] | null>(null);
  useEffect(() => {
    let alive = true;
    setBlocks(null);
    void (async () => {
      await book.load();
      const exercisePath = BotafogoLinks.coursPath(statementURL);
      if (exercisePath) {
        const page = await book.page(exercisePath);
        if (page && page.length > 0) { if (alive) setBlocks(page); return; }
      }
      const seriesPath = BotafogoLinks.coursPath(seriesURL);
      if (seriesPath) {
        const page = await book.page(seriesPath);
        const exercises = page ? BotafogoPage.exercises(page) : [];
        const found = exercises[position];
        if (found) { if (alive) setBlocks([{ type: "exercise", label: found.label, content: found.blocks }]); return; }
      }
      if (alive) { setBlocks([]); onEmpty?.(); }
    })();
    return () => { alive = false; };
  }, [site, seriesURL, statementURL, position]);

  if (blocks === null) return <p style={{ color: "var(--ink-tertiary)", margin: 0 }}>Lecture de l'énoncé sur le site du cours…</p>;
  if (blocks.length === 0) return null;
  const onLink = (href: string) => {
    let url: URL | null = null;
    try { url = new URL(href, book.root ?? book.site); } catch { return; }
    openWeb(url.toString());
  };
  return (
    <div style={{ ["--bf-tint" as string]: tint, fontSize: 16 }}>
      <BotafogoBlocks blocks={blocks} context={{ book, onLink }} />
    </div>
  );
}
