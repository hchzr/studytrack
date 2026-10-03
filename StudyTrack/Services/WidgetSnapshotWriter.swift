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
            timer: widgetTimer(FocusTimerStore.load(), courses: courses),
            week: widgetWeek(tracked: tracked, sessions: sessions, settings: settings),
            schedule: schedule(context: context, exams: exams),
            deadlines: exams
                .filter { $0.date >= Date() }
                .sorted { $0.date < $1.date }
                .prefix(3)
                .map { WidgetDeadline(id: $0.id.uuidString,
                                      title: $0.title.isEmpty ? $0.kind.label : $0.title,
                                      courseCode: $0.course?.displayCode ?? "",
                                      date: $0.date,
                                      colorHex: $0.course?.colorHex ?? "#6B655A") })

        // Rien de visible n'a changé (une note de correction, un titre de
        // session) : pas de rechargement. iOS accorde aux widgets un budget de
        // rechargements, et chacun réveille l'extension.
        if var previous = WidgetBridge.read() {
            previous.updatedAt = snapshot.updatedAt
            if previous == snapshot { return }
        }
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
                            done: done, total: total, summary: summary,
                            name: course.name,
                            theoryDone: week.watchedCount, theoryTotal: week.videoCount,
                            exercisesDone: week.doneCount, exercisesTotal: week.exerciseCount,
                            late: ProgressEngine.lateCount(for: course))
    }

    private static func widgetWeek(tracked: [Course], sessions: [StudySession],
                                   settings: SettingsStore) -> WidgetWeek {
        let start = DateUtils.startOfWeek(Date())
        let end = DateUtils.addDays(7, to: start)
        var days = Array(repeating: 0, count: 7)
        for session in sessions where session.startedAt >= start && session.startedAt < end {
            let index = DateUtils.daysBetween(start, session.startedAt)
            if days.indices.contains(index) { days[index] += session.durationSeconds }
        }
        let workload = WorkloadEngine.aggregateWeekly(courses: tracked, hoursPerCredit: settings.hoursPerCredit,
                                                      from: start, to: end)
        let term = AcademicTerm.resolve(from: tracked.compactMap(\.term))
        return WidgetWeek(weekStart: start,
                          number: term.flatMap { $0.isRunning ? $0.currentWeek : nil },
                          totalWeeks: term?.totalWeeks,
                          actualSeconds: workload.actualSeconds,
                          expectedSeconds: workload.expectedSeconds,
                          days: days)
    }

    /// Aujourd'hui et demain : séances de l'horaire, sessions planifiées,
    /// évaluations.
    private static func schedule(context: ModelContext, exams: [Exam]) -> [WidgetEvent] {
        let start = DateUtils.startOfDay(Date())
        let end = DateUtils.addDays(2, to: start)
        let events = (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? []
        let planned = (try? context.fetch(FetchDescriptor<PlannedSession>())) ?? []
        var items: [WidgetEvent] = []
        // Les événements « toute la journée » (anniversaires, congés) ne sont pas
        // un horaire : ils remplissaient le widget de « 00:00 – 23:59 ».
        for event in events where event.startsAt >= start && event.startsAt < end
            && event.durationSeconds < 20 * 3600 && event.isAcademic {
            items.append(WidgetEvent(id: "event-\(event.id)", start: event.startsAt, end: event.endsAt,
                                     title: event.title,
                                     subtitle: [event.course?.displayCode, event.location.isEmpty ? nil : event.location]
                                        .compactMap { $0 }.joined(separator: " · "),
                                     colorHex: event.course?.colorHex ?? "#6B655A"))
        }
        for session in planned where session.startsAt >= start && session.startsAt < end {
            items.append(WidgetEvent(id: "planned-\(session.id)", start: session.startsAt, end: session.endsAt,
                                     title: session.title,
                                     subtitle: [session.course?.displayCode, session.location.isEmpty ? nil : session.location]
                                        .compactMap { $0 }.joined(separator: " · "),
                                     colorHex: session.course?.colorHex ?? "#6B655A"))
        }
        for exam in exams where exam.date >= start && exam.date < end {
            items.append(WidgetEvent(id: "exam-\(exam.id)", start: exam.date, end: nil,
                                     title: exam.title.isEmpty ? exam.kind.label : exam.title,
                                     subtitle: [exam.course?.displayCode, exam.location.isEmpty ? nil : exam.location]
                                        .compactMap { $0 }.joined(separator: " · "),
                                     colorHex: exam.course?.colorHex ?? "#6B655A"))
        }
        return items.sorted { $0.start < $1.start }
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
                    exercise.setDone(true)
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
