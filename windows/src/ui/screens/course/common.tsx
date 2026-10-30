// Les briques communes aux quatre volets d'un cours : coche, pastilles de
// correction, barres, liens. Elles reprennent le dessin de `CourseLines.swift`
// (ExerciseStageMark, CorrectionDots) et de `WeekTheoryCard.swift` (pastilles de
// lien), sans dépendre de SwiftUI.

import type { ReactNode } from "react";
import { ConfidenceLevel, Correctness, TheoryKind, type Tint } from "../../../models/enums.ts";
import type { ContentLink, ContentLinkKind } from "../../../models/jsonTypes.ts";
import type { ExerciseSeries } from "../../../models/exercise.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import type { ExerciseStage } from "../../../domain/exerciseFlow.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { MathMarkup } from "../../../domain/mathMarkup.ts";

/** `SettingsStore.hoursPerCredit` a pour défaut 30 ; les réglages ne sont pas portés. */
export const HOURS_PER_CREDIT = 30;

// MARK: - Couleurs (tokens, jamais des hexadécimaux)

export const CORRECTNESS_COLOR: Record<Correctness, string> = {
  correct: "var(--correct)",
  partial: "var(--review)",
  wrong: "var(--wrong)",
};

export const CONFIDENCE_COLOR: Record<ConfidenceLevel, string> = {
  green: "var(--correct)",
  orange: "var(--review)",
  red: "var(--wrong)",
};

/** Les teintes nommées des énumérations, traduites en variables CSS. */
export function tintColor(tint: Tint): string {
  switch (tint) {
    case "green": return "var(--correct)";
    case "orange": return "var(--review)";
    case "red": return "var(--wrong)";
    case "yellow": return "var(--review)";
    case "gray": return "var(--ink-secondary)";
    case "blue": case "teal": case "indigo": case "purple": case "pink": case "brown": return "var(--ink-secondary)";
  }
}

// MARK: - Liens

export interface LinkTarget {
  title: string;
  url: string;
  icon: string;
}

/** `ExerciseLinks.web` : une adresse http(s) seulement. */
export function webURL(raw: string): string | null {
  const value = raw.trim();
  if (!/^https?:\/\//i.test(value)) return null;
  try {
    return new URL(value).href;
  } catch {
    return null;
  }
}

export function openURL(url: string): void {
  window.open(url, "_blank", "noopener,noreferrer");
}

export function siteName(host: string): string {
  const lower = host.toLowerCase();
  if (lower.includes("mediaspace")) return "MediaSpace";
  if (lower.includes("courseware")) return "Courseware";
  if (lower.includes("botafogo")) return "Botafogo";
  if (lower.includes("moodle")) return "Moodle";
  if (lower.includes("dropbox")) return "Dropbox";
  if (lower.includes("github")) return "GitHub";
  if (lower.includes("youtube") || lower.includes("youtu.be")) return "YouTube";
  return lower.replace("www.", "");
}

export function hostOf(raw: string): string | null {
  const url = webURL(raw);
  if (!url) return null;
  try {
    return new URL(url).hostname || null;
  } catch {
    return null;
  }
}

/** Le glyphe d'un support, à défaut d'un jeu d'icônes (contrat UI : texte seul). */
export function linkGlyph(kind: ContentLinkKind): string {
  switch (kind) {
    case "video": return "▶";
    case "slides": return "◫";
    case "notes": return "✎";
    case "pdf": return "▤";
    case "page": return "↗";
    case "solution": return "✓";
  }
}

export function linkChipLabel(kind: ContentLinkKind): string {
  switch (kind) {
    case "video": return "Vidéo";
    case "slides": return "Transparents";
    case "notes": return "Notes";
    case "pdf": return "PDF";
    case "page": return "Page";
    case "solution": return "Corrigé";
  }
}

/** « transparents », « notes » : le mot d'une ligne de détail. */
export function linkShortLabel(kind: ContentLinkKind): string {
  switch (kind) {
    case "video": return "vidéo";
    case "slides": return "transparents";
    case "notes": return "notes";
    case "pdf": return "PDF";
    case "page": return "page";
    case "solution": return "corrigé";
  }
}

/** `ExerciseLinks.seriesLinks` : l'énoncé puis le corrigé, s'ils sont publiés. */
export function seriesLinks(series: ExerciseSeries, now: Date = new Date()): LinkTarget[] {
  const links: LinkTarget[] = [];
  const statement = webURL(series.urlString);
  if (statement) links.push({ title: "Énoncé de la série", url: statement, icon: "↗" });
  const solution = webURL(series.solutionURLString);
  if (solution) {
    if (series.solutionsAt && series.solutionsAt > now) {
      links.push({ title: `Corrigé (publié le ${DateUtils.shortDay(series.solutionsAt)})`, url: solution, icon: "◷" });
    } else {
      links.push({ title: "Corrigé", url: solution, icon: "✓" });
    }
  }
  return links;
}

/** `ExerciseLinks.links` : l'énoncé de l'exercice, puis ceux de sa série. */
export function exerciseLinks(
  statementURLString: string,
  series: ExerciseSeries | null,
  now: Date = new Date(),
): LinkTarget[] {
  const links: LinkTarget[] = [];
  const statement = webURL(statementURLString);
  if (statement) links.push({ title: "Énoncé de l'exercice", url: statement, icon: "↗" });
  if (series) {
    for (const link of seriesLinks(series, now)) {
      if (!links.some((existing) => existing.url === link.url)) links.push(link);
    }
  }
  return links;
}

/** Les liens d'un élément de théorie, le principal compris. */
export function theoryLinks(item: TheoryItem): ContentLink[] {
  const all: ContentLink[] = item.links.length > 0
    ? item.links
    : (webURL(item.urlString)
      ? [{ title: item.title, url: item.urlString, kind: item.kind === "video" ? "video" : "page" }]
      : []);
  const order: ContentLinkKind[] = ["video", "slides", "notes", "pdf", "page", "solution"];
  return all
    .filter((link) => webURL(link.url) !== null)
    .sort((a, b) => {
      const ia = order.indexOf(a.kind);
      const ib = order.indexOf(b.kind);
      return (ia < 0 ? 9 : ia) - (ib < 0 ? 9 : ib);
    });
}

/** `CarnetTheoryLine.detail(for:)` : « Vidéo · 1 h 32 · MediaSpace ». */
export function theoryDetail(item: TheoryItem): string {
  const links = item.links;
  const parts: string[] = [];
  const videos = links.filter((link) => link.kind === "video").length;
  if (videos > 1) parts.push(`${videos} vidéos`);
  else if (item.videoCount > 1) parts.push(`${item.videoCount} vidéos`);
  else parts.push(TheoryKind.label(item.kind));
  if (item.durationSeconds > 0) parts.push(DateUtils.durationLabel(item.durationSeconds));
  const others = [...new Set(links.map((link) => link.kind))]
    .filter((kind) => kind !== "video")
    .map(linkShortLabel)
    .sort();
  parts.push(...others);
  const host = hostOf(links[0]?.url ?? item.urlString);
  if (host) parts.push(siteName(host));
  return parts.join(" · ");
}

// MARK: - Formats

/** `fmt` de CourseDetailView : entier si la valeur est ronde, sinon une décimale. */
export function fmtNumber(value: number): string {
  return value === Math.round(value) ? String(Math.trunc(value)) : value.toFixed(1);
}

// MARK: - Texte mathématique

/**
 * Un énoncé avec des formules (`MathText` de la couche SwiftUI) : les indices et
 * les exposants sont mis en forme, les commandes remplacées. Le texte reste
 * sélectionnable.
 */
export function MathText({ text }: { text: string }) {
  if (!MathMarkup.hasMarkup(text)) return <>{text}</>;
  return (
    <>
      {MathMarkup.runs(text).map((run, index) => {
        if (run.style === "subscripted") return <sub key={index}>{run.text}</sub>;
        if (run.style === "superscripted") return <sup key={index}>{run.text}</sup>;
        return <span key={index}>{run.text}</span>;
      })}
    </>
  );
}

// MARK: - Coche et marques

export function CheckCircle({ isOn, tint, label, onToggle, size = 22 }:
  { isOn: boolean; tint: string; label: string; onToggle: () => void; size?: number }) {
  return (
    <button
      type="button"
      aria-label={label}
      aria-pressed={isOn}
      onClick={(event) => { event.stopPropagation(); onToggle(); }}
      style={{
        width: size, height: size, borderRadius: "50%", flexShrink: 0, padding: 0,
        border: `1.6px solid ${isOn ? tint : "var(--ink-tertiary)"}`,
        background: isOn ? tint : "transparent",
        color: isOn ? "white" : "var(--ink-tertiary)",
        fontSize: size * 0.55, lineHeight: 1, display: "grid", placeItems: "center",
      }}
    >
      {isOn ? "✓" : ""}
    </button>
  );
}

/** `ExerciseStageMark` : cercle vide, anneau qui se remplit, coche, couleur, ↺. */
export function StageMark({ stage, size = 24 }: { stage: ExerciseStage; size?: number }) {
  switch (stage.kind) {
    case "toDo":
      return (
        <span style={{
          width: size, height: size, borderRadius: "50%", display: "inline-block",
          border: "1.8px solid var(--ink-tertiary)",
        }} />
      );
    case "inProgress": {
      const deg = Math.round((stage.done / Math.max(stage.total, 1)) * 360);
      return (
        <span style={{
          position: "relative", width: size, height: size, borderRadius: "50%", display: "inline-block",
          background: `conic-gradient(var(--ink) ${deg}deg, var(--rule) 0deg)`,
        }}>
          <span style={{ position: "absolute", inset: 3, borderRadius: "50%", background: "var(--sheet)" }} />
        </span>
      );
    }
    case "toCorrect":
      return filledMark("var(--selection)", "✓", size);
    case "corrected":
      return filledMark(CORRECTNESS_COLOR[stage.correctness], correctnessGlyph(stage.correctness), size);
    case "redo":
      return (
        <span style={{
          width: size, height: size, borderRadius: "50%", display: "inline-grid", placeItems: "center",
          border: "2px solid var(--wrong)", color: "var(--wrong)", fontSize: size * 0.5, fontWeight: 700,
        }}>↺</span>
      );
  }
}

function filledMark(color: string, glyph: string, size: number) {
  return (
    <span style={{
      width: size, height: size, borderRadius: "50%", display: "inline-grid", placeItems: "center",
      background: color, color: "white", fontSize: size * 0.46, fontWeight: 700,
    }}>{glyph}</span>
  );
}

export function correctnessGlyph(value: Correctness): string {
  switch (value) {
    case "correct": return "✓";
    case "partial": return "~";
    case "wrong": return "✕";
  }
}

/** `CorrectionDots` : trois pastilles vert / orange / rouge, un toucher corrige. */
export function CorrectionDots({ value, onChange, size = 20 }:
  { value: Correctness | null; onChange: (next: Correctness | null) => void; size?: number }) {
  return (
    <div style={{ display: "flex", gap: 2, flexShrink: 0 }} role="group" aria-label="Correction">
      {Correctness.allCases.map((option) => {
        const isOn = value === option;
        const color = CORRECTNESS_COLOR[option];
        return (
          <button
            key={option}
            type="button"
            title={`Correction : ${Correctness.label(option)}`}
            aria-label={`Correction : ${Correctness.label(option)}`}
            aria-pressed={isOn}
            onClick={(event) => { event.stopPropagation(); onChange(isOn ? null : option); }}
            style={{
              width: size, height: size, borderRadius: "50%", padding: 0,
              border: `1.5px solid ${color}`,
              background: isOn ? color : "transparent",
              color: isOn ? "white" : color,
              fontSize: size * 0.48, fontWeight: 700, lineHeight: 1,
              opacity: value === null || isOn ? 1 : 0.45,
              display: "grid", placeItems: "center",
            }}
          >
            {correctnessGlyph(option)}
          </button>
        );
      })}
    </div>
  );
}

/** Le glyphe de la pastille : ✓, =, ? (les noms Swift sont des symboles SF, pas des caractères). */
export function confidenceGlyph(level: ConfidenceLevel): string {
  switch (level) {
    case "green": return "✓";
    case "orange": return "=";
    case "red": return "?";
  }
}

export function ConfidenceDot({ level, size = 14 }: { level: ConfidenceLevel; size?: number }) {
  return (
    <span
      role="img"
      aria-label={ConfidenceLevel.label(level)}
      title={ConfidenceLevel.label(level)}
      style={{
        width: size, height: size, borderRadius: "50%", background: CONFIDENCE_COLOR[level],
        color: "white", fontSize: size * 0.62, fontWeight: 700, lineHeight: 1,
        display: "inline-grid", placeItems: "center", flexShrink: 0,
      }}
    >
      {confidenceGlyph(level)}
    </span>
  );
}

/** Les trois pastilles de sûreté (vert / orange / rouge), comme la correction. */
export function ConfidencePicker({ value, onChange, size = 20 }:
  { value: ConfidenceLevel | null; onChange: (next: ConfidenceLevel | null) => void; size?: number }) {
  return (
    <div style={{ display: "flex", gap: 2 }} role="group" aria-label="Sûreté">
      {ConfidenceLevel.allCases.map((option) => {
        const isOn = value === option;
        const color = CONFIDENCE_COLOR[option];
        return (
          <button
            key={option}
            type="button"
            title={ConfidenceLevel.label(option)}
            aria-label={ConfidenceLevel.label(option)}
            aria-pressed={isOn}
            onClick={(event) => { event.stopPropagation(); onChange(isOn ? null : option); }}
            style={{
              width: size, height: size, borderRadius: "50%", padding: 0,
              border: `1.5px solid ${color}`,
              background: isOn ? color : "transparent",
              color: isOn ? "white" : color,
              fontSize: size * 0.48, fontWeight: 700,
              opacity: value === null || isOn ? 1 : 0.45,
              display: "grid", placeItems: "center",
            }}
          >
            {confidenceGlyph(option)}
          </button>
        );
      })}
    </div>
  );
}

// MARK: - Barres et pastilles

export function Bar({ value, tint, height = 4 }: { value: number; tint: string; height?: number }) {
  const ratio = Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
  return (
    <div aria-hidden style={{ height, borderRadius: height, background: "var(--rule)", overflow: "hidden" }}>
      <div style={{ width: `${ratio * 100}%`, height: "100%", background: tint, borderRadius: height }} />
    </div>
  );
}

export function ProgressRing({ value, tint, size = 28, lineWidth = 4 }:
  { value: number; tint: string; size?: number; lineWidth?: number }) {
  const ratio = Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
  return (
    <span style={{
      position: "relative", width: size, height: size, borderRadius: "50%", flexShrink: 0,
      background: `conic-gradient(${tint} ${ratio * 360}deg, var(--rule) 0deg)`,
    }}>
      <span style={{ position: "absolute", inset: lineWidth, borderRadius: "50%", background: "var(--sheet)" }} />
    </span>
  );
}

export function Pill({ children, color, icon }: { children: ReactNode; color?: string; icon?: string }) {
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: 4, borderRadius: 999,
      border: `1px solid ${color ?? "var(--rule)"}`, color: color ?? "var(--ink-secondary)",
      padding: "1px 7px", fontSize: 11, fontWeight: 600, whiteSpace: "nowrap",
    }}>
      {icon && <span aria-hidden>{icon}</span>}
      {children}
    </span>
  );
}

export function LinkChip({ link }: { link: LinkTarget }) {
  return (
    <button
      type="button"
      onClick={(event) => { event.stopPropagation(); openURL(link.url); }}
      style={{
        display: "inline-flex", alignItems: "center", gap: 6, borderRadius: 999,
        border: "1px solid var(--rule)", background: "var(--sheet-raised)", color: "var(--ink)",
        padding: "4px 10px", fontSize: 12,
      }}
    >
      <span aria-hidden style={{ color: "var(--ink-secondary)" }}>{link.icon}</span>
      {link.title}
    </button>
  );
}

export function EmptyState({ title, message }: { title: string; message: string }) {
  return (
    <div className="card" style={{ color: "var(--ink-secondary)" }}>
      <strong className="serif" style={{ color: "var(--ink)", fontSize: 17 }}>{title}</strong>
      <p style={{ margin: "4px 0 0" }}>{message}</p>
    </div>
  );
}
