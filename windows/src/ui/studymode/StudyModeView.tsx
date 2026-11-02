// L'écran plein du mode étude (StudyModeView + StudyModeController.Screen) :
// le choix avant de commencer, la session, puis « c'est fait ». Toujours
// sombre — le papier de nuit est posé en variables CSS sur la racine, pour
// que tout ce qui est dedans le lise, l'app fût-elle claire.

import { useEffect, useMemo, useState } from "react";
import { Course } from "../../models/index.ts";
import { useData } from "../../data/dataContext.tsx";
import { timerController } from "../timerController.ts";
import { StudySetup, type SetupScreen } from "./StudySetup.tsx";
import { StudyWorkspace } from "./StudyWorkspace.tsx";
import { LectureDoneView, StudyDoneView } from "./doneViews.tsx";
import "./studymode.css";
import { StudyBackground, tintOfCourse } from "./parts.tsx";
import { readStudyLocks, studyPalette, writeStudyLocks } from "./studyPalette.ts";
import { useStudyTimer } from "./useStudyTimer.ts";
import type { StudyPane } from "./paneKind.ts";

type Stage = "setup" | "session";

/**
 * `initialCourseID` : le cours choisi d'office (le `presentSetup(courseID:)` du
 * Mac, depuis le menu d'un cours) ; sinon celui du chrono.
 */
export function StudyModeView({ onExit, initialCourseID }: { onExit?: () => void; initialCourseID?: string }) {
  const { store, version, save } = useData();
  const timer = useStudyTimer();

  // Les cours suivis, par code (comme la requête du Mac).
  const courses = useMemo(
    () => (store
      ? store.fetch(Course).filter((course) => course.isTracked).sort((a, b) => a.code.localeCompare(b.code))
      : []),
    [store, version],
  );

  // Ce que montre l'écran : le choix avant de commencer, ou la session
  // (StudyModeController.Screen). Lancé ailleurs — l'écran s'ouvre ici aussi.
  const [stage, setStage] = useState<Stage>(() =>
    timerController.isStudying || timerController.studyIsOver ? "session" : "setup");
  const [screen, setScreen] = useState<SetupScreen>(() => ({
    courseID: initialCourseID ?? timer.courseID,
    taskType: timer.taskType,
    targetID: initialCourseID && initialCourseID !== timer.courseID ? undefined : timer.targetID,
    locks: readStudyLocks(),
  }));
  /** Le panneau que le prochain bureau ouvrira (enchaîner sur la série). */
  const [nextPane, setNextPane] = useState<StudyPane>("desk");

  // À chaque changement du chrono : la session s'impose ; sortie du mode étude,
  // l'écran se ferme (update() du contrôleur du Mac).
  useEffect(() => {
    if (timer.isStudying || timer.studyIsOver) {
      if (stage !== "session") setStage("session");
    } else if (stage === "session") {
      if (onExit) onExit();
      else setStage("setup");
    }
  });

  const patchScreen = (patch: Partial<SetupScreen>) => {
    if (patch.locks !== undefined) writeStudyLocks(patch.locks);
    setScreen((current) => ({ ...current, ...patch }));
  };

  // Lancer : le chrono démarre (ou se verrouille), l'écran bascule. Le choix
  // « Libre » sur une session ouverte garde le contexte courant, comme le Mac
  // (begin → enterStudy, `nil` résolu par le chrono).
  const begin = (minutes: number | null, pomodoro: boolean) => {
    timerController.enterStudy(minutes, {
      courseID: screen.courseID ?? timer.courseID,
      taskType: screen.taskType,
      targetID: screen.targetID ?? (screen.courseID === undefined ? timer.targetID : undefined),
      pomodoro,
      locks: screen.locks,
    });
    setNextPane("desk");
    setStage("session");
  };

  const course = courses.find((item) => item.id === (stage === "setup" ? screen.courseID : timer.courseID)) ?? null;
  const tint = tintOfCourse(course);
  const lectureFollowed = timer.taskType === "lecture";

  return (
    <div className="study-root" style={{
      position: "fixed", inset: 0, zIndex: 100, ...studyPalette,
      background: "var(--ground)", color: "var(--ink)", overflow: "hidden",
    }}>
      <StudyBackground tint={tint} />
      <div style={{ position: "absolute", inset: 0 }}>
        {stage === "setup" && (
          <StudySetup
            screen={screen}
            onScreen={patchScreen}
            courses={courses}
            timer={timer}
            onBegin={begin}
            onCancel={() => { if (onExit) onExit(); }}
          />
        )}
        {stage === "session" && (
          timer.studyIsOver && lectureFollowed ? (
            <LectureDoneView
              course={courses.find((item) => item.id === timer.courseID) ?? null}
              onOpenExercise={() => setNextPane("exercise")}
            />
          ) : timer.studyIsOver ? (
            <StudyDoneView timer={timer} />
          ) : timer.phase.type === "idle" ? (
            // La session a été terminée ailleurs : l'écran va se fermer.
            <div style={{ position: "absolute", inset: 0, display: "grid", placeItems: "center" }}>
              <span aria-hidden style={{
                width: 28, height: 28, borderRadius: "50%", border: "3px solid var(--rule)",
                borderTopColor: "var(--ink)", animation: "study-spin 0.8s linear infinite",
              }} />
            </div>
          ) : (
            <StudyWorkspace courses={courses} timer={timer} save={save} initialPane={nextPane} />
          )
        )}
      </div>
    </div>
  );
}
