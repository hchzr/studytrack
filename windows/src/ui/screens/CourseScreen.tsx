// Un cours, sa théorie, ses séries, sa progression et ses examens.
// Porte Views/Courses/CourseDetailView.swift (Mac : MacCourseView.swift) en
// cinq volets ; les sous-parties vivent dans `./course/`.
//
// Hors du Mac : Progression et Examens (vues de l'iPhone) sont gardés, et les
// notes du cours (CourseNotesView) ont leur volet. Non portés : l'import d'une
// série depuis un PDF (service de lecture de PDF) et le glisser-déposer qui s'y
// rattache.

import { useMemo, useState, type CSSProperties } from "react";
import type { Course } from "../../models/index.ts";
import type { ExerciseSeries } from "../../models/exercise.ts";
import type { TheoryItem } from "../../models/theoryItem.ts";
import type { Exam } from "../../models/exam.ts";
import type { PastExam } from "../../models/pastExam.ts";
import { useData } from "../../data/dataContext.tsx";
import { ProgressEngine } from "../../domain/progressEngine.ts";
import { Button, Segmented, Select, useContextMenu } from "../kit.tsx";
import { timerController } from "../timerController.ts";
import { fmtNumber, hostOf, openURL, siteName, webURL, ProgressRing, type CourseActions } from "./course/common.tsx";
import { TheoryTab } from "./course/TheoryTab.tsx";
import { ExercisesTab } from "./course/ExercisesTab.tsx";
import { ProgressTab } from "./course/ProgressTab.tsx";
import { ExamsTab } from "./course/ExamsTab.tsx";
import { NotesTab } from "./course/NotesTab.tsx";
import { CourseDialog, ExamDialog, PastExamDialog, SeriesDialog, TheoryDialog } from "./course/Dialogs.tsx";
import "./course/course.css";

type CourseTab = "theory" | "exercises" | "progress" | "exams" | "notes";
const TABS: CourseTab[] = ["theory", "exercises", "progress", "exams", "notes"];

/** Ce qui est en cours d'édition dans une boîte de dialogue. */
type Editor =
  | { kind: "course" }
  | { kind: "series"; series: ExerciseSeries | null }
  | { kind: "theory"; item: TheoryItem | null }
  | { kind: "exam"; exam: Exam | null }
  | { kind: "pastExam"; exam: PastExam };

/** `?tab=` : le volet d'ouverture (captures et essais), sinon les exercices. */
function initialTab(): CourseTab {
  const raw = new URLSearchParams(window.location.search).get("tab");
  return (TABS as string[]).includes(raw ?? "") ? (raw as CourseTab) : "exercises";
}

/**
 * `focusTarget` : l'exercice ou l'élément de théorie à montrer à l'ouverture
 * (un résultat de recherche, un lien d'un autre écran) — le `focusTarget` du Mac.
 */
export function CourseScreen({ course, focusTarget }: { course: Course; focusTarget?: string | null }) {
  const { save, remove } = useData();
  const [tab, setTab] = useState<CourseTab>(() =>
    focusTarget && course.theoryItems.some((item) => item.id === focusTarget) ? "theory"
      : focusTarget && course.allExercises.some((e) => e.id === focusTarget) ? "exercises"
      : initialTab());
  const [week, setWeek] = useState(0);
  const [editor, setEditor] = useState<Editor | null>(null);
  const menu = useContextMenu();

  const persistAll = async (objects: object[]) => {
    try {
      for (const object of [...new Set(objects)]) await save(object);
    } catch (error) {
      console.error("Enregistrement impossible", error);
    }
  };
  const removeOne = async (object: object) => {
    try { await remove(object); } catch (error) { console.error("Suppression impossible", error); }
  };

  const actions: CourseActions = {
    editSeries: (series) => setEditor({ kind: "series", series }),
    editTheory: (item) => setEditor({ kind: "theory", item }),
    editExam: (exam) => setEditor({ kind: "exam", exam }),
    editPastExam: (exam) => { if (exam) setEditor({ kind: "pastExam", exam }); },
    // Démarre — ou, si une session tourne, bascule dessus sans la couper.
    time: (targetID, type) => {
      timerController.retarget(course.id, type, targetID);
      if (timerController.phase().type === "idle") timerController.start();
    },
  };

  const progress = ProgressEngine.progress(course);
  const late = ProgressEngine.lateCount(course);
  const ahead = ProgressEngine.aheadCount(course);
  const standing = ProgressEngine.standingLabel(late, ahead);
  const percent = Math.round(progress.completion * 100);
  const weeks = useMemo(() => [...new Set([
    ...course.theoryItems.map((item) => item.plannedWeek),
    ...course.series.map((entry) => entry.plannedWeek),
  ])].filter((value) => value > 0).sort((a, b) => a - b),
  // eslint-disable-next-line react-hooks/exhaustive-deps
  [course.theoryItems.length, course.series.length, course.theoryItems.map((i) => i.plannedWeek).join(), course.series.map((s) => s.plannedWeek).join()]);

  const examCount = course.exams.length + course.pastExams.length;
  const tabOptions: { value: CourseTab; label: React.ReactNode }[] = [
    { value: "theory", label: <>Théorie <span className="mono faint small">{progress.watchedCount}/{progress.videoCount}</span></> },
    { value: "exercises", label: <>Exercices <span className="mono faint small">{progress.doneCount}/{progress.exerciseCount}</span></> },
    { value: "progress", label: "Progression" },
    { value: "exams", label: <>Examens{examCount > 0 && <> <span className="mono faint small">{examCount}</span></>}</> },
    { value: "notes", label: "Notes" },
  ];
  const showWeeks = tab === "theory" || tab === "exercises";
  const sites = courseSites(course);

  const addMenu = (event: React.MouseEvent<HTMLButtonElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    menu.openAt(rect.right - 200, rect.bottom + 4, [
      { label: "Nouvelle série…", icon: "plus", action: () => actions.editSeries(null) },
      { label: "Ajouter de la théorie…", icon: "book", action: () => actions.editTheory(null) },
      { label: "Nouvelle évaluation…", icon: "calendar.badge.clock", action: () => actions.editExam(null) },
      "divider",
      { label: "Modifier le cours…", icon: "pencil", action: () => setEditor({ kind: "course" }) },
    ]);
  };

  return (
    <div className="cs" style={{ ["--course" as string]: course.colorHex } as CSSProperties}>
      <header className="cs-head">
        <div className="cs-head-top">
          <div className="cs-head-title">
            <span className="cs-tag">{course.displayCode}</span>
            <h1 className="serif cs-title">{course.name === "" ? course.displayCode : course.name}</h1>
          </div>
          <Button icon="plus" trailingIcon="chevron.down" onClick={addMenu} aria-haspopup="menu"
            title="Ajouter une série, de la théorie, une évaluation">
            Ajouter
          </Button>
        </div>

        {sites.length > 0 && (
          <div className="cs-sites">
            {sites.map((site) => (
              <Button key={site.url} size="sm" icon="link" onClick={() => openURL(site.url)}>{site.title}</Button>
            ))}
          </div>
        )}

        <div className="cs-sub">
          {[
            course.lecturer !== "" ? course.lecturer : null,
            course.term ? course.term.displayName : null,
            metaLine(course),
          ].filter((part): part is string => part !== null).join(" · ")}
        </div>

        <div className="cs-summary">
          <span className="cs-sub">
            {course.currentWeek > 0 && <span>{`Semaine ${course.currentWeek} / ${course.term?.totalWeeks ?? 14}`} ·</span>}
            <span className={late > 0 ? "late" : undefined}>{standing}</span>
          </span>
          <span className="grow" />
          <div className="cs-stat"><b>{progress.watchedCount}/{progress.videoCount}</b><span>Théorie</span></div>
          <div className="cs-stat"><b>{progress.doneCount}/{progress.exerciseCount}</b><span>Exercices</span></div>
          <div className="cs-ring" title={`${percent} %`}>
            <span className="ring"><ProgressRing value={progress.completion} tint={course.colorHex} size={46} lineWidth={5} /></span>
            <b>{percent}</b>
          </div>
        </div>
      </header>

      <div className="cs-toolbar">
        <Segmented value={tab} onChange={setTab} options={tabOptions} ariaLabel="Volets du cours" />
        <span className="spacer" />
        {showWeeks && weeks.length > 0 && (
          <Select
            ariaLabel="Semaine"
            value={String(week)}
            onChange={(value) => setWeek(Number(value))}
            options={[
              { value: "0", label: "Tout le semestre" },
              ...weeks.map((value) => ({
                value: String(value),
                label: course.isTermRunning && value === course.currentWeek ? `Semaine ${value} (en cours)` : `Semaine ${value}`,
              })),
            ]}
          />
        )}
      </div>

      {tab === "theory" && <TheoryTab course={course} week={week} saveAll={persistAll} actions={actions} focusID={focusTarget} />}
      {tab === "exercises" && <ExercisesTab course={course} week={week} saveAll={persistAll} actions={actions} focusID={focusTarget} />}
      {tab === "progress" && <ProgressTab course={course} saveAll={persistAll} />}
      {tab === "exams" && <ExamsTab course={course} saveAll={persistAll} actions={actions} />}
      {tab === "notes" && <NotesTab course={course} saveAll={persistAll} />}

      {menu.element}

      {editor?.kind === "course" && <CourseDialog course={course} save={persistAll} onClose={() => setEditor(null)} />}
      {editor?.kind === "series" && (
        <SeriesDialog course={course} series={editor.series} save={persistAll} remove={removeOne} onClose={() => setEditor(null)} />
      )}
      {editor?.kind === "theory" && (
        <TheoryDialog course={course} item={editor.item} save={persistAll} remove={removeOne} onClose={() => setEditor(null)} />
      )}
      {editor?.kind === "exam" && (
        <ExamDialog course={course} exam={editor.exam} save={persistAll} remove={removeOne} onClose={() => setEditor(null)} />
      )}
      {editor?.kind === "pastExam" && (
        <PastExamDialog exam={editor.exam} save={persistAll} remove={removeOne} onClose={() => setEditor(null)} />
      )}
    </div>
  );
}

/** Les sites du cours (`StudyMode.courseSites`) : Moodle, puis les pages d'import, un par hôte. */
function courseSites(course: Course): { title: string; url: string }[] {
  const result: { title: string; url: string }[] = [];
  const seen = new Set<string>();
  const add = (raw: string) => {
    const url = webURL(raw);
    const host = url ? hostOf(url) : null;
    if (!url || !host) return;
    const title = siteName(host);
    if (seen.has(title)) return;
    seen.add(title);
    result.push({ title, url });
  };
  if (course.moodleLink) add(course.moodleLink.href);
  course.contentSources.forEach(add);
  return result;
}

/** « 6 ECTS · 3 h de cours · 2 h d'exercices » (espaces insécables comme le Swift). */
function metaLine(course: Course): string {
  const parts = [`${fmtNumber(course.credits)} ECTS`];
  parts.push(course.hasLectures
    ? `${fmtNumber(course.weeklyLectureHours)} h de cours · ${fmtNumber(course.weeklyExerciseHours)} h d'exercices`
    : `${fmtNumber(course.weeklyExerciseHours)} h d'exercices, sans amphi`);
  return parts.join(" · ");
}
