import Foundation
import SwiftData

/// Ce qui tombe à une date : une évaluation, une série à rendre, un corrigé
/// qui s'ouvre. Lu dans les cours : l'accueil (iPhone, Mac), l'agenda et les widgets.
struct Deadline: Identifiable, Equatable {
    enum Kind { case exam, due, solutions }
    var id: String
    var kind: Kind
    var date: Date
    var title: String
    var detail: String
    var courseID: UUID
    var courseCode: String
    var colorHex: String
    var targetID: UUID?

    var icon: String {
        switch kind {
        case .exam: return "graduationcap.fill"
        case .due: return "tray.and.arrow.up"
        case .solutions: return "checkmark.seal"
        }
    }

    /// Les échéances des `days` prochains jours (et celles du jour), triées.
    static func upcoming(in courses: [Course], from start: Date = DateUtils.startOfDay(Date()), days: Int) -> [Deadline] {
        between(courses, start, DateUtils.addDays(days, to: start))
    }

    static func between(_ courses: [Course], _ start: Date, _ end: Date) -> [Deadline] {
        var result: [Deadline] = []
        for course in courses {
            for exam in course.exams where exam.date >= start && exam.date < end {
                result.append(Deadline(id: "exam:\(exam.id)", kind: .exam, date: exam.date,
                                       title: exam.title.isEmpty ? exam.kind.label : exam.title,
                                       detail: [exam.kind.label, exam.weightLabel, exam.location.isEmpty ? nil : exam.location]
                                           .compactMap { $0 }.joined(separator: " · "),
                                       courseID: course.id, courseCode: course.displayCode, colorHex: course.colorHex))
            }
            for series in course.series {
                let name = series.title.isEmpty ? String(localized: "Série \(series.seriesNumber)") : series.title
                if let due = series.dueDate, due >= start, due < end {
                    let left = series.requiredExercises.count - series.doneCount
                    result.append(Deadline(id: "due:\(series.id)", kind: .due, date: due, title: String(localized: "\(name) à rendre"),
                                           detail: left > 0 ? "\(Plural.count(left, "\(left) exercice à faire", "\(left) exercices à faire"))" : String(localized: "tout est fait"),
                                           courseID: course.id, courseCode: course.displayCode, colorHex: course.colorHex,
                                           targetID: series.sortedExercises.first { !$0.isDone }?.id))
                }
                if let open = series.solutionsAt, open >= start, open < end {
                    result.append(Deadline(id: "sol:\(series.id)", kind: .solutions, date: open, title: String(localized: "Corrigé de la \(name.lowercased())"),
                                           detail: String(localized: "à corriger ensuite"),
                                           courseID: course.id, courseCode: course.displayCode, colorHex: course.colorHex))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}
