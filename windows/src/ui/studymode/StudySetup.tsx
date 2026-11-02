// L'écran avant de commencer (StudySetupView) : sur quoi, combien de temps,
// à quel rythme, et le blocage. La carte grandit avec les cours à l'horaire —
// défilable, jamais hors cadre.

import { studyLockNote } from "../../native/studyLock.ts";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { Course } from "../../models/course.ts";
import { LinkedCalendarEvent } from "../../models/linkedCalendarEvent.ts";
import { TaskType } from "../../models/enums.ts";
import { useData } from "../../data/dataContext.tsx";
import { DateUtils } from "../../domain/dateUtils.ts";
import { DeskSchedule, kindLabelOf, type ScheduledClass } from "../../domain/deskSchedule.ts";
import { LectureClock } from "../../domain/deskMoment.ts";
import { StudyMode } from "../../domain/studyMode.ts";
import { targetOptionsFor } from "../screens/focus/timerView.ts";
import { durationChipLabel, endLabel } from "./helpers.ts";
import { studyDuration, studyOpenEnded, studyPomodoro } from "./studyPalette.ts";
import type { StudyTimerApi } from "./useStudyTimer.ts";
import { Icon, Select, Stepper, Switch, type IconName } from "../kit.tsx";
import { CourseChip, Glyph, InkButton, Kicker, PaperButton } from "./parts.tsx";

/** Ce que le choix retient (StudyModeController.Screen, les champs du choix). */
export interface SetupScreen {
  courseID?: string;
  taskType: TaskType;
  targetID?: string;
  /** Bloquer le reste pendant cette session. */
  locks: boolean;
}

/** Les types de travail proposés : ceux du chrono, plus « suivre un cours ». */
const setupTaskTypes: TaskType[] = [...TaskType.choices, "lecture"];

export function StudySetup({ screen, onScreen, courses, timer, onBegin, onCancel }: {
  screen: SetupScreen;
  onScreen: (patch: Partial<SetupScreen>) => void;
  courses: Course[];
  timer: StudyTimerApi;
  onBegin: (minutes: number | null, pomodoro: boolean) => void;
  onCancel: () => void;
}) {
  const { store, version } = useData();
  const [minutes, setMinutes] = useState(() => studyDuration.read());
  /** Sans heure de fin : on termine quand on a fini.
   *  (Le Mac règle ces valeurs dans ses Réglages ; ici elles sont gardées localement.) */
  const [openEnded, setOpenEnded] = useState(() => studyOpenEnded.read());
  const [pomodoro, setPomodoro] = useState(() =>
    timer.phase.type === "idle" ? studyPomodoro.read() : timer.state?.pomodoro ?? false);

  // L'horaire du jour : le cours à suivre, s'il y en a un maintenant.
  const classes = useMemo(
    () => (store ? DeskSchedule.today(store.fetch(LinkedCalendarEvent), timer.now) : []),
    [store, version, timer.now.getDate()],
  );
  const currentClass: ScheduledClass | null = DeskSchedule.current(classes, timer.now);

  const course = courses.find((item) => item.id === screen.courseID) ?? null;
  const options = course ? targetOptionsFor(course, screen.taskType) : null;
  const running = timer.phase.type !== "idle";

  // Suivre un cours (le panneau, l'accueil, le choix ici) : jusqu'à sa fin,
  // sans Pomodoro — un cours ne s'interrompt pas toutes les 25 minutes.
  useEffect(() => {
    if (screen.taskType !== "lecture") return;
    setPomodoro(false);
    setOpenEnded(false);
    if (currentClass && currentClass.slot.courseID === screen.courseID) {
      setMinutes(LectureClock.studyMinutes(currentClass.slot, timer.now));
    }
    // `currentClass` et l'heure dépendent du battement ; seules les vraies
    // frontières (le travail choisi, le cours) relancent l'ajustement.
  }, [screen.taskType, screen.courseID]);

  const setMinutesField = (value: number) => {
    const clamped = Math.min(Math.max(value, StudyMode.minuteRange.lowerBound), StudyMode.minuteRange.upperBound);
    setMinutes(clamped);
    setOpenEnded(false);
  };

  const followClass = () => {
    if (!currentClass) return;
    onScreen({ courseID: currentClass.slot.courseID, taskType: "lecture", targetID: undefined });
    setMinutes(LectureClock.studyMinutes(currentClass.slot, timer.now));
    setOpenEnded(false);
    setPomodoro(false);
  };

  const begin = () => {
    studyDuration.write(minutes);
    studyOpenEnded.write(openEnded);
    studyPomodoro.write(pomodoro);
    onBegin(openEnded ? null : minutes, pomodoro);
  };

  // Entrée commence, Échap annule (.defaultAction / .cancelAction du Mac).
  const latest = useRef({ begin, onCancel });
  latest.current = { begin, onCancel };
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") latest.current.onCancel();
      else if (event.key === "Enter" && !event.shiftKey) {
        const target = event.target as HTMLElement | null;
        // Un bouton, une liste ou un champ qui a le focus garde son Entrée.
        if (target && (target.closest("button, select, textarea, a") || target.tagName === "INPUT")) return;
        latest.current.begin();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // L'heure de fin, éditable : « jusqu'à » (le DatePicker du Mac).
  const endTime = new Date(timer.now.getTime() + minutes * 60_000);
  const endValue = `${String(endTime.getHours()).padStart(2, "0")}:${String(endTime.getMinutes()).padStart(2, "0")}`;
  const setEndValue = (value: string) => {
    const [hours, mins] = value.split(":").map(Number);
    if (!Number.isFinite(hours) || !Number.isFinite(mins)) return;
    const until = new Date(timer.now);
    until.setHours(hours, mins, 0, 0);
    setMinutesField(StudyMode.minutes(until, timer.now));
  };

  // Les outils ouverts quand le blocage est choisi (StudyToolStrip) : les sites.
  const tools = screen.locks
    ? StudyMode.tools(course?.name ?? null,
      course ? [course.moodleURLString, ...course.contentSources].filter((link) => link !== "") : [])
      .filter((tool) => tool.kind.type === "web")
    : [];

  return (
    <div style={{ position: "absolute", inset: 0, overflowY: "auto", display: "flex" }}>
      <div className="desk-glass" style={{
        width: 720, maxWidth: "calc(100% - 48px)", margin: "auto", padding: 32, borderRadius: 28,
        display: "flex", flexDirection: "column", gap: 20,
      }}>
        <header style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <Kicker color={course?.colorHex ?? "var(--ink-secondary)"}>Mode étude</Kicker>
          <h1 className="serif" style={{ fontSize: 52, margin: 0, lineHeight: 1.05, color: "var(--ink)" }}>
            On s'y met ?
          </h1>
          <p style={{ margin: 0, fontSize: 20, color: "var(--ink-secondary)" }}>
            Seulement tes outils de cours, jusqu'à la fin.
          </p>
        </header>

        {currentClass && !(screen.taskType === "lecture" && screen.courseID === currentClass.slot.courseID) && (
          // Un cours à l'horaire, maintenant : le suivre, jusqu'à sa fin.
          <button
            type="button"
            className="study-follow"
            onClick={followClass}
            style={{ background: currentClass.colorHex }}
          >
            <Glyph name="person.wave.2" size={20} />
            <span style={{ flex: 1, minWidth: 0 }}>
              <span style={{ display: "block", fontWeight: 600, fontSize: 15 }}>Suivre le cours · {currentClass.slot.courseCode}</span>
              <span style={{ display: "block", fontSize: 12, opacity: 0.8 }}>
                {`${kindLabelOf(currentClass.slot)}${currentClass.location === "" ? "" : ` · ${currentClass.location}`} · jusqu'à ${DateUtils.time(currentClass.slot.end)}`}
              </span>
            </span>
            <Glyph name="arrow.right" />
          </button>
        )}

        <Field title="Sur quoi">
          <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 7 }}>
              <CourseChip
                title="Libre"
                color="var(--ink-secondary)"
                selected={screen.courseID === undefined}
                onClick={() => onScreen({ courseID: undefined, targetID: undefined })}
              />
              {courses.map((item) => (
                <CourseChip
                  key={item.id}
                  title={item.displayCode}
                  help={item.name}
                  color={item.colorHex}
                  selected={screen.courseID === item.id}
                  onClick={() => onScreen({ courseID: item.id, targetID: undefined })}
                />
              ))}
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
              <Select
                ariaLabel="Travail"
                value={screen.taskType}
                options={setupTaskTypes.map((choice) => ({ value: choice, label: TaskType.label(choice) }))}
                onChange={(value) => onScreen({ taskType: value, targetID: undefined })}
              />
              {course && options && (
                <TargetSelect
                  options={options}
                  value={screen.targetID}
                  onChange={(value) => onScreen({ targetID: value })}
                />
              )}
            </div>
          </div>
        </Field>

        <Field title="Durée">
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
              {StudyMode.durations.map((value) => (
                <DurationChip
                  key={value}
                  title={durationChipLabel(value)}
                  selected={!openEnded && minutes === value}
                  onClick={() => { setMinutes(value); setOpenEnded(false); }}
                />
              ))}
              <DurationChip
                title="Sans fin"
                icon="repeat"
                selected={openEnded}
                help="Pas d'heure de fin : tu termines quand tu as fini."
                onClick={() => setOpenEnded(true)}
              />
            </div>
            {/* Une durée libre, en minutes, ou une heure de fin. */}
            <div style={{ display: "flex", alignItems: "center", gap: 10, opacity: openEnded ? 0.45 : 1, flexWrap: "wrap" }}>
              <Stepper
                label="la durée"
                value={minutes}
                min={StudyMode.minuteRange.lowerBound}
                max={StudyMode.minuteRange.upperBound}
                step={5}
                format={(value) => `${value} min`}
                onChange={setMinutesField}
              />
              <span style={{ fontSize: 14, color: "var(--ink-secondary)" }}>jusqu'à</span>
              <input
                type="time"
                className="field"
                aria-label="Heure de fin"
                value={endValue}
                disabled={openEnded}
                onChange={(event) => setEndValue(event.target.value)}
              />
            </div>
          </div>
        </Field>

        <div style={{ display: "flex", gap: 36, flexWrap: "wrap" }}>
          <Field title="Rythme">
            <div style={{ opacity: running ? 0.5 : 1 }}>
              <Switch
                checked={pomodoro}
                disabled={running}
                onChange={setPomodoro}
                label={
                  <span style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                    <span style={{ color: "var(--ink)", fontSize: 14 }}>Pomodoro</span>
                    <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
                      {`${timer.settings.cycle.focusMinutes} min de travail, ${timer.settings.cycle.shortBreakMinutes} min de pause.`}
                    </span>
                  </span>
                }
              />
            </div>
          </Field>

          <Field title="Blocage">
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              <Switch
                checked={screen.locks}
                onChange={(value) => onScreen({ locks: value })}
                label={<span style={{ color: "var(--ink)", fontSize: 14 }}>Bloquer le reste</span>}
              />
              {/* Blocage natif au mieux (src/native/studyLock.ts) : le texte dit
                  ce qui sera réellement tenu sur ce poste. */}
              <span style={{ fontSize: 12, color: "var(--ink-secondary)", maxWidth: 380 }}>
                {studyLockNote()}
              </span>
            </div>
          </Field>
        </div>

        {screen.locks && tools.length > 0 && (
          <Field title="Ouverts">
            <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
              {tools.map((tool) => (
                <span key={tool.id} title={tool.title} style={{
                  display: "flex", flexDirection: "column", alignItems: "center", gap: 5, width: 64,
                }}>
                  <span aria-hidden className="row-icon" style={{
                    display: "grid", placeItems: "center", width: 32, height: 32, borderRadius: 8,
                    background: "var(--sheet-raised)", color: "var(--ink)",
                  }}><Glyph name={tool.icon} size={16} /></span>
                  <span style={{
                    fontSize: 11, color: "var(--ink-secondary)", maxWidth: "100%",
                    overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
                  }}>{tool.title}</span>
                </span>
              ))}
            </div>
          </Field>
        )}

        <footer style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 4 }}>
          <PaperButton large onClick={onCancel}>Annuler</PaperButton>
          <div style={{ flex: 1 }} />
          <span style={{ fontSize: 14, color: "var(--ink-secondary)" }}>{endLabel(minutes, openEnded, timer.now)}</span>
          <InkButton large onClick={begin}>
            <Glyph name="lock.fill" size={15} />
            {running ? "Verrouiller la session" : "Commencer"}
          </InkButton>
        </footer>
      </div>
    </div>
  );
}

function Field({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      <h2 className="serif" style={{ fontSize: 20, margin: 0, color: "var(--ink)" }}>{title}</h2>
      {children}
    </section>
  );
}

/** Le choix de la cible : tout le cours, ce qui reste, ce qui est fait (TargetMenu). */
function TargetSelect({ options, value, onChange }: {
  options: NonNullable<ReturnType<typeof targetOptionsFor>>;
  value: string | undefined;
  onChange: (value: string | undefined) => void;
}) {
  return (
    <select
      className="select"
      aria-label="Cible"
      value={value ?? ""}
      style={{ maxWidth: 280 }}
      onChange={(event) => onChange(event.target.value === "" ? undefined : event.target.value)}
    >
      <option value="">Tout le cours</option>
      {options.upNext.length > 0 && (
        <optgroup label="À faire">
          {options.upNext.map((option) => <option key={option.id} value={option.id}>{option.label}</option>)}
        </optgroup>
      )}
      {options.done.length > 0 && (
        <optgroup label={options.doneLabel}>
          {options.done.map((option) => <option key={option.id} value={option.id}>{option.label}</option>)}
        </optgroup>
      )}
    </select>
  );
}

/** Une durée proposée (durationChip du Mac). */
function DurationChip({ title, icon, selected, help, onClick }: {
  title: string;
  icon?: IconName;
  selected: boolean;
  help?: string;
  onClick: () => void;
}) {
  return (
    <button type="button" className="study-duration" title={help ?? title} aria-pressed={selected} onClick={onClick}>
      {icon && <Icon name={icon} size={16} />}
      {title}
    </button>
  );
}
