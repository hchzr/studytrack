// Les schémas de la fiche (DiagramViews.swift) : un enchaînement, des dépendances, un arbre, ou un
// tableau de comparaison, dessinés par Claude à partir de la fiche. Toucher un nœud ouvre la notion.

import { useState } from "react";
import type { RevisionSheet } from "../../domain/revisionSheet.ts";
import type { StudyMap } from "../../domain/studyMap.ts";
import { DiagramLayout, type Diagram } from "../../domain/studyMapGraph.ts";
import { RichInline } from "../rich/RichText.tsx";
import { MasteryDot } from "./StudyMapViews.tsx";

const KIND_LABEL: Record<string, string> = { flow: "Enchaînement", dependencies: "Dépendances", tree: "Arbre", comparison: "Comparaison" };
const NODE = { w: 176, h: 56 };

export function DiagramsView({ sheet, map, chapter, tint, openConcept, comprehend }: {
  sheet: RevisionSheet; map: StudyMap; chapter: string | null; tint: string;
  openConcept: (key: string) => void; comprehend: React.ReactNode;
}) {
  const [chosen, setChosen] = useState<string | null>(null);
  const order = sheet.chapters.map((c) => c.id);
  const shown = map.diagrams
    .filter((d) => chapter === null || d.chapter === chapter)
    .sort((a, b) => order.indexOf(a.chapter ?? "") - order.indexOf(b.chapter ?? ""));
  if (shown.length === 0) {
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 10, alignItems: "flex-start" }}>
        <span className="serif" style={{ fontSize: 22, color: "var(--ink)" }}>{chapter === null ? "Des schémas pour comprendre" : "Pas encore de schéma pour ce chapitre"}</span>
        <span style={{ fontSize: 14, color: "var(--ink-secondary)" }}>Claude dessine les enchaînements, les méthodes et les pièges du cours à partir de la fiche.</span>
        {comprehend}
      </div>
    );
  }
  const current = shown.find((d) => d.id === chosen) ?? shown[0];
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <div style={{ display: "flex", gap: 8, overflowX: "auto", paddingBottom: 2 }}>
        {shown.map((d) => (
          <button key={d.id} type="button" className="chip" aria-pressed={d.id === current.id} onClick={() => setChosen(d.id)} style={{ flex: "none" }}>
            {d.title}
          </button>
        ))}
      </div>
      <div>
        <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: 1, textTransform: "uppercase", color: tint }}>{KIND_LABEL[current.kind] ?? current.kind}</div>
        <div className="serif" style={{ fontSize: 24, color: "var(--ink)" }}><RichInline text={current.title} /></div>
        {current.summary && <div style={{ fontSize: 14, color: "var(--ink-secondary)" }}><RichInline text={current.summary} /></div>}
      </div>
      {current.kind === "comparison" ? <ComparisonTable diagram={current} /> : <DiagramCanvas diagram={current} map={map} tint={tint} open={openConcept} />}
      {comprehend}
    </div>
  );
}

function DiagramCanvas({ diagram, map, tint, open }: { diagram: Diagram; map: StudyMap; tint: string; open: (key: string) => void }) {
  const layout = DiagramLayout.layered(diagram, NODE.w, NODE.h);
  const back = new Set(layout.backEdges.map((e) => `${e.from}>${e.to}`));
  return (
    <div style={{ overflowX: "auto" }}>
      <div style={{ position: "relative", width: layout.width, height: layout.height, margin: "6px 0" }}>
        <svg width={layout.width} height={layout.height} style={{ position: "absolute", inset: 0, overflow: "visible" }} aria-hidden>
          {diagram.edges.map((edge, index) => {
            const a = layout.positions[edge.from];
            const b = layout.positions[edge.to];
            if (!a || !b) return null;
            const isBack = back.has(`${edge.from}>${edge.to}`);
            const sx = a.x, sy = a.y + NODE.h / 2, ex = b.x, ey = b.y - NODE.h / 2;
            const path = isBack
              ? (() => { const side = Math.max(a.x, b.x) + NODE.w / 2 + 24; return `M${sx},${sy} C${side},${sy + 30} ${side},${b.y} ${b.x + NODE.w / 2},${b.y}`; })()
              : `M${sx},${sy} C${sx},${sy + (ey - sy) / 2} ${ex},${ey - (ey - sy) / 2} ${ex},${ey}`;
            return (
              <g key={index}>
                <path d={path} fill="none" stroke="var(--ink-secondary)" strokeOpacity={0.8} strokeWidth={1.6} strokeDasharray={isBack ? "5 4" : undefined} />
                {!isBack && <path d={`M${ex - 5},${ey - 9} L${ex},${ey} L${ex + 5},${ey - 9}`} fill="none" stroke="var(--ink-secondary)" strokeWidth={1.6} />}
                {edge.label && <text x={(sx + ex) / 2 + 14} y={(sy + ey) / 2} fontSize={11} fontWeight={600} fill="var(--ink-secondary)">{edge.label}</text>}
              </g>
            );
          })}
        </svg>
        {diagram.nodes.map((node) => {
          const p = layout.positions[node.id];
          if (!p) return null;
          const level = node.entry ? map.mastery(node.entry) : null;
          return (
            <button key={node.id} type="button" title={node.entry ? "Ouvrir la notion" : undefined} disabled={!node.entry}
              onClick={() => node.entry && open(node.entry)}
              style={{
                position: "absolute", left: p.x - NODE.w / 2, top: p.y - NODE.h / 2, width: NODE.w, height: NODE.h,
                display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 2, padding: "0 8px",
                background: "var(--sheet)", borderRadius: 11, cursor: node.entry ? "pointer" : "default", color: "var(--ink)",
                border: node.entry ? `1.5px solid color-mix(in srgb, ${tint} 70%, transparent)` : "1px solid var(--rule)",
              }}>
              <span style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 12, textAlign: "center", lineHeight: 1.25 }}>
                {level && <MasteryDot level={level} size={10} />}
                <RichInline text={node.label} />
              </span>
              {node.detail && <span style={{ fontSize: 10, color: "var(--ink-secondary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: "100%" }}>{node.detail}</span>}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function ComparisonTable({ diagram }: { diagram: Diagram }) {
  const columns = diagram.columns ?? [];
  const rows = diagram.rows ?? [];
  const cell = (text: string, header: boolean, shaded = false, key?: number) => (
    <td key={key} style={{ padding: "8px 12px", fontWeight: header ? 600 : 400, background: shaded ? "var(--sheet)" : undefined, borderTop: "1px solid var(--rule)", fontSize: 13, verticalAlign: "top" }}>
      <RichInline text={text} />
    </td>
  );
  return (
    <div style={{ overflowX: "auto", border: "1px solid var(--rule)", borderRadius: 12 }}>
      <table style={{ borderCollapse: "collapse", minWidth: "100%" }}>
        <thead><tr>{cell("", true)}{columns.map((c, i) => cell(c, true, false, i))}</tr></thead>
        <tbody>{rows.map((row, r) => <tr key={r}>{row.map((value, c) => cell(value, c === 0, r % 2 === 1, c))}</tr>)}</tbody>
      </table>
    </div>
  );
}
