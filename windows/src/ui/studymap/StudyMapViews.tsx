// La fiche vue autrement (RevisionSheetView du Mac) : la **carte** mentale du cours (chapitres
// et notions autour du cours, repliables), le **parcours** (par où commencer, ce qui est à
// reprendre d'abord, chaque notion dans l'ordre où la comprendre) et, pour chaque notion, sa
// fiche — l'énoncé, en clair, ce qui vient avant et après, et où l'on en est (pas encore,
// fragile, solide). Ce qui est à toi (maîtrise, carte) est rangé dans le cours, synchronisé.

import { useMemo, useState } from "react";
import type { Course } from "../../models/course.ts";
import { RevisionSheet } from "../../domain/revisionSheet.ts";
import { StudyMap, StudyMastery } from "../../domain/studyMap.ts";
import { LearningPath, MindGraph, MindLayout, StudyLinks, type MindNode } from "../../domain/studyMapGraph.ts";
import { RichInline } from "../rich/RichText.tsx";
import { Icon } from "../icons.tsx";

const MASTERY_COLOR: Record<StudyMastery, string> = { 0: "var(--ink-tertiary)", 1: "var(--review)", 2: "var(--correct)" };

export function readStudyMap(course: Course): StudyMap {
  return StudyMap.decode(course.studyMapRaw) ?? new StudyMap();
}

/** Change la carte du cours et la range (synchronisée avec le cours). */
export function updateStudyMap(course: Course, save: (instance: object) => Promise<void>, change: (map: StudyMap) => void): void {
  const map = readStudyMap(course);
  change(map);
  course.studyMapRaw = map.isEmpty && map.enrichedAt === null ? "" : map.encoded();
  void save(course);
}

export function MasteryDot({ level, size = 10 }: { level: StudyMastery; size?: number }) {
  return (
    <span aria-label={StudyMastery.label(level)} title={StudyMastery.label(level)} style={{
      display: "inline-block", width: size, height: size, borderRadius: "50%", flexShrink: 0,
      background: level === 0 ? "transparent" : MASTERY_COLOR[level], border: `1.5px solid ${MASTERY_COLOR[level]}`,
    }} />
  );
}

// MARK: - Le parcours

export function LearningPathView({ sheet, map, chapter, tint, openConcept, selectChapter }: {
  sheet: RevisionSheet; map: StudyMap; chapter: string | null; tint: string;
  openConcept: (key: string) => void; selectChapter: (id: string | null) => void;
}) {
  const counts = LearningPath.counts(sheet, map, chapter);
  const order = LearningPath.order(sheet, map, chapter);
  const next = LearningPath.next(sheet, map, chapter);
  const weak = LearningPath.weakSpots(sheet, map, 4, chapter);
  const nextItem = next ? sheet.entryForKey(next) : null;
  const chapters = sheet.chapters.filter((item) => item.entries.length > 0);
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 22 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
        <Ring fraction={counts.fraction} />
        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>{counts.solid} notions solides sur {counts.total}</span>
          <span style={{ display: "flex", gap: 12, fontSize: 12, color: "var(--ink-secondary)" }}>
            {([2, 1, 0] as StudyMastery[]).map((level) => (
              <span key={level} style={{ display: "inline-flex", alignItems: "center", gap: 4 }}>
                <MasteryDot level={level} size={11} />
                {level === 2 ? counts.solid : level === 1 ? counts.shaky : counts.unknown} {StudyMastery.label(level).toLowerCase()}
              </span>
            ))}
          </span>
        </div>
      </div>

      {chapter === null && chapters.length > 1 && (
        <section style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <Kicker>Chapitre par chapitre</Kicker>
          {chapters.map((item) => {
            const c = LearningPath.counts(sheet, map, item.id);
            return (
              <button key={item.id} type="button" onClick={() => selectChapter(item.id)} style={row}>
                <span style={{ flex: 1, minWidth: 0, textAlign: "left" }}><RichInline text={item.title} /></span>
                <span style={{ width: 90, height: 5, borderRadius: 3, background: "var(--rule)", overflow: "hidden" }}>
                  <span style={{ display: "block", height: "100%", width: `${c.fraction * 100}%`, background: "var(--correct)" }} />
                </span>
                <span className="mono" style={{ width: 44, textAlign: "right", fontSize: 12, color: "var(--ink-secondary)" }}>{c.solid}/{c.total}</span>
                <Icon name="chevron.right" size={12} />
              </button>
            );
          })}
        </section>
      )}

      {nextItem && (
        <button type="button" onClick={() => openConcept(nextItem.key)} style={{
          ...row, padding: 14, borderRadius: 14, border: `1px solid color-mix(in srgb, ${tint} 40%, transparent)`,
          background: `color-mix(in srgb, ${tint} 12%, transparent)`,
        }}>
          <Icon name={map.mastery(nextItem.key) === 0 ? "play.fill" : "arrow.clockwise"} size={18} color={tint} />
          <span style={{ flex: 1, minWidth: 0, textAlign: "left", display: "flex", flexDirection: "column", gap: 2 }}>
            <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>{map.mastery(nextItem.key) === 0 ? "Commencer par" : "Reprendre"}</span>
            <span className="serif" style={{ fontSize: 16, color: "var(--ink)" }}><RichInline text={nextItem.entry.title} /></span>
            <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>{nextItem.chapterTitle}</span>
          </span>
          <Icon name="chevron.right" size={12} />
        </button>
      )}

      {weak.length > 0 && counts.solid + counts.shaky > 0 && (
        <section style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <Kicker>À reprendre d'abord</Kicker>
          <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>Ce qui n'est pas solide et sur quoi d'autres notions s'appuient.</span>
          {weak.map((key) => {
            const item = sheet.entryForKey(key);
            return item ? <ConceptRow key={key} title={item.entry.title} level={map.mastery(key)} onClick={() => openConcept(key)} /> : null;
          })}
        </section>
      )}

      <section style={{ display: "flex", flexDirection: "column", gap: 2 }}>
        <Kicker>Dans l'ordre pour comprendre</Kicker>
        {order.map((key, index) => {
          const item = sheet.entryForKey(key);
          if (!item) return null;
          return (
            <button key={key} type="button" onClick={() => openConcept(key)} style={{ ...row, background: "none", padding: "6px 4px" }}>
              <span className="mono" style={{ width: 26, textAlign: "right", fontSize: 12, color: "var(--ink-tertiary)" }}>{index + 1}</span>
              <MasteryDot level={map.mastery(key)} size={12} />
              <span style={{ flex: 1, minWidth: 0, textAlign: "left", display: "flex", flexDirection: "column" }}>
                <span style={{ fontSize: 14, color: "var(--ink)" }}><RichInline text={item.entry.title} /></span>
                {map.enrichment[key]?.gist && <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}><RichInline text={map.enrichment[key]!.gist!} /></span>}
              </span>
            </button>
          );
        })}
      </section>
    </div>
  );
}

const row: React.CSSProperties = {
  display: "flex", alignItems: "center", gap: 12, width: "100%", padding: "9px 12px", borderRadius: 10,
  border: "none", background: "var(--sheet)", color: "var(--ink)", cursor: "pointer", font: "inherit",
};

function Kicker({ children }: { children: React.ReactNode }) {
  return <span style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.08em", textTransform: "uppercase", color: "var(--ink-tertiary)" }}>{children}</span>;
}

function Ring({ fraction }: { fraction: number }) {
  const r = 32;
  const c = 2 * Math.PI * r;
  return (
    <svg width={74} height={74} viewBox="0 0 74 74" aria-hidden>
      <circle cx={37} cy={37} r={r} fill="none" stroke="var(--rule)" strokeWidth={7} />
      <circle cx={37} cy={37} r={r} fill="none" stroke="var(--correct)" strokeWidth={7} strokeLinecap="round"
        strokeDasharray={`${c * fraction} ${c}`} transform="rotate(-90 37 37)" />
      <text x={37} y={42} textAnchor="middle" fontSize={14} fontWeight={600} fill="var(--ink)">{Math.round(fraction * 100)} %</text>
    </svg>
  );
}

function ConceptRow({ title, level, onClick }: { title: string; level: StudyMastery; onClick: () => void }) {
  return (
    <button type="button" onClick={onClick} style={row}>
      <MasteryDot level={level} size={12} />
      <span style={{ flex: 1, minWidth: 0, textAlign: "left", fontSize: 14 }}><RichInline text={title} /></span>
      <Icon name="chevron.right" size={12} />
    </button>
  );
}

// MARK: - La carte mentale

export function MindMapView({ sheet, map, courseTitle, chapter, tint, openConcept, toggleCollapsed }: {
  sheet: RevisionSheet; map: StudyMap; courseTitle: string; chapter: string | null; tint: string;
  openConcept: (key: string) => void; toggleCollapsed: (id: string) => void;
}) {
  const all = useMemo(() => MindGraph.nodes(sheet, map, courseTitle, chapter), [sheet, map, courseTitle, chapter]);
  const nodes = MindGraph.visible(all, map.collapsed);
  const positions = MindLayout.twoSided(nodes);
  const bounds = MindLayout.bounds(positions);
  if (!bounds) return <p style={{ color: "var(--ink-tertiary)" }}>Pas encore de notions sur la fiche.</p>;
  const pad = 140;
  const width = bounds.maxX - bounds.minX + pad * 2;
  const height = bounds.maxY - bounds.minY + 80;
  const at = (id: string) => {
    const p = positions[id];
    return p ? { x: p.x - bounds.minX + pad, y: p.y - bounds.minY + 40 } : null;
  };
  const hasChildren = new Set(all.filter((node) => node.parent !== null).map((node) => node.parent!));
  return (
    <div style={{ overflow: "auto", border: "1px solid var(--rule)", borderRadius: 14, background: "var(--sheet)", maxHeight: "70vh" }}>
      <svg width={width} height={height} style={{ display: "block" }}>
        {nodes.filter((node) => node.parent !== null).map((node) => {
          const a = at(node.parent!);
          const b = at(node.id);
          if (!a || !b) return null;
          const mid = (a.x + b.x) / 2;
          return <path key={`e-${node.id}`} d={`M${a.x},${a.y} C${mid},${a.y} ${mid},${b.y} ${b.x},${b.y}`} fill="none" stroke="var(--rule-strong, var(--rule))" strokeWidth={1.5} />;
        })}
        {nodes.map((node) => {
          const p = at(node.id);
          if (!p) return null;
          return <MindLabel key={node.id} node={node} x={p.x} y={p.y} tint={tint} level={node.role.kind === "entry" ? map.mastery(node.id) : null}
            collapsed={map.collapsed.has(node.id)} collapsible={node.role.kind !== "root" && hasChildren.has(node.id)}
            onClick={() => {
              if (node.role.kind === "entry") openConcept(node.id);
              else if (node.role.kind === "chapter" || hasChildren.has(node.id)) toggleCollapsed(node.id);
            }} />;
        })}
      </svg>
    </div>
  );
}

function MindLabel({ node, x, y, tint, level, collapsed, collapsible, onClick }: {
  node: MindNode; x: number; y: number; tint: string; level: StudyMastery | null; collapsed: boolean; collapsible: boolean; onClick: () => void;
}) {
  const root = node.role.kind === "root";
  const chapter = node.role.kind === "chapter";
  const label = node.title.replace(/\$([^$]*)\$/g, "$1");
  const text = label.length > 34 ? label.slice(0, 33) + "…" : label;
  const w = Math.max(60, text.length * (root ? 9 : 7) + (level !== null ? 22 : 16));
  const h = root ? 34 : 26;
  return (
    <g transform={`translate(${x - w / 2},${y - h / 2})`} style={{ cursor: "pointer" }} onClick={onClick}>
      <title>{label}</title>
      <rect width={w} height={h} rx={h / 2} fill={root ? tint : chapter ? "var(--sheet-raised, var(--sheet))" : "var(--sheet)"}
        stroke={root ? tint : chapter ? `color-mix(in srgb, ${tint} 50%, transparent)` : "var(--rule)"} />
      {level !== null && <circle cx={12} cy={h / 2} r={4} fill={level === 0 ? "none" : MASTERY_COLOR[level]} stroke={MASTERY_COLOR[level]} strokeWidth={1.5} />}
      <text x={level !== null ? 22 : w / 2} y={h / 2 + 4} textAnchor={level !== null ? "start" : "middle"} fontSize={root ? 14 : 12}
        fontWeight={root || chapter ? 600 : 400} fill={root ? "#fff" : "var(--ink)"}>{text}{collapsible && collapsed ? " +" : ""}</text>
    </g>
  );
}

// MARK: - Une notion

export function ConceptPanel({ sheet, map, conceptKey, tint, setMastery, openConcept, close }: {
  sheet: RevisionSheet; map: StudyMap; conceptKey: string; tint: string;
  setMastery: (level: StudyMastery) => void; openConcept: (key: string) => void; close: () => void;
}) {
  const [revealed, setRevealed] = useState(false);
  const item = sheet.entryForKey(conceptKey);
  if (!item) return null;
  const enrichment = map.enrichment[conceptKey];
  const keys = new Set(sheet.keyedIn(null).map((entry) => entry.key));
  const around = StudyLinks.neighbourhood(conceptKey, map, keys);
  const level = map.mastery(conceptKey);
  const list = (title: string, items: { key: string; note: string | null }[]) => items.length === 0 ? null : (
    <section style={{ display: "flex", flexDirection: "column", gap: 4 }}>
      <Kicker>{title}</Kicker>
      {items.map((neighbour) => {
        const other = sheet.entryForKey(neighbour.key);
        return other ? <ConceptRow key={neighbour.key} title={other.entry.title} level={map.mastery(neighbour.key)} onClick={() => openConcept(neighbour.key)} /> : null;
      })}
    </section>
  );
  return (
    <aside style={{ width: 380, flexShrink: 0, borderLeft: "1px solid var(--rule)", padding: "20px 22px", overflowY: "auto", display: "flex", flexDirection: "column", gap: 16 }}>
      <div style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
        <span style={{ flex: 1, display: "flex", flexDirection: "column", gap: 2 }}>
          <span style={{ fontSize: 12, color: "var(--ink-tertiary)" }}>{item.chapterTitle}</span>
          <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}><RichInline text={item.entry.title} /></span>
        </span>
        <button type="button" className="icon-btn" title="Fermer" onClick={close}><Icon name="xmark" size={14} /></button>
      </div>
      <div style={{ display: "flex", gap: 6 }}>
        {([0, 1, 2] as StudyMastery[]).map((value) => (
          <button key={value} type="button" className="btn" aria-pressed={level === value} onClick={() => setMastery(value)}
            style={level === value ? { borderColor: MASTERY_COLOR[value], color: "var(--ink)" } : undefined}>
            <MasteryDot level={value} size={10} /> {StudyMastery.label(value)}
          </button>
        ))}
      </div>
      <p className="serif" style={{ margin: 0, fontSize: 15, lineHeight: 1.6, color: "var(--ink)", whiteSpace: "pre-wrap" }}><RichInline text={item.entry.body} /></p>
      {enrichment?.gist && <p style={{ margin: 0, fontSize: 14, color: "var(--ink-secondary)" }}><strong style={{ color: tint }}>En clair. </strong><RichInline text={enrichment.gist} /></p>}
      {enrichment?.why && <p style={{ margin: 0, fontSize: 14, color: "var(--ink-secondary)" }}><strong>Pourquoi. </strong><RichInline text={enrichment.why} /></p>}
      {enrichment?.example && <p style={{ margin: 0, fontSize: 14, color: "var(--ink-secondary)" }}><strong>Exemple. </strong><RichInline text={enrichment.example} /></p>}
      {enrichment?.check && (
        <section style={{ padding: 12, borderRadius: 12, background: "var(--sheet-raised, var(--sheet))", display: "flex", flexDirection: "column", gap: 8 }}>
          <Kicker>Vérifie-toi</Kicker>
          <span style={{ fontSize: 14 }}><RichInline text={enrichment.check.question} /></span>
          {revealed
            ? <span style={{ fontSize: 14, color: "var(--ink-secondary)" }}><RichInline text={enrichment.check.answer} /></span>
            : <button type="button" className="btn" style={{ alignSelf: "flex-start" }} onClick={() => setRevealed(true)}>Voir la réponse</button>}
        </section>
      )}
      {list("Avant, il faut", around.before)}
      {list("Ensuite", around.after)}
      {list("À ne pas confondre", around.aside)}
    </aside>
  );
}
