import Foundation
import SwiftData

/// Session de travail enregistrée (chrono ou saisie manuelle).
@Model
final class StudySession {
    @Attribute(.unique) var id: UUID
    var course: Course?
    var taskTypeRaw: String
    var startedAt: Date
    var durationSeconds: Int
    var isManual: Bool
    var note: String
    var createdAt: Date

    /// Sur **quoi** portait exactement la session, quand l'étudiant·e l'a précisé.
    ///
    /// `nil` reste normal — un cours plus un type de travail suffisent. Mais
    /// « 2 h d'exercices sur CS-250 » ne dit pas si c'était la série 3 ou la
    /// série 5, et c'est cette information qui rend le temps exploitable.
    var exercise: Exercise?
    var theoryItem: TheoryItem?

    init(id: UUID = UUID(),
         course: Course? = nil,
         taskType: TaskType = .other,
         startedAt: Date = Date(),
         durationSeconds: Int = 0,
         isManual: Bool = false,
         note: String = "",
         exercise: Exercise? = nil,
         theoryItem: TheoryItem? = nil) {
        self.id = id
        self.course = course
        self.taskTypeRaw = taskType.rawValue
        self.startedAt = startedAt
        self.durationSeconds = max(0, durationSeconds)
        self.isManual = isManual
        self.note = note
        self.exercise = exercise
        self.theoryItem = theoryItem
        self.createdAt = Date()
    }

    var taskType: TaskType {
        get { TaskType(rawValue: taskTypeRaw) ?? .other }
        set { taskTypeRaw = newValue.rawValue }
    }

    /// Libellé de la cible précise : « Exercice 3.2 », « Chapitre 1.1 »…
    /// `nil` quand la session n'a pas été précisée.
    var targetLabel: String? {
        exercise?.displayNumber ?? theoryItem?.displayNumber
    }

    var endedAt: Date { startedAt.addingTimeInterval(TimeInterval(durationSeconds)) }
    var durationMinutes: Int { durationSeconds / 60 }
    var durationHours: Double { Double(durationSeconds) / 3600 }
    var durationLabel: String { DateUtils.durationLabel(seconds: durationSeconds) }
}
