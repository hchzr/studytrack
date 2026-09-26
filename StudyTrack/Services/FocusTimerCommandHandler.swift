import Foundation
import SwiftData

/// Exécute les commandes venues de la Live Activity et de l'écran verrouillé.
///
/// Les boutons du chrono s'exécutent dans le processus de l'app : c'est ce qui
/// permet d'**enregistrer une session** depuis l'écran verrouillé, sans ouvrir
/// l'app. Le pont ne transporte qu'une commande ; tout ce qui touche aux données
/// se fait ici, où SwiftData est disponible.
///
/// Posé une fois au lancement. `LiveActivityIntent` lance l'app avant d'exécuter
/// la commande, donc le gestionnaire existe quand elle arrive.
enum FocusTimerCommandHandler {

    /// Notification interne : l'écran Focus recharge son état.
    static let didChange = Notification.Name("studytrack.focusTimerDidChange")

    @MainActor
    static func install(container: AppContainer) {
        FocusTimerBridge.handler = { command in
            Task { @MainActor in
                handle(command, container: container)
            }
        }
    }

    /// Rejoue une commande déposée pendant que l'app était éteinte.
    @MainActor
    static func consumePending(container: AppContainer) {
        guard let command = FocusTimerBridge.takePending() else { return }
        handle(command, container: container)
    }

    @MainActor
    static func handle(_ command: FocusTimerCommand, container: AppContainer) {
        // La commande a pu être traitée par le chemin direct : on la retire pour
        // qu'un prochain lancement ne la rejoue pas.
        FocusTimerBridge.clearPending()

        guard var state = FocusTimerStore.load(),
              state.isRestorable() || state.runningSince != nil else {
            StudyActivityController.end()
            return
        }

        switch command {
        case .pause:
            state.pause()
            FocusTimerStore.save(state)
            StudyActivityController.sync(
                attributes: attributes(for: state, container: container),
                state: .make(elapsed: state.elapsed(), running: false))
            notify()

        case .resume:
            state.start()
            FocusTimerStore.save(state)
            StudyActivityController.sync(
                attributes: attributes(for: state, container: container),
                state: .make(elapsed: state.elapsed(), running: true))
            notify()

        case .finish:
            save(state, container: container)
            FocusTimerStore.save(nil)
            StudyActivityController.end()
            notify()
        }
    }

    /// Enregistre la session — la même écriture que le bouton « Enregistrer ».
    @MainActor
    private static func save(_ state: FocusTimerState, container: AppContainer) {
        let seconds = Int(state.elapsed())
        guard seconds >= 1 else { return }

        let context = ModelContext(container.modelContainer)
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let course = state.courseID.flatMap { id in courses.first { $0.id == id } }

        var exercise: Exercise?
        var theoryItem: TheoryItem?
        if let targetID = state.targetID, let course {
            exercise = course.allExercises.first { $0.id == targetID }
            theoryItem = course.theoryItems.first { $0.id == targetID }
        }

        let session = StudySession(course: course,
                                   taskType: state.taskType,
                                   startedAt: state.sessionStartedAt,
                                   durationSeconds: seconds,
                                   isManual: false,
                                   note: state.note,
                                   exercise: exercise,
                                   theoryItem: theoryItem)
        context.insert(session)
        try? context.save()
        WidgetSnapshotWriter.refresh(context: context, settings: container.settings)
    }

    @MainActor
    private static func attributes(for state: FocusTimerState,
                                   container: AppContainer) -> StudyActivityAttributes {
        let context = ModelContext(container.modelContainer)
        let course = ((try? context.fetch(FetchDescriptor<Course>())) ?? [])
            .first { $0.id == state.courseID }
        let target = targetLabel(state, course: course)
        return StudyActivityAttributes(courseCode: course?.displayCode ?? "Sans cours",
                                       courseName: course?.name ?? "Session libre",
                                       taskLabel: state.taskType.label,
                                       taskIcon: state.taskType.icon,
                                       target: target)
    }

    @MainActor
    private static func targetLabel(_ state: FocusTimerState, course: Course?) -> String? {
        guard let course, let targetID = state.targetID else { return nil }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return exercise.displayNumber
        }
        if let item = course.theoryItems.first(where: { $0.id == targetID }) {
            return item.displayNumber
        }
        return nil
    }

    @MainActor
    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
