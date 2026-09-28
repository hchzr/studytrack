import AppIntents
import Foundation
import SwiftData

// MARK: - Entité « cours »

struct CourseEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Cours"
    static var defaultQuery = CourseEntityQuery()

    var id: UUID
    var code: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(code)", subtitle: "\(name)")
    }

    init(_ course: Course) {
        self.id = course.id
        self.code = course.code
        self.name = course.name
    }
}

struct CourseEntityQuery: EntityQuery {

    func entities(for identifiers: [UUID]) async throws -> [CourseEntity] {
        await MainActor.run {
            let courses = Self.loadCourses()
            return courses.filter { identifiers.contains($0.id) }.map(CourseEntity.init)
        }
    }

    func suggestedEntities() async throws -> [CourseEntity] {
        await MainActor.run {
            Self.loadCourses().filter(\.isTracked).map(CourseEntity.init)
        }
    }

    func defaultResult() async -> CourseEntity? {
        await MainActor.run {
            Self.loadCourses().first(where: \.isTracked).map(CourseEntity.init)
        }
    }

    @MainActor
    private static func loadCourses() -> [Course] {
        guard let context = AppRuntime.container?.modelContainer.mainContext else { return [] }
        return (try? context.fetch(FetchDescriptor<Course>())) ?? []
    }
}

// MARK: - Énumération « type de travail »

enum TaskTypeAppEnum: String, AppEnum {
    case lecture, video, exercise, theory, flashcards, summary, correction, project, other

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Type de travail"

    static var caseDisplayRepresentations: [TaskTypeAppEnum: DisplayRepresentation] = [
        // Les anciennes valeurs restent (des raccourcis les ont enregistrées),
        // nommées d'après la catégorie à laquelle elles comptent désormais.
        .lecture: "Cours en amphi",
        .video: "Théorie (vidéo)",
        .exercise: "Séries",
        .theory: "Théorie",
        .flashcards: "Anki",
        .summary: "Théorie (résumé)",
        .correction: "Correction",
        .project: "Autre (projet)",
        .other: "Autre"
    ]

    var taskType: TaskType { TaskType(rawValue: rawValue) ?? .other }
}

// MARK: - Intents

/// Démarre le chrono sur un cours, depuis Siri ou Raccourcis.
struct StartStudyTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Démarrer une session d'étude"
    static var description: IntentDescription = IntentDescription(
        "Ouvre StudyTrack et démarre le chrono sur le cours choisi.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Cours")
    var course: CourseEntity?

    @Parameter(title: "Type de travail")
    var taskType: TaskTypeAppEnum?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            guard let container = AppRuntime.container else { return }
            let code = course?.code ?? ""
            let type = taskType?.taskType ?? .theory
            container.router.startFocus(courseID: course?.id,
                                        courseCode: code,
                                        taskType: type,
                                        label: code.isEmpty ? "Session libre" : "\(code) · \(type.label)")
        }
        return .result(dialog: "Chrono démarré dans StudyTrack.")
    }
}

/// Enregistre une session déjà terminée, sans ouvrir l'app.
struct LogStudySessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Enregistrer une session d'étude"
    static var description: IntentDescription = IntentDescription(
        "Ajoute une session de travail passée, avec sa durée et son type.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Cours")
    var course: CourseEntity?

    @Parameter(title: "Type de travail")
    var taskType: TaskTypeAppEnum?

    @Parameter(title: "Durée (minutes)")
    var minutes: Int

    init() {}

    init(course: CourseEntity?, taskType: TaskTypeAppEnum?, minutes: Int) {
        self.course = course
        self.taskType = taskType
        self.minutes = minutes
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clamped = max(1, min(minutes, 1440))
        await MainActor.run {
            guard let container = AppRuntime.container else { return }
            let context = container.modelContainer.mainContext
            let identifier = course?.id
            let target = identifier.flatMap { id in
                (try? context.fetch(FetchDescriptor<Course>()))?.first { $0.id == id }
            }
            let session = StudySession(course: target,
                                       taskType: taskType?.taskType ?? .other,
                                       startedAt: Date().addingTimeInterval(-Double(clamped * 60)),
                                       durationSeconds: clamped * 60,
                                       isManual: true,
                                       note: "Enregistré depuis Raccourcis")
            context.insert(session)
            try? context.save()
        }
        return .result(dialog: "Session enregistrée.")
    }
}

/// Ajoute une tâche liée à un cours.
struct AddStudyTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Ajouter une tâche d'étude"
    static var description: IntentDescription = IntentDescription(
        "Crée une tâche StudyTrack, éventuellement liée à un cours et datée.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Titre")
    var title: String

    @Parameter(title: "Cours")
    var course: CourseEntity?

    @Parameter(title: "Échéance")
    var dueDate: Date?

    init() {}

    init(title: String, course: CourseEntity?, dueDate: Date?) {
        self.title = title
        self.course = course
        self.dueDate = dueDate
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTitle.isEmpty else {
            return .result(dialog: "Il faut un titre.")
        }
        await MainActor.run {
            guard let container = AppRuntime.container else { return }
            let context = container.modelContainer.mainContext
            let identifier = course?.id
            let target = identifier.flatMap { id in
                (try? context.fetch(FetchDescriptor<Course>()))?.first { $0.id == id }
            }
            let task = LinkedTask(provider: .reminders,
                                  externalID: nil,
                                  title: resolvedTitle,
                                  dueDate: dueDate)
            task.course = target
            context.insert(task)
            try? context.save()
        }
        return .result(dialog: "Tâche ajoutée.")
    }
}

// MARK: - Sureté exposée à Siri

enum ConfidenceAppEnum: String, AppEnum {
    case high, medium, low

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sureté"
    static var caseDisplayRepresentations: [ConfidenceAppEnum: DisplayRepresentation] = [
        .high: "Sûr",
        .medium: "Moyennement sûr",
        .low: "Pas sûr"
    ]

    var confidence: ConfidenceLevel {
        switch self {
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }
}

// MARK: - Planification et suivi depuis Siri

/// Planifie une session d'étude, et l'écrit dans le calendrier système si l'accès
/// est autorisé. C'est le pont entre « dis-le à Siri » et l'agenda du téléphone.
struct PlanStudySessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Planifier une session d'étude"
    static var description: IntentDescription = IntentDescription(
        "Crée une session d'étude à venir : elle apparaît dans l'agenda de l'app et, si l'accès est autorisé, dans le calendrier système.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Cours")
    var course: CourseEntity?

    @Parameter(title: "Début")
    var start: Date

    @Parameter(title: "Durée (minutes)", default: 90)
    var minutes: Int

    init() {}

    init(course: CourseEntity?, start: Date, minutes: Int) {
        self.course = course
        self.start = start
        self.minutes = minutes
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clamped = max(15, min(minutes, 480))

        // On **renvoie** la valeur au lieu de muter une variable capturée :
        // `MainActor.run` est `@Sendable`, et y muter est une erreur en Swift 6.
        let planned = await MainActor.run { () -> Bool in
            guard let container = AppRuntime.container else { return false }
            let context = container.modelContainer.mainContext
            // Passer par une variable : `course?.id.flatMap` déroulerait l'optionnel
            // avant l'appel, et `flatMap` n'existe pas sur `UUID`.
            let identifier = course?.id
            let target = identifier.flatMap { id in
                (try? context.fetch(FetchDescriptor<Course>()))?.first { $0.id == id }
            }
            let session = PlannedSession(course: target,
                                         title: "Session d'étude",
                                         startsAt: start,
                                         durationMinutes: clamped)
            context.insert(session)

            if container.calendar.hasAccess {
                let spec = CalendarEventSpec(title: session.title,
                                             startsAt: session.startsAt,
                                             endsAt: session.endsAt,
                                             notes: "Planifié depuis Raccourcis.",
                                             calendarTitle: "StudyTrack")
                if let identifier = container.calendar.createEvent(spec) {
                    session.externalCalendarEventID = identifier
                }
            }
            try? context.save()
            return true
        }

        guard planned else {
            return .result(dialog: "Ouvre StudyTrack une fois avant de planifier.")
        }
        let duration = DateUtils.durationLabel(seconds: clamped * 60)
        return .result(dialog: "Session de \(duration) planifiée le \(DateUtils.shortDay.string(from: start)) à \(DateUtils.time.string(from: start)).")
    }
}

/// Marque un exercice comme fait, avec son niveau de sureté.
struct MarkExerciseDoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Marquer un exercice comme fait"
    static var description: IntentDescription = IntentDescription(
        "Enregistre qu'un exercice est fait. Sans cours précisé, cherche dans tous les cours suivis.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Cours")
    var course: CourseEntity?

    @Parameter(title: "Numéro d'exercice", description: "Par exemple 3.2")
    var number: String

    @Parameter(title: "Sureté")
    var confidence: ConfidenceAppEnum?

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let wanted = number.trimmingCharacters(in: .whitespaces)

        // Même raison que ci-dessus : on renvoie le libellé trouvé, on ne le mute pas.
        let matched = await MainActor.run { () -> String? in
            guard let container = AppRuntime.container else { return nil }
            let context = container.modelContainer.mainContext
            guard let courses = try? context.fetch(FetchDescriptor<Course>()) else { return nil }

            let identifier = course?.id
            let candidates = identifier.flatMap { id in courses.filter { $0.id == id } }
                ?? courses.filter(\.isTracked)

            for target in candidates {
                guard let exercise = target.allExercises.first(where: { $0.exerciseNumber == wanted })
                        ?? target.allExercises.first(where: {
                            $0.exerciseNumber.hasSuffix(".\(wanted)")
                        }) else { continue }
                exercise.doneAt = exercise.doneAt ?? Date()
                if let confidence {
                    exercise.confidence = confidence.confidence
                } else if exercise.confidence == nil {
                    exercise.confidence = .medium
                }
                try? context.save()
                return "\(target.displayCode) · \(exercise.displayNumber)"
            }
            return nil
        }

        guard let matched else {
            return .result(dialog: "Je n'ai pas trouvé l'exercice \(wanted). Précise le cours.")
        }
        return .result(dialog: "\(matched) marqué comme fait.")
    }
}

// MARK: - Raccourcis proposés par défaut

struct StudyTrackShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartStudyTimerIntent(),
                    phrases: [
                        "Démarre une session d'étude dans \(.applicationName)",
                        "Lance mon chrono \(.applicationName)"
                    ],
                    shortTitle: "Démarrer une session",
                    systemImageName: "timer")

        AppShortcut(intent: LogStudySessionIntent(),
                    phrases: [
                        "Enregistre une session d'étude dans \(.applicationName)",
                        "Ajoute du temps de travail dans \(.applicationName)"
                    ],
                    shortTitle: "Enregistrer une session",
                    systemImageName: "clock.badge.checkmark")

        AppShortcut(intent: AddStudyTaskIntent(),
                    phrases: [
                        "Ajoute une tâche d'étude dans \(.applicationName)"
                    ],
                    shortTitle: "Ajouter une tâche",
                    systemImageName: "checklist")

        AppShortcut(intent: PlanStudySessionIntent(),
                    phrases: [
                        "Planifie une session d'étude dans \(.applicationName)",
                        "Planifie une session \(.applicationName)"
                    ],
                    shortTitle: "Planifier une session",
                    systemImageName: "calendar.badge.plus")

        AppShortcut(intent: MarkExerciseDoneIntent(),
                    phrases: [
                        "Marque un exercice comme fait dans \(.applicationName)",
                        "J'ai fini un exercice dans \(.applicationName)"
                    ],
                    shortTitle: "Marquer un exercice fait",
                    systemImageName: "checkmark.circle")
    }
}
