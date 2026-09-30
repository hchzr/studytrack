import Foundation
import SwiftData

/// Évaluation du cours : midterm, examen final, quiz, projet…
@Model
final class Exam {
    @Attribute(.unique) var id: UUID
    var course: Course?
    var kindRaw: String
    var title: String
    var date: Date
    var weightPercent: Double?
    var location: String
    /// La page de l'échéance (le devoir sur Moodle), quand elle vient d'un import.
    var urlString: String = ""
    var notes: String
    var externalCalendarEventID: String?

    init(id: UUID = UUID(),
         course: Course? = nil,
         kind: ExamKind = .exam,
         title: String = "",
         date: Date = Date(),
         weightPercent: Double? = nil,
         location: String = "",
         notes: String = "") {
        self.id = id
        self.course = course
        self.kindRaw = kind.rawValue
        self.title = title.isEmpty ? kind.label : title
        self.date = date
        self.weightPercent = weightPercent
        self.location = location
        self.notes = notes
    }

    var kind: ExamKind {
        get { ExamKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var daysUntil: Int {
        Calendar.current.dateComponents([.day],
                                        from: Calendar.current.startOfDay(for: Date()),
                                        to: Calendar.current.startOfDay(for: date)).day ?? 0
    }

    var isPast: Bool { date < Date() }

    var weightLabel: String? {
        guard let weightPercent else { return nil }
        return "\(Int(weightPercent)) %"
    }

}
