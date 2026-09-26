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
    /// Ce que l'exercice demande, en une phrase (« Montrer que (xₙ) est
    /// croissante ⇔ ad − bc ⩾ 0 »). Sans elle, un exercice sans questions
    /// numérotées n'était qu'un numéro et un titre. Lue par l'IA sur la page.
    var statement: String = ""
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

    /// Les questions **de premier niveau**, dans l'ordre du polycopié.
    ///
    /// `subQuestions` contient tous les nœuds — premier et second niveau — parce
    /// que chacun garde son lien vers l'exercice (suppression en cascade, requêtes
    /// simples). L'arbre se lit par `parent` / `children`.
    var sortedSubQuestions: [SubQuestion] {
        subQuestions.filter { $0.parent == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Les cases à cocher réelles : les questions sans sous-questions.
    ///
    /// « 1) (a) (b) 2) (a) » compte **trois** cases, pas cinq : 1) et 2) ne sont
    /// faits que lorsque leurs points le sont.
    var leafSubQuestions: [SubQuestion] {
        sortedSubQuestions.flatMap { $0.sortedChildren.isEmpty ? [$0] : $0.sortedChildren }
    }

    var hasSubQuestions: Bool { !subQuestions.isEmpty }
    var subQuestionDoneCount: Int { leafSubQuestions.filter(\.isDone).count }

    /// « 2/3 », ou `nil` quand l'exercice n'a pas de sous-questions.
    var subQuestionLabel: String? {
        guard hasSubQuestions else { return nil }
        return "\(subQuestionDoneCount)/\(leafSubQuestions.count)"
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
        for question in sortedSubQuestions where !question.children.isEmpty {
            question.refreshFromChildren()
        }
        if leafSubQuestions.allSatisfy(\.isDone) {
            doneAt = doneAt ?? Date()
        } else {
            doneAt = nil
        }
    }

    /// Remplace l'arbre des sous-questions par celui d'une relecture.
    ///
    /// L'ancienne version de l'import ne faisait qu'**ajouter** les étiquettes
    /// manquantes : une question mal lue restait pour toujours, et un réimport ne
    /// réparait rien. L'arbre relu fait foi ; l'état « fait » est repris sur chaque
    /// case dont le chemin (« 1 », « 1.a ») existait déjà — c'est du travail de
    /// l'étudiant·e, pas de l'import.
    func replaceSubQuestions(with questions: [DetectedSubQuestion], in context: ModelContext?) {
        var done: [String: Date] = [:]
        for question in subQuestions where question.isDone && question.children.isEmpty {
            done[question.path] = question.doneAt ?? Date()
        }
        let old = subQuestions
        subQuestions = []
        for question in old { context?.delete(question) }

        func make(_ detected: DetectedSubQuestion, parent: SubQuestion?, order: Int) -> SubQuestion {
            let node = SubQuestion(exercise: self, parent: parent,
                                   label: detected.label.trimmingCharacters(in: .whitespaces),
                                   text: detected.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                   kind: detected.kind, sortOrder: order)
            context?.insert(node)
            subQuestions.append(node)
            if let doneAt = done[node.path] {
                node.isDone = true
                node.doneAt = doneAt
            }
            return node
        }
        for (index, question) in questions.enumerated() {
            let node = make(question, parent: nil, order: index)
            for (childIndex, child) in question.children.enumerated() {
                node.children.append(make(child, parent: node, order: childIndex))
            }
            node.refreshFromChildren()
        }
        if subQuestions.isEmpty {
            // Plus aucune question : l'exercice garde son propre état.
            return
        }
        refreshCompletion()
    }

    /// L'arbre, dans la forme de la relecture — pour le rééditer.
    var detectedSubQuestions: [DetectedSubQuestion] {
        sortedSubQuestions.map { question in
            DetectedSubQuestion(label: question.label, text: question.text, kind: question.kind,
                                children: question.sortedChildren.map {
                                    DetectedSubQuestion(label: $0.label, text: $0.text, kind: $0.kind)
                                })
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
    /// La question dont celle-ci est un point : « (a) » sous « 1) ». `nil` au
    /// premier niveau. Deux niveaux au plus — c'est ce que les polycopiés font.
    var parent: SubQuestion?
    @Relationship(deleteRule: .cascade, inverse: \SubQuestion.parent)
    var children: [SubQuestion] = []
    /// L'étiquette telle qu'elle apparaît dans le polycopié : « 1 », « 2 », « a ».
    /// Vide pour une partie sans numéro (« Ensuite, … »).
    var label: String
    /// L'énoncé court, quand il a pu être lu. Facultatif : beaucoup de
    /// sous-questions n'ont qu'une formule.
    var text: String
    /// `SubQuestionKind.rawValue`. Une « partie » est un travail demandé sans
    /// numéro : la consigne d'ouverture avant une liste, ou « Ensuite, … » après.
    var kindRaw: String = SubQuestionKind.question.rawValue
    var isDone: Bool
    var doneAt: Date?
    var sortOrder: Int

    init(id: UUID = UUID(),
         exercise: Exercise? = nil,
         parent: SubQuestion? = nil,
         label: String,
         text: String = "",
         kind: SubQuestionKind = .question,
         isDone: Bool = false,
         sortOrder: Int = 0) {
        self.id = id
        self.exercise = exercise
        self.parent = parent
        self.label = label
        self.text = text
        self.kindRaw = kind.rawValue
        self.isDone = isDone
        self.doneAt = isDone ? Date() : nil
        self.sortOrder = sortOrder
    }

    var kind: SubQuestionKind {
        get { SubQuestionKind(rawValue: kindRaw) ?? .question }
        set { kindRaw = newValue.rawValue }
    }

    var sortedChildren: [SubQuestion] {
        children.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Le chemin stable de la question : « 1 », « 1.a ». Sert à retrouver une
    /// case cochée quand on remplace l'arbre par un nouvel import.
    var path: String {
        let own = label.isEmpty ? "#\(sortOrder)" : label
        guard let parent else { return own }
        return "\(parent.path).\(own)"
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

    /// Une question avec des points se coche **par ses points** : la toucher
    /// coche ou décoche tous ses points d'un coup.
    func toggle() {
        let target = !isDone
        if children.isEmpty {
            isDone = target
            doneAt = target ? Date() : nil
        } else {
            let now = Date()
            for child in children {
                child.isDone = target
                child.doneAt = target ? (child.doneAt ?? now) : nil
            }
            refreshFromChildren()
        }
        parent?.refreshFromChildren()
        (exercise ?? parent?.exercise)?.refreshCompletion()
    }

    /// Une question à points est faite quand tous ses points le sont.
    func refreshFromChildren() {
        guard !children.isEmpty else { return }
        let all = children.allSatisfy(\.isDone)
        isDone = all
        doneAt = all ? (doneAt ?? Date()) : nil
    }
}

enum SubQuestionKind: String, Codable, CaseIterable {
    /// Une question étiquetée : « 1) », « (a) ».
    case question
    /// Un travail demandé sans étiquette : consigne d'ouverture ou « Ensuite, … ».
    case part
}
