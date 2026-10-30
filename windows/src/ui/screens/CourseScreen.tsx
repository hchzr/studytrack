import type { Course } from "../../models/index.ts";
import { PageHeader, Placeholder } from "../kit.tsx";

// À porter depuis Views/Courses/CourseDetailView.swift (Mac : MacCourseView.swift) :
// onglets Théorie / Exercices / Progression / Examens.
export function CourseScreen({ course }: { course: Course }) {
  return (
    <>
      <PageHeader title={course.name} subtitle={course.code} />
      <Placeholder screen="Détail d'un cours" from="Views/Courses/CourseDetailView.swift" />
    </>
  );
}
