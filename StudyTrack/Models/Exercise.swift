import Foundation
import SwiftData

/// Série d'exercices (« Série 1 ») contenant des sous-exercices.
@Model
final class ExerciseSeries {
    @Attribute(.unique) var id: UUID
    var course: Course?
    var seriesNumber: Int
    var title: String
    var plannedWeek: Int
    var publishedAt: Date?
    var dueDate: Date?
    var urlString: String

    @Relationship(deleteRule: .cascade, inverse: \Exercise.series)
    var exercises: [Exercise] = []

    init(id: UUID = UUID(),
         course: Course? = nil,
         seriesNumber: Int,
         title: String = "",
         plannedWeek: Int = 1,
         publishedAt: Date? = nil,
         dueDate: Date? = nil,
         urlString: String = "") {
        self.id = id
        self.course = course
        self.seriesNumber = seriesNumber
        self.title = title.isEmpty ? "Série \(seriesNumber)" : title
        self.plannedWeek = plannedWeek
        self.publishedAt = publishedAt
        self.dueDate = dueDate
        self.urlString = urlString
    }

    var sortedExercises: [Exercise] {
        exercises.sorted { $0.sortOrder < $1.sortOrder }
    }

    var requiredExercises: [Exercise] { exercises.filter { !$0.isBonus } }
    var bonusExercises: [Exercise] { exercises.filter(\.isBonus) }

    var doneCount: Int { requiredExercises.filter { $0.doneAt != nil }.count }
    var correctedCount: Int { requiredExercises.filter { $0.correctedAt != nil }.count }

    var isComplete: Bool {
        !requiredExercises.isEmpty && doneCount == requiredExercises.count
    }

    var progress: Double {
        requiredExercises.isEmpty ? 0 : Double(doneCount) / Double(requiredExercises.count)
    }
}

/// Sous-exercice (« exercice 1.1 », « 1.2 ») avec suivi complet.
@Model
final class Exercise {
    @Attribute(.unique) var id: UUID
    var series: ExerciseSeries?
    /// Numéro affiché : « 1.1 ».
    var exerciseNumber: String
    var title: String
    var isBonus: Bool
    var sortOrder: Int
    var statementURLString: String

    // Fait
    var doneAt: Date?
    /// ConfidenceLevel.rawValue — code couleur vert / orange / rouge.
    var confidenceRaw: String?

    // Correction
    var correctedAt: Date?
    /// Correctness.rawValue — juste / moyennement juste / faux.
    var correctnessRaw: String?
    var redoRequired: Bool
    var correctionNote: String?
    var score: Double?
    var maxScore: Double?

    init(id: UUID = UUID(),
         series: ExerciseSeries? = nil,
         exerciseNumber: String,
         title: String = "",
         isBonus: Bool = false,
         sortOrder: Int = 0,
         statementURLString: String = "") {
        self.id = id
        self.series = series
        self.exerciseNumber = exerciseNumber
        self.title = title
        self.isBonus = isBonus
        self.sortOrder = sortOrder
        self.statementURLString = statementURLString
        self.redoRequired = false
    }

    var displayNumber: String { "Exercice \(exerciseNumber)" }
    var isDone: Bool { doneAt != nil }
    var isCorrected: Bool { correctedAt != nil }

    var confidence: ConfidenceLevel? {
        get { confidenceRaw.flatMap(ConfidenceLevel.init(rawValue:)) }
        set { confidenceRaw = newValue?.rawValue }
    }

    var correctness: Correctness? {
        get { correctnessRaw.flatMap(Correctness.init(rawValue:)) }
        set { correctnessRaw = newValue?.rawValue }
    }

    /// Score formaté : « 4/5 ».
    var scoreLabel: String? {
        guard let score else { return nil }
        if let maxScore { return "\(Int(score))/\(Int(maxScore))" }
        return "\(Int(score))"
    }
}
