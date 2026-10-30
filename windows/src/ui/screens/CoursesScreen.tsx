// « Mes cours » (StudyTrack/Views/Courses/CoursesView.swift) : le plan du
// semestre, groupé par semestre, une carte par cours avec son avancement.
//
// Sur Mac, le volet de détail ouvre `MacCourseView` ; ici `onOpenCourse` fait le
// même travail. Le suivi (archiver / réactiver) et l'ajout d'un cours passent par
// `save()` — jamais par le magasin directement.

import { useState } from "react";
import { useData } from "../../data/dataContext.tsx";
import { AcademicTerm, Course } from "../../models/index.ts";
import { PageHeader, Section, Card } from "../kit.tsx";
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
    <button onClick={() => setShowAdd((value) => !value)} style={{
      border: "1px solid var(--rule)", background: "var(--sheet-raised)",
      borderRadius: 10, padding: "7px 12px", fontSize: 13, color: "var(--ink)",
    }}>+ Ajouter un cours</button>
  );

  return (
    <>
      <PageHeader title="Cours" subtitle={subtitleParts.join(" · ")} actions={headerActions} />

      {showAdd && (
        <div style={{ marginBottom: 24 }}>
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
          <div className="serif" style={{ fontSize: 20 }}>Aucun cours</div>
          <div style={{ color: "var(--ink-secondary)", margin: "6px 0 12px" }}>
            Depuis Moodle ou ton horaire IS-Academia — ou à la main.
          </div>
          <button onClick={() => setShowAdd(true)} style={{
            border: "none", background: "var(--ink)", color: "var(--ground)",
            borderRadius: 10, padding: "8px 14px", fontSize: 13,
          }}>Ajouter un cours</button>
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
            <div style={{ fontSize: 12, color: "var(--ink-secondary)", marginBottom: 10 }}>
              {status} · {groupTracked.length} {groupTracked.length === 1 ? "cours suivi" : "cours suivis"}
              {groupCredits > 0 ? ` · ${groupCredits} ECTS` : ""}
            </div>

            {groupTracked.length === 0 ? (
              <Card>
                <span style={{ color: "var(--ink-secondary)", fontSize: 13 }}>
                  Aucun cours suivi dans ce semestre.
                </span>
              </Card>
            ) : (
              <div style={{
                display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))", gap: 12,
              }}>
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
              <div style={{ marginTop: 16 }}>
                <div style={{
                  fontSize: 11, textTransform: "uppercase", letterSpacing: 0.6,
                  color: "var(--ink-tertiary)", marginBottom: 6,
                }}>Archivés · {groupArchived.length}</div>
                <Card>
                  {groupArchived.map((course, index) => (
                    <div key={course.id} style={{
                      borderTop: index === 0 ? "none" : "1px solid var(--rule)", padding: "0 4px",
                    }}>
                      <ArchivedCourseRow course={course} onOpen={onOpenCourse} onToggle={toggleTracked} />
                    </div>
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
