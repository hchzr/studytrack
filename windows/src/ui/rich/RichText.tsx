// Le texte des sites de cours, mis en page pour de vrai (StudyKit/MathTypeset + RichTextViews) :
// les formules par KaTeX (fractions, matrices, systèmes), et le Markdown léger que produisent
// les lecteurs (`**gras**`, `*italique*`, `` `code` ``, `[lien](adresse)`, `$formule$`).
// Une formule que KaTeX ne sait pas lire reste lisible en texte, jamais en erreur rouge.

import { memo, type ReactNode } from "react";
import katex from "katex";
import "katex/dist/katex.min.css";

const cache = new Map<string, string | null>();

/** Le HTML de KaTeX pour une formule ; `null` si elle ne passe pas. */
export function renderTeX(tex: string, display: boolean): string | null {
  const key = (display ? "D|" : "T|") + tex;
  if (cache.has(key)) return cache.get(key) ?? null;
  let html: string | null;
  try {
    html = katex.renderToString(tex, {
      displayMode: display,
      throwOnError: true,
      strict: "ignore",
      trust: false,
      output: "html",
      // Les macros des polycopiés EPFL les plus courantes.
      macros: {
        "\\R": "\\mathbb{R}", "\\N": "\\mathbb{N}", "\\Z": "\\mathbb{Z}", "\\Q": "\\mathbb{Q}", "\\C": "\\mathbb{C}",
        "\\dd": "\\mathrm{d}", "\\eps": "\\varepsilon",
      },
    });
  } catch {
    try {
      // Une commande inconnue : KaTeX l'écrit en rouge plutôt que de tout perdre.
      html = katex.renderToString(tex, { displayMode: display, throwOnError: false, strict: "ignore", trust: false, errorColor: "currentColor" });
    } catch {
      html = null;
    }
  }
  if (cache.size > 2000) cache.clear();
  cache.set(key, html);
  return html;
}

export const MathTeX = memo(function MathTeX({ tex, display = false }: { tex: string; display?: boolean }) {
  const html = renderTeX(tex, display);
  if (html === null) return display ? <div className="mono">{tex}</div> : <span className="mono">{tex}</span>;
  if (display) {
    return <div className="rich-display-math" dangerouslySetInnerHTML={{ __html: html }} />;
  }
  return <span dangerouslySetInnerHTML={{ __html: html }} />;
});

type Token =
  | { kind: "text"; text: string }
  | { kind: "math"; tex: string; display: boolean }
  | { kind: "bold" | "italic"; children: Token[] }
  | { kind: "code"; text: string }
  | { kind: "link"; children: Token[]; href: string };

/** Découpe le Markdown léger des lecteurs. Les `$` d'une formule ne sont jamais pris pour du texte. */
export function tokenize(source: string): Token[] {
  const out: Token[] = [];
  let buffer = "";
  const flush = () => { if (buffer) { out.push({ kind: "text", text: buffer }); buffer = ""; } };
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (c === "\\" && source[i + 1] === "$") { buffer += "$"; i += 2; continue; }
    if (c === "$") {
      const display = source[i + 1] === "$";
      const open = display ? 2 : 1;
      const close = source.indexOf(display ? "$$" : "$", i + open);
      if (close > i + open) {
        flush();
        out.push({ kind: "math", tex: source.slice(i + open, close), display });
        i = close + open;
        continue;
      }
    }
    if (c === "`") {
      const close = source.indexOf("`", i + 1);
      if (close > i) { flush(); out.push({ kind: "code", text: source.slice(i + 1, close) }); i = close + 1; continue; }
    }
    if (c === "*" && source[i + 1] === "*") {
      const close = source.indexOf("**", i + 2);
      if (close > i + 2) { flush(); out.push({ kind: "bold", children: tokenize(source.slice(i + 2, close)) }); i = close + 2; continue; }
    }
    if (c === "*" && source[i + 1] !== " ") {
      const close = source.indexOf("*", i + 1);
      if (close > i + 1 && source[close - 1] !== " ") {
        flush(); out.push({ kind: "italic", children: tokenize(source.slice(i + 1, close)) }); i = close + 1; continue;
      }
    }
    if (c === "[") {
      const end = matchBracket(source, i);
      if (end > 0 && source[end + 1] === "(") {
        const close = source.indexOf(")", end + 2);
        if (close > end) {
          flush();
          out.push({ kind: "link", children: tokenize(source.slice(i + 1, end)), href: source.slice(end + 2, close) });
          i = close + 1;
          continue;
        }
      }
    }
    buffer += c;
    i++;
  }
  flush();
  return out;
}

/** Le `]` qui ferme le `[` en `start`, en sautant les formules (`$[0,1]$`). */
function matchBracket(source: string, start: number): number {
  let depth = 0;
  let inMath = false;
  for (let i = start; i < source.length; i++) {
    const c = source[i];
    if (c === "$") inMath = !inMath;
    if (inMath) continue;
    if (c === "[") depth++;
    if (c === "]") { depth--; if (depth === 0) return i; }
  }
  return -1;
}

function render(tokens: Token[], onLink: ((href: string) => void) | undefined, key = ""): ReactNode[] {
  return tokens.map((token, index) => {
    const k = key + index;
    switch (token.kind) {
      case "text": return <span key={k}>{token.text}</span>;
      case "math": return <MathTeX key={k} tex={token.tex} display={token.display} />;
      case "code": return <code key={k} className="mono rich-code">{token.text}</code>;
      case "bold": return <strong key={k}>{render(token.children, onLink, k + "b")}</strong>;
      case "italic": return <em key={k}>{render(token.children, onLink, k + "i")}</em>;
      case "link":
        return (
          <a key={k} href={token.href} className="rich-link" onClick={(event) => {
            event.preventDefault();
            onLink?.(token.href);
          }}>
            {render(token.children, onLink, k + "l")}
          </a>
        );
    }
  });
}

/** Une phrase avec ses formules et ses liens. `onLink` reçoit l'adresse (l'app décide où l'ouvrir). */
export function RichInline({ text, onLink }: { text: string; onLink?: (href: string) => void }) {
  return <>{render(tokenize(text), onLink)}</>;
}
