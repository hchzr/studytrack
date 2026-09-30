import Foundation

/// Où en est un exercice, en **une** valeur.
///
/// La ligne d'exercice empilait une coche, trois pastilles de sureté, un
/// compteur de questions et une étiquette de correction : quatre indications
/// qu'il fallait recomposer de tête pour savoir « qu'est-ce qui reste à faire
/// sur 3.4 ». Ce type les réduit à l'étape du parcours — faire, juger, corriger,
/// refaire — et c'est lui que la liste, l'espace de travail et l'assistant lisent.
enum ExerciseStage: Equatable {
    /// Rien de coché.
    case toDo
    /// Des questions cochées, pas toutes.
    case inProgress(done: Int, total: Int)
    /// Fait, sureté pas encore dite.
    case needsConfidence
    /// Fait et jugé, pas encore corrigé.
    case toCorrect(ConfidenceLevel)
    /// Corrigé.
    case corrected(Correctness)
    /// Marqué « à refaire » — prime sur tout le reste, c'est le travail qui attend.
    case redo

    init(_ exercise: Exercise) {
        if exercise.redoRequired {
            self = .redo
        } else if let correctness = exercise.correctness, exercise.isCorrected {
            self = .corrected(correctness)
        } else if exercise.isDone {
            if let confidence = exercise.confidence {
                self = .toCorrect(confidence)
            } else {
                self = .needsConfidence
            }
        } else if exercise.hasSubQuestions, exercise.subQuestionDoneCount > 0 {
            self = .inProgress(done: exercise.subQuestionDoneCount, total: exercise.leafSubQuestions.count)
        } else {
            self = .toDo
        }
    }

    /// Reste-t-il quelque chose à faire **sur** l'exercice (le faire, le juger,
    /// le corriger ou le refaire) ?
    var isOpen: Bool {
        if case .corrected = self { return false }
        return true
    }

    /// L'exercice est-il fait (au sens de la progression) ?
    var isDone: Bool {
        switch self {
        case .toDo, .inProgress: return false
        case .redo: return false
        default: return true
        }
    }

    /// « à faire », « 2/5 », « sureté ? », « à corriger », « juste »…
    var label: String {
        switch self {
        case .toDo: return "à faire"
        case .inProgress(let done, let total): return "\(done)/\(total)"
        case .needsConfidence: return "sureté ?"
        case .toCorrect: return "à corriger"
        case .corrected(let correctness): return correctness.shortLabel.lowercased()
        case .redo: return "à refaire"
        }
    }
}

/// Le parcours d'une série, exercice après exercice.
enum ExerciseFlow {

    /// L'exercice où reprendre la série : le premier qui n'est pas fait, dans
    /// l'ordre du polycopié ; à défaut, le premier à refaire, puis un bonus pas
    /// fait, puis le premier à juger ou à corriger. `nil` quand tout est corrigé.
    ///
    /// Les bonus passent après les exercices obligatoires **et** après ce qui
    /// est à refaire : on ne reprend pas une série par son bonus.
    static func resumePoint(in exercises: [Exercise]) -> Exercise? {
        let ordered = exercises.sorted { lhs, rhs in
            if lhs.isBonus != rhs.isBonus { return !lhs.isBonus }
            return lhs.sortOrder < rhs.sortOrder
        }
        let pending = { (exercise: Exercise) in !ExerciseStage(exercise).isDone && !exercise.redoRequired }
        if let open = ordered.first(where: { !$0.isBonus && pending($0) }) { return open }
        if let redo = ordered.first(where: \.redoRequired) { return redo }
        if let bonus = ordered.first(where: pending) { return bonus }
        return ordered.first { ExerciseStage($0).isOpen }
    }

    /// L'exercice qui suit `current` dans l'ordre de la série, en sautant ceux
    /// qui sont déjà faits — ce que « Suivant » propose une fois l'exercice fini.
    /// À défaut, simplement le suivant ; `nil` en fin de série.
    static func next(after current: Exercise, in exercises: [Exercise]) -> Exercise? {
        let ordered = exercises.sorted { $0.sortOrder < $1.sortOrder }
        guard let index = ordered.firstIndex(where: { $0.id == current.id }) else { return nil }
        let rest = ordered.dropFirst(index + 1)
        return rest.first { !ExerciseStage($0).isDone } ?? rest.first
    }

    /// Le temps passé sur un exercice : ses sessions enregistrées, plus ce que
    /// le chrono compte **en ce moment** sur lui.
    static func seconds(on exerciseID: UUID, sessions: [StudySession], live: TimeInterval = 0) -> Int {
        sessions.reduce(0) { total, session in
            session.exercise?.id == exerciseID ? total + session.durationSeconds : total
        } + Int(live)
    }

    /// Le temps passé sur une série entière.
    static func seconds(on series: ExerciseSeries, sessions: [StudySession]) -> Int {
        let ids = Set(series.exercises.map(\.id))
        return sessions.reduce(0) { total, session in
            guard let id = session.exercise?.id, ids.contains(id) else { return total }
            return total + session.durationSeconds
        }
    }
}

extension Exercise {
    /// Marque l'exercice fait ou à faire — questions comprises — **sans**
    /// inventer de sureté.
    ///
    /// Cocher mettait « orange » d'office : une sureté que personne n'avait
    /// donnée, qui faussait ensuite « ce que je maîtrise mal ». Elle reste vide,
    /// et l'interface la demande.
    func setDone(_ done: Bool) {
        if hasSubQuestions {
            setSubQuestions(done: done)
        } else {
            doneAt = done ? (doneAt ?? Date()) : nil
        }
        if !done { confidence = nil }
    }

    /// Enregistre une correction. « Faux » marque à refaire ; « juste » retire
    /// le « à refaire » qu'une correction précédente avait posé.
    func correct(_ result: Correctness) {
        correctness = result
        correctedAt = Date()
        switch result {
        case .wrong: redoRequired = true
        case .correct: redoRequired = false
        case .partial: break
        }
    }
}
