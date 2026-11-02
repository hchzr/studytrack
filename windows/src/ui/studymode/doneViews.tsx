// La fin d'une session : « C'est fait. », et — quand un cours a été suivi —
// l'enchaînement sur la série (StudyDoneView, LectureDoneView + LectureAfterClass).

import type { Course } from "../../models/course.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { elapsed } from "../../domain/focusTimerState.ts";
import { FocusTargets } from "../../domain/focusTargets.ts";
import type { StudyTimerApi } from "./useStudyTimer.ts";
import { timerController } from "../timerController.ts";
import { Icon } from "../kit.tsx";
import { Glyph, InkButton, PaperButton } from "./parts.tsx";
/** La fin d'un mode étude : prolonger, continuer sans le plein écran, terminer. */
export function StudyDoneView({ timer }: { timer: StudyTimerApi }) {
  const state = timer.state;
  const work = state ? Math.trunc(elapsed(state, timer.now)) : 0;
  return (
    <div style={{
      position: "absolute", inset: 0, display: "flex", flexDirection: "column",
      alignItems: "center", justifyContent: "center", gap: 22, padding: 60, textAlign: "center",
    }}>
      <span aria-hidden style={{
        display: "grid", placeItems: "center", width: 56, height: 56, borderRadius: "50%",
        border: "1.5px solid var(--correct)", color: "var(--correct)",
      }}><Icon name="checkmark" size={28} strokeWidth={1.5} /></span>
      <h1 className="serif" style={{ fontSize: 60, margin: 0, color: "var(--ink)" }}>C'est fait.</h1>
      <p style={{ margin: 0, fontSize: 20, color: "var(--ink-secondary)" }}>
        {DateUtils.durationLabel(work)} de travail.
      </p>
      <div style={{ display: "flex", gap: 12, marginTop: 8, flexWrap: "wrap", justifyContent: "center" }}>
        <PaperButton large onClick={() => timerController.leaveStudy()}>Continuer sans</PaperButton>
        <PaperButton large onClick={() => timerController.extendStudy(25)}>
          <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
            <Glyph name="plus" /> Encore 25 min
          </span>
        </PaperButton>
        <InkButton large onClick={() => { void timerController.finish(); }}>
          <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
            <Glyph name="checkmark" /> Terminer
          </span>
        </InkButton>
      </div>
    </div>
  );
}

/**
 * La fin d'un cours suivi : enchaîner sur la série, prolonger, terminer
 * (LectureAfterClass). Les repères posés pendant le cours (LectureMarkStore)
 * ne sont pas portés : la ligne qui les annonce n'apparaît jamais.
 */
export function LectureDoneView({ course, onOpenExercise }: {
  course: Course | null;
  onOpenExercise: () => void;
}) {
  const hasSeries = course?.sortedSeries.some((series) => !series.isComplete && series.exercises.length > 0) === true;
  const startSeries = () => {
    if (!course) return;
    const next = FocusTargets.exercises(course.series, "exercise").upNext[0];
    timerController.retarget(course.id, "exercise", next?.id);
    timerController.extendStudy(50);
    onOpenExercise();
  };
  return (
    <div style={{
      position: "absolute", inset: 0, display: "flex", flexDirection: "column",
      alignItems: "center", justifyContent: "center", gap: 20, padding: 60, textAlign: "center",
    }}>
      <span aria-hidden style={{
        display: "grid", placeItems: "center", width: 56, height: 56, borderRadius: "50%",
        border: "1.5px solid var(--correct)", color: "var(--correct)",
      }}><Icon name="checkmark" size={28} strokeWidth={1.5} /></span>
      <h1 className="serif" style={{ fontSize: 56, margin: 0, color: "var(--ink)" }}>Le cours est fini.</h1>
      <div style={{ display: "flex", flexDirection: "column", gap: 10, marginTop: 4, alignItems: "center" }}>
        {hasSeries && (
          <InkButton large onClick={startSeries}>
            <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
              <Glyph name="doc.text" /> Enchaîner sur la série
            </span>
          </InkButton>
        )}
        <div style={{ display: "flex", gap: 10 }}>
          <PaperButton large onClick={() => timerController.extendStudy(25)}>
            <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
              <Glyph name="plus" /> Encore 25 min
            </span>
          </PaperButton>
          <PaperButton large onClick={() => { void timerController.finish(); }}>
            <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
              <Glyph name="checkmark" /> Terminer
            </span>
          </PaperButton>
        </div>
      </div>
    </div>
  );
}
