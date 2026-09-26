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
            StudyActivityController.publish(state, container: container)
            notify()

        case .resume:
            state.start()
            FocusTimerStore.save(state)
            StudyActivityController.publish(state, container: container)
            notify()

        case .finish:
            save(state, container: container)
            FocusTimerStore.save(nil)
            StudyActivityController.end()
            notify()

        case .nextQuestion:
            // La coche est du travail de l'étudiant·e : elle est écrite avant
            // toute chose, et l'activité n'est republiée qu'ensuite — sinon un
            // appui donnerait un compte qui avance sans que la case soit cochée.
            tickNextQuestion(state, container: container)
            StudyActivityController.publish(state, container: container)
            notify()
        }
    }

    /// Coche la première sous-question non faite de la cible.
    ///
    /// « La première non faite » et non « la suivante d'un curseur » : il n'y a
    /// pas de curseur à tenir, donc rien qui puisse se désynchroniser de ce que
    /// l'app affiche. Cocher depuis l'écran verrouillé et cocher dans la liste
    /// écrivent la même chose.
    @MainActor
    private static func tickNextQuestion(_ state: FocusTimerState, container: AppContainer) {
        let context = ModelContext(container.modelContainer)
        guard let course = StudyActivityController.course(for: state, context: context),
              let exercise = StudyActivityController.exercise(for: state, course: course),
              let next = exercise.leafSubQuestions.first(where: { !$0.isDone }) else { return }

        next.isDone = true
        next.doneAt = Date()
        // `refreshCompletion` remonte l'état aux questions parentes puis à
        // l'exercice : `doneAt` reste la seule vérité pour le reste de l'app.
        exercise.refreshCompletion()
        try? context.save()
        WidgetSnapshotWriter.refresh(context: context, settings: container.settings)
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
    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
