// Théorie d'un cours (TheoryTabView.swift + WeekTheoryCard.swift).
//
// Tout support — vidéo, lecture, section de polycopié, diapos — est de la
// théorie ; son type n'est qu'un glyphe. Un chapitre porte son titre
// (« Suites réelles »), pas « Section 3 ». La carte de la semaine nomme chaque
// vidéo et chaque support ; la liste complète garde les chapitres repliés.

import { useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import { TheoryKind } from "../../../models/enums.ts";
import type { ContentLink } from "../../../models/jsonTypes.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { ContentDraftBuilder } from "../../../domain/courseContentImport.ts";
import { Bar, CheckCircle, EmptyState, MathText, Pill, theoryLinks, linkChipLabel, linkShortLabel, siteName, hostOf, webURL, openURL } from "./common.tsx";

interface TheoryTabProps {
  course: Course;
  week: number;
  saveAll: (objects: object[]) => Promise<void>;
}

export function TheoryTab({ course, week, saveAll }: TheoryTabProps) {
  const [showsDone, setShowsDone] = useState(true);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const currentWeek = course.currentWeek;

  const all = course.sortedTheoryItems;
  const visible = all.filter((item) => week === 0 || item.plannedWeek === week);
  const weekItems = all.filter((item) => item.plannedWeek === currentWeek)
    .sort(compareWeekItems);
  const selected = selectedId === null ? null : all.find((item) => item.id === selectedId) ?? null;

  if (all.length === 0) {
    return <EmptyState title="Aucune théorie" message="Depuis Moodle, Courseware ou Botafogo." />;
  }

  const toggleWatched = async (item: TheoryItem) => {
    if (item.isWatched) {
      item.watchedAt = null;
      item.summarizedAt = null;
    } else {
      item.watchedAt = new Date();
    }
    await saveAll([item]);
  };

  const sections = [...new Set(visible.map((item) => item.sectionNumber))].sort((a, b) => a - b);

  return (
    <div style={{ display: "grid", gridTemplateColumns: selected ? "minmax(0, 1fr) 360px" : "minmax(0, 1fr)", gap: 18, alignItems: "start" }}>
      <div>
        {week === 0 && (
          <section style={{ marginBottom: 28 }}>
            <h2 style={{ fontSize: 13, textTransform: "uppercase", letterSpacing: 0.6,
              color: "var(--ink-tertiary)", margin: "0 0 10px" }}>
              {course.isTermRunning ? `Cette semaine · S${currentWeek}` : "Hors semestre"}
            </h2>
            {weekItems.length === 0 ? (
              <div className="card" style={{ color: "var(--ink-secondary)", fontSize: 13 }}>
                {course.isTermRunning
                  ? "Aucune théorie planifiée cette semaine."
                  : "Le semestre n'est pas en cours : le plan hebdomadaire est en pause."}
              </div>
            ) : (
              <WeekTheoryPanel
                course={course}
                items={weekItems}
                onToggleWatched={(item) => void toggleWatched(item)}
                onSelect={(item) => setSelectedId(item.id)}
              />
            )}
          </section>
        )}

        <section>
          <div style={{ display: "flex", alignItems: "baseline", gap: 12, marginBottom: 10 }}>
            <h2 style={{ fontSize: 13, textTransform: "uppercase", letterSpacing: 0.6,
              color: "var(--ink-tertiary)", margin: 0 }}>
              {week === 0 ? "Tout le cours" : `Semaine ${week}`}
            </h2>
            <span className="mono" style={{ color: "var(--ink-secondary)", fontSize: 12 }}>
              {visible.filter((item) => item.isWatched).length}/{visible.length}
            </span>
            <span style={{ flex: 1 }} />
            <button
              type="button"
              onClick={() => setShowsDone((value) => !value)}
              style={{ border: "none", background: "none", color: "var(--ink-secondary)", fontSize: 12, padding: 0 }}
            >
              {showsDone ? "Masquer le fait" : "Tout afficher"}
            </button>
          </div>

          {visible.length === 0 ? (
            <EmptyState title="Pas de théorie" message={`Rien en semaine ${week}.`} />
          ) : (
            sections.map((section) => {
              const sectionItems = visible.filter((item) => item.sectionNumber === section);
              const shown = showsDone ? sectionItems : sectionItems.filter((item) => !item.isWatched);
              if (shown.length === 0) return null;
              const title = sectionItems.find((item) => item.sectionTitle !== "")?.sectionTitle ?? `Chapitre ${section}`;
              const watched = sectionItems.filter((item) => item.isWatched).length;
              return (
                <div key={section} className="card" style={{ padding: 14, marginBottom: 12 }}>
                  <div style={{ display: "flex", alignItems: "baseline", gap: 10, marginBottom: 6 }}>
                    <strong className="serif" style={{ fontSize: 16, flex: 1 }}>{title}</strong>
                    <span className="mono" style={{ fontSize: 12, color: watched === sectionItems.length ? "var(--correct)" : "var(--ink-secondary)" }}>
                      {watched}/{sectionItems.length}
                    </span>
                  </div>
                  {shown.map((item, index) => (
                    <div key={item.id} style={{ borderTop: index === 0 ? "none" : "1px solid var(--rule)" }}>
                      <TheoryRow
                        item={item}
                        isCurrentWeek={item.plannedWeek === currentWeek && course.isTermRunning}
                        selected={selectedId === item.id}
                        onToggleWatched={() => void toggleWatched(item)}
                        onSelect={() => setSelectedId(item.id)}
                      />
                    </div>
                  ))}
                </div>
              );
            })
          )}
        </section>
      </div>

      {selected && (
        <TheoryDetail
          key={selected.id}
          item={selected}
          onClose={() => setSelectedId(null)}
          saveAll={saveAll}
        />
      )}
    </div>
  );
}

/** Ordre de la semaine : le cours d'abord, puis les chapitres du MOOC par numéro. */
function compareWeekItems(lhs: TheoryItem, rhs: TheoryItem): number {
  const l = lhs.title.startsWith("MOOC");
  const r = rhs.title.startsWith("MOOC");
  if (l !== r) return l ? 1 : -1;
  if (l && r && lhs.number !== rhs.number) return lhs.number.localeCompare(rhs.number, undefined, { numeric: true });
  return lhs.sortOrder - rhs.sortOrder;
}

// MARK: - La carte de la semaine

function WeekTheoryPanel({ course, items, onToggleWatched, onSelect }:
  { course: Course; items: TheoryItem[]; onToggleWatched: (item: TheoryItem) => void; onSelect: (item: TheoryItem) => void }) {
  const done = items.filter((item) => item.isWatched).length;
  const remainingSeconds = items.filter((item) => !item.isWatched)
    .reduce((sum, item) => sum + item.durationSeconds, 0);
  const videos = items.reduce((sum, item) => sum + item.videoCount, 0);
  const tint = course.colorHex;

  return (
    <div className="card" style={{ padding: 0, borderLeft: `4px solid ${tint}`, overflow: "hidden" }}>
      <div style={{ padding: "12px 14px 8px" }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
          <strong className="serif" style={{ fontSize: 19 }}>
            {course.isTermRunning ? `Semaine ${course.currentWeek}` : "Hors semestre"}
          </strong>
          <span style={{ flex: 1 }} />
          <span className="mono" style={{ color: "var(--ink-secondary)", fontSize: 12 }}>{done}/{items.length}</span>
        </div>
        <div style={{ marginTop: 8 }}>
          <Bar value={done / Math.max(items.length, 1)} tint={tint} />
        </div>
        {(videos > 0 || remainingSeconds > 0) && (
          <div style={{ marginTop: 6, color: "var(--ink-secondary)", fontSize: 12 }}>
            {[
              videos > 0 ? `${videos} ${videos > 1 ? "vidéos" : "vidéo"}` : null,
              remainingSeconds > 0 ? `${DateUtils.durationLabel(remainingSeconds)} à regarder` : null,
            ].filter((part): part is string => part !== null).join(" · ")}
          </div>
        )}
      </div>
      <div>
        {items.map((item, index) => (
          <div key={item.id} style={{ borderTop: index === 0 ? "1px solid var(--rule)" : "none" }}>
            <WeekTheoryCard
              item={item}
              tint={tint}
              onToggleWatched={() => onToggleWatched(item)}
              onSelect={() => onSelect(item)}
            />
          </div>
        ))}
      </div>
    </div>
  );
}

/** Un élément de la semaine avec tout ce qu'il faut regarder, nommé ligne à ligne. */
function WeekTheoryCard({ item, tint, onToggleWatched, onSelect }:
  { item: TheoryItem; tint: string; onToggleWatched: () => void; onSelect: () => void }) {
  const [showsAll, setShowsAll] = useState(false);
  const links = theoryLinks(item);
  const rows = buildRows(links);
  const title = (item.title === "" ? item.number : item.title).replace(/^MOOC · /, "");
  const summary = weekSummary(item, links, rows);
  const shown = showsAll ? rows : rows.slice(0, 5);

  return (
    <div style={{ borderTop: "1px solid var(--rule)" }}>
      <div style={{ display: "flex", alignItems: "flex-start", gap: 8, padding: "10px 14px 8px 10px" }}>
        <CheckCircle
          isOn={item.isWatched}
          tint={tint}
          label={`Marquer ${title} vu`}
          onToggle={onToggleWatched}
        />
        <button
          type="button"
          onClick={onSelect}
          style={{ flex: 1, textAlign: "left", border: "none", background: "none", padding: 0 }}
        >
          <div style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.7, color: tint, fontWeight: 700 }}>
            {kicker(item, links)}
          </div>
          <div className="serif" style={{ fontSize: 17, color: item.isWatched ? "var(--ink-secondary)" : "var(--ink)" }}>
            <MathText text={title} />
          </div>
          <div style={{ color: "var(--ink-secondary)", fontSize: 12, marginTop: 2 }}>{summary}</div>
        </button>
      </div>

      {shown.length > 0 && (
        <div style={{ borderTop: "1px solid var(--rule)" }}>
          {shown.map((row, index) => (
            <div key={row.id} style={{ borderTop: index === 0 ? "none" : "1px solid var(--rule)" }}>
              <ResourceRow row={row} tint={tint} />
            </div>
          ))}
          {rows.length > 5 && (
            <button
              type="button"
              onClick={() => setShowsAll((value) => !value)}
              style={{
                width: "100%", border: "none", borderTop: "1px solid var(--rule)", background: "transparent",
                color: "var(--ink-secondary)", padding: "9px 14px", fontSize: 12,
              }}
            >
              {showsAll ? "Moins" : `Voir les ${rows.length} lignes`}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

// MARK: - Regroupement des liens (WeekTheoryCard.Row)

interface Row {
  id: string;
  title: string;
  kind: ContentLink["kind"];
  links: ContentLink[];
  icon?: string;
  detail?: string;
}

function isMOOCLink(link: ContentLink): boolean {
  const host = hostOf(link.url);
  return host !== null && host.includes("courseware");
}

function rowTitle(link: ContentLink): string {
  const text = link.title === "" ? linkChipLabel(link.kind) : link.title;
  return text.replace(/\s*\((?:\d+ pages? sur \d+|1 page sur 1)\)/gi, "");
}

function buildRows(links: ContentLink[]): Row[] {
  const result: Row[] = [];
  const extras: ContentLink[] = [];
  for (const link of links) {
    const cleaned = rowTitle(link);
    const lesson = cleaned.split(" — ")[0] ?? cleaned;
    const folded = ContentDraftBuilder.fold(lesson);
    if (link.kind === "page" && isMOOCLink(link)) {
      const count = /\((\d+) questions?\)/i.exec(lesson);
      if (count !== null || folded.includes("controle des connaissances") || folded.includes("quiz")) {
        const name = lesson
          .replace(/\s*\(\d+ questions?\)/gi, "")
          .replace(/^[\d.]+\s+/, "");
        result.push({
          id: `q:${folded}`,
          title: name === "" ? "Quiz du chapitre" : name,
          kind: link.kind,
          links: [link],
          icon: "☑",
          detail: count ? `Quiz · ${count[1]} questions · Courseware` : "Quiz · Courseware",
        });
      } else {
        extras.push(link);
      }
      continue;
    }
    const key = (link.kind === "video" ? "v:" : "d:") + folded;
    const index = result.findIndex((row) => row.id === key);
    if (index >= 0) {
      // Un support en double garde la version complète (« 1 page sur 1 »).
      if (link.kind !== "video") continue;
      const row = result[index];
      result[index] = { ...row, links: [...row.links, link] };
    } else {
      result.push({ id: key, title: lesson, kind: link.kind, links: [link] });
    }
  }
  if (extras.length > 0) {
    const names = extras.map(rowTitle);
    result.push({
      id: "p:extras",
      title: extras.length === 1 ? names[0] : names.join(", "),
      kind: "page",
      links: extras,
      icon: "▤",
      detail: extras.length === 1 ? "Page · Courseware" : `${extras.length} pages · Courseware`,
    });
  }
  return result;
}

function ResourceRow({ row, tint }: { row: Row; tint: string }) {
  const first = row.links[0];
  const open = (link: ContentLink) => {
    const url = webURL(link.url);
    if (url) openURL(url);
  };
  return (
    <div style={{ padding: "7px 14px 7px 18px" }}>
      <div style={{ display: "flex", alignItems: "flex-start", gap: 10 }}>
        <span aria-hidden style={{ width: 20, color: row.kind === "video" ? tint : "var(--ink-secondary)", fontSize: 14 }}>
          {row.icon ?? (row.kind === "video" ? "▶" : "▤")}
        </span>
        <button
          type="button"
          onClick={() => first && open(first)}
          style={{ flex: 1, textAlign: "left", border: "none", background: "none", padding: 0 }}
        >
          <div style={{ fontSize: 13 }}><MathText text={row.title} /></div>
          <div style={{ fontSize: 11, color: "var(--ink-tertiary)" }}>{rowDetail(row)}</div>
        </button>
        <span aria-hidden style={{ color: "var(--ink-tertiary)", fontSize: 11 }}>{row.links.length > 1 ? "▾" : "›"}</span>
      </div>
      {row.links.length > 1 && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, margin: "6px 0 0 30px" }}>
          {row.links.map((link, index) => (
            <button
              key={`${link.url}-${index}`}
              type="button"
              onClick={() => open(link)}
              style={{
                border: "1px solid var(--rule)", background: "var(--sheet-raised)", color: "var(--ink)",
                borderRadius: 999, padding: "2px 8px", fontSize: 11,
              }}
            >
              {link.kind === "video" ? videoName(link, index) : rowTitle(link)}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/** « 2 vidéos · transparents · 1 h 32 · vu ». */
function weekSummary(item: TheoryItem, links: ContentLink[], rows: Row[]): string {
  const parts: string[] = [];
  const videos = links.filter((link) => link.kind === "video").length;
  if (item.title.startsWith("MOOC")) {
    const lessons = rows.filter((row) => row.kind === "video").length;
    if (lessons > 1) parts.push(`${lessons} leçons`);
    if (videos > 0) parts.push(videos === 1 ? "1 vidéo" : `${videos} vidéos`);
    if (rows.some((row) => row.id.startsWith("q:"))) parts.push("quiz");
  } else {
    if (videos > 0) parts.push(videos === 1 ? "1 vidéo" : `${videos} vidéos`);
    const supports = [...new Set(links.map((link) => link.kind))]
      .filter((kind) => kind !== "video")
      .map(linkShortLabel);
    parts.push(...supports);
  }
  if (item.durationSeconds > 0) parts.push(DateUtils.durationLabel(item.durationSeconds));
  if (item.isWatched) parts.push("vu");
  return parts.length === 0 ? TheoryKind.label(item.kind) : parts.join(" · ");
}

/** « Cours » ou « MOOC » : d'où vient ce travail. */
function kicker(item: TheoryItem, links: ContentLink[]): string {
  if (item.title.startsWith("MOOC") || (links.length > 0 && links.every(isMOOCLink))) return "MOOC · à regarder";
  const videos = links.filter((link) => link.kind === "video").length;
  const supports = links.length - videos;
  if (videos > 0 && supports > 0) return "Cours · enregistrement et supports";
  if (videos > 0) return "Cours · enregistrement";
  if (supports > 0) return "Cours · supports";
  return "Cours";
}

/** « 2 vidéos · Courseware », « Transparents · proginsc ». */
function rowDetail(row: Row): string {
  if (row.detail) return row.detail;
  const host = hostOf(row.links[0]?.url ?? "");
  const site = host ? siteName(host) : "";
  const what = row.kind === "video"
    ? (row.links.length > 1 ? `${row.links.length} parties` : "Vidéo")
    : linkChipLabel(row.kind);
  return [what, site].filter((part) => part !== "").join(" · ");
}

/** La fin du titre (« Variables — Déclaration » → « Déclaration »), sinon le numéro de la partie. */
function videoName(link: ContentLink, index: number): string {
  const parts = link.title.split(" — ");
  const suffix = parts.slice(1).join(" — ").trim();
  const generic = /^(regardez|video|watch)?\s*:?$/i.test(ContentDraftBuilder.fold(suffix));
  if (suffix !== "" && !generic) return suffix;
  const range = /partie_?(\d+)/i.exec(link.url);
  if (range) return `Partie ${range[1]}`;
  return `Vidéo ${index + 1}`;
}

// MARK: - Ligne de la liste complète

function TheoryRow({ item, isCurrentWeek, selected, onToggleWatched, onSelect }:
  { item: TheoryItem; isCurrentWeek: boolean; selected: boolean; onToggleWatched: () => void; onSelect: () => void }) {
  const link = theoryLinks(item)[0];
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 10, padding: "8px 2px",
      background: selected ? "var(--sheet-raised)" : "transparent", borderRadius: 8,
    }}>
      <CheckCircle
        isOn={item.isWatched}
        tint="var(--selection)"
        label={`Marquer ${item.displayNumber} comme faite`}
        onToggle={onToggleWatched}
        size={20}
      />
      <button
        type="button"
        onClick={onSelect}
        style={{ flex: 1, textAlign: "left", border: "none", background: "none", padding: 0 }}
      >
        <div style={{ display: "flex", alignItems: "baseline", gap: 8, flexWrap: "wrap" }}>
          <span style={{ color: item.isWatched ? "var(--ink-secondary)" : "var(--ink)", fontSize: 14 }}>
            <MathText text={item.numberAndTitle} />
          </span>
          {isCurrentWeek && <Pill color="var(--ink-secondary)">S{item.plannedWeek}</Pill>}
          {item.isSummarized && <Pill color="var(--ink-secondary)">résumé</Pill>}
        </div>
        <div style={{ color: "var(--ink-secondary)", fontSize: 12, marginTop: 2 }}>{videoMeta(item, isCurrentWeek)}</div>
      </button>
      {link && (
        <button
          type="button"
          aria-label={item.kind === "video" ? "Regarder" : "Ouvrir"}
          onClick={(event) => { event.stopPropagation(); const url = webURL(link.url); if (url) openURL(url); }}
          style={{ border: "none", background: "none", color: "var(--ink-secondary)", padding: 4 }}
        >
          {item.kind === "video" ? "▶" : "↗"}
        </button>
      )}
    </div>
  );
}

/** « 3 vidéos · 45 min · résumé », ce qui compte, sans « 0 min ». */
function videoMeta(item: TheoryItem, isCurrentWeek: boolean): string {
  const parts: string[] = [];
  if (item.videoCount > 1) parts.push(`${item.videoCount} vidéos`);
  else if (item.videoCount === 1 || item.kind === "video") parts.push("Vidéo");
  else parts.push(TheoryKind.label(item.kind));
  if (item.hasDuration) parts.push(item.durationLabel);
  if (item.isSummarized) parts.push("résumé");
  if (item.plannedWeek > 0 && !isCurrentWeek) parts.push(`S${item.plannedWeek}`);
  return parts.join(" · ");
}

// MARK: - Détail d'un élément

function TheoryDetail({ item, onClose, saveAll }:
  { item: TheoryItem; onClose: () => void; saveAll: (objects: object[]) => Promise<void> }) {
  const [summary, setSummary] = useState(item.summaryText ?? "");
  const [busy, setBusy] = useState(false);
  const links = theoryLinks(item);

  const toggleWatched = async () => {
    if (item.isWatched) {
      item.watchedAt = null;
      item.summarizedAt = null;
    } else {
      item.watchedAt = new Date();
    }
    await saveAll([item]);
  };

  const toggleSummarized = async () => {
    item.summarizedAt = item.isSummarized ? null : new Date();
    if (item.summarizedAt !== null && item.watchedAt === null) item.watchedAt = item.summarizedAt;
    await saveAll([item]);
  };

  const saveSummary = async () => {
    const trimmed = summary.trim();
    item.summaryText = trimmed;
    if (trimmed !== "" || item.isSummarized) item.summarizedAt = new Date();
    if (item.watchedAt === null) item.watchedAt = new Date();
    setBusy(true);
    await saveAll([item]);
    setBusy(false);
  };

  return (
    <aside className="card" style={{ position: "sticky", top: 0, padding: 16 }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
        <span style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: 0.7, fontWeight: 700, color: "var(--ink-secondary)" }}>
          {TheoryKind.label(item.kind)} {item.number}
        </span>
        <span style={{ flex: 1 }} />
        <button type="button" onClick={onClose} aria-label="Fermer" style={{ border: "none", background: "none", color: "var(--ink-secondary)", fontSize: 16 }}>✕</button>
      </div>
      <h3 className="serif" style={{ margin: "6px 0", fontSize: 20 }}>{item.title === "" ? item.number : item.title}</h3>
      {item.plannedWeek > 0 && (
        <div className="mono" style={{ color: "var(--ink-secondary)", fontSize: 12 }}>Semaine {item.plannedWeek}</div>
      )}

      <dl style={{ display: "grid", gridTemplateColumns: "auto 1fr", gap: "6px 12px", margin: "14px 0", fontSize: 13 }}>
        <dt style={{ color: "var(--ink-secondary)" }}>Support</dt>
        <dd style={{ margin: 0 }}>{item.videoCount > 1 ? `${item.videoCount} vidéos` : TheoryKind.label(item.kind)}</dd>
        {item.hasDuration && (<>
          <dt style={{ color: "var(--ink-secondary)" }}>Durée</dt>
          <dd className="mono" style={{ margin: 0 }}>{item.durationLabel}</dd>
        </>)}
        <dt style={{ color: "var(--ink-secondary)" }}>Faite le</dt>
        <dd style={{ margin: 0 }}>{item.watchedAt ? DateUtils.shortDay(item.watchedAt) : "—"}</dd>
        <dt style={{ color: "var(--ink-secondary)" }}>Résumé le</dt>
        <dd style={{ margin: 0 }}>{item.summarizedAt ? DateUtils.shortDay(item.summarizedAt) : "—"}</dd>
      </dl>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 14 }}>
        <button type="button" onClick={() => void toggleWatched()} style={buttonStyle}>
          {item.isWatched ? "↺ Marquer à faire" : "✓ Marquer comme faite"}
        </button>
        <button type="button" onClick={() => void toggleSummarized()} style={buttonStyle}>
          {item.isSummarized ? "↺ Retirer le résumé" : "✎ Marquer résumé"}
        </button>
      </div>

      {links.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <div style={labelStyle}>Supports</div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {links.map((link, index) => (
              <button
                key={`${link.url}-${index}`}
                type="button"
                onClick={() => { const url = webURL(link.url); if (url) openURL(url); }}
                style={buttonStyle}
              >
                {link.title === "" ? linkChipLabel(link.kind) : link.title} ↗
              </button>
            ))}
          </div>
        </div>
      )}

      <div style={labelStyle}>Résumé</div>
      <textarea
        value={summary}
        onChange={(event) => setSummary(event.target.value)}
        rows={6}
        placeholder="Ce qu'il faut retenir…"
        style={{
          width: "100%", resize: "vertical", borderRadius: 10, border: "1px solid var(--rule)",
          background: "var(--ground)", color: "var(--ink)", padding: 10, font: "inherit",
        }}
      />
      <button
        type="button"
        disabled={busy}
        onClick={() => void saveSummary()}
        style={{ ...buttonStyle, marginTop: 8, borderColor: "var(--ink)", fontWeight: 600 }}
      >
        ✓ Enregistrer le résumé
      </button>
      {item.summaryText && item.summaryText !== summary && (
        <div style={{ color: "var(--ink-secondary)", fontSize: 11, marginTop: 6 }}>
          Un résumé est déjà enregistré. « Enregistrer » le remplace.
        </div>
      )}
    </aside>
  );
}

const buttonStyle = {
  border: "1px solid var(--rule)",
  background: "var(--sheet-raised)",
  color: "var(--ink)",
  borderRadius: 999,
  padding: "5px 11px",
  fontSize: 12,
} as const;

const labelStyle = {
  fontSize: 10,
  textTransform: "uppercase",
  letterSpacing: 0.7,
  color: "var(--ink-tertiary)",
  marginBottom: 6,
} as const;

