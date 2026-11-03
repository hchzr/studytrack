// Les blocs d'une page de site (Ed, Courseware, Moodle) : texte et formules, images, et les
// fichiers, vidéos et liens rendus à l'app (`openWeb` décide où les ouvrir).

import type { SiteBlock } from "../../domain/siteContent.ts";
import { Icon } from "../icons.tsx";
import { RichInline } from "./RichText.tsx";
import "../botafogo/botafogo.css";

/** Les blocs d'un message d'Ed (texte et formules, images, fichiers, liens). */
export function SiteBlocks({ blocks, openWeb }: { blocks: SiteBlock[]; openWeb: (url: string) => void }) {
  return (
    <div className="bf-blocks">
      {blocks.map((block, index) => {
        switch (block.type) {
          case "markdown":
            return block.text.split(/\n{2,}/).map((paragraph, i) => (
              <p key={`${index}-${i}`} className="bf-p" style={{ whiteSpace: "pre-wrap" }}><RichInline text={paragraph} onLink={openWeb} /></p>
            ));
          case "image": return <img key={index} className="bf-img" src={block.url} alt="" loading="lazy" />;
          case "file": case "video": case "link":
            return (
              <button key={index} type="button" className="bf-media-link" onClick={() => openWeb(block.url)}>
                <Icon name={block.type === "video" ? "play.rectangle.fill" : block.type === "file" ? "doc.text" : "link"} size={16} />
                <span>{block.title || block.url}</span>
              </button>
            );
        }
      })}
    </div>
  );
}

