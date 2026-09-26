import Foundation

/// « Que faire maintenant ? » — une seule réponse pour toute l'app.
///
/// L'accueil, le démarrage d'un chrono et les widgets proposaient chacun leur
/// idée de la prochaine tâche. Ce moteur les remplace par un classement unique :
///
///   1. une **série à rendre** dans les 48 h qui n'est pas finie ;
///   2. les exercices **à refaire** ;
///   3. une **évaluation** dans les 7 jours : réviser ce cours ;
///   4. puis l'ordre de `DailyPlanner` — théorie de la semaine, exercices, corrections.
///
/// Fonction pure du modèle et d'une date : testable, et la même partout.
struct NextAction: Identifiable, Equatable {
    enum Reason: Equatable {
        case seriesDue(Date)
        case redo
        case exam(Date)
        case planned(StudyTodo.Kind)
    }

    var id: String
    var reason: Reason
    var courseID: UUID
    var courseCode: String
    var colorHex: String
    var title: String
    var detail: String
    var taskType: TaskType
    var targetID: UUID?

    /// Ce que le chrono affichera : « CS-250 · Exercice 3.2 ».
    var focusLabel: String { "\(courseCode) · \(title)" }

    var icon: String {
        switch reason {
        case .seriesDue: return "clock.badge.exclamationmark"
        case .redo: return "arrow.counterclockwise"
        case .exam: return "graduationcap"
        case .planned(let kind):
            switch kind {
            case .redo: return "arrow.counterclockwise"
            case .video: return TaskType.video.icon
            case .exercise: return TaskType.exercise.icon
            case .correction: return TaskType.correction.icon
            }
        }
    }

    /// Une étiquette courte de la raison, pour la ligne sous le titre.
    var reasonLabel: String {
        switch reason {
        case .seriesDue: return "À rendre bientôt"
        case .redo: return "À refaire"
        case .exam: return "Évaluation proche"
        case .planned(let kind): return kind.label
        }
    }
}

enum NextActionEngine {

    static let dueWindow: TimeInterval = 48 * 3600
    static let examWindowDays = 7

    static func actions(for courses: [Course], now: Date = Date(), limit: Int = 8) -> [NextAction] {
        let tracked = courses.filter(\.isTracked)
        var result: [NextAction] = []
        var seen = Set<String>()
        func add(_ action: NextAction) {
            guard seen.insert(action.id).inserted else { return }
            result.append(action)
        }

        // 1. Séries à rendre bientôt, la plus urgente d'abord.
        let dueSeries = tracked.flatMap { course in course.series.map { (course, $0) } }
            .filter { _, series in
                guard let due = series.dueDate else { return false }
                return due > now && due.timeIntervalSince(now) <= dueWindow && !series.isComplete
            }
            .sorted { ($0.1.dueDate ?? now) < ($1.1.dueDate ?? now) }
        for (course, series) in dueSeries {
            guard let due = series.dueDate,
                  let exercise = series.sortedExercises.first(where: { !$0.isDone && !$0.isBonus }) else { continue }
            let remaining = series.requiredExercises.filter { !$0.isDone }.count
            add(NextAction(id: "ex-\(exercise.id)", reason: .seriesDue(due),
                           courseID: course.id, courseCode: course.displayCode, colorHex: course.colorHex,
                           title: exercise.displayNumber,
                           detail: "\(series.title) à rendre \(relativeDay(due, now: now)) · \(remaining) exercice\(remaining > 1 ? "s" : "") restant\(remaining > 1 ? "s" : "")",
                           taskType: .exercise, targetID: exercise.id))
        }

        // 2. À refaire.
        let todos = DailyPlanner.todos(for: tracked, limit: 40)
        for todo in todos where todo.kind == .redo {
            add(action(from: todo, reason: .redo))
        }

        // 3. Évaluation dans la semaine : réviser ce cours.
        let calendar = Calendar.current
        let exams = tracked.flatMap { course in course.exams.map { (course, $0) } }
            .filter { _, exam in
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                   to: calendar.startOfDay(for: exam.date)).day ?? .max
                return exam.date > now && days <= examWindowDays
            }
            .sorted { $0.1.date < $1.1.date }
        for (course, exam) in exams {
            add(NextAction(id: "exam-\(exam.id)", reason: .exam(exam.date),
                           courseID: course.id, courseCode: course.displayCode, colorHex: course.colorHex,
                           title: "Réviser · \(exam.title.isEmpty ? exam.kind.label : exam.title)",
                           detail: "\(exam.kind.label) \(relativeDay(exam.date, now: now))",
                           taskType: .summary, targetID: nil))
        }

        // 4. Le reste, dans l'ordre du planificateur.
        for todo in todos where todo.kind != .redo {
            add(action(from: todo, reason: .planned(todo.kind)))
        }
        return Array(result.prefix(limit))
    }

    private static func action(from todo: StudyTodo, reason: NextAction.Reason) -> NextAction {
        NextAction(id: todo.kind == .video ? "th-\(todo.targetID)" : "ex-\(todo.targetID)",
                   reason: reason, courseID: todo.courseID, courseCode: todo.courseCode,
                   colorHex: todo.colorHex, title: todo.title, detail: todo.detail,
                   taskType: todo.taskType, targetID: todo.targetID)
    }

    /// « aujourd'hui », « demain », « dans 3 jours ».
    static func relativeDay(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<1: return "aujourd'hui"
        case 1: return "demain"
        default: return "dans \(days) jours"
        }
    }
}
