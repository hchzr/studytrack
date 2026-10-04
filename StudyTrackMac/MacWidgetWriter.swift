import Foundation
import SwiftData
import WidgetKit

/// Écrit ce que les widgets du bureau affichent, et ne les recharge que si
/// quelque chose a changé (WidgetKit limite les rechargements).
@MainActor
enum MacWidgetWriter {
    private static var pending: Task<Void, Never>?

    /// Regroupe les écritures rapprochées (une coche, puis une autre).
    static func schedule(container: ModelContainer, timer: MacTimer) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            write(container: container, timer: timer)
        }
    }

    static func write(container: ModelContainer, timer: MacTimer) {
        let context = ModelContext(container)
        let courses = ((try? context.fetch(FetchDescriptor<Course>(sortBy: [SortDescriptor(\.code)]))) ?? []).filter(\.isTracked)
        let weekStart = DateUtils.startOfWeek(Date())
        let sessions = (try? context.fetch(FetchDescriptor<StudySession>(predicate: #Predicate { $0.startedAt >= weekStart }))) ?? []
        let today = sessions.filter { Calendar.current.isDateInToday($0.startedAt) }

        var widgetTimer: MacWidgetSnapshot.Timer?
        if let state = timer.state {
            let course = courses.first { $0.id == state.courseID }
            let target = course?.allExercises.first { $0.id == state.targetID }?.displayNumber
                ?? course?.theoryItems.first { $0.id == state.targetID }.map { "Théorie \($0.number)" }
            widgetTimer = .init(courseCode: course?.displayCode ?? "",
                                colorHex: course?.colorHex ?? "#888888",
                                label: target ?? state.taskType.label,
                                runningSince: state.runningSince,
                                accumulated: state.accumulated,
                                breakEndsAt: state.currentBreak?.endsAt)
        }

        let todos = DailyPlanner.todos(for: courses, limit: 8).map { todo in
            MacWidgetSnapshot.Todo(id: todo.id, title: todo.title,
                                   detail: "\(todo.courseCode) · \(todo.kind.label)",
                                   colorHex: todo.colorHex, icon: todo.icon)
        }
        let weeks = courses.map { course in
            let week = ProgressEngine.weekProgress(for: course, week: course.currentWeek)
            return MacWidgetSnapshot.CourseWeek(id: course.id.uuidString, code: course.displayCode, colorHex: course.colorHex,
                                                done: week.watchedCount + week.doneCount,
                                                total: week.videoCount + week.exerciseCount,
                                                late: ProgressEngine.lateCount(for: course))
        }

        let snapshot = MacWidgetSnapshot(updatedAt: Date(),
                                         todaySeconds: today.reduce(0) { $0 + $1.durationSeconds },
                                         weekSeconds: sessions.reduce(0) { $0 + $1.durationSeconds },
                                         week: courses.first?.currentWeek ?? 0,
                                         timer: widgetTimer, todos: todos, courses: weeks)
        guard !snapshot.sameContent(as: MacWidgetSnapshot.load()) else { return }
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
