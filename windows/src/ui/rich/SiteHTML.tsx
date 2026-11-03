// Le HTML d'un site de cours (Moodle, Ed, Courseware) montré dans l'app : nettoyé (ni script,
// ni gestionnaire d'événement, ni cadre), les formules typographiées par KaTeX (`$$…$$`,
// `\(…\)`, `\[…\]`), et les liens rendus à l'app, qui décide où les ouvrir.

import { useEffect, useMemo, useRef } from "react";
import renderMathInElement from "katex/contrib/auto-render";
import "katex/dist/katex.min.css";

const DROP = "script, style, iframe, object, embed, form, input, button, select, textarea, link, meta, base, noscript";

/** Le HTML sans rien d'exécutable ; les liens et images gardent leur adresse (déjà absolue). */
export function sanitizeHTML(html: string): string {
  const doc = new DOMParser().parseFromString(`<div>${html}</div>`, "text/html");
  const root = doc.body.firstElementChild;
  if (!root) return "";
  root.querySelectorAll(DROP).forEach((node) => node.remove());
  root.querySelectorAll("*").forEach((node) => {
    for (const attribute of [...node.attributes]) {
      const name = attribute.name.toLowerCase();
      const value = attribute.value.trim().toLowerCase();
      if (name.startsWith("on") || name === "style" && /expression|url\(/.test(value)) node.removeAttribute(attribute.name);
      else if ((name === "href" || name === "src" || name === "xlink:href") && /^(javascript|vbscript|data:text)/.test(value)) node.removeAttribute(attribute.name);
    }
  });
  root.querySelectorAll("img").forEach((img) => { img.setAttribute("loading", "lazy"); img.removeAttribute("width"); img.removeAttribute("height"); });
  return root.innerHTML;
}

export function SiteHTML({ html, onLink, className }: { html: string; onLink: (href: string) => void; className?: string }) {
  const clean = useMemo(() => sanitizeHTML(html), [html]);
  const ref = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    try {
      renderMathInElement(el, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "\\[", right: "\\]", display: true },
          { left: "\\(", right: "\\)", display: false },
        ],
        throwOnError: false,
        strict: "ignore",
      });
    } catch {
      // Le texte reste, sans mise en page des formules.
    }
  }, [clean]);
  return (
    <div
      ref={ref}
      className={`site-html ${className ?? ""}`}
      dangerouslySetInnerHTML={{ __html: clean }}
      onClick={(event) => {
        const anchor = (event.target as HTMLElement).closest("a");
        if (!anchor) return;
        const href = anchor.getAttribute("href");
        event.preventDefault();
        if (href && /^https?:/i.test(href)) onLink(href);
      }}
    />
  );
}
