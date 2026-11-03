// La palette Ctrl+K (CommandPalette.swift + PaletteList.swift) : tout l'app au
// clavier. Taper un cours, une série, un exercice, une action ; ↩ ouvre,
// Ctrl+↩ chronomètre, Échap ferme.

import { openQuickNote } from "../quicknote/QuickNote.tsx";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { useData } from "../../data/dataContext.tsx";
import { Course } from "../../models/index.ts";
import { SearchEngine, SearchKind } from "../../domain/searchEngine.ts";
import { SearchIndexBuilder } from "../../domain/searchIndexBuilder.ts";
import { timerController } from "../timerController.ts";
import { cx, Icon } from "../kit.tsx";
import {
  PALETTE_KINDS, iconForKind, matches, moveSelection, resolveHit, sortBySection, startsSection,
  type PaletteItem,
} from "./paletteHelpers.ts";
import "./palette.css";

type PageKind = "today" | "courses" | "focus" | "agenda" | "stats" | "settings";

export function CommandPalette({ onClose, onOpenCourse, onNavigate, onStudyMode }: {
  onClose: () => void;
  onOpenCourse: (id: string, item?: string | null) => void;
  onNavigate: (kind: PageKind) => void;
  onStudyMode: () => void;
}) {
  const { store } = useData();
  const snap = useSyncExternalStore(timerController.subscribe, timerController.snapshot);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const [byMouse, setByMouse] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);

  // Les cours suivis, triés par code (@Query(sort: \Course.code) + isTracked).
  const tracked = useMemo(
    () => (store ? store.fetch(Course).filter((c) => c.isTracked).sort((a, b) => a.code.localeCompare(b.code)) : []),
    [store],
  );
  // L'index se construit une fois à l'ouverture, pas à chaque frappe.
  const documents = useMemo(() => SearchIndexBuilder.documents({ courses: tracked }), [tracked]);

  const items = useMemo(() => {
    // Ctrl+↩ : démarrer sur la cible, ou la changer si le chrono tourne déjà.
    const time = (courseID: string, type: "theory" | "exercise", target: string | null) => {
      const idle = timerController.phase().type === "idle";
      timerController.retarget(courseID, type, target ?? undefined);
      if (idle) timerController.start();
    };

    const phase = timerController.phase().type;
    const actions: PaletteItem[] = [];
    const action = (a: Omit<PaletteItem, "subtitle"> & { subtitle?: string }) => actions.push({ subtitle: "", ...a });
    switch (phase) {
      case "idle":
        action({ id: "a.start", title: "Démarrer le chrono", icon: "play.fill", section: "Chrono", run: () => timerController.start() });
        break;
      case "working":
        action({ id: "a.pause", title: "Mettre en pause", icon: "pause.fill", section: "Chrono", run: () => timerController.pause() });
        break;
      case "paused":
        action({ id: "a.resume", title: "Reprendre", icon: "play.fill", section: "Chrono", run: () => timerController.resume() });
        break;
      case "onBreak":
        action({ id: "a.skip", title: "Écourter la pause", icon: "forward.end.fill", section: "Chrono", run: () => timerController.skipBreak() });
        break;
    }
    action({ id: "p.today", title: "Aujourd'hui", icon: "sun.max", section: "Aller à", run: () => onNavigate("today") });
    action({ id: "p.focus", title: "Chrono", icon: "timer", section: "Aller à", run: () => onNavigate("focus") });
    action({ id: "p.agenda", title: "Agenda", icon: "calendar", section: "Aller à", run: () => onNavigate("agenda") });
    action({ id: "p.stats", title: "Bilan", icon: "chart.bar.xaxis", section: "Aller à", run: () => onNavigate("stats") });
    action({
      id: "a.study", title: "Mode étude…", subtitle: "Plein écran", icon: "moon", section: "Actions",
      shortcut: "Ctrl+Maj+E", run: onStudyMode,
    });
    action({ id: "a.quicknote", title: "Note rapide…", subtitle: "Une ligne datée dans les notes d'un cours", icon: "note.text", section: "Actions", run: () => openQuickNote() });
    action({ id: "a.settings", title: "Réglages…", icon: "gearshape", section: "Aller à", run: () => onNavigate("settings") });

    const needle = query.trim();
    const shown = actions.filter((a) => needle === "" || matches(a.title, needle));

    if (needle === "") {
      return [
        ...shown,
        ...tracked.map<PaletteItem>((course) => ({
          id: `c.${course.id}`, title: course.name, subtitle: course.displayCode, icon: "book",
          tint: course.colorHex, section: "Cours",
          run: () => onOpenCourse(course.id),
          time: () => time(course.id, "exercise", null),
        })),
      ];
    }

    const found: PaletteItem[] = [];
    for (const hit of SearchEngine.search(needle, documents).filter((h) => PALETTE_KINDS.includes(h.kind)).slice(0, 40)) {
      const target = resolveHit(tracked, hit);
      if (!target) continue;
      const course = tracked.find((c) => c.id === target.course);
      found.push({
        id: hit.document.id,
        title: hit.document.title,
        subtitle: [hit.document.courseCode, hit.document.subtitle].filter((s): s is string => !!s).join(" · "),
        icon: iconForKind(hit.kind),
        tint: course?.colorHex,
        section: SearchKind.label(hit.kind),
        run: () => onOpenCourse(target.course, target.item),
        time: () => time(target.course, target.type, target.item),
      });
    }
    return [...shown, ...sortBySection(found)];
    // `snap` : les actions du chrono suivent sa phase.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query, tracked, documents, snap, onNavigate, onOpenCourse, onStudyMode]);

  useEffect(() => { setSelected(0); }, [query]);

  // La sélection suit le clavier : la ligne reste visible.
  useEffect(() => {
    if (byMouse) return;
    listRef.current?.querySelector<HTMLElement>(`[data-index="${selected}"]`)?.scrollIntoView({ block: "nearest" });
  }, [selected, byMouse]);

  function run(timing: boolean) {
    const item = items[selected];
    if (!item) return;
    if (timing && item.time) item.time(); else item.run();
    onClose();
  }

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      setByMouse(false);
      setSelected((s) => moveSelection(s, e.key === "ArrowDown" ? 1 : -1, items.length));
    } else if (e.key === "Enter") {
      e.preventDefault();
      run(e.ctrlKey || e.metaKey);
    } else if (e.key === "Escape") {
      e.preventDefault();
      onClose();
    }
  }

  return (
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="dialog palette" role="dialog" aria-label="Palette de commandes" onKeyDown={onKeyDown}>
        <div className="palette-field">
          <Icon name="magnifyingglass" size={18} />
          <input
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Chercher"
            aria-label="Chercher"
            role="combobox"
            aria-expanded
            aria-controls="palette-list"
            spellCheck={false}
            autoComplete="off"
          />
        </div>
        <div className="palette-list" id="palette-list" role="listbox" ref={listRef}>
          {items.length === 0 && <div className="palette-empty">Rien pour « {query} ».</div>}
          {items.map((item, index) => (
            <div key={item.id}>
              {startsSection(items, index) && (
                <div className={cx("palette-section", index === 0 && "first")}>{item.section}</div>
              )}
              <div
                className={cx("palette-row", index === selected && "selected")}
                role="option"
                aria-selected={index === selected}
                data-index={index}
                onClick={() => { setSelected(index); run(false); }}
                onMouseMove={() => { if (selected !== index || !byMouse) { setByMouse(true); setSelected(index); } }}
              >
                <span className="palette-icon" style={item.tint && index !== selected ? { color: item.tint } : undefined}>
                  <Icon name={item.icon} size={16} />
                </span>
                <span className="palette-title">{item.title}</span>
                {item.subtitle !== "" && <span className="palette-sub">{item.subtitle}</span>}
                <span className="palette-spacer" />
                {item.shortcut && <span className="palette-shortcut">{item.shortcut}</span>}
              </div>
            </div>
          ))}
        </div>
        <div className="palette-hints">
          <Hint keys="↩" label="ouvrir" />
          <Hint keys="Ctrl ↩" label="chronométrer" />
          <Hint keys="↑↓" label="choisir" />
          <span className="palette-spacer" />
          <Hint keys="Échap" label="fermer" />
        </div>
      </div>
    </div>
  );
}

function Hint({ keys, label }: { keys: string; label: string }) {
  return (
    <span className="palette-hint">
      <kbd>{keys}</kbd>
      <span>{label}</span>
    </span>
  );
}
