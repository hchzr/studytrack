// Les briques communes aux quatre volets d'un cours : coche, pastilles de
// correction, barres, liens. Elles reprennent le dessin de `CourseLines.swift`
// (ExerciseStageMark, CorrectionDots) et de `WeekTheoryCard.swift` (pastilles de
// lien), sans dépendre de SwiftUI.

import { useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import { timerController } from "../../timerController.ts";
import { Button, Icon, cx, type IconName } from "../../kit.tsx";
import "./course.css";
import { ConfidenceLevel, Correctness, TheoryKind, type Tint } from "../../../models/enums.ts";
import type { ContentLink, ContentLinkKind } from "../../../models/jsonTypes.ts";
import type { ExerciseSeries } from "../../../models/exercise.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import type { Exam } from "../../../models/exam.ts";
import type { PastExam } from "../../../models/pastExam.ts";
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
  icon: IconName;
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

/** L'icône d'un support (les symboles SF de `ContentLinkKind.icon`). */
export function linkIcon(kind: ContentLinkKind): IconName {
  switch (kind) {
    case "video": return "play.fill";
    case "slides": return "square.stack.3d.up";
    case "notes": return "note.text";
    case "pdf": return "doc.text";
    case "page": return "arrow.up.right.square";
    case "solution": return "checkmark.circle";
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
  if (statement) links.push({ title: "Énoncé de la série", url: statement, icon: "doc.text" });
  const solution = webURL(series.solutionURLString);
  if (solution) {
    if (series.solutionsAt && series.solutionsAt > now) {
      links.push({ title: `Corrigé (publié le ${DateUtils.shortDay(series.solutionsAt)})`, url: solution, icon: "lock" });
    } else {
      links.push({ title: "Corrigé", url: solution, icon: "checkmark.circle" });
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
  if (statement) links.push({ title: "Énoncé de l'exercice", url: statement, icon: "doc.text" });
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

// MARK: - Actions que l'écran met à disposition des volets

/** Ce que l'écran du cours sait faire pour un volet : ouvrir un formulaire, lancer le chrono. */
export interface CourseActions {
  editSeries: (series: ExerciseSeries | null) => void;
  editTheory: (item: TheoryItem | null) => void;
  editExam: (exam: Exam | null) => void;
  editPastExam: (exam: PastExam | null) => void;
  /** Démarre — ou bascule sans couper — le chrono sur une cible du cours. */
  time: (targetID: string, type: "exercise" | "theory") => void;
}

/** Une couleur passée aux feuilles de style (`var(--tone)`). */
const tone = (color: string): CSSProperties => ({ ["--tone" as string]: color });

// MARK: - Coche et marques

export function CheckCircle({ isOn, tint, label, onToggle, size = 22 }:
  { isOn: boolean; tint: string; label: string; onToggle: () => void; size?: number }) {
  return (
    <button
      type="button"
      className="cs-check"
      aria-label={label}
      title={label}
      aria-pressed={isOn}
      onClick={(event) => { event.stopPropagation(); onToggle(); }}
      style={{ ...tone(tint), width: size, height: size }}
    >
      <Icon name="checkmark" size={Math.round(size * 0.58)} strokeWidth={3} />
    </button>
  );
}

/** `ExerciseStageMark` : cercle vide, anneau qui se remplit, coche, couleur, retour. */
export function StageMark({ stage, size = 24 }: { stage: ExerciseStage; size?: number }) {
  const glyph = Math.round(size * 0.55);
  switch (stage.kind) {
    case "toDo":
      return <span className="cs-mark blank" style={{ width: size, height: size }} />;
    case "inProgress": {
      const deg = Math.round((stage.done / Math.max(stage.total, 1)) * 360);
      return (
        <span className="cs-ring-mark" style={{ width: size, height: size,
          background: `conic-gradient(var(--ink) ${deg}deg, var(--rule) 0deg)` }}>
          <i style={{ inset: Math.max(2, Math.round(size / 8)) }} />
        </span>
      );
    }
    case "toCorrect":
      return <FilledMark color="var(--selection)" icon="checkmark" size={size} glyph={glyph} />;
    case "corrected":
      return <FilledMark color={CORRECTNESS_COLOR[stage.correctness]} icon={correctnessIcon(stage.correctness)}
        size={size} glyph={glyph} />;
    case "redo":
      return (
        <span className="cs-mark redo" style={{ width: size, height: size }}>
          <Icon name="arrow.counterclockwise" size={glyph} strokeWidth={2.5} />
        </span>
      );
  }
}

function FilledMark({ color, icon, size, glyph }: { color: string; icon: IconName; size: number; glyph: number }) {
  return (
    <span className="cs-mark" style={{ width: size, height: size, background: color }}>
      <Icon name={icon} size={glyph} strokeWidth={3} />
    </span>
  );
}

export function correctnessIcon(value: Correctness): IconName {
  switch (value) {
    case "correct": return "checkmark";
    case "partial": return "ellipsis";
    case "wrong": return "xmark";
  }
}

/** `CorrectionDots` : trois pastilles vert / orange / rouge, un toucher corrige. */
export function CorrectionDots({ value, onChange, size = 20 }:
  { value: Correctness | null; onChange: (next: Correctness | null) => void; size?: number }) {
  return (
    <div className="cs-dots" role="group" aria-label="Correction">
      {Correctness.allCases.map((option) => {
        const isOn = value === option;
        const label = `Correction : ${Correctness.label(option)}`;
        return (
          <button
            key={option}
            type="button"
            className={cx("cs-dot", value !== null && !isOn && "dim")}
            title={label}
            aria-label={label}
            aria-pressed={isOn}
            onClick={(event) => { event.stopPropagation(); onChange(isOn ? null : option); }}
            style={{ ...tone(CORRECTNESS_COLOR[option]), width: size, height: size }}
          >
            <Icon name={correctnessIcon(option)} size={Math.round(size * 0.55)} strokeWidth={3} />
          </button>
        );
      })}
    </div>
  );
}

/** Le symbole de la pastille de sûreté : coche, points de suspension, drapeau (pas de « = » ni de « ? » dans le jeu d'icônes). */
export function confidenceIcon(level: ConfidenceLevel): IconName {
  switch (level) {
    case "green": return "checkmark";
    case "orange": return "ellipsis";
    case "red": return "flag";
  }
}

export function ConfidenceDot({ level, size = 14 }: { level: ConfidenceLevel; size?: number }) {
  return (
    <span
      role="img"
      className="cs-conf"
      aria-label={ConfidenceLevel.label(level)}
      title={ConfidenceLevel.label(level)}
      style={{ width: size, height: size, background: CONFIDENCE_COLOR[level] }}
    >
      <Icon name={confidenceIcon(level)} size={Math.round(size * 0.66)} strokeWidth={3} />
    </span>
  );
}

/** Les trois pastilles de sûreté (vert / orange / rouge), comme la correction. */
export function ConfidencePicker({ value, onChange, size = 20 }:
  { value: ConfidenceLevel | null; onChange: (next: ConfidenceLevel | null) => void; size?: number }) {
  return (
    <div className="cs-dots" role="group" aria-label="Sûreté">
      {ConfidenceLevel.allCases.map((option) => {
        const isOn = value === option;
        return (
          <button
            key={option}
            type="button"
            className={cx("cs-dot", value !== null && !isOn && "dim")}
            title={ConfidenceLevel.label(option)}
            aria-label={ConfidenceLevel.label(option)}
            aria-pressed={isOn}
            onClick={(event) => { event.stopPropagation(); onChange(isOn ? null : option); }}
            style={{ ...tone(CONFIDENCE_COLOR[option]), width: size, height: size }}
          >
            <Icon name={confidenceIcon(option)} size={Math.round(size * 0.55)} strokeWidth={3} />
          </button>
        );
      })}
    </div>
  );
}

// MARK: - Anneau et pastilles

export function ProgressRing({ value, tint, size = 28, lineWidth = 4 }:
  { value: number; tint: string; size?: number; lineWidth?: number }) {
  const ratio = Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
  return (
    <span className="cs-ring-mark" aria-hidden
      style={{ width: size, height: size, background: `conic-gradient(${tint} ${ratio * 360}deg, var(--rule) 0deg)` }}>
      <i style={{ inset: lineWidth }} />
    </span>
  );
}

/** Une petite pastille d'état (« bonus », « à refaire »), contour de la teinte. */
export function Pill({ children, color, icon }: { children: ReactNode; color?: string; icon?: IconName }) {
  return (
    <span className="cs-pill" style={color ? tone(color) : undefined}>
      {icon && <Icon name={icon} size={11} strokeWidth={2.25} />}
      {children}
    </span>
  );
}

/** Un lien (énoncé, corrigé) : un bouton discret du kit qui ouvre la page. */
export function LinkChip({ link }: { link: LinkTarget }) {
  return (
    <Button size="sm" icon={link.icon} trailingIcon="arrow.up.right"
      onClick={(event) => { event.stopPropagation(); openURL(link.url); }}>
      {link.title}
    </Button>
  );
}

/** L'élément que le chrono vise en ce moment (l'icône « en cours » des lignes). */
export function useTimedTarget(): string | undefined {
  const snap = useSyncExternalStore(timerController.subscribe, timerController.snapshot);
  return snap.state ? snap.state.targetID : undefined;
}
