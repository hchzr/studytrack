import Foundation
import SwiftUI

/// Une chose concrète à faire, dérivée de l'état réel du cours.
struct StudyTodo: Identifiable, Equatable {
    enum Kind: String {
        case redo
        case video
        case exercise
        case correction

        /// Ordre de priorité d'affichage.
        var rank: Int {
            switch self {
            case .redo: return 0
            case .video: return 1
            case .exercise: return 2
            case .correction: return 3
            }
        }

        var label: String {
            switch self {
            case .redo: return "À refaire"
            case .video: return "Théorie"
            case .exercise: return "Exercice"
            case .correction: return "À corriger"
            }
        }
    }

    var id: String
    var kind: Kind
    var courseID: UUID
    var courseCode: String
    var courseName: String
    var colorHex: String
    var title: String
    var detail: String
    var minutes: Int
    var week: Int
    var taskType: TaskType
    var targetID: UUID

    var icon: String {
        switch kind {
        case .redo: return "arrow.counterclockwise"
        case .video: return TaskType.video.icon
        case .exercise: return TaskType.exercise.icon
        case .correction: return TaskType.correction.icon
        }
    }

    var tint: Color {
        switch kind {
        case .redo: return .red
        case .video: return TaskType.video.tint
        case .exercise: return TaskType.exercise.tint
        case .correction: return TaskType.correction.tint
        }
    }

    var durationLabel: String? {
        minutes > 0 ? DateUtils.durationLabel(seconds: minutes * 60) : nil
    }
}

/// Construit la liste « quoi faire maintenant » à partir de l'état des cours.
///
/// Point clé : la semaine est calculée **par cours** (`Course.currentWeek`, bornée
/// à la durée du semestre). Auparavant une semaine globale était dérivée du premier
/// cours, ce qui vidait l'écran principal dès qu'un semestre importé était ancien.
enum DailyPlanner {

    static func todos(for courses: [Course], limit: Int = 10) -> [StudyTodo] {
        var items: [StudyTodo] = []

        for course in courses where course.isTracked {
            let week = course.currentWeek
            let running = course.isTermRunning

            // 1. Exercices marqués « à refaire » — priorité absolue.
            for exercise in course.allExercises where exercise.redoRequired {
                items.append(makeTodo(kind: .redo,
                                      course: course,
                                      targetID: exercise.id,
                                      title: exercise.displayNumber,
                                      detail: exercise.correctionNote?.isEmpty == false
                                          ? (exercise.correctionNote ?? "")
                                          : "Marqué à refaire",
                                      minutes: 20,
                                      week: week,
                                      taskType: .exercise))
            }

            guard running else { continue }

            // 2. Théorie de la semaine — vidéo, lecture, chapitre ou diapos.
            for item in ProgressEngine.remainingVideos(for: course, week: week) {
                items.append(makeTodo(kind: .video,
                                      course: course,
                                      targetID: item.id,
                                      title: item.displayNumber,
                                      detail: item.title.isEmpty
                                          ? "\(item.kind.label) de théorie"
                                          : item.title,
                                      minutes: item.durationMinutes,
                                      week: week,
                                      taskType: item.kind == .video ? .video : .theory))
            }

            // 3. Exercices de la semaine.
            for exercise in ProgressEngine.remainingExercises(for: course, week: week) {
                items.append(makeTodo(kind: .exercise,
                                      course: course,
                                      targetID: exercise.id,
                                      title: exercise.displayNumber,
                                      detail: exercise.isBonus ? "Bonus" : (exercise.title.isEmpty ? "À faire" : exercise.title),
                                      minutes: 30,
                                      week: week,
                                      taskType: .exercise))
            }

            // 4. Exercices faits mais pas encore corrigés.
            for exercise in course.allExercises where exercise.isDone && !exercise.isCorrected {
                items.append(makeTodo(kind: .correction,
                                      course: course,
                                      targetID: exercise.id,
                                      title: exercise.displayNumber,
                                      detail: "Fait, à corriger",
                                      minutes: 15,
                                      week: week,
                                      taskType: .correction))
            }
        }

        return items
            .sorted { lhs, rhs in
                if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
                return lhs.courseCode < rhs.courseCode
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func makeTodo(kind: StudyTodo.Kind,
                                 course: Course,
                                 targetID: UUID,
                                 title: String,
                                 detail: String,
                                 minutes: Int,
                                 week: Int,
                                 taskType: TaskType) -> StudyTodo {
        StudyTodo(id: "\(kind.rawValue)-\(targetID.uuidString)",
                  kind: kind,
                  courseID: course.id,
                  courseCode: course.code,
                  courseName: course.name,
                  colorHex: course.colorHex,
                  title: title,
                  detail: detail,
                  minutes: minutes,
                  week: week,
                  taskType: taskType,
                  targetID: targetID)
    }
}
