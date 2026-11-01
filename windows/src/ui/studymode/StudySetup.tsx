// L'écran avant de commencer (StudySetupView) : sur quoi, combien de temps,
// à quel rythme, et le blocage. La carte grandit avec les cours à l'horaire —
// défilable, jamais hors cadre.

import { useEffect, useMemo, useState, type ReactNode } from "react";
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

  return (
    <div style={{ position: "absolute", inset: 0, overflowY: "auto" }}>
      <div style={{
        maxWidth: 720, margin: "0 auto", padding: "24px 32px 40px",
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
            onClick={followClass}
            style={{
              display: "flex", alignItems: "center", gap: 12, width: "100%", textAlign: "left",
              padding: 14, borderRadius: 14, border: "none", cursor: "pointer",
              background: currentClass.colorHex, color: "var(--ground)",
            }}
          >
            <Glyph name="person.wave.2" />
            <span style={{ flex: 1, minWidth: 0 }}>
              <span style={{ display: "block", fontWeight: 600 }}>Suivre le cours · {currentClass.slot.courseCode}</span>
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
              <Pill>
                <select
                  aria-label="Travail"
                  value={screen.taskType}
                  style={selectStyle}
                  onChange={(event) => onScreen({ taskType: event.target.value as TaskType, targetID: undefined })}
                >
                  {setupTaskTypes.map((choice) => (
                    <option key={choice} value={choice}>{TaskType.label(choice)}</option>
                  ))}
                </select>
              </Pill>
              {course && options && (
                <Pill>
                  <select
                    aria-label="Cible"
                    value={screen.targetID ?? ""}
                    style={selectStyle}
                    onChange={(event) => onScreen({ targetID: event.target.value === "" ? undefined : event.target.value })}
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
                </Pill>
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
                glyph="infinity"
                selected={openEnded}
                titleText="Pas d'heure de fin : tu termines quand tu as fini."
                onClick={() => setOpenEnded(true)}
              />
            </div>
            {/* Une durée libre, en minutes. Le Mac propose aussi une heure de fin
                par son sélecteur ; ici le champ et le pas-à-pas, avec l'heure
                de fin qui en résulte. */}
            <div style={{ display: "flex", alignItems: "center", gap: 8, opacity: openEnded ? 0.45 : 1 }}>
              <input
                type="number"
                aria-label="Minutes"
                value={minutes}
                min={StudyMode.minuteRange.lowerBound}
                max={StudyMode.minuteRange.upperBound}
                onChange={(event) => {
                  const value = Number(event.target.value);
                  if (Number.isFinite(value)) setMinutesField(value);
                }}
                style={{
                  width: 64, padding: "5px 8px", borderRadius: 8, fontSize: 14,
                  border: "1px solid var(--rule)", background: "var(--sheet-raised)", color: "var(--ink)",
                }}
              />
              <span aria-hidden style={{ display: "flex", gap: 2 }}>
                <Stepper onClick={() => setMinutesField(minutes - 5)}>−</Stepper>
                <Stepper onClick={() => setMinutesField(minutes + 5)}>+</Stepper>
              </span>
              <span style={{ fontSize: 14, color: "var(--ink-secondary)" }}>
                min, jusqu'à {endLabel(0, false, new Date(timer.now.getTime() + minutes * 60_000)).replace("jusqu'à ", "")}
              </span>
            </div>
          </div>
        </Field>

        <div style={{ display: "flex", gap: 36, flexWrap: "wrap" }}>
          <Field title="Rythme">
            <label style={{ display: "flex", alignItems: "flex-start", gap: 10, cursor: running ? "not-allowed" : "pointer", opacity: running ? 0.5 : 1 }}>
              <input
                type="checkbox"
                checked={pomodoro}
                disabled={running}
                onChange={(event) => setPomodoro(event.target.checked)}
                style={{ width: 16, height: 16, marginTop: 2, accentColor: "var(--correct)" }}
              />
              <span style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                <span style={{ color: "var(--ink)" }}>Pomodoro</span>
                <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
                  {`${timer.settings.cycle.focusMinutes} min de travail, ${timer.settings.cycle.shortBreakMinutes} min de pause.`}
                </span>
              </span>
            </label>
          </Field>

          <Field title="Blocage">
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              <label style={{ display: "flex", alignItems: "center", gap: 10, cursor: "pointer" }}>
                <input
                  type="checkbox"
                  checked={screen.locks}
                  onChange={(event) => onScreen({ locks: event.target.checked })}
                  style={{ width: 16, height: 16, accentColor: "var(--correct)" }}
                />
                <span style={{ color: "var(--ink)" }}>Bloquer le reste</span>
              </label>
              {/* Sur Windows, rien n'est encore fermé : apps et sites restent
                  ouverts. Le choix est retenu pour quand le blocage natif
                  existera — le reste de l'écran reste honnête là-dessus. */}
              <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>
                Sur Windows, le blocage des apps et des sites n'est pas encore disponible — le choix est retenu pour quand il le sera.
              </span>
            </div>
          </Field>
        </div>

        <footer style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 8 }}>
          <PaperButton onClick={onCancel}>Annuler</PaperButton>
          <div style={{ flex: 1 }} />
          <span style={{ fontSize: 14, color: "var(--ink-secondary)" }}>{endLabel(minutes, openEnded, timer.now)}</span>
          <InkButton onClick={begin}>
            <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
              <Glyph name="lock.fill" />
              {running ? "Verrouiller la session" : "Commencer"}
            </span>
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

const selectStyle = {
  appearance: "none",
  WebkitAppearance: "none",
  background: "transparent",
  border: "none",
  outline: "none",
  font: "inherit",
  fontSize: 13,
  fontWeight: 500,
  color: "inherit",
  padding: "6px 26px 6px 12px",
  cursor: "pointer",
  maxWidth: 260,
} as const;

/** Une pastille qui ouvre un menu (la forme des menus du Mac, PillLabel). */
function Pill({ children }: { children: ReactNode }) {
  return (
    <span style={{
      position: "relative", display: "inline-flex", alignItems: "center", color: "var(--ink)",
      background: "var(--sheet-raised)", borderRadius: 999,
    }}>
      {children}
      <span aria-hidden style={{
        position: "absolute", right: 10, top: "50%", transform: "translateY(-50%)",
        fontSize: 9, color: "var(--ink-tertiary)", pointerEvents: "none",
      }}>▾</span>
    </span>
  );
}

function DurationChip({ title, glyph, selected, titleText, onClick }: {
  title: string;
  glyph?: string;
  selected: boolean;
  titleText?: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      title={titleText ?? title}
      aria-pressed={selected}
      onClick={onClick}
      style={{
        display: "inline-flex", alignItems: "center", gap: 5, borderRadius: 999, height: 36,
        padding: "0 16px", fontSize: 15, fontWeight: selected ? 600 : 400, border: "none",
        background: selected ? "var(--ink)" : "var(--sheet-raised)",
        color: selected ? "var(--ground)" : "var(--ink)",
      }}
    >
      {glyph && <Glyph name={glyph} />}
      {title}
    </button>
  );
}

function Stepper({ onClick, children }: { onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{
        width: 28, height: 28, borderRadius: 8, border: "1px solid var(--rule)",
        background: "var(--sheet-raised)", color: "var(--ink)", fontSize: 15, lineHeight: 1,
      }}
    >
      {children}
    </button>
  );
}
