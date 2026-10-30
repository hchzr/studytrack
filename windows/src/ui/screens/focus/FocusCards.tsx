// Les cartes autour du cadran : ce qu'on va chronométrer, ce qu'on fait
// maintenant, la répartition de la session, le récapitulatif et l'objectif du
// jour — les mêmes blocs que MacFocusView, adaptés à une fenêtre de bureau.

import { useState, type CSSProperties, type ReactNode } from "react";
import type { Course } from "../../../models/course.ts";
import { TaskType } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { allocation, currentTargetElapsed } from "../../../domain/focusTimerState.ts";
import { TimerText } from "../../../domain/timerText.ts";
import type { FocusRecap, FocusTimerApi } from "./useFocusTimer.ts";
import { headlineOf, targetOptionsFor, tintOf, upNextOf } from "./timerView.ts";

const kickerStyle: CSSProperties = {
  fontSize: 11,
  fontWeight: 600,
  letterSpacing: 1.1,
  textTransform: "uppercase",
  color: "var(--ink-tertiary)",
};

function CardTitle({ children, trailing }: { children: ReactNode; trailing?: ReactNode }) {
  return (
    <div style={{ display: "flex", alignItems: "baseline", gap: 12 }}>
      <div className="serif" style={{ fontSize: 18 }}>{children}</div>
      <div style={{ flex: 1 }} />
      {trailing}
    </div>
  );
}

const selectStyle: CSSProperties = {
  appearance: "none",
  WebkitAppearance: "none",
  background: "transparent",
  border: "none",
  outline: "none",
  font: "inherit",
  fontSize: 13,
  fontWeight: 500,
  color: "var(--ink)",
  padding: "6px 28px 6px 12px",
  cursor: "pointer",
  maxWidth: 240,
};

/** Une pastille qui ouvre un menu : la forme des menus du Mac (`PillLabel`). */
function Pill({ children }: { children: ReactNode }) {
  return (
    <span style={{
      position: "relative", display: "inline-flex", alignItems: "center",
      background: "var(--sheet-raised)", borderRadius: 999, maxWidth: "100%",
    }}>
      {children}
      <span aria-hidden="true" style={{
        position: "absolute", right: 11, top: "50%", transform: "translateY(-50%)",
        fontSize: 9, fontWeight: 700, color: "var(--ink-tertiary)", pointerEvents: "none",
      }}>▾</span>
    </span>
  );
}

function InkButton({ onClick, children }: { onClick: () => void; children: ReactNode }) {
  const [hovering, setHovering] = useState(false);
  return (
    <button type="button" onClick={onClick}
      onMouseEnter={() => setHovering(true)} onMouseLeave={() => setHovering(false)}
      style={{
        border: "none", borderRadius: 999, padding: "7px 16px", fontSize: 13, fontWeight: 600,
        background: "var(--ink)", color: "var(--ground)", filter: hovering ? "brightness(1.15)" : undefined,
      }}>{children}</button>
  );
}

function TextButton({ onClick, children }: { onClick: () => void; children: ReactNode }) {
  const [hovering, setHovering] = useState(false);
  return (
    <button type="button" onClick={onClick}
      onMouseEnter={() => setHovering(true)} onMouseLeave={() => setHovering(false)}
      style={{
        border: "none", background: "none", padding: 0, fontSize: 13,
        color: hovering ? "var(--ink)" : "var(--ink-secondary)",
      }}>{children}</button>
  );
}

/** Une ligne cliquable qui s'éclaire au survol (`hoverRow` du Mac). */
function RowButton({ onClick, children }: { onClick: () => void; children: ReactNode }) {
  const [hovering, setHovering] = useState(false);
  return (
    <button type="button" onClick={onClick}
      onMouseEnter={() => setHovering(true)} onMouseLeave={() => setHovering(false)}
      style={{
        display: "flex", alignItems: "center", gap: 8, width: "100%", textAlign: "left",
        padding: "5px 8px", borderRadius: 8, border: "none", fontSize: 13,
        background: hovering ? "var(--sheet-raised)" : "transparent", color: "var(--ink)",
      }}>{children}</button>
  );
}

function Rule() {
  return <div style={{ height: 1, background: "var(--rule)", margin: "2px 0" }} />;
}

// MARK: - Nouvelle session

/** Au repos : le cours, le travail, la cible, le mode (`TimerSetup`). */
export function FocusSetupCard({ api, courses }: { api: FocusTimerApi; courses: Course[] }) {
  const course = courses.find((entry) => entry.id === api.courseID) ?? null;
  const options = course ? targetOptionsFor(course, api.taskType) : null;
  return (
    <div className="card" style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <CardTitle>Nouvelle session</CardTitle>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
        <Pill>
          <select aria-label="Cours" value={api.courseID ?? ""} style={selectStyle}
            onChange={(event) => api.chooseCourse(event.target.value === "" ? undefined : event.target.value)}>
            <option value="">Sans cours</option>
            {courses.map((entry) => (
              <option key={entry.id} value={entry.id}>{entry.displayCode} · {entry.name}</option>
            ))}
          </select>
        </Pill>
        <Pill>
          <select aria-label="Type de travail" value={api.taskType} style={selectStyle}
            onChange={(event) => api.chooseTaskType(event.target.value as TaskType)}>
            {TaskType.choices.map((choice) => (
              <option key={choice} value={choice}>{TaskType.label(choice)}</option>
            ))}
          </select>
        </Pill>
        {course && options && (
          <Pill>
            <select aria-label="Cible" value={api.targetID ?? ""} style={selectStyle}
              onChange={(event) => api.chooseTarget(event.target.value === "" ? undefined : event.target.value)}>
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
      <label style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, cursor: "pointer" }}>
        <input type="checkbox" checked={api.pomodoro}
          onChange={(event) => api.setPomodoro(event.target.checked)}
          style={{ width: 16, height: 16, accentColor: "var(--ink)" }} />
        <span>Pomodoro · {api.settings.cycle.focusMinutes}/{api.settings.cycle.shortBreakMinutes} min</span>
      </label>
    </div>
  );
}

// MARK: - En session

/** Pendant une session : la cible, son temps, et ce qui vient ensuite. */
export function FocusSessionCard({ api, courses }: { api: FocusTimerApi; courses: Course[] }) {
  const course = courses.find((entry) => entry.id === api.courseID) ?? null;
  const options = course ? targetOptionsFor(course, api.taskType) : null;
  const upNext = course ? upNextOf(course, api.taskType, api.targetID) : [];
  const targetSeconds = api.state ? currentTargetElapsed(api.state, api.now) : 0;

  const chooseTarget = (id: string | undefined) => {
    if (course) api.retarget(course.id, api.taskType, id);
  };

  return (
    <div className="card" style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <CardTitle trailing={course && options ? (
        <Pill>
          <select aria-label="Cible" value={api.targetID ?? ""} style={selectStyle}
            onChange={(event) => chooseTarget(event.target.value === "" ? undefined : event.target.value)}>
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
      ) : undefined}>
        Sur quoi
      </CardTitle>

      {api.targetID && (
        <div style={{ display: "flex", alignItems: "baseline", fontSize: 13, color: "var(--ink-secondary)" }}>
          <span>Sur cet exercice</span>
          <div style={{ flex: 1 }} />
          <span className="mono" style={{ color: "var(--ink)" }}>{TimerText.clock(targetSeconds)}</span>
        </div>
      )}

      <Rule />
      <div style={kickerStyle}>Ensuite</div>
      {course ? (
        upNext.length === 0
          ? <span style={{ fontSize: 13, color: "var(--ink-secondary)" }}>Rien d'autre à faire pour l'instant.</span>
          : (
            <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
              {upNext.map((item) => (
                <RowButton key={item.id} onClick={() => api.retarget(course.id, item.taskType, item.id)}>
                  <span style={{ width: 7, height: 7, borderRadius: 4, background: tintOf(course), flexShrink: 0 }} />
                  <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.title}</span>
                  <div style={{ flex: 1 }} />
                  <span style={{ fontSize: 12, color: "var(--ink-secondary)" }}>Passer</span>
                </RowButton>
              ))}
            </div>
          )
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <span style={{ fontSize: 13, color: "var(--ink-secondary)" }}>Pas de cours choisi.</span>
          <Pill>
            <select aria-label="Choisir un cours" value="" style={selectStyle}
              onChange={(event) => {
                if (event.target.value !== "") api.retarget(event.target.value, api.taskType, undefined);
              }}>
              <option value="">Choisir un cours</option>
              {courses.map((entry) => (
                <option key={entry.id} value={entry.id}>{entry.displayCode}</option>
              ))}
            </select>
          </Pill>
        </div>
      )}
    </div>
  );
}

/** La répartition du temps de la session, cible par cible (`segmentsCard`). */
export function FocusSegmentsCard({ api, courses }: { api: FocusTimerApi; courses: Course[] }) {
  if (!api.state || (api.state.segments?.length ?? 0) === 0) return null;
  const parts = allocation(api.state, api.now);
  if (parts.length <= 1) return null;
  return (
    <div className="card" style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <CardTitle>Cette session</CardTitle>
      {parts.map((part, index) => {
        const partCourse = courses.find((entry) => entry.id === part.courseID) ?? null;
        return (
          <div key={index} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13 }}>
            <span style={{ width: 3, height: 14, borderRadius: 2, background: tintOf(partCourse), flexShrink: 0 }} />
            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {headlineOf(partCourse, TaskType.fromRaw(part.taskTypeRaw) ?? "other", part.targetID)}
            </span>
            <div style={{ flex: 1 }} />
            <span className="mono" style={{ color: "var(--ink-secondary)" }}>{TimerText.clock(part.seconds)}</span>
          </div>
        );
      })}
    </div>
  );
}

// MARK: - Récapitulatif

/** Après « Terminer » : ce qui a été compté, et de quoi annuler un geste de trop. */
export function FocusRecapCard({ recap, courses, onUndo, onDismiss }: {
  recap: FocusRecap;
  courses: Course[];
  onUndo: () => void;
  onDismiss: () => void;
}) {
  return (
    <div className="card" style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
        <span aria-hidden="true" style={{
          display: "inline-grid", placeItems: "center", width: 20, height: 20, borderRadius: "50%",
          border: `1px solid ${recap.discarded ? "var(--ink-secondary)" : "var(--correct)"}`,
          color: recap.discarded ? "var(--ink-secondary)" : "var(--correct)", fontSize: 11,
          transform: "translateY(3px)", flexShrink: 0,
        }}>{recap.discarded ? "✕" : "✓"}</span>
        <div className="serif" style={{ fontSize: 18 }}>
          {recap.discarded ? "Trop court, pas gardé" : "Enregistré"}
        </div>
        <div style={{ flex: 1 }} />
        {!recap.discarded && (
          <span className="serif" style={{ fontSize: 17, fontVariantNumeric: "tabular-nums" }}>
            {DateUtils.durationLabel(recap.totalSeconds)}
          </span>
        )}
      </div>

      {recap.parts.map((part) => {
        const course = courses.find((entry) => entry.id === part.courseID) ?? null;
        return (
          <div key={part.session.id} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13 }}>
            <span style={{ width: 3, height: 16, borderRadius: 2, background: tintOf(course), flexShrink: 0 }} />
            <strong style={{ fontWeight: 600 }}>{course?.displayCode ?? "Libre"}</strong>
            <span style={{ color: "var(--ink-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {headlineOf(course, part.taskType, part.targetID)}
            </span>
            <div style={{ flex: 1 }} />
            <span className="mono" style={{ color: "var(--ink-secondary)" }}>{DateUtils.durationLabel(part.seconds)}</span>
          </div>
        );
      })}

      <div style={{ display: "flex", alignItems: "center", gap: 12, fontSize: 13 }}>
        {!recap.discarded && <TextButton onClick={onUndo}>Annuler</TextButton>}
        <div style={{ flex: 1 }} />
        <InkButton onClick={onDismiss}>OK</InkButton>
      </div>
    </div>
  );
}

// MARK: - Objectif du jour

/** « 2 h 10 / 3 h » et une barre ; la session en cours s'ajoute à la minute. */
export function FocusGoalBar({ seconds, goal }: { seconds: number; goal: number }) {
  const progress = Math.min(1, seconds / Math.max(goal, 1));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 5, padding: "0 4px" }}>
      <div style={{ display: "flex", alignItems: "baseline", fontSize: 12, color: "var(--ink-secondary)" }}>
        <span>Aujourd'hui</span>
        <div style={{ flex: 1 }} />
        <span className="mono" style={{ color: progress >= 1 ? "var(--correct)" : "var(--ink-secondary)" }}>
          {DateUtils.hoursLabel(seconds)} / {DateUtils.hoursLabel(goal)}
        </span>
      </div>
      <div style={{ height: 5, borderRadius: 3, background: "var(--rule)", overflow: "hidden" }}>
        <div style={{
          height: "100%", minWidth: 4, width: `${progress * 100}%`, borderRadius: 3,
          background: progress >= 1 ? "var(--correct)" : "var(--review)",
        }} />
      </div>
    </div>
  );
}

/** La ligne de la session de groupe, quand le chrono vient d'un autre appareil. */
export function TogetherLabel({ name }: { name: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, fontWeight: 600 }}>
      <span aria-hidden="true" style={{ width: 8, height: 8, borderRadius: 4, background: "var(--correct)" }} />
      Session ensemble · {name}
    </div>
  );
}
