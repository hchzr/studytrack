// Les notes du cours, dans le bureau (NotesPane, réduit) : sur le Mac, ce
// volet lit les cahiers GoodNotes (NotesStore) et le Markdown des notes du
// cours ; sur Windows, il n'y a pas de cahiers — le champ des notes du cours,
// gardé avec lui, en direct.

import { useEffect, useRef, useState } from "react";
import type { Course } from "../../../models/course.ts";
import { Kicker } from "../parts.tsx";

export function NotesPane({ course, save }: {
  course: Course | null;
  save: (instance: object) => Promise<void>;
}) {
  const [text, setText] = useState(() => course?.notes ?? "");
  const writing = useRef<number | null>(null);
  // Le cours auquel le texte affiché appartient (le champ survit aux
  // rechargements de la base ; il ne survit pas à un changement de cours).
  const held = useRef<Course | null>(course);
  const textRef = useRef(text);
  textRef.current = text;

  const commit = (target: Course | null, value: string) => {
    if (!target || target.notes === value) return;
    target.notes = value;
    void save(target);
  };

  // Un autre cours : le texte affiché appartient encore au précédent — on
  // l'écrit là, puis le champ prend les notes du nouveau.
  useEffect(() => {
    if (held.current?.id === course?.id) return;
    commit(held.current, textRef.current);
    held.current = course;
    setText(course?.notes ?? "");
    // Le cours rendu change avec le contexte de la session, pas sa valeur :
    // c'est son identité qui compte, pas l'objet relu après chaque écriture.
  }, [course?.id]);

  // Parti (le panneau se ferme) : l'attente est écrite, pas perdue.
  useEffect(() => () => {
    if (writing.current !== null) window.clearTimeout(writing.current);
    commit(held.current, textRef.current);
  }, []);

  // Le champ écrit le cours, à peine retouché (un peu de mou, pas une écriture
  // par frappe) ; le champ quitté, il écrit tout de suite.
  const onChange = (value: string) => {
    setText(value);
    if (writing.current !== null) window.clearTimeout(writing.current);
    writing.current = window.setTimeout(() => {
      writing.current = null;
      commit(held.current, value);
    }, 600);
  };

  if (!course) {
    return (
      <div style={{ height: "100%", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 10, textAlign: "center" }}>
        <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>Pas de cours</span>
        <span style={{ color: "var(--ink-secondary)", fontSize: 14 }}>Choisis-en un pour la session.</span>
      </div>
    );
  }

  return (
    <div style={{ height: "100%", overflowY: "auto", padding: "24px 28px 40px" }}>
      <div style={{ maxWidth: 760, display: "flex", flexDirection: "column", gap: 12 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
          <Kicker>{course.displayCode} · Notes du cours</Kicker>
          <div style={{ flex: 1 }} />
          <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>Markdown</span>
        </div>
        <textarea
          value={text}
          onChange={(event) => onChange(event.target.value)}
          onBlur={() => {
            if (writing.current !== null) {
              window.clearTimeout(writing.current);
              writing.current = null;
            }
            commit(held.current, textRef.current);
          }}
          placeholder="Barème, ce que le prof a dit…"
          spellCheck={false}
          style={{
            width: "100%", minHeight: "60vh", resize: "vertical", padding: 16, borderRadius: 14,
            border: "1px solid var(--rule)", background: "var(--sheet)", color: "var(--ink)",
            font: "inherit", fontSize: 14, lineHeight: 1.6, outline: "none",
          }}
        />
        {/* Sur le Mac, les cahiers de la série se lisent ici (GoodNotes, via
            NotesStore) ; ils n'ont pas d'équivalent Windows pour l'instant. */}
      </div>
    </div>
  );
}
