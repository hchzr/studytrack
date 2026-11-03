// La barre du haut du bureau : la session à gauche (l'anneau, ce qui reste,
// la pause), sur quoi on travaille au milieu, et à droite la sortie — qui ne
// se replie jamais (StudyTopBar). Les outils repliables du Mac (musique, état,
// centre de contrôle) n'ont pas d'équivalent Windows.

import type { Course } from "../../models/course.ts";
import { TaskType } from "../../models/enums.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { StudyMode } from "../../domain/studyMode.ts";
import { DeskMoment, type DeskMoment as DeskMomentValue } from "../../domain/deskMoment.ts";
import { TimerText } from "../../domain/timerText.ts";
import { displaySecondsOf } from "../screens/focus/timerView.ts";
import { timerController } from "../timerController.ts";
import type { StudyTimerApi } from "./useStudyTimer.ts";
import { Icon, IconButton, type IconName, type MenuItem } from "../kit.tsx";
import { openInApp } from "./openers.ts";
import { releaseStudyLock } from "../../native/studyLock.ts";
import { CourseTag, DropMenu, Glyph, HoldButton, SmallRing } from "./parts.tsx";

/** La forme du bureau : le chrono continue, le temps déjà compté reste. */
function MomentMenu({ course, moment, onPick }: {
  course: Course | null;
  moment: DeskMomentValue;
  onPick: (taskType: TaskType) => void;
}) {
  const items: MenuItem[] = [
    { label: DeskMoment.title("lecture"), icon: DeskMoment.icon("lecture") as IconName, action: () => onPick("lecture") },
    { label: DeskMoment.title("series"), icon: DeskMoment.icon("series") as IconName, action: () => onPick("exercise") },
    {
      label: course?.nextSitting != null ? DeskMoment.title("revision") : TaskType.label("theory"),
      icon: DeskMoment.icon("revision") as IconName, action: () => onPick("theory"),
    },
  ];
  return (
    <DropMenu
      items={items}
      trigger={({ toggle, open }) => (
        <button type="button" className="study-pill" title="La forme du bureau" aria-haspopup="menu"
          aria-expanded={open} disabled={course === null} onClick={toggle}>
          <span aria-hidden style={{ color: "var(--ink-tertiary)" }}>·</span>
          <Glyph name={DeskMoment.icon(moment)} size={13} />
          {DeskMoment.title(moment)}
          <Icon name="chevron.down" size={11} strokeWidth={2.5} />
        </button>
      )}
    />
  );
}

/** Les ressources gardées du cours, à un clic : elles s'ouvrent au-dehors (resourcesMenu). */
function ResourcesMenu({ course }: { course: Course }) {
  const resources = course.sortedResources;
  const items: MenuItem[] = resources.length === 0
    ? [
      { label: "Rien de gardé pour l'instant", disabled: true, action: () => {} },
      { label: "Le signet en haut d'un document, ou Cours › Gardés", disabled: true, action: () => {} },
    ]
    : resources.map((resource): MenuItem => ({
      label: resource.title,
      icon: resource.isPinned ? "bookmark" : "link",
      disabled: resource.isFile || !/^https?:\/\//i.test(resource.address),
      action: () => { void openInApp(resource.address); },
    }));
  return (
    <DropMenu
      items={items}
      trigger={({ toggle, open }) => (
        <IconButton icon="bookmark" label="Tes ressources gardées" aria-haspopup="menu" aria-expanded={open}
          onClick={toggle} style={resources.length > 0 ? { color: "var(--ink)" } : undefined} />
      )}
    />
  );
}

/** Le menu de sortie : prolonger, le rythme, et les sorties de la session. */
function ExitMenu({ timer }: { timer: StudyTimerApi }) {
  const state = timer.state;
  const openEnded = state !== null && StudyMode.isOpenEnded(state);
  const items: MenuItem[] = [];
  if (!openEnded) {
    items.push({ label: "Encore 25 min", icon: "plus", action: () => timerController.extendStudy(25) }, "divider");
  }
  if (state?.groupSession == null) {
    items.push({
      label: state?.pomodoro === true ? "Couper le Pomodoro" : "Allumer le Pomodoro",
      icon: "timer",
      action: () => timerController.setPomodoro(state?.pomodoro !== true),
    });
  }
  // « Réorganiser les outils » et « Mes cours » n'ont pas d'équivalent
  // Windows : pas de colonne d'outils épinglables, une seule fenêtre.
  if (!timer.isLocked) {
    items.push(
      "divider",
      { label: "Sortir, garder la session", icon: "rectangle.portrait.and.arrow.right", action: () => timerController.leaveStudy() },
      { label: "Abandonner", icon: "trash", danger: true, action: () => timerController.discard() },
    );
  }
  return (
    <DropMenu
      align="right"
      items={items}
      trigger={({ toggle, open }) => (
        <IconButton icon="ellipsis" label="Plus" aria-haspopup="menu" aria-expanded={open} onClick={toggle} />
      )}
    />
  );
}

export function StudyTopBar({ course, tint, moment, timer, headline, sideOpen, onToggleSide }: {
  course: Course | null;
  tint: string;
  moment: DeskMomentValue;
  timer: StudyTimerApi;
  headline: string;
  sideOpen: boolean;
  onToggleSide: () => void;
}) {
  const state = timer.state;
  if (!state) return null;
  const paused = timer.phase.type === "paused";
  const onBreak = timer.phase.type === "onBreak";
  const openEnded = StudyMode.isOpenEnded(state);

  const caption = paused
    ? "En pause"
    : openEnded
      ? `depuis ${DateUtils.time(state.studySince ?? timer.now)}`
      : `jusqu'à ${DateUtils.time(state.studyUntil ?? timer.now)}`;

  const buttonIcon = timer.phase.type === "working" ? "pause" : onBreak ? "forward" : "play";
  const buttonTitle = timer.phase.type === "working"
    ? "Mettre la session en pause"
    : onBreak ? "Écourter la pause" : "Reprendre la session";

  const group = state.groupSession;
  return (
    <header className="desk-chrome edge-bottom" style={{
      display: "flex", alignItems: "center", gap: 16, padding: "9px 18px", flexShrink: 0, position: "relative", zIndex: 5,
    }}>
      {/* La session : l'anneau, ce qui reste (ou depuis quand), et la pause. */}
      <div style={{
        display: "flex", alignItems: "center", gap: 12, padding: "5px 6px 5px 12px",
        borderRadius: 999, background: "var(--sheet-raised)", flexShrink: 0,
        border: `1px solid ${paused ? `color-mix(in srgb, ${tint} 60%, transparent)` : "var(--rule)"}`,
        transition: "border-color var(--t-med)",
      }}>
        <SmallRing progress={StudyMode.progress(state, timer.now)} tint={tint} />
        <div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
          <span className="mono" style={{
            fontSize: 20, lineHeight: 1.15, fontVariantNumeric: "tabular-nums",
            color: paused ? "var(--ink-secondary)" : "var(--ink)",
          }}>
            {TimerText.clock(StudyMode.clock(state, timer.now))}
          </span>
          <span style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 11, color: paused ? "var(--review)" : "var(--ink-tertiary)" }}>
            {caption}
            {state.pomodoro && (
              <>
                <span aria-hidden>·</span>
                <Glyph name={onBreak ? "cup.and.saucer" : "timer"} size={11} />
                <span className="mono">{TimerText.clock(displaySecondsOf(state, timer.cycle, timer.now))}</span>
              </>
            )}
          </span>
        </div>
        <button
          type="button"
          className="bar-play"
          title={buttonTitle}
          aria-label={buttonTitle}
          onClick={() => {
            if (onBreak) timerController.skipBreak();
            else timerController.toggle();
          }}
          style={paused ? { background: tint } : undefined}
        >
          <Glyph name={buttonIcon} size={14} />
        </button>
      </div>

      {/* Le cours et la forme du bureau sur une ligne, la cible dessous. */}
      <div style={{ display: "flex", flexDirection: "column", gap: 2, minWidth: 0, maxWidth: 360, flex: 1 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          {course && <CourseTag code={course.displayCode} tint={tint} />}
          <MomentMenu
            course={course}
            moment={moment}
            onPick={(taskType) => timerController.retarget(timer.courseID, taskType, undefined)}
          />
          {group && (
            <span title="Chrono commun avec le groupe" style={{
              display: "inline-flex", alignItems: "center", gap: 4, fontSize: 12, color: "var(--ink-secondary)",
            }}>
              <Glyph name="person.2" size={12} /> {group.groupName}
            </span>
          )}
        </div>
        <span className="serif" style={{
          fontSize: 22, lineHeight: 1.2, color: "var(--ink)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
        }}>
          {headline}
        </span>
      </div>

      <div style={{ flex: 1 }} />

      {/* Les ressources, puis la sortie de la session : toujours visible. */}
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        {course && <ResourcesMenu course={course} />}
        <IconButton
          icon="sidebar.right"
          label={sideOpen ? "Fermer le volet d'à côté (Ctrl+\\)" : "Le volet d'à côté : l'énoncé, la fiche, tes liens (Ctrl+\\)"}
          aria-pressed={sideOpen}
          onClick={onToggleSide}
          style={sideOpen ? { background: "var(--sheet-raised)", color: tint } : undefined}
        />
        <div style={{ width: 1, height: 26, background: "var(--rule)" }} />
        {timer.isLocked ? (
          // Sous verrou : une seule sortie, qu'on ne prend pas par réflexe.
          <>
            <span title="Session verrouillée" style={{ color: "var(--ink-tertiary)", display: "grid" }}>
              <Glyph name="lock.fill" />
            </span>
            <HoldButton
              title="Sortie d'urgence"
              glyph="exclamationmark.triangle"
              hold={StudyMode.emergencyHold}
              tint="var(--wrong)"
              help={`Maintiens ${Math.trunc(StudyMode.emergencyHold)} secondes : la session s'enregistre, notée « sortie d'urgence », et l'écran est rendu.`}
              onAct={() => {
                // L'écran d'abord : la sortie d'urgence ne doit dépendre de rien d'autre.
                void releaseStudyLock();
                void timerController.finish({ emergency: true });
              }}
            />
          </>
        ) : (
          // Sans verrou, un clic suffit (« tenir pour terminer » n'est pas réglé ici).
          <HoldButton
            title="Terminer"
            glyph="checkmark"
            hold={0}
            onAct={() => { void timerController.finish(); }}
          />
        )}
        <ExitMenu timer={timer} />
      </div>
    </header>
  );
}
