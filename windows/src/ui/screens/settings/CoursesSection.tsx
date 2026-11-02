// Les cours du semestre — la liste de `SchoolSetupView` avec ses deux
// interrupteurs (suivi / heures d'amphi), plus le formulaire de création et de
// modification. L'import d'horaire (.ics) demanderait le pipeline d'import du
// Mac : il n'est pas branché côté Windows.

import { useMemo, useState } from "react";
import { useData } from "../../../data/dataContext.tsx";
import { AcademicTerm, Course } from "../../../models/index.ts";
import { Badge, Button, Section, Card, Switch } from "../../kit.tsx";
import { Stat } from "./controls.tsx";
import { CourseForm } from "./CourseForm.tsx";
import { readSectionCode } from "./preferences.ts";

export function CoursesSection() {
  const { store, save, version } = useData();
  const [adding, setAdding] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);

  const courses = useMemo(
    () => (store ? [...store.fetch(Course)].sort((a, b) => a.code.localeCompare(b.code)) : []),
    [store, version],
  );
  const terms = useMemo(
    () => (store ? AcademicTerm.sorted(store.fetch(AcademicTerm)) : []),
    [store, version],
  );

  const tracked = courses.filter((course) => course.isTracked);
  const lectureCourses = courses.filter((course) => course.hasLectures);
  const editing = editingId === null ? null : courses.find((course) => course.id === editingId) ?? null;
  const formOpen = adding || editing !== null;

  const setTracked = async (course: Course, value: boolean) => {
    course.isTracked = value;
    await save(course);
  };

  const setHasLectures = async (course: Course, value: boolean) => {
    course.hasLectures = value;
    await save(course);
  };

  const closeForm = () => {
    setAdding(false);
    setEditingId(null);
  };

  return (
    <Section title={`Cours (${tracked.length} suivis)`}>
      <Card>
        <div className="settings-stats">
          <Stat value={tracked.length} label="cours suivis" />
          <Stat value={lectureCourses.length} label="avec amphi" />
        </div>

        {courses.length === 0 ? (
          <p className="settings-empty">Aucun cours pour l'instant.</p>
        ) : (
          <div className="settings-courses">
            {courses.map((course) => (
              <div key={course.id} className="settings-course-row">
                <span className="settings-course-color" aria-hidden="true"
                  style={{ background: course.colorHex }} />
                <div className="settings-course-main">
                  <span className="settings-course-code mono">{course.displayCode}</span>
                  <span className="settings-course-name">{course.name}</span>
                  {!course.isTracked && <Badge>archivé</Badge>}
                </div>
                <div className="settings-course-actions">
                  <Switch checked={course.isTracked} label="Suivi"
                    ariaLabel={`Suivre ${course.code}`}
                    onChange={(value) => void setTracked(course, value)} />
                  <Switch checked={course.hasLectures} label="Amphi"
                    ariaLabel={`${course.code} a des heures de cours`}
                    onChange={(value) => void setHasLectures(course, value)} />
                  <Button size="sm" icon="pencil"
                    onClick={() => { setAdding(false); setEditingId(course.id); }}>
                    Modifier
                  </Button>
                </div>
              </div>
            ))}
          </div>
        )}

        <div className="settings-course-footer">
          <p className="settings-hint">
            « Suivi » compte le cours ce semestre ; « Amphi » lui donne des heures de cours.
          </p>
          <Button variant="primary" icon="plus"
            onClick={() => { setEditingId(null); setAdding(true); }}>
            Ajouter un cours
          </Button>
        </div>

        {formOpen && (
          <CourseForm
            key={editing?.id ?? "new"}
            course={editing}
            terms={terms}
            defaultSectionCode={readSectionCode()}
            onClose={closeForm}
          />
        )}
      </Card>
    </Section>
  );
}
