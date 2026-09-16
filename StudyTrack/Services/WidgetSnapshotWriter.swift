import Foundation
import SwiftData
import WidgetKit

/// Publie l'état de l'app dans le conteneur partagé et recharge les widgets.
///
/// Appelé quand l'app passe au premier plan ou à l'arrière-plan, et après
/// l'enregistrement d'une session.
@MainActor
enum WidgetSnapshotWriter {

    static func refresh(context: ModelContext, settings: SettingsStore) {
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<StudySession>())) ?? []
        let exams = (try? context.fetch(FetchDescriptor<Exam>())) ?? []

        let tracked = courses.filter(\.isTracked)
        let weekStart = DateUtils.dateRange(days: 7).start
        let weekSeconds = sessions
            .filter { $0.startedAt >= weekStart }
            .reduce(0) { $0 + $1.durationSeconds }

        let allTodos = DailyPlanner.todos(for: tracked, limit: 100)
        let nextExam = exams
            .filter { $0.date >= DateUtils.startOfDay(Date()) }
            .min { $0.date < $1.date }
        let xp = GamificationEngine.totalXP(courses: courses, sessions: sessions)

        let snapshot = WidgetSnapshot(
            updatedAt: Date(),
            weekSeconds: weekSeconds,
            streak: GamificationEngine.currentStreak(sessions: sessions),
            level: GamificationEngine.level(forXP: xp),
            xp: xp,
            todoCount: allTodos.count,
            todos: allTodos.prefix(5).map {
                WidgetTodo(id: $0.id,
                           courseCode: $0.courseCode,
                           title: "\($0.title) · \($0.detail)",
                           kind: $0.kind.label,
                           colorHex: $0.colorHex)
            },
            nextExamTitle: nextExam?.title,
            nextExamCourse: nextExam?.course?.code,
            nextExamDate: nextExam?.date)

        WidgetBridge.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
