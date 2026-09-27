import ActivityKit
import Foundation
import SwiftData
import os

/// Pilote la Live Activity du chrono.
///
/// Volontairement tolérant : si les Live Activities sont désactivées dans les
/// réglages, refusées par le système, ou absentes de cette build, **le chrono
/// continue de fonctionner normalement**. Le suivi du temps ne doit jamais dépendre
/// d'un ornement d'écran verrouillé.
///
/// La source de vérité est `Activity.activities`, **pas** une variable de ce type.
/// Une variable ne survit pas à une relance de l'app ; l'activité, si. C'est ce
/// décalage qui laissait l'îlot afficher un chrono éteint : après un redémarrage,
/// `end()` ne trouvait plus rien à terminer et `sync()` créait une **seconde**
/// activité au lieu de mettre à jour la première.
/// Trace d'exécution de l'îlot, lisible dans le journal unifié.
private let activityTrace = Logger(subsystem: "com.hczr.studytrack", category: "îlot")

@MainActor
enum StudyActivityController {

    /// Ce qui a empêché la dernière tentative, en clair.
    ///
    /// `try?` avalait l'erreur : une Live Activity qui ne s'affiche jamais et une
    /// Live Activity qui s'affiche donnent exactement le même résultat visible —
    /// rien. Un ornement d'écran verrouillé peut échouer sans gravité, mais il ne
    /// doit pas échouer **en silence**.
    private(set) static var lastError: String?

    static var isEnabledBySystem: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Les activités réellement vivantes sur le système.
    private static var live: [Activity<StudyActivityAttributes>] {
        Activity<StudyActivityAttributes>.activities
    }

    /// Démarre l'activité si besoin, la met à jour sinon.
    ///
    /// Appelée à chaque changement d'état du chrono (démarrage, reprise, pause) :
    /// une seule entrée pour les deux cas évite d'avoir à suivre si une activité
    /// est déjà en cours.
    static func sync(attributes: StudyActivityAttributes,
                     state: StudyActivityAttributes.ContentState) {
        // Retenu ici, et pas chez l'appelant : l'écran Focus publie aussi
        // directement, et un cache tenu ailleurs deviendrait faux dès qu'un
        // chemin l'oublierait.
        publishedQuestions = state.questionsLabel
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "Les Live Activities sont désactivées pour StudyTrack."
            AppLog.record(.warning, "îlot", "Live Activities désactivées dans les réglages")
            return
        }

        // Une seule activité à la fois : on reprend celle qui existe, même si elle
        // a été créée par une exécution précédente de l'app.
        if let existing = live.first {
            Task { await existing.update(content(state)) }
            // Une activité en double a pu s'installer avant cette correction :
            // on nettoie les suivantes.
            for extra in live.dropFirst() {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
            lastError = nil
            return
        }

        do {
            let created = try Activity.request(attributes: attributes,
                                               content: content(state),
                                               pushType: nil)
            lastError = nil
            // Trace de vérification : c'est la seule façon de savoir, depuis un
            // terminal, si le **système** accepte l'activité — le simulateur ne
            // photographie pas l'îlot. `Logger` et non `print` : seule la sortie
            // unifiée est lisible depuis la ligne de commande.
            activityTrace.notice("activité créée \(created.id, privacy: .public) — \(self.live.count, privacy: .public) vivante(s)")
        } catch {
            // `\(…)` et non `\\(…)` : la seconde écrit un `\(` **littéral**, et le
            // message affichait le texte de l'expression au lieu de l'erreur.
            lastError = "Démarrage impossible : \(error.localizedDescription)"
            AppLog.record(.error, "îlot", "Live Activity refusée par le système",
                          detail: error.localizedDescription)
        }
    }

    /// Termine **toutes** les activités du chrono.
    ///
    /// Toutes, et pas seulement celle dont ce processus se souvient : c'est la
    /// seule façon de garantir qu'aucun îlot ne survive à un chrono éteint.
    static func end() {
        let running = live
        for activity in running {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        lastError = nil
    }

    /// À appeler au lancement : l'activité doit refléter le chrono, ni plus ni moins.
    ///
    /// Sans ce raccord, une activité laissée par une exécution précédente — app
    /// quittée pendant une session, ou chrono abandonné — restait affichée pour
    /// toujours, y compris après que le chrono a été arrêté.
    static func reconcile(with state: FocusTimerState?) {
        let stillRunning = state?.isRestorable() == true
        if !stillRunning, !live.isEmpty {
            end()
        }
    }

    /// Le nombre d'activités vivantes — pour le diagnostic.
    static var liveCount: Int { live.count }

    // MARK: Publier depuis le chrono persisté

    /// Le dernier compte de sous-questions publié.
    ///
    /// `ModelContext.didSave` se déclenche à chaque écriture — une série importée,
    /// une note modifiée. Republier l'activité à chaque fois enverrait des dizaines
    /// de mises à jour identiques à ActivityKit, qui les limite. On ne republie
    /// donc que si le compte affiché change réellement.
    private static var publishedQuestions: String?

    /// Publie l'activité depuis l'état persisté du chrono.
    ///
    /// Le chemin unique : l'écran Focus, les commandes de l'écran verrouillé et le
    /// rafraîchissement sur écriture passent tous par ici.
    static func publish(_ state: FocusTimerState, container: AppContainer) {
        let context = ModelContext(container.modelContainer)
        let course = course(for: state, context: context)
        let exercise = exercise(for: state, course: course)
        let content = makeState(elapsed: state.elapsed(),
                                running: state.isRunning,
                                pomodoro: state.pomodoro,
                                focusMinutes: container.settings.pomodoroFocusMinutes,
                                exercise: exercise)
        sync(attributes: attributes(for: state, course: course), state: content)
    }

    /// Republie l'activité si une case a été cochée ailleurs dans l'app.
    ///
    /// Cocher (a) dans la liste des exercices doit faire passer l'îlot de « 3/9 »
    /// à « 4/9 » : l'écran verrouillé et l'app ne peuvent pas montrer deux comptes
    /// différents de la même chose.
    static func refreshQuestions(container: AppContainer) {
        guard !live.isEmpty,
              let state = FocusTimerStore.load(),
              state.isRestorable() || state.isRunning else { return }
        let context = ModelContext(container.modelContainer)
        let exercise = exercise(for: state, course: course(for: state, context: context))
        let label = makeState(elapsed: state.elapsed(),
                              running: state.isRunning,
                              pomodoro: state.pomodoro,
                              focusMinutes: container.settings.pomodoroFocusMinutes,
                              exercise: exercise).questionsLabel
        guard label != publishedQuestions else { return }
        publish(state, container: container)
    }

    /// Le cours de la session, s'il y en a un.
    static func course(for state: FocusTimerState, context: ModelContext) -> Course? {
        guard let id = state.courseID else { return nil }
        return ((try? context.fetch(FetchDescriptor<Course>())) ?? []).first { $0.id == id }
    }

    /// L'exercice visé, s'il en existe un : seul porteur de sous-questions.
    static func exercise(for state: FocusTimerState, course: Course?) -> Exercise? {
        guard let course, let targetID = state.targetID else { return nil }
        return course.allExercises.first { $0.id == targetID }
    }

    /// Ce qui ne change pas de la session : cours, type de travail, cible.
    static func attributes(for state: FocusTimerState,
                           course: Course?) -> StudyActivityAttributes {
        StudyActivityAttributes(courseCode: course?.displayCode ?? "Sans cours",
                               courseName: course?.name ?? "Session libre",
                               taskLabel: state.taskType.label,
                               taskIcon: state.taskType.icon,
                               target: targetLabel(state, course: course))
    }

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

    /// Construit l'état à publier depuis le chrono et sa cible.
    ///
    /// Une seule fonction pour les deux appelants — l'écran Focus et le
    /// gestionnaire des commandes de l'écran verrouillé. Avant, chacun composait
    /// son `ContentState` : mettre en pause depuis l'îlot effaçait donc le compte
    /// de sous-questions et l'anneau, que seul l'écran savait remplir.
    ///
    /// - Parameters:
    ///   - elapsed: temps de travail compté.
    ///   - running: le chrono tourne-t-il ?
    ///   - pomodoro: la session est-elle structurée en blocs ?
    ///   - focusMinutes: la durée d'un bloc, depuis les réglages.
    ///   - exercise: la cible, quand c'est un exercice — seul porteur de
    ///     sous-questions.
    static func makeState(elapsed: TimeInterval,
                          running: Bool,
                          pomodoro: Bool,
                          focusMinutes: Int,
                          exercise: Exercise?) -> StudyActivityAttributes.ContentState {
        var block: ActivityPomodoro?
        if pomodoro {
            let status = PomodoroEngine.status(elapsed: elapsed, focusMinutes: focusMinutes)
            block = ActivityPomodoro.make(blockNumber: status.blockNumber,
                                          elapsedInBlock: status.elapsedInBlock,
                                          remaining: status.remaining,
                                          completedBlocks: status.completedBlocks,
                                          running: running)
        }
        // `hasSubQuestions` et non `leafSubQuestions.isEmpty` : un exercice sans
        // sous-questions ne doit pas publier « 0/0 », qui allumerait le bouton
        // « question suivante » sur une cible qui n'en a aucune.
        let leaves = exercise?.hasSubQuestions == true ? exercise?.leafSubQuestions : nil
        return .make(elapsed: elapsed,
                     running: running,
                     questionsDone: leaves.map { $0.filter(\.isDone).count },
                     questionsTotal: leaves.map(\.count),
                     pomodoro: block)
    }

    /// Lance une activité d'essai, pour vérifier l'îlot sans attendre un chrono.
    ///
    /// Le diagnostic avait un angle mort : impossible de distinguer « le système
    /// refuse l'activité » de « l'activité existe mais l'îlot ne l'affiche pas ».
    static func startTest() {
        sync(attributes: StudyActivityAttributes(courseCode: "TEST-100",
                                                  courseName: "Essai",
                                                  taskLabel: TaskType.theory.label,
                                                  taskIcon: TaskType.theory.icon,
                                                  target: "Vérification"),
             state: StudyActivityAttributes.ContentState.make(elapsed: 90, running: true))
    }

    /// Combien de temps une pause reste « fraîche » sur l'écran verrouillé.
    ///
    /// Un chrono qui tourne n'est jamais périmé : le système le fait avancer seul.
    /// Une pause, si — une session oubliée la veille ne doit pas se présenter comme
    /// une information du moment. `reconcile` ne passe qu'au lancement de l'app :
    /// d'ici là, c'est le système qui la grise.
    static let pausedFreshness: TimeInterval = 2 * 3600

    private static func content(_ state: StudyActivityAttributes.ContentState)
        -> ActivityContent<StudyActivityAttributes.ContentState> {
        ActivityContent(state: state,
                        staleDate: state.isRunning ? nil : Date().addingTimeInterval(pausedFreshness))
    }
}
