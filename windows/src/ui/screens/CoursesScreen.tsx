import { useData } from "../../data/dataContext.tsx";
import { Course } from "../../models/index.ts";
import { PageHeader, Card } from "../kit.tsx";

// À enrichir en portant Views/Courses/CoursesView.swift (Mac : MacCourseView.swift).
export function CoursesScreen({ onOpenCourse }: { onOpenCourse: (id: string) => void }) {
  const { store } = useData();
  const courses = store!.fetch(Course).sort((a, b) => a.code.localeCompare(b.code));
  return (
    <>
      <PageHeader title="Cours" subtitle={`${courses.length} cours`} />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(240px, 1fr))", gap: 12 }}>
        {courses.map((c) => (
          <button key={c.id} onClick={() => onOpenCourse(c.id)} style={{ textAlign: "left", border: "none", padding: 0, background: "none" }}>
            <Card accent={c.colorHex}>
              <div className="serif" style={{ fontSize: 18 }}>{c.name}</div>
              <div style={{ color: "var(--ink-secondary)", fontSize: 13, marginTop: 4 }}>{c.code}</div>
            </Card>
          </button>
        ))}
      </div>
    </>
  );
}
