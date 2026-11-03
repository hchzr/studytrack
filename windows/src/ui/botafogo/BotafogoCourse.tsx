// Un cours Botafogo en entier, dans l'app (StudyKit/BotafogoCourse.swift) : à gauche le
// sommaire (les semaines, le polycopié, les infos ; une recherche ; ce qu'on a lu), au centre
// la page avec son fil d'Ariane, précédent / suivant et l'historique. Sans page ouverte, la
// semaine en cours : ce qu'il y a à lire, et où reprendre.

import { useEffect, useMemo, useRef, useState } from "react";
import { BotafogoLinks, BotafogoProgram, BotafogoSite, type BotafogoNode, type ChapterSection } from "../../domain/botafogoProgram.ts";
import { BotafogoNavigation } from "../../domain/botafogoNavigation.ts";
import { BotafogoPage, type BotafogoBlock } from "../../domain/botafogoPage.ts";
import { MathMarkup } from "../../domain/mathMarkup.ts";
import { botafogoBook, type BotafogoBook } from "../../services/botafogoBook.ts";
import { Icon, type IconName } from "../icons.tsx";
import { Segmented } from "../kit.tsx";
import { BotafogoBlocks } from "./BotafogoBlocks.tsx";
import { RichInline } from "../rich/RichText.tsx";
import "./botafogo.css";

export interface BotafogoLocation { title: string; url: string }

type Part = "sessions" | "handout" | "infos";

function useBook(site: string): BotafogoBook {
  const book = useMemo(() => botafogoBook(site), [site]);
  const [, bump] = useState(0);
  useEffect(() => {
    const off = book.subscribe(() => bump((n) => n + 1));
    void book.load();
    return off;
  }, [book]);
  return book;
}

function nodeIcon(type: string): IconName {
  switch (type) {
    case "series": return "list.number";
    case "session": return "person.2";
    case "weekContent": return "calendar";
    case "exam": return "doc.text.magnifyingglass";
    case "lecture": return "play.rectangle.fill";
    default: return "book";
  }
}

const dayFormat = new Intl.DateTimeFormat("fr-CH", { weekday: "long", day: "numeric", month: "long" });
const shortDay = new Intl.DateTimeFormat("fr-CH", { day: "numeric", month: "short" });

function fold(text: string): string {
  return MathMarkup.plain(text).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
}

/** Les sections lues, rangées par site (comme le Mac : `botafogo.read.<site>`). */
function useRead(book: BotafogoBook): [Set<string>, (url: string, value: boolean) => void] {
  const key = BotafogoNavigation.readKey(book.root ?? book.site);
  const [read, setRead] = useState<Set<string>>(() => new Set());
  useEffect(() => {
    try { setRead(new Set(JSON.parse(localStorage.getItem(key) ?? "[]") as string[])); } catch { setRead(new Set()); }
  }, [key]);
  const set = (url: string, value: boolean) => {
    setRead((current) => {
      const next = new Set(current);
      if (value) next.add(url); else next.delete(url);
      try { localStorage.setItem(key, JSON.stringify([...next].sort())); } catch { /* pour cette session */ }
      return next;
    });
  };
  return [read, set];
}

export function BotafogoCourse({ site, tint, openWeb, location, onLocation }: {
  site: string;
  tint: string;
  /** Une adresse hors du site (Moodle, une vidéo, un outil). */
  openWeb: (url: string) => void;
  location: BotafogoLocation | null;
  onLocation: (location: BotafogoLocation | null) => void;
}) {
  const book = useBook(site);
  const [read, setRead] = useRead(book);
  const [part, setPart] = useState<Part>("sessions");
  const [query, setQuery] = useState("");
  const [back, setBack] = useState<BotafogoLocation[]>([]);
  const [forward, setForward] = useState<BotafogoLocation[]>([]);
  const [sideHidden, setSideHidden] = useState(false);

  const go = (next: BotafogoLocation | null, travel: "push" | "none" = "push") => {
    if (travel === "push" && location) { setBack([...back, location]); setForward([]); }
    onLocation(next);
  };
  const goBack = () => {
    const previous = back[back.length - 1];
    if (!previous) return;
    setBack(back.slice(0, -1));
    if (location) setForward([location, ...forward]);
    onLocation(previous);
  };
  const goForward = () => {
    const next = forward[0];
    if (!next) return;
    setForward(forward.slice(1));
    if (location) setBack([...back, location]);
    onLocation(next);
  };

  const openPoly = (path: string) => go({ title: book.section(path)?.title ?? "Polycopié", url: path });

  /** Un lien d'une page : le polycopié et le cours restent dans l'app, le reste s'ouvre au-dehors. */
  const onLink = (href: string) => {
    let url: URL | null = null;
    try { url = new URL(href, book.root ?? book.site); } catch { /* adresse illisible */ }
    if (url) {
      const poly = BotafogoPage.handoutPathFromLink(url);
      if (poly) return openPoly(poly);
      if (url.hostname.includes("botafogo")) {
        const cours = BotafogoLinks.coursPath(url.toString());
        if (cours) return go({ title: cours, url: cours });
        const polycopie = url.searchParams.get("polycopie");
        if (polycopie) return openPoly("/handout/" + BotafogoLinks.handoutID(polycopie));
      }
      openWeb(url.toString());
    }
  };

  if (book.state.kind === "loading" || book.state.kind === "idle") {
    return <div className="bf-center"><span className="spinner" aria-hidden /> Lecture du site du cours…</div>;
  }
  if (book.state.kind === "failed") {
    return (
      <div className="bf-center">
        <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Le site du cours n'a pas pu être lu</span>
        <span>{book.state.message}</span>
        <div style={{ display: "flex", gap: 8 }}>
          <button type="button" className="btn" onClick={() => void book.retry()}>Réessayer</button>
          <button type="button" className="btn" onClick={() => openWeb(site)}>Ouvrir le site</button>
        </div>
      </div>
    );
  }

  const style = { ["--bf-tint" as string]: tint };
  return (
    <div className="bf-course" style={style}>
      {(!sideHidden || location === null) && (
        <aside className="bf-side">
          <div className="bf-side-top">
            <input className="field" type="search" placeholder="Chercher dans le cours" value={query}
              aria-label="Chercher dans le cours" onChange={(event) => setQuery(event.target.value)} />
            {query.trim() === "" && (
              <Segmented<Part> ariaLabel="Partie du cours" value={part} onChange={setPart} options={[
                { value: "sessions", label: "Semaines" },
                ...(book.chapters.length > 0 ? [{ value: "handout" as Part, label: "Polycopié" }] : []),
                ...(book.infos.length > 0 ? [{ value: "infos" as Part, label: "Infos" }] : []),
              ]} />
            )}
          </div>
          <div className="bf-side-list">
            {query.trim() !== ""
              ? <SearchResults book={book} query={query} location={location} read={read} go={go} />
              : part === "sessions" ? <Weeks book={book} location={location} read={read} go={go} />
                : part === "handout" ? <Handout book={book} location={location} read={read} go={go} />
                  : <Infos book={book} location={location} read={read} go={go} />}
          </div>
        </aside>
      )}
      <div className="bf-main">
        {location ? (
          <Page key={location.url} book={book} location={location} read={read.has(location.url)}
            setRead={(value) => setRead(location.url, value)}
            canGoBack={back.length > 0} canGoForward={forward.length > 0} goBack={goBack} goForward={goForward}
            sideHidden={sideHidden} toggleSide={() => setSideHidden(!sideHidden)}
            close={() => go(null)} go={go} onLink={onLink} />
        ) : (
          <WeekHome book={book} read={read} go={go} />
        )}
      </div>
    </div>
  );
}

interface ListProps {
  book: BotafogoBook;
  location: BotafogoLocation | null;
  read: Set<string>;
  go: (location: BotafogoLocation) => void;
}

function Row({ icon, title, detail, url, location, read, go, readingTitle }: {
  icon: IconName; title: string; detail?: string; url: string; readingTitle?: string;
  location: BotafogoLocation | null; read: Set<string>; go: (location: BotafogoLocation) => void;
}) {
  const selected = location?.url === url;
  return (
    <button type="button" className={`bf-row${selected ? " selected" : ""}${read.has(url) ? " read" : ""}`}
      onClick={() => go({ title: readingTitle ?? MathMarkup.plain(title), url })}>
      <Icon name={read.has(url) ? "checkmark.circle.fill" : icon} size={14} />
      <span style={{ flex: 1, minWidth: 0 }}>
        <RichInline text={title} />
        {detail && <span className="bf-detail">{detail}</span>}
      </span>
    </button>
  );
}

function Disclosure({ title, open, onToggle, accessory }: { title: string; open: boolean; onToggle: () => void; accessory?: React.ReactNode }) {
  return (
    <button type="button" className="bf-disclosure" aria-expanded={open} onClick={onToggle}>
      <Icon name={open ? "chevron.down" : "chevron.right"} size={12} strokeWidth={2.4} />
      <span className="bf-title"><RichInline text={title} /></span>
      {accessory}
    </button>
  );
}

function weekParts(week: BotafogoNode): BotafogoNode[] {
  return (week.children ?? []).filter((node) => BotafogoSite.isSessionPart(node) && node.url !== null);
}

function partTitle(node: BotafogoNode): string {
  return node.type === "weekContent" ? "Programme de la semaine" : node.displayName;
}

function partDate(node: BotafogoNode): string | undefined {
  const date = BotafogoProgram.date(node.meta("date"));
  return date ? dayFormat.format(date) : undefined;
}

function Weeks({ book, location, read, go }: ListProps) {
  const current = BotafogoSite.currentWeek(book.weeks);
  const [open, setOpen] = useState<Set<number>>(() => new Set(current !== null ? [current] : []));
  return (
    <>
      {book.weeks.map((week, index) => {
        const parts = weekParts(week);
        const series = (week.children ?? []).filter((node) => node.type === "series" && node.url !== null);
        if (parts.length === 0 && series.length === 0) return null;
        const isOpen = open.has(index);
        const first = (week.children ?? []).map((c) => BotafogoProgram.date(c.meta("date"))).filter((d): d is Date => d !== null)
          .sort((a, b) => a.getTime() - b.getTime())[0];
        return (
          <div key={index}>
            <Disclosure title={week.name ?? `Semaine ${index + 1}`} open={isOpen}
              onToggle={() => { const next = new Set(open); if (isOpen) next.delete(index); else next.add(index); setOpen(next); }}
              accessory={index === current ? <span className="bf-badge now">Cette semaine</span>
                : first ? <span className="bf-badge">{shortDay.format(first)}</span> : undefined} />
            {isOpen && (
              <div className="bf-rows">
                {parts.map((node, i) => (
                  <Row key={`p${i}`} icon={nodeIcon(node.type)} title={partTitle(node)} detail={partDate(node)} url={node.url ?? ""}
                    readingTitle={node.type === "weekContent" ? MathMarkup.plain(week.name ?? partTitle(node)) : undefined}
                    location={location} read={read} go={go} />
                ))}
                {series.map((node, i) => (
                  <Row key={`s${i}`} icon="list.number" title={BotafogoSite.seriesTitle(node)} detail={node.name ?? undefined}
                    url={node.url ?? ""} location={location} read={read} go={go} />
                ))}
                <WeekReadings book={book} week={week} location={location} read={read} go={go} />
              </div>
            )}
          </div>
        );
      })}
    </>
  );
}

/** Les sections du polycopié que la semaine fait lire (citées par sa page). */
function WeekReadings({ book, week, location, read, go }: ListProps & { week: BotafogoNode }) {
  const content = (week.children ?? []).find((node) => node.type === "weekContent")?.url ?? null;
  const [sections, setSections] = useState<ChapterSection[]>([]);
  useEffect(() => {
    let alive = true;
    if (content) void book.readings(content).then((found) => { if (alive) setSections(found); });
    return () => { alive = false; };
  }, [book, content]);
  return (
    <>
      {sections.map((section) => (
        <Row key={section.path} icon="book" title={section.title} url={section.path} location={location} read={read} go={go} />
      ))}
    </>
  );
}

function Handout({ book, location, read, go }: ListProps) {
  const [open, setOpen] = useState<Set<string>>(() => {
    const here = location ? book.chapter(location.url)?.title : undefined;
    return new Set(here ? [here] : []);
  });
  return (
    <>
      {book.chapters.map((chapter) => {
        const isOpen = open.has(chapter.title);
        const progress = BotafogoNavigation.progress(chapter, read);
        return (
          <div key={chapter.title}>
            <Disclosure title={chapter.title} open={isOpen}
              onToggle={() => { const next = new Set(open); if (isOpen) next.delete(chapter.title); else next.add(chapter.title); setOpen(next); }}
              accessory={<span className="bf-badge mono">{progress.read}/{progress.total}</span>} />
            {isOpen && (
              <div className="bf-rows">
                {chapter.sections.map((section) => (
                  <Row key={section.path} icon="book" title={section.title} url={section.path} location={location} read={read} go={go} />
                ))}
              </div>
            )}
          </div>
        );
      })}
    </>
  );
}

function Infos({ book, location, read, go }: ListProps) {
  return (
    <>
      {book.infos.map((group, index) => (
        <div key={index}>
          <div className="bf-group-title serif">{MathMarkup.plain(group.name ?? "Infos")}</div>
          {(group.children ?? []).filter((node) => node.url !== null).map((node, i) => (
            <Row key={i} icon="info.circle" title={node.displayName} url={node.url ?? ""} location={location} read={read} go={go} />
          ))}
        </div>
      ))}
    </>
  );
}

function SearchResults({ book, query, location, read, go }: ListProps & { query: string }) {
  const needle = fold(query.trim());
  const matches = (text: string) => fold(text).includes(needle);
  const sections = BotafogoNavigation.order(book.chapters).filter((section) => matches(section.title));
  const documents = book.weeks.flatMap((week) => weekParts(week)
    .filter((node) => matches(node.displayName) || matches(week.name ?? ""))
    .map((node) => ({ week, node })));
  if (sections.length === 0 && documents.length === 0) {
    return <p style={{ padding: 12, color: "var(--ink-tertiary)", fontSize: 13 }}>Rien ne correspond.</p>;
  }
  return (
    <>
      {sections.length > 0 && <div className="bf-group-title">Polycopié</div>}
      {sections.map((section) => (
        <Row key={section.path} icon="book" title={section.title} url={section.path} location={location} read={read} go={go} />
      ))}
      {documents.length > 0 && <div className="bf-group-title">Semaines</div>}
      {documents.map(({ week, node }, i) => (
        <Row key={i} icon={nodeIcon(node.type)} title={node.type === "weekContent" ? (week.name ?? node.displayName) : node.displayName}
          detail={week.name ? MathMarkup.plain(week.name) : undefined} url={node.url ?? ""} location={location} read={read} go={go} />
      ))}
    </>
  );
}

/** L'ordre de lecture des documents du cours (semaine après semaine), pour précédent / suivant. */
function courseOrder(book: BotafogoBook): BotafogoLocation[] {
  return book.weeks.flatMap((week) => weekParts(week).map((node) => ({
    title: node.type === "weekContent" ? MathMarkup.plain(week.name ?? "La semaine") : node.displayName,
    url: node.url ?? "",
  })));
}

function neighbours(book: BotafogoBook, url: string): { previous: BotafogoLocation | null; next: BotafogoLocation | null } {
  if (BotafogoSite.isHandout(url)) {
    const found = BotafogoNavigation.neighbours(url, book.chapters);
    return {
      previous: found.previous ? { title: found.previous.title, url: found.previous.path } : null,
      next: found.next ? { title: found.next.title, url: found.next.path } : null,
    };
  }
  const order = courseOrder(book);
  const index = order.findIndex((item) => item.url === url);
  if (index < 0) return { previous: null, next: null };
  return { previous: order[index - 1] ?? null, next: order[index + 1] ?? null };
}

function trail(book: BotafogoBook, url: string): string {
  if (BotafogoSite.isHandout(url)) {
    const chapter = book.chapter(url);
    return ["Polycopié", chapter ? MathMarkup.plain(chapter.title) : null].filter(Boolean).join(" › ");
  }
  const week = book.week(url);
  const index = week ? book.weeks.indexOf(week) : -1;
  return week ? [`Semaine ${index + 1}`, week.name ? MathMarkup.plain(week.name) : null].filter(Boolean).join(" › ") : "Le cours";
}

function Page({ book, location, read, setRead, canGoBack, canGoForward, goBack, goForward, sideHidden, toggleSide, close, go, onLink }: {
  book: BotafogoBook; location: BotafogoLocation; read: boolean; setRead: (value: boolean) => void;
  canGoBack: boolean; canGoForward: boolean; goBack: () => void; goForward: () => void;
  sideHidden: boolean; toggleSide: () => void; close: () => void;
  go: (location: BotafogoLocation) => void; onLink: (href: string) => void;
}) {
  const [blocks, setBlocks] = useState<BotafogoBlock[] | null | "loading">("loading");
  const scroller = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    let alive = true;
    setBlocks("loading");
    void book.page(location.url).then((found) => { if (alive) setBlocks(found); });
    return () => { alive = false; };
  }, [book, location.url]);

  // Arriver au bout de la page la marque lue (comme sur le Mac).
  const onScroll = () => {
    const el = scroller.current;
    if (!el || read) return;
    if (el.scrollTop + el.clientHeight >= el.scrollHeight - 40) setRead(true);
  };

  const near = neighbours(book, location.url);
  return (
    <>
      <div className="bf-page-bar">
        <button type="button" className="icon-btn" title={sideHidden ? "Montrer le sommaire" : "Replier le sommaire"} onClick={toggleSide}>
          <Icon name={sideHidden ? "sidebar.left" : "arrow.left"} size={15} />
        </button>
        <button type="button" className="icon-btn" title="Page précédente de l'historique" disabled={!canGoBack} onClick={goBack}>
          <Icon name="chevron.left" size={15} />
        </button>
        <button type="button" className="icon-btn" title="Page suivante de l'historique" disabled={!canGoForward} onClick={goForward}>
          <Icon name="chevron.right" size={15} />
        </button>
        <span className="bf-trail">{trail(book, location.url)}</span>
        <button type="button" className="btn" onClick={() => setRead(!read)} title="Marquer la page comme lue">
          <Icon name={read ? "checkmark.circle.fill" : "circle"} size={14} /> {read ? "Lue" : "Marquer lue"}
        </button>
        <button type="button" className="icon-btn" title="Fermer la page" onClick={close}><Icon name="xmark" size={15} /></button>
      </div>
      <div className="bf-scroll" ref={scroller} onScroll={onScroll}>
        <article className="bf-page">
          <h1 className="bf-page-title serif"><RichInline text={location.title} /></h1>
          {blocks === "loading" && <p style={{ color: "var(--ink-tertiary)" }}>Chargement…</p>}
          {blocks === null && <p style={{ color: "var(--wrong)" }}>Cette page n'a pas pu être lue.</p>}
          {Array.isArray(blocks) && blocks.length === 0 && <p style={{ color: "var(--ink-tertiary)" }}>Page vide.</p>}
          {Array.isArray(blocks) && <BotafogoBlocks blocks={blocks} context={{ book, onLink }} />}
          <div className="bf-neighbours">
            {near.previous ? (
              <button type="button" className="bf-neighbour" onClick={() => go(near.previous!)}>
                <small>Précédent</small><RichInline text={near.previous.title} />
              </button>
            ) : <span style={{ flex: 1 }} />}
            {near.next ? (
              <button type="button" className="bf-neighbour next" onClick={() => { if (!read) setRead(true); go(near.next!); }}>
                <small>Suivant</small><RichInline text={near.next.title} />
              </button>
            ) : <span style={{ flex: 1 }} />}
          </div>
        </article>
      </div>
    </>
  );
}

/** Sans page ouverte : la semaine en cours, ce qu'il y a à lire, et où reprendre. */
function WeekHome({ book, read, go }: { book: BotafogoBook; read: Set<string>; go: (location: BotafogoLocation) => void }) {
  const index = BotafogoSite.currentWeek(book.weeks) ?? 0;
  const week = book.weeks[index];
  const nextUnread = BotafogoNavigation.nextUnread(BotafogoNavigation.order(book.chapters), read);
  return (
    <div className="bf-scroll">
      <div className="bf-page">
        <span className="bf-badge">Semaine {index + 1}</span>
        <h1 className="bf-page-title serif"><RichInline text={week?.name ?? "Le cours"} /></h1>
        <div className="bf-rows" style={{ paddingLeft: 0 }}>
          {week && weekParts(week).map((node, i) => (
            <Row key={i} icon={nodeIcon(node.type)} title={partTitle(node)} detail={partDate(node)} url={node.url ?? ""}
              readingTitle={node.type === "weekContent" ? MathMarkup.plain(week.name ?? partTitle(node)) : undefined}
              location={null} read={read} go={go} />
          ))}
          {week && (week.children ?? []).filter((node) => node.type === "series" && node.url).map((node, i) => (
            <Row key={`s${i}`} icon="list.number" title={BotafogoSite.seriesTitle(node)} detail={node.name ?? undefined}
              url={node.url ?? ""} location={null} read={read} go={go} />
          ))}
          {week && <WeekReadings book={book} week={week} location={null} read={read} go={go} />}
        </div>
        {nextUnread && (
          <button type="button" className="bf-neighbour next" style={{ marginTop: 12 }}
            onClick={() => go({ title: nextUnread.title, url: nextUnread.path })}>
            <small>Reprendre le polycopié</small><RichInline text={nextUnread.title} />
          </button>
        )}
      </div>
    </div>
  );
}
