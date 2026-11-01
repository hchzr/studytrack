// Le volet d'à côté (SidePicker + StudyWorkspace.sideSuggestions) : ce qu'on
// peut garder sous les yeux pendant qu'on travaille au centre — l'énoncé, les
// notes, la fiche, les outils du cours et ce qui est gardé. Sur le Mac, ce
// volet porte des onglets (cahiers, PDF, Botafogo) ; ici, tout ce qui est du
// web s'ouvre dans le navigateur du système, et le reste mène au centre.

import { useState, type ReactNode } from "react";
import type { Course } from "../../models/course.ts";
import type { ExerciseSeries } from "../../models/exercise.ts";
import { StudyMode, type StudyTool } from "../../domain/studyMode.ts";
import { seriesName, solutionAddress } from "./helpers.ts";
import { openWebURL } from "./openers.ts";
import type { StudyPane } from "./paneKind.ts";
import { Glyph, Kicker, tintOfCourse } from "./parts.tsx";

/** Une ligne du volet : icône, titre, détail — et où elle mène. */
function Row({ icon, title, detail, onClick, tint }: {
  icon: string;
  title: string;
  detail: string;
  onClick: () => void;
  tint: string;
}) {
  const [hovering, setHovering] = useState(false);
  return (
    <button
      type="button"
      onClick={onClick}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
      style={{
        display: "flex", alignItems: "center", gap: 12, width: "100%", textAlign: "left",
        padding: 8, borderRadius: 10, border: "none", cursor: "pointer", fontSize: 14,
        background: hovering ? "var(--sheet-raised)" : "transparent", color: "var(--ink)",
      }}
    >
      <span aria-hidden style={{
        display: "grid", placeItems: "center", width: 32, height: 32, borderRadius: 8,
        background: "var(--sheet-raised)", color: tint, fontSize: 15, flexShrink: 0,
      }}>
        <Glyph name={icon} />
      </span>
      <span style={{ minWidth: 0, flex: 1 }}>
        <span style={{ display: "block", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {title}
        </span>
        {detail !== "" && (
          <span style={{ display: "block", fontSize: 12, color: "var(--ink-secondary)",
            overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {detail}
          </span>
        )}
      </span>
    </button>
  );
}

/**
 * Les outils web du cours, permis par la règle des sites (StudyTools.tools) :
 * seulement les sites permis, jamais les apps — il n'y a pas de blocage
 * Windows, la règle sert à ne proposer que ce que le mode étude ouvrirait.
 */
function allowedWebTools(course: Course | null): StudyTool[] {
  const links = course
    ? [course.moodleURLString, ...course.contentSources].filter((link) => link !== "")
    : [];
  const sites = StudyMode.defaultSites();
  return StudyMode.tools(course?.name ?? null, links)
    .filter((tool) => tool.kind.type === "web" && StudyMode.isAllowed(tool.kind.url, sites));
}

export function StudySidePanel({ course, series, now, onOpenPane, onClose }: {
  course: Course | null;
  /** La série de l'exercice suivi (le corrigé s'y trouve). */
  series: ExerciseSeries | null;
  now: Date;
  onOpenPane: (pane: StudyPane) => void;
  onClose: () => void;
}) {
  const tint = tintOfCourse(course);
  const tools = allowedWebTools(course);
  const resources = course?.sortedResources ?? [];
  const solution = series ? solutionAddress(series, now) : null;

  return (
    <aside style={{
      width: 300, flexShrink: 0, borderLeft: "1px solid var(--rule)", background: "var(--sheet)",
      display: "flex", flexDirection: "column", minHeight: 0,
    }}>
      <div style={{
        display: "flex", alignItems: "center", gap: 8, padding: "10px 10px 10px 16",
        borderBottom: "1px solid var(--rule)",
      }}>
        <div style={{ flex: 1 }}>
          <span className="serif" style={{ fontSize: 18, color: "var(--ink)" }}>À côté</span>
          <span style={{ display: "block", fontSize: 12, color: "var(--ink-secondary)", lineHeight: 1.3 }}>
            Ce que tu veux garder sous les yeux.
          </span>
        </div>
        <button
          type="button"
          title="Fermer le volet d'à côté"
          aria-label="Fermer le volet d'à côté"
          onClick={onClose}
          style={{
            border: "none", background: "transparent", color: "var(--ink-secondary)",
            fontSize: 15, padding: "4px 8px", borderRadius: 8, cursor: "pointer",
          }}
        >
          ✕
        </button>
      </div>

      <div style={{ flex: 1, overflowY: "auto", padding: "14px 10px 20px", display: "flex", flexDirection: "column", gap: 18 }}>
        {course && (
          <Group title="Pour l'exercice">
            <Row
              icon="doc.text"
              title="L'énoncé"
              detail="La série, les questions, j'ai fini"
              tint={tint}
              onClick={() => onOpenPane("exercise")}
            />
            {solution !== null && series !== null && (
              <Row
                icon="checkmark.seal"
                title="Corrigé"
                detail={seriesName(series)}
                tint={tint}
                onClick={() => { void openWebURL(solution); }}
              />
            )}
          </Group>
        )}

        <Group title="Le cours">
          <Row
            icon="text.alignleft"
            title="Notes du cours"
            detail="Markdown"
            tint={tint}
            onClick={() => onOpenPane("notes")}
          />
          <Row
            icon="list.bullet.rectangle"
            title="Fiche"
            detail="Ta fiche de révision"
            tint={tint}
            onClick={() => onOpenPane("sheet")}
          />
        </Group>

        {tools.length > 0 && (
          <Group title="Outils">
            {tools.map((tool) => (
              <Row
                key={tool.id}
                icon={tool.icon}
                title={tool.title}
                detail={tool.subtitle}
                tint={tint}
                onClick={() => {
                  if (tool.kind.type === "web") void openWebURL(tool.kind.url.href);
                }}
              />
            ))}
          </Group>
        )}

        {resources.length > 0 && (
          <Group title="Gardés">
            {resources.slice(0, 8).map((resource) => {
              const openable = !resource.isFile && /^https?:\/\//i.test(resource.address);
              return (
                <Row
                  key={resource.id}
                  icon={resource.isPinned ? "pin" : "bookmark"}
                  title={resource.title}
                  detail={openable ? "Gardé" : "Gardé — pas une adresse web"}
                  tint={tint}
                  onClick={() => { if (openable) void openWebURL(resource.address); }}
                />
              );
            })}
          </Group>
        )}

        {/* Sur le Mac, « À côté » en haut d'un document l'ajoute ici ; les
            onglets du volet (cahier, PDF, Botafogo) ne sont pas portés. */}
        <span style={{ fontSize: 12, color: "var(--ink-tertiary)", padding: "0 8px" }}>
          Les liens s'ouvrent dans le navigateur, hors de l'app.
        </span>
      </div>
    </aside>
  );
}

function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
      <Kicker>{title}</Kicker>
      {children}
    </div>
  );
}
