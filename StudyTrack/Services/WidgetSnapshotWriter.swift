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
        let snapshot = WidgetSnapshot(
            updatedAt: Date(),
            weekSeconds: weekSeconds,
            // Champs gardés pour que l'instantané reste lisible par un widget
            // d'une version précédente ; la gamification n'existe plus.
            streak: 0,
            level: 0,
            xp: 0,
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
            nextExamDate: nextExam?.date,
            next: NextActionEngine.actions(for: tracked, limit: 1).first.map(widgetAction),
            courses: tracked.map(widgetCourse),
            timer: widgetTimer(FocusTimerStore.load(), courses: courses))

        WidgetBridge.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        // Le contrôle « Pause du chrono » lit le même instantané.
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
    }

    /// Rafraîchissement **groupé** : plusieurs enregistrements rapprochés (cocher
    /// trois questions de suite) ne rechargent les widgets qu'une fois.
    private static var pending: Task<Void, Never>?

    static func scheduleRefresh(context: ModelContext, settings: SettingsStore) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            refresh(context: context, settings: settings)
        }
    }

    private static func widgetAction(_ action: NextAction) -> WidgetAction {
        let kind: String?
        switch action.reason {
        case .exam: kind = nil
        case .planned(let planned) where planned == .video: kind = "theory"
        case .planned(let planned) where planned == .correction: kind = nil
        default: kind = "exercise"
        }
        return WidgetAction(targetKind: action.targetID == nil ? nil : kind,
                            targetID: action.targetID?.uuidString,
                            courseID: action.courseID.uuidString,
                            courseCode: action.courseCode,
                            title: MathMarkup.plain(action.title),
                            detail: MathMarkup.plain(action.detail),
                            reason: action.reasonLabel,
                            colorHex: action.colorHex,
                            taskType: action.taskType.rawValue,
                            icon: action.icon)
    }

    private static func widgetCourse(_ course: Course) -> WidgetCourse {
        let week = ProgressEngine.weekProgress(for: course, week: course.currentWeek)
        let total = week.videoCount + week.exerciseCount
        let done = week.watchedCount + week.doneCount
        let theory = week.videoCount - week.watchedCount
        let exercises = week.exerciseCount - week.doneCount
        var parts: [String] = []
        if theory > 0 { parts.append("\(theory) théorie") }
        if exercises > 0 { parts.append("\(exercises) exo\(exercises > 1 ? "s" : "")") }
        let summary = total == 0 ? "rien de prévu" : (parts.isEmpty ? "à jour" : "reste " + parts.joined(separator: " · "))
        return WidgetCourse(id: course.id.uuidString, code: course.displayCode, colorHex: course.colorHex,
                            done: done, total: total, summary: summary)
    }

    private static func widgetTimer(_ state: FocusTimerState?, courses: [Course]) -> WidgetTimer? {
        guard let state, state.isRunning || state.isRestorable() else { return nil }
        let course = courses.first { $0.id == state.courseID }
        let label = state.contextLabel.isEmpty
            ? [course?.displayCode ?? "Session libre", state.taskType.label].joined(separator: " · ")
            : state.contextLabel
        let elapsed = state.elapsed()
        return WidgetTimer(label: label, colorHex: course?.colorHex ?? "#5247E6",
                           effectiveStart: Date().addingTimeInterval(-elapsed),
                           isRunning: state.isRunning, elapsedWhenPaused: elapsed,
                           breakEndsAt: state.currentBreak?.endsAt,
                           breakLabel: state.currentBreak?.kind.label)
    }

    /// Applique les coches faites dans un widget pendant que l'app dormait.
    static func applyPendingCompletions(context: ModelContext) -> Int {
        var applied = 0
        for (kind, raw) in PendingWidgetActions.take() {
            guard let id = UUID(uuidString: raw) else { continue }
            switch kind {
            case "exercise":
                let descriptor = FetchDescriptor<Exercise>(predicate: #Predicate { $0.id == id })
                if let exercise = try? context.fetch(descriptor).first, !exercise.isDone {
                    if exercise.hasSubQuestions { exercise.setSubQuestions(done: true) } else { exercise.doneAt = Date() }
                    if exercise.confidence == nil { exercise.confidence = .medium }
                    if exercise.redoRequired { exercise.redoRequired = false }
                    applied += 1
                }
            case "theory":
                let descriptor = FetchDescriptor<TheoryItem>(predicate: #Predicate { $0.id == id })
                if let item = try? context.fetch(descriptor).first, item.watchedAt == nil {
                    item.watchedAt = Date()
                    applied += 1
                }
            default:
                continue
            }
        }
        if applied > 0 { try? context.save() }
        return applied
    }
}
