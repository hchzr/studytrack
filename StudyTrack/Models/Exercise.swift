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

    /// Les sous-questions — « 1. », « 2. », « (a) » — d'un même exercice.
    ///
    /// Un polycopié numérote souvent ses exercices 1, 2, 3 dans chaque section, et
    /// regroupe sous un seul de ces numéros plusieurs questions. Les compter comme
    /// des exercices séparés gonfle la liste et fausse la progression : c'est le
    /// même travail, à rendre ensemble.
    @Relationship(deleteRule: .cascade, inverse: \SubQuestion.exercise)
    var subQuestions: [SubQuestion] = []

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

    // MARK: Sous-questions

    /// Les sous-questions, dans l'ordre du polycopié.
    var sortedSubQuestions: [SubQuestion] {
        subQuestions.sorted { $0.sortOrder < $1.sortOrder }
    }

    var hasSubQuestions: Bool { !subQuestions.isEmpty }
    var subQuestionDoneCount: Int { subQuestions.filter(\.isDone).count }

    /// « 2/3 », ou `nil` quand l'exercice n'a pas de sous-questions.
    var subQuestionLabel: String? {
        guard hasSubQuestions else { return nil }
        return "\(subQuestionDoneCount)/\(subQuestions.count)"
    }

    /// Marque toutes les sous-questions d'un coup.
    ///
    /// Cocher l'exercice entier est le geste courant ; le refuser obligerait à
    /// ouvrir chaque sous-question une par une.
    func setSubQuestions(done: Bool) {
        let now = Date()
        for question in subQuestions {
            question.isDone = done
            question.doneAt = done ? (question.doneAt ?? now) : nil
        }
        doneAt = done ? (doneAt ?? now) : nil
    }

    /// Recalcule « fait » à partir des sous-questions.
    ///
    /// `doneAt` reste la **seule** vérité pour tout le reste de l'app — séries,
    /// progression, statistiques, groupes. Cocher une sous-question le met donc à
    /// jour ici, plutôt que de forcer chaque calcul à connaître les sous-questions.
    func refreshCompletion() {
        guard hasSubQuestions else { return }
        if subQuestions.allSatisfy(\.isDone) {
            doneAt = doneAt ?? Date()
        } else {
            doneAt = nil
        }
    }

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

/// Une sous-question d'un exercice : « 1. », « 2. », « (a) », « (b) ».
///
/// Elle a son propre état — fait ou non — parce que c'est ainsi qu'on travaille :
/// on fait la première question, on bute sur la deuxième, on y revient. La
/// progression de l'exercice en découle, et celle de la série en découle aussi.
@Model
final class SubQuestion {
    @Attribute(.unique) var id: UUID
    var exercise: Exercise?
    /// L'étiquette telle qu'elle apparaît dans le polycopié : « 1 », « 2 », « a ».
    var label: String
    /// L'énoncé court, quand il a pu être lu. Facultatif : beaucoup de
    /// sous-questions n'ont qu'une formule.
    var text: String
    var isDone: Bool
    var doneAt: Date?
    var sortOrder: Int

    init(id: UUID = UUID(),
         exercise: Exercise? = nil,
         label: String,
         text: String = "",
         isDone: Bool = false,
         sortOrder: Int = 0) {
        self.id = id
        self.exercise = exercise
        self.label = label
        self.text = text
        self.isDone = isDone
        self.doneAt = isDone ? Date() : nil
        self.sortOrder = sortOrder
    }

    /// « 1. » ou « (a). », selon ce que le polycopié écrit.
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        // Une étiquette déjà ponctuée n'est pas reponctuée.
        if trimmed.hasSuffix(".") || trimmed.hasSuffix(")") || trimmed.hasSuffix(":") {
            return trimmed
        }
        return trimmed.count == 1 && trimmed.first!.isLetter ? "(\(trimmed))" : "\(trimmed)."
    }

    func toggle() {
        isDone.toggle()
        doneAt = isDone ? Date() : nil
        exercise?.refreshCompletion()
    }
}
