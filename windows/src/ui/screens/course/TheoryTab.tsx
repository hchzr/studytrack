// Théorie d'un cours (TheoryTabView.swift + WeekTheoryCard.swift ; Mac : la
// liste de MacCourseView et son inspecteur).
//
// Tout support — vidéo, lecture, section de polycopié, diapos — est de la
// théorie ; son type n'est qu'une icône. Un chapitre porte son titre
// (« Suites réelles »), pas « Section 3 ». La carte de la semaine nomme chaque
// vidéo et chaque support ; la liste complète garde les chapitres repliés.

import { useEffect, useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import { TheoryKind } from "../../../models/enums.ts";
import type { ContentLink } from "../../../models/jsonTypes.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { ContentDraftBuilder } from "../../../domain/courseContentImport.ts";
import {
  Button, Card, EmptyState, Icon, IconButton, ProgressBar, Section, cx, useContextMenu,
  type IconName, type MenuItem,
} from "../../kit.tsx";
import {
  CheckCircle, MathText, Pill, hostOf, linkChipLabel, linkIcon, linkShortLabel, openURL, siteName,
  theoryLinks, useTimedTarget, webURL, type CourseActions,
} from "./common.tsx";
import "./course.css";

interface TheoryTabProps {
  course: Course;
  week: number;
  saveAll: (objects: object[]) => Promise<void>;
  actions: CourseActions;
}

/** L'icône du type de support (`TheoryKind.icon`). */
function kindIcon(kind: TheoryKind): IconName {
  switch (kind) {
    case "video": return "play.fill";
    case "reading": return "book";
    case "chapter": return "doc.text";
    case "slides": return "square.stack.3d.up";
  }
}

export function TheoryTab({ course, week, saveAll, actions, focusID }: TheoryTabProps & { focusID?: string | null }) {
  const [showsDone, setShowsDone] = useState(true);
  const [selectedId, setSelectedId] = useState<string | null>(focusID ?? null);
  // L'élément demandé (palette, lien d'un autre écran) : amené au milieu.
  useEffect(() => {
    if (focusID) document.querySelector(`[data-item="${focusID}"]`)?.scrollIntoView({ block: "center" });
  }, [focusID]);
  const menu = useContextMenu();
  const timedId = useTimedTarget();
  const currentWeek = course.currentWeek;

  const all = course.sortedTheoryItems;
  const visible = all.filter((item) => week === 0 || item.plannedWeek === week);
  const weekItems = all.filter((item) => item.plannedWeek === currentWeek)
    .sort(compareWeekItems);
  const selected = selectedId === null ? null : all.find((item) => item.id === selectedId) ?? null;

  if (all.length === 0) {
    return (
      <EmptyState icon="book" title="Aucune théorie"
        action={<Button icon="plus" onClick={() => actions.editTheory(null)}>Ajouter de la théorie</Button>}>
        Importe-la depuis Moodle, Courseware ou Botafogo, ou ajoute-la à la main.
      </EmptyState>
    );
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

  /** Le `.contextMenu` d'une ligne de théorie du Mac. */
  const itemMenu = (item: TheoryItem) => {
    const link = theoryLinks(item)[0];
    const items: MenuItem[] = [
      { label: item.isWatched ? "Marquer non vu" : "Marquer comme vu",
        icon: item.isWatched ? "arrow.counterclockwise" : "checkmark", action: () => void toggleWatched(item) },
      { label: "Chronométrer", icon: "timer", action: () => actions.time(item.id, "theory") },
      ...(link ? [{ label: "Ouvrir", icon: "arrow.up.right.square", action: () => openURL(link.url) } as MenuItem] : []),
      "divider",
      { label: "Modifier…", icon: "pencil", action: () => actions.editTheory(item) },
    ];
    return menu.open(items);
  };

  const sections = [...new Set(visible.map((item) => item.sectionNumber))].sort((a, b) => a - b);

  return (
    <div className={cx("cs-split", selected && "has-aside")}>
      <div>
        {week === 0 && (
          <Section title={course.isTermRunning ? `Cette semaine · S${currentWeek}` : "Hors semestre"}>
            {weekItems.length === 0 ? (
              <Card flat className="muted" >
                {course.isTermRunning
                  ? "Aucune théorie planifiée cette semaine."
                  : "Le semestre n'est pas en cours : le plan hebdomadaire est en pause."}
              </Card>
            ) : (
              <WeekTheoryPanel
                course={course}
                items={weekItems}
                selectedId={selectedId}
                itemMenu={itemMenu}
                onToggleWatched={(item) => void toggleWatched(item)}
                onSelect={(item) => setSelectedId(item.id)}
              />
            )}
          </Section>
        )}

        <Section
          title={`${week === 0 ? "Tout le cours" : `Semaine ${week}`} · ${visible.filter((item) => item.isWatched).length}/${visible.length}`}
          action={
            <Button variant="ghost" size="sm" icon={showsDone ? "eye.slash" : "eye"} onClick={() => setShowsDone((value) => !value)}>
              {showsDone ? "Masquer le fait" : "Tout afficher"}
            </Button>
          }
        >
          {visible.length === 0 ? (
            <EmptyState icon="book" title="Pas de théorie">{`Rien en semaine ${week}.`}</EmptyState>
          ) : (
            sections.map((section) => {
              const sectionItems = visible.filter((item) => item.sectionNumber === section);
              const shown = showsDone ? sectionItems : sectionItems.filter((item) => !item.isWatched);
              if (shown.length === 0) return null;
              const title = sectionItems.find((item) => item.sectionTitle !== "")?.sectionTitle ?? `Chapitre ${section}`;
              const watched = sectionItems.filter((item) => item.isWatched).length;
              return (
                <Card key={section} className="cs-chapter" flat>
                  <div className="cs-chapter-head">
                    <strong>{title}</strong>
                    <span className="mono small" style={{ color: watched === sectionItems.length ? "var(--correct)" : "var(--ink-secondary)" }}>
                      {watched}/{sectionItems.length}
                    </span>
                  </div>
                  {shown.map((item) => (
                    <TheoryRow
                      key={item.id}
                      item={item}
                      isCurrentWeek={item.plannedWeek === currentWeek && course.isTermRunning}
                      selected={selectedId === item.id}
                      timed={timedId === item.id}
                      onContextMenu={itemMenu(item)}
                      onToggleWatched={() => void toggleWatched(item)}
                      onSelect={() => setSelectedId(item.id)}
                    />
                  ))}
                </Card>
              );
            })
          )}
        </Section>
      </div>

      {selected && (
        <TheoryDetail
          key={selected.id}
          item={selected}
          timed={timedId === selected.id}
          onClose={() => setSelectedId(null)}
          onTime={() => actions.time(selected.id, "theory")}
          onEdit={() => actions.editTheory(selected)}
          saveAll={saveAll}
        />
      )}
      {menu.element}
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

function WeekTheoryPanel({ course, items, selectedId, itemMenu, onToggleWatched, onSelect }: {
  course: Course; items: TheoryItem[]; selectedId: string | null;
  itemMenu: (item: TheoryItem) => (event: React.MouseEvent) => void;
  onToggleWatched: (item: TheoryItem) => void; onSelect: (item: TheoryItem) => void;
}) {
  const done = items.filter((item) => item.isWatched).length;
  const remainingSeconds = items.filter((item) => !item.isWatched)
    .reduce((sum, item) => sum + item.durationSeconds, 0);
  const videos = items.reduce((sum, item) => sum + item.videoCount, 0);

  return (
    <Card className="cs-week" flat>
      <div className="cs-week-head">
        <div className="top">
          <strong>{course.isTermRunning ? `Semaine ${course.currentWeek}` : "Hors semestre"}</strong>
          <span className="spacer" />
          <span className="mono small muted">{done}/{items.length}</span>
        </div>
        <div style={{ marginTop: 8 }}>
          <ProgressBar value={done / Math.max(items.length, 1)} color="var(--course)" />
        </div>
        {(videos > 0 || remainingSeconds > 0) && (
          <div className="cs-week-sub">
            {[
              videos > 0 ? `${videos} ${videos > 1 ? "vidéos" : "vidéo"}` : null,
              remainingSeconds > 0 ? `${DateUtils.durationLabel(remainingSeconds)} à regarder` : null,
            ].filter((part): part is string => part !== null).join(" · ")}
          </div>
        )}
      </div>
      {items.map((item) => (
        <WeekTheoryCard
          key={item.id}
          item={item}
          selected={selectedId === item.id}
          onContextMenu={itemMenu(item)}
          onToggleWatched={() => onToggleWatched(item)}
          onSelect={() => onSelect(item)}
        />
      ))}
    </Card>
  );
}

/** Un élément de la semaine avec tout ce qu'il faut regarder, nommé ligne à ligne. */
function WeekTheoryCard({ item, selected, onContextMenu, onToggleWatched, onSelect }: {
  item: TheoryItem; selected: boolean; onContextMenu: (event: React.MouseEvent) => void;
  onToggleWatched: () => void; onSelect: () => void;
}) {
  const [showsAll, setShowsAll] = useState(false);
  const links = theoryLinks(item);
  const rows = buildRows(links);
  const title = (item.title === "" ? item.number : item.title).replace(/^MOOC · /, "");
  const summary = weekSummary(item, links, rows);
  const shown = showsAll ? rows : rows.slice(0, 5);

  return (
    <div className={cx("cs-item", item.isWatched && "watched")} onContextMenu={onContextMenu}>
      <div className="cs-item-head" style={selected ? { background: "var(--sheet-raised)" } : undefined}>
        <CheckCircle
          isOn={item.isWatched}
          tint="var(--course)"
          label={item.isWatched ? `Marquer ${title} non vu` : `Marquer ${title} vu`}
          onToggle={onToggleWatched}
        />
        <button type="button" className="cs-pick" onClick={onSelect} aria-current={selected || undefined}>
          <span className="cs-kicker">{kicker(item, links)}</span>
          <span className="cs-item-title"><MathText text={title} /></span>
          <span className="muted small">{summary}</span>
        </button>
      </div>

      {shown.map((row) => <ResourceRow key={row.id} row={row} />)}
      {rows.length > 5 && (
        <button type="button" className="cs-more" onClick={() => setShowsAll((value) => !value)} aria-expanded={showsAll}>
          {showsAll ? "Moins" : `Voir les ${rows.length} lignes`}
        </button>
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
  icon?: IconName;
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
          icon: "checkmark.square",
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
      icon: "doc.text",
      detail: extras.length === 1 ? "Page · Courseware" : `${extras.length} pages · Courseware`,
    });
  }
  return result;
}

function ResourceRow({ row }: { row: Row }) {
  const first = row.links[0];
  const open = (link: ContentLink) => {
    const url = webURL(link.url);
    if (url) openURL(url);
  };
  return (
    <div className="cs-res">
      <div className="cs-res-main">
        <Icon name={row.icon ?? (row.kind === "video" ? "play.fill" : linkIcon(row.kind))} size={15}
          className={cx("cs-res-ico", row.kind === "video" && "video")} />
        <button type="button" className="cs-res-open" onClick={() => first && open(first)}>
          <span className="t"><MathText text={row.title} /></span>
          <span className="d">{rowDetail(row)}</span>
        </button>
        <Icon name="arrow.up.right" size={13} className="cs-chev" />
      </div>
      {row.links.length > 1 && (
        <div className="cs-parts">
          {row.links.map((link, index) => (
            <Button key={`${link.url}-${index}`} size="sm" icon={linkIcon(link.kind)} onClick={() => open(link)}>
              {link.kind === "video" ? videoName(link, index) : rowTitle(link)}
            </Button>
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

function TheoryRow({ item, isCurrentWeek, selected, timed, onContextMenu, onToggleWatched, onSelect }: {
  item: TheoryItem; isCurrentWeek: boolean; selected: boolean; timed: boolean;
  onContextMenu: (event: React.MouseEvent) => void; onToggleWatched: () => void; onSelect: () => void;
}) {
  const link = theoryLinks(item)[0];
  return (
    <div className={cx("cs-th-row", selected && "selected", item.isWatched && "watched")} onContextMenu={onContextMenu}
      data-item={item.id}>
      <CheckCircle
        isOn={item.isWatched}
        tint="var(--course)"
        label={item.isWatched ? `Marquer ${item.displayNumber} non faite` : `Marquer ${item.displayNumber} comme faite`}
        onToggle={onToggleWatched}
        size={20}
      />
      <Icon name={kindIcon(item.kind)} size={15} className="cs-th-ico" />
      <button type="button" className="cs-pick" onClick={onSelect} aria-current={selected || undefined}>
        <span className="cs-meta">
          <span className="name"><MathText text={item.numberAndTitle} /></span>
          {isCurrentWeek && <Pill>S{item.plannedWeek}</Pill>}
          {item.isSummarized && <Pill icon="note.text">résumé</Pill>}
          {timed && <Icon name="timer" size={13} className="muted" label="Chrono en cours" />}
        </span>
        <span className="muted small">{videoMeta(item, isCurrentWeek)}</span>
      </button>
      {link && (
        <IconButton icon={item.kind === "video" ? "play.fill" : "arrow.up.right.square"}
          label={item.kind === "video" ? "Regarder" : "Ouvrir"} size="sm"
          onClick={() => { const url = webURL(link.url); if (url) openURL(url); }} />
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

function TheoryDetail({ item, timed, onClose, onTime, onEdit, saveAll }: {
  item: TheoryItem; timed: boolean; onClose: () => void; onTime: () => void; onEdit: () => void;
  saveAll: (objects: object[]) => Promise<void>;
}) {
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
    <Card className="cs-aside" flat>
      <div className="cs-aside-head">
        <span className="cs-kicker">{[TheoryKind.label(item.kind), item.number].filter((part) => part !== "").join(" ")}</span>
        <span className="spacer" />
        <IconButton icon="pencil" label="Modifier" size="sm" onClick={onEdit} />
        <IconButton icon="xmark" label="Fermer" size="sm" onClick={onClose} />
      </div>
      <h3 className="serif">{item.title === "" ? item.number : item.title}</h3>
      {item.plannedWeek > 0 && <div className="mono small muted">Semaine {item.plannedWeek}</div>}

      <dl className="cs-dl">
        <dt>Support</dt>
        <dd>{item.videoCount > 1 ? `${item.videoCount} vidéos` : TheoryKind.label(item.kind)}</dd>
        {item.hasDuration && (<>
          <dt>Durée</dt>
          <dd className="mono">{item.durationLabel}</dd>
        </>)}
        <dt>Faite le</dt>
        <dd>{item.watchedAt ? DateUtils.shortDay(item.watchedAt) : "—"}</dd>
        <dt>Résumé le</dt>
        <dd>{item.summarizedAt ? DateUtils.shortDay(item.summarizedAt) : "—"}</dd>
      </dl>

      <div className="cs-actions">
        <Button size="sm" variant={item.isWatched ? "default" : "primary"}
          icon={item.isWatched ? "arrow.counterclockwise" : "checkmark"} onClick={() => void toggleWatched()}>
          {item.isWatched ? "Marquer à faire" : "Marquer comme faite"}
        </Button>
        <Button size="sm" icon={item.isSummarized ? "arrow.counterclockwise" : "note.text"} onClick={() => void toggleSummarized()}>
          {item.isSummarized ? "Retirer le résumé" : "Marquer résumé"}
        </Button>
        <Button size="sm" icon="timer" onClick={onTime} disabled={timed}>
          {timed ? "Chrono en cours" : "Chronométrer"}
        </Button>
      </div>

      {links.length > 0 && (
        <div className="cs-block">
          <div className="cs-label">Supports</div>
          <div className="cs-links" style={{ margin: 0 }}>
            {links.map((link, index) => (
              <Button key={`${link.url}-${index}`} size="sm" icon={linkIcon(link.kind)} trailingIcon="arrow.up.right"
                onClick={() => { const url = webURL(link.url); if (url) openURL(url); }}>
                {link.title === "" ? linkChipLabel(link.kind) : link.title}
              </Button>
            ))}
          </div>
        </div>
      )}

      <div className="cs-block">
        <label className="cs-label" htmlFor={`summary-${item.id}`}>Résumé</label>
        <textarea id={`summary-${item.id}`} className="field cs-area" value={summary}
          onChange={(event) => setSummary(event.target.value)} rows={6} placeholder="Ce qu'il faut retenir…" />
        <div className="hstack" style={{ marginTop: 8 }}>
          <Button size="sm" variant="primary" icon="checkmark" disabled={busy || summary.trim() === (item.summaryText ?? "").trim()}
            onClick={() => void saveSummary()}>
            Enregistrer le résumé
          </Button>
        </div>
        {item.summaryText && item.summaryText !== summary && (
          <div className="faint small" style={{ marginTop: 6 }}>
            Un résumé est déjà enregistré. « Enregistrer » le remplace.
          </div>
        )}
      </div>
    </Card>
  );
}
