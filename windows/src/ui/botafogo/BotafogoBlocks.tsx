// Un document Botafogo dessiné comme sur le site (StudyKit/BotafogoViews.swift) : texte et
// formules, listes en colonnes, théorèmes encadrés, exercices, indications et solutions
// repliées, quiz, images, vidéos et figures (l'image fixe que le site publie à côté).

import { useState } from "react";
import type { BotafogoBlock, BotafogoFold, BotafogoQuizChoice, BotafogoTheoremKind } from "../../domain/botafogoPage.ts";
import { BotafogoFigure } from "../../domain/siteContent.ts";
import { Institution } from "../../domain/institution.ts";
import type { BotafogoBook } from "../../services/botafogoBook.ts";
import { MathTeX, RichInline } from "../rich/RichText.tsx";
import { Icon } from "../icons.tsx";
import "./botafogo.css";

export interface BlockContext {
  book: BotafogoBook;
  onLink: (href: string) => void;
}

const THEOREM_TITLE: Record<BotafogoTheoremKind, string> = {
  theorem: "Théorème", definition: "Définition", proposition: "Proposition", lemma: "Lemme",
  corollary: "Corollaire", remark: "Remarque", example: "Exemple", other: "",
};

const FOLD_TITLE: Record<BotafogoFold, string> = {
  solution: "Solution", hint: "Indication", proof: "Preuve", aside: "Pour aller plus loin",
};

export function BotafogoBlocks({ blocks, context }: { blocks: BotafogoBlock[]; context: BlockContext }) {
  return (
    <div className="bf-blocks">
      {blocks.map((block, index) => (
        <div key={index} id={`block-${index}`} className="bf-block">
          <Block block={block} context={context} />
        </div>
      ))}
    </div>
  );
}

function Block({ block, context }: { block: BotafogoBlock; context: BlockContext }) {
  const { book, onLink } = context;
  switch (block.type) {
    case "paragraph":
      return <p className="bf-p"><RichInline text={block.text} onLink={onLink} /></p>;
    case "heading": {
      const Tag = (block.level <= 2 ? "h2" : block.level === 3 ? "h3" : "h4") as "h2" | "h3" | "h4";
      return <Tag className="bf-h serif"><RichInline text={block.text} onLink={onLink} /></Tag>;
    }
    case "math":
      return <MathTeX tex={block.tex} display />;
    case "list": {
      const Tag = block.ordered ? "ol" : "ul";
      return (
        <Tag className="bf-list" style={block.columns > 1 ? { columnCount: block.columns } : undefined}>
          {block.items.map((item, index) => (
            <li key={index}><BotafogoBlocks blocks={item} context={context} /></li>
          ))}
        </Tag>
      );
    }
    case "image": {
      const src = book.assetURL(block.source);
      return src ? <img className="bf-img" src={src} alt="" loading="lazy" style={block.width ? { maxWidth: block.width } : undefined} /> : null;
    }
    case "figure": {
      const src = book.assetURL(BotafogoFigure.imagePath(block.script));
      return src ? <img className="bf-img" src={src} alt="Figure" loading="lazy" style={block.width ? { maxWidth: block.width } : undefined} /> : null;
    }
    case "animation":
    case "video": {
      const src = book.assetURL(block.source);
      const poster = block.type === "video" && block.poster ? book.assetURL(block.poster) ?? undefined : undefined;
      return src ? (
        <figure className="bf-video">
          <video src={src} poster={poster} controls preload="metadata" />
          {block.title && <figcaption>{block.title}</figcaption>}
        </figure>
      ) : null;
    }
    case "kaltura": {
      const address = `https://${Institution.current.videoHostName}/media/t/${block.id}`;
      return (
        <button type="button" className="bf-media-link" onClick={() => onLink(address)}>
          <Icon name="play.rectangle.fill" size={18} />
          <span>{block.title || "Vidéo du cours"}</span>
          <span className="bf-media-host">MediaSpace</span>
        </button>
      );
    }
    case "theorem": {
      const label = THEOREM_TITLE[block.kind];
      return (
        <section className={`bf-theorem bf-theorem-${block.kind}`}>
          {(label || block.title) && (
            <header>
              {label && <strong>{label}</strong>}
              {block.title && <span> <RichInline text={block.title} onLink={onLink} /></span>}
            </header>
          )}
          <BotafogoBlocks blocks={block.content} context={context} />
        </section>
      );
    }
    case "aside":
      return (
        <section className="bf-aside">
          <header><Icon name="lightbulb" size={14} /> {block.title || "À retenir"}</header>
          <BotafogoBlocks blocks={block.content} context={context} />
        </section>
      );
    case "exercise":
      return (
        <section className="bf-exercise">
          <header className="serif">{block.label}</header>
          <BotafogoBlocks blocks={block.content} context={context} />
        </section>
      );
    case "folded":
      return <Folded fold={block.fold} title={block.title} content={block.content} context={context} />;
    case "quiz":
      return <Quiz title={block.title} prompt={block.prompt} choices={block.choices} columns={block.columns} context={context} />;
  }
}

function Folded({ fold, title, content, context }: { fold: BotafogoFold; title: string; content: BotafogoBlock[]; context: BlockContext }) {
  const [open, setOpen] = useState(false);
  return (
    <section className={`bf-fold${open ? " open" : ""}`}>
      <button type="button" className="bf-fold-head" aria-expanded={open} onClick={() => setOpen(!open)}>
        <Icon name={open ? "chevron.down" : "chevron.right"} size={13} strokeWidth={2.4} />
        <span>{title || FOLD_TITLE[fold]}</span>
      </button>
      {open && <div className="bf-fold-body"><BotafogoBlocks blocks={content} context={context} /></div>}
    </section>
  );
}

function Quiz({ title, prompt, choices, columns, context }: {
  title: string; prompt: BotafogoBlock[]; choices: BotafogoQuizChoice[]; columns: number; context: BlockContext;
}) {
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [checked, setChecked] = useState(false);
  const toggle = (index: number) => {
    if (checked) return;
    const next = new Set(picked);
    if (next.has(index)) next.delete(index); else next.add(index);
    setPicked(next);
  };
  return (
    <section className="bf-quiz">
      <header className="serif">{title || "Quiz"}</header>
      <BotafogoBlocks blocks={prompt} context={context} />
      <div className="bf-quiz-choices" style={{ gridTemplateColumns: `repeat(${Math.max(1, columns)}, minmax(0, 1fr))` }}>
        {choices.map((choice, index) => {
          const state = !checked ? (picked.has(index) ? "picked" : "")
            : choice.correct ? "correct" : picked.has(index) ? "wrong" : "";
          return (
            <button key={index} type="button" className={`bf-choice ${state}`} aria-pressed={picked.has(index)} onClick={() => toggle(index)}>
              <span className="bf-choice-box" aria-hidden>{checked ? (choice.correct ? "✓" : picked.has(index) ? "✗" : "") : picked.has(index) ? "●" : ""}</span>
              <span><RichInline text={choice.text} onLink={context.onLink} />
                {checked && choice.explanation && <span className="bf-choice-why"><RichInline text={choice.explanation} onLink={context.onLink} /></span>}
              </span>
            </button>
          );
        })}
      </div>
      <div className="bf-quiz-actions">
        {checked
          ? <button type="button" className="btn" onClick={() => { setChecked(false); setPicked(new Set()); }}>Recommencer</button>
          : <button type="button" className="btn btn-primary" disabled={picked.size === 0} onClick={() => setChecked(true)}>Vérifier</button>}
      </div>
    </section>
  );
}
