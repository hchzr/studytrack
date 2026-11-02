// Le bureau du mode étude (StudyWorkspace) : une barre en haut (ce qui reste,
// sur quoi, les gestes), une colonne d'outils à gauche, l'outil choisi au
// centre, le volet d'à côté à droite. Tout est natif-web : pas de navigateur
// intégré, pas de Claude ni de calcul ni de musique — les liens du cours
// s'ouvrent au-dehors, le reste se lit dans l'app.

import { useEffect, useMemo, useRef, useState } from "react";
import { Course } from "../../models/course.ts";
import { LinkedCalendarEvent } from "../../models/linkedCalendarEvent.ts";
import { TaskType } from "../../models/enums.ts";
import { useData } from "../../data/dataContext.tsx";
import { DeskSchedule, type ScheduledClass } from "../../domain/deskSchedule.ts";
import { LectureClock } from "../../domain/deskMoment.ts";
import type { SoundtrackPhase } from "../../domain/sessionSoundtrack.ts";
import { DeskArrangement, type DeskCenter, type DeskArrangementContextInit, type DeskTakeover } from "../../domain/deskArrangement.ts";
import { StudyMode } from "../../domain/studyMode.ts";
import { headlineOf } from "../screens/focus/timerView.ts";
import { timerController } from "../timerController.ts";
import type { StudyTimerApi } from "./useStudyTimer.ts";
import { STUDY_PANES, type StudyPane } from "./paneKind.ts";
import { solutionAddress } from "./helpers.ts";
import { StudyTopBar } from "./StudyTopBar.tsx";
import { StudySidePanel } from "./StudySidePanel.tsx";
import { TakeoverOverlay } from "./TakeoverCards.tsx";
import { DeskHome } from "./panes/DeskHome.tsx";
import { ExercisePane } from "./panes/ExercisePane.tsx";
import { NotesPane } from "./panes/NotesPane.tsx";
import { SheetPane } from "./panes/SheetPane.tsx";
import { Glyph, tintOfCourse } from "./parts.tsx";

/** La série du moment : celle de l'exercice suivi, sinon celle de la semaine. */
function currentSeriesOf(course: Course | null, targetID: string | undefined) {
  if (!course) return null;
  const current = course.allExercises.find((item) => item.id === targetID)?.series;
  if (current) return current;
  const all = course.sortedSeries.filter((series) => series.exercises.length > 0);
  return all.find((series) => series.plannedWeek >= course.currentWeek && !series.isComplete) ?? all[all.length - 1] ?? null;
}

/** Ce que le bureau du Mac met au centre, sur nos outils : le panneau Cours
 *  n'existe pas ici — les notes du cours tiennent sa place ; calc, web et
 *  musique ne sont pas portés, le panneau courant reste. */
function mapCenter(center: DeskCenter): StudyPane | null {
  switch (center) {
    case "desk": return "desk";
    case "exercise": return "exercise";
    case "course": case "notes": return "notes";
    default: return null;
  }
}

/** Un bouton de la colonne d'outils (RailButtonLabel). */
function RailButton({ label, icon, selected, help, onClick }: {
  label: string;
  icon: string;
  selected: boolean;
  help: string;
  onClick: () => void;
}) {
  return (
    <button type="button" className="rail-btn" title={help} aria-pressed={selected} onClick={onClick}>
      <span aria-hidden className="rail-icon"><Glyph name={icon} size={18} /></span>
      <span className="rail-label">{label}</span>
    </button>
  );
}

export function StudyWorkspace({ courses, timer, save, initialPane = "desk" }: {
  courses: Course[];
  timer: StudyTimerApi;
  save: (instance: object) => Promise<void>;
  /** Le panneau que le bureau ouvre (l'enchaînement sur la série). */
  initialPane?: StudyPane;
}) {
  const { store, version } = useData();
  const [pane, setPane] = useState<StudyPane>(initialPane);
  const [sideOpen, setSideOpen] = useState(false);
  /** Le voile de pause / bilan qu'on a écarté (jusqu'au prochain changement). */
  const [dismissed, setDismissed] = useState<DeskTakeover | null>(null);
  /** Ce qu'un geste a épinglé (le bureau ne bouge pas sous les mains). */
  const pins = useRef({ center: false, side: false });
  const lastKey = useRef<string | null>(null);

  const state = timer.state;
  const course = courses.find((item) => item.id === timer.courseID) ?? null;
  const tint = tintOfCourse(course);
  const moment = DeskSchedule.moment(timer.taskType, state?.groupSession != null, course);

  // L'horaire du jour : le cours en cours (la pause du cours), la suite.
  const classes = useMemo<ScheduledClass[]>(
    () => (store ? DeskSchedule.today(store.fetch(LinkedCalendarEvent), timer.now) : []),
    [store, version, timer.now.getDate()],
  );
  const klass = DeskSchedule.latest(course?.id ?? null, classes, timer.now);

  const exercise = course?.allExercises.find((item) => item.id === timer.targetID) ?? null;
  const series = exercise?.series ?? currentSeriesOf(course, timer.targetID);

  // Ce que le bureau sait de la situation (StudyWorkspace.arrangementContext) :
  // `writingApp` (GoodNotes au premier plan) et `hasCopy` (la copie de la
  // série dans tes notes) n'ont pas d'équivalent Windows — toujours faux.
  const phase: SoundtrackPhase = !timer.isStudying ? "ended"
    : timer.phase.type === "onBreak" ? "onBreak"
    : timer.phase.type === "paused" ? "paused"
    : "running";
  const context: DeskArrangementContextInit = {
    moment,
    isTheory: TaskType.canonical(timer.taskType) === "theory",
    phase,
    hasTarget: exercise !== null,
    targetDone: exercise?.isDone ?? false,
    seriesComplete: exercise !== null && (exercise.series?.isComplete ?? false),
    solutionAvailable: series !== null && solutionAddress(series, timer.now) !== null,
    hasCopy: false,
    hasCourseNotes: course !== null,
    minutesLeft: state && !StudyMode.isOpenEnded(state)
      ? Math.trunc(StudyMode.remaining(state, timer.now) / 60)
      : null,
    classBreak: moment === "lecture" && klass !== null
      && LectureClock.phase(klass.slot, timer.now).kind === "pause",
    writingApp: false,
  };

  // À un changement de moment : le bureau se met en place, sauf ce que
  // l'étudiant·e a épinglé ; le voile écarté revient.
  const key = DeskArrangement.signature(context);
  useEffect(() => {
    if (lastKey.current === key) return;
    const first = lastKey.current === null;
    lastKey.current = key;
    pins.current = { center: false, side: false };
    setDismissed(null);
    const wanted = DeskArrangement.layout(context);
    const mapped = mapCenter(wanted.center);
    // Au premier passage, le bureau s'ouvre sur son accueil ; ensuite seulement
    // les changements déplacent le centre.
    if (!first && mapped !== null) setPane(mapped);
    setSideOpen(wanted.side.length > 0 && wanted.sideOpen);
    // Le contexte se déduit de l'état affiché ; seule sa clé (le moment)
    // relance la mise en place — pas chaque battement de l'horloge.
  }, [key]);

  const openPane = (next: StudyPane) => {
    pins.current.center = true;
    setPane(next);
  };

  const toggleSide = () => {
    pins.current.side = true;
    setSideOpen(!sideOpen);
  };

  // Les raccourcis du Mac (⌘1…⌘4 : l'outil du centre ; ⌘\ : le volet d'à côté),
  // sur Ctrl : Ctrl+1…4 et Ctrl+\.
  const shortcuts = useRef({ openPane, toggleSide });
  shortcuts.current = { openPane, toggleSide };
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return;
      if (event.key === "\\") {
        event.preventDefault();
        shortcuts.current.toggleSide();
        return;
      }
      const index = Number(event.key) - 1;
      if (Number.isInteger(index) && index >= 0 && index < STUDY_PANES.length) {
        event.preventDefault();
        shortcuts.current.openPane(STUDY_PANES[index].kind);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (!state) return null;
  const takeover = DeskArrangement.layout(context).takeover;

  return (
    <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column" }}>
      <StudyTopBar
        course={course}
        tint={tint}
        moment={moment}
        timer={timer}
        headline={headlineOf(course, timer.taskType, timer.targetID)}
        sideOpen={sideOpen}
        onToggleSide={toggleSide}
      />
      <div style={{ flex: 1, display: "flex", minHeight: 0 }}>
        {/* La colonne d'outils : le centre, un outil à la fois (StudyRail,
            sans Claude ni apps permises — rien à lancer hors du navigateur). */}
        <nav aria-label="Outils" className="desk-chrome edge-right" style={{
          width: 76, flexShrink: 0, display: "flex", flexDirection: "column", alignItems: "center",
          gap: 6, padding: "14px 0",
        }}>
          {STUDY_PANES.map((entry) => (
            <RailButton
              key={entry.kind}
              label={entry.label}
              icon={entry.icon}
              help={`${entry.help} (Ctrl+${STUDY_PANES.indexOf(entry) + 1})`}
              selected={pane === entry.kind}
              onClick={() => openPane(entry.kind)}
            />
          ))}
        </nav>

        <main style={{ flex: 1, minWidth: 0, position: "relative" }}>
          {pane === "desk" && (
            <DeskHome
              course={course}
              courses={courses}
              classes={classes}
              timer={timer}
              save={save}
              onOpenPane={openPane}
            />
          )}
          {pane === "exercise" && <ExercisePane course={course} timer={timer} save={save} />}
          {pane === "notes" && <NotesPane course={course} save={save} />}
          {pane === "sheet" && <SheetPane course={course} />}
        </main>

        {sideOpen && (
          <StudySidePanel
            course={course}
            series={series}
            now={timer.now}
            onOpenPane={openPane}
            onClose={() => setSideOpen(false)}
          />
        )}
      </div>

      {takeover !== "none" && dismissed !== takeover && (
        <TakeoverOverlay
          kind={takeover}
          state={state}
          cycle={timer.cycle}
          now={timer.now}
          exercise={exercise}
          onDismiss={() => setDismissed(takeover)}
          onSkipBreak={() => timerController.skipBreak()}
          onResume={() => timerController.resume()}
          onExtend={(minutes) => timerController.extendStudy(minutes)}
          onConfidence={(level) => {
            if (!exercise) return;
            exercise.confidence = level;
            void save(exercise);
          }}
        />
      )}
    </div>
  );
}
