// « Mes cours » (StudyTrack/Views/Courses/CoursesView.swift) : le plan du
// semestre, groupé par semestre, une carte par cours avec son avancement.
//
// Sur Mac, le volet de détail ouvre `MacCourseView` ; ici `onOpenCourse` fait le
// même travail. Le suivi (archiver / réactiver) et l'ajout d'un cours passent par
// `save()` — jamais par le magasin directement.

import { useState } from "react";
import { useData } from "../../data/dataContext.tsx";
import { AcademicTerm, Course } from "../../models/index.ts";
import { PageHeader, Section, Card, Button, EmptyState } from "../kit.tsx";
import "./home/today.css";
import { AddCourseForm, ArchivedCourseRow, CourseCard } from "./home/courseCards.tsx";

interface CourseGroup {
  term: AcademicTerm | null;
  courses: Course[];
}

function termStatus(term: AcademicTerm): string {
  if (term.hasEnded) return "semestre terminé";
  if (term.hasNotStarted) return "semestre à venir";
  return `semaine ${term.currentWeek} sur ${term.totalWeeks}`;
}

export function CoursesScreen({ onOpenCourse }: { onOpenCourse: (id: string) => void }) {
  const { store, save } = useData();
  const [showAdd, setShowAdd] = useState(false);
  const now = new Date();
  if (!store) return null;

  const courses = store.fetch(Course).sort((a, b) => a.code.localeCompare(b.code));
  const terms = store.fetch(AcademicTerm).sort((a, b) => b.startDate.getTime() - a.startDate.getTime());
  const tracked = courses.filter((course) => course.isTracked);
  const credits = tracked.reduce((sum, course) => sum + Math.trunc(course.credits), 0);
  const resolvedTerm = AcademicTerm.resolve(
    courses.flatMap((course) => (course.term ? [course.term] : [])),
    now,
  );
  const defaultTerm = resolvedTerm ?? terms[0] ?? null;

  const subtitleParts = [
    resolvedTerm?.displayName ?? "Semestre",
    ...(resolvedTerm?.isRunning ? [`semaine ${resolvedTerm.currentWeek}`] : []),
    `${tracked.length} cours`,
    `${credits} ECTS`,
  ];

  const groupsByTerm = new Map<string, CourseGroup>();
  for (const course of courses) {
    const key = course.term?.id ?? "none";
    const group = groupsByTerm.get(key) ?? { term: course.term ?? null, courses: [] };
    group.courses.push(course);
    groupsByTerm.set(key, group);
  }
  const groups = [...groupsByTerm.values()].sort((a, b) => {
    if (!a.term) return 1;
    if (!b.term) return -1;
    return b.term.startDate.getTime() - a.term.startDate.getTime();
  });

  const toggleTracked = (course: Course, next: boolean) => {
    course.isTracked = next;
    void save(course);
  };

  const headerActions = (
    <Button icon="plus" aria-expanded={showAdd} onClick={() => setShowAdd((value) => !value)}>
      Ajouter un cours
    </Button>
  );

  return (
    <>
      <PageHeader title="Cours" subtitle={subtitleParts.join(" · ")} actions={headerActions} />

      {showAdd && (
        <div style={{ marginBottom: 28 }}>
          <AddCourseForm
            terms={terms}
            defaultTerm={defaultTerm}
            onCancel={() => setShowAdd(false)}
            onCreate={async (course) => {
              await save(course);
              setShowAdd(false);
            }}
          />
        </div>
      )}

      {courses.length === 0 ? (
        <Card>
          <EmptyState icon="books.vertical" title="Aucun cours"
            action={<Button variant="primary" icon="plus" onClick={() => setShowAdd(true)}>Ajouter un cours</Button>}>
            Depuis Moodle ou ton horaire IS-Academia — ou à la main.
          </EmptyState>
        </Card>
      ) : groups.map((group) => {
        const groupTracked = group.courses
          .filter((course) => course.isTracked)
          .sort((a, b) => a.code.localeCompare(b.code));
        const groupArchived = group.courses
          .filter((course) => !course.isTracked)
          .sort((a, b) => a.code.localeCompare(b.code));
        const groupCredits = groupTracked.reduce((sum, course) => sum + Math.trunc(course.credits), 0);
        const status = group.term ? termStatus(group.term) : "cours sans semestre";
        const label = group.term?.displayName ?? "Sans semestre";
        return (
          <Section key={group.term?.id ?? "none"} title={label}>
            <div className="c-term-meta">
              {status} · {groupTracked.length} {groupTracked.length === 1 ? "cours suivi" : "cours suivis"}
              {groupCredits > 0 ? ` · ${groupCredits} ECTS` : ""}
            </div>

            {groupTracked.length === 0 ? (
              <Card>
                <span className="muted" style={{ fontSize: 13 }}>
                  Aucun cours suivi dans ce semestre.
                </span>
              </Card>
            ) : (
              <div className="c-grid">
                {groupTracked.map((course) => (
                  <CourseCard
                    key={course.id}
                    course={course}
                    onOpen={onOpenCourse}
                    onToggle={toggleTracked}
                  />
                ))}
              </div>
            )}

            {groupArchived.length > 0 && (
              <div className="c-archived">
                <div className="caps" style={{ margin: "0 2px 8px" }}>Archivés · {groupArchived.length}</div>
                <Card className="t-list">
                  {groupArchived.map((course) => (
                    <ArchivedCourseRow key={course.id} course={course} onOpen={onOpenCourse} onToggle={toggleTracked} />
                  ))}
                </Card>
              </div>
            )}
          </Section>
        );
      })}
    </>
  );
}
