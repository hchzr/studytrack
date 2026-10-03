import Foundation
import SwiftData

/// Tâche synchronisée depuis un fournisseur externe (Rappels, Todoist).
@Model
final class LinkedTask {
    var id: UUID = UUID()
    var providerRaw: String = ""
    var externalID: String?
    var title: String = ""
    var note: String = ""
    var dueDate: Date?
    var isDone: Bool = false
    var priority: Int = 0
    var course: Course?
    var video: TheoryItem?
    var exercise: Exercise?
    var updatedAt: Date = Date.now
    var lastSyncedAt: Date?

    init(id: UUID = UUID(),
         provider: TaskProvider = .reminders,
         externalID: String? = nil,
         title: String,
         note: String = "",
         dueDate: Date? = nil,
         isDone: Bool = false,
         priority: Int = 1) {
        self.id = id
        self.providerRaw = provider.rawValue
        self.externalID = externalID
        self.title = title
        self.note = note
        self.dueDate = dueDate
        self.isDone = isDone
        self.priority = priority
        self.updatedAt = Date()
    }

    var provider: TaskProvider {
        get { TaskProvider(rawValue: providerRaw) ?? .reminders }
        set { providerRaw = newValue.rawValue }
    }

    var isOverdue: Bool {
        guard let dueDate, !isDone else { return false }
        return dueDate < Date()
    }

    var isDueToday: Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }

    var linkLabel: String? {
        if let exercise { return exercise.displayNumber }
        if let video { return video.displayNumber }
        if let course { return course.code }
        return nil
    }
}
