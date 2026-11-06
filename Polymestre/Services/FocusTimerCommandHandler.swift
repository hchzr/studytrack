import Foundation

/// Relaie au chrono les commandes venues de la Live Activity et de l'écran
/// verrouillé.
///
/// Les boutons de l'îlot s'exécutent dans le processus de l'app
/// (`LiveActivityIntent`), mais leur code est compilé dans l'extension aussi :
/// il ne peut que déposer une commande dans le pont partagé. Ce type la récupère
/// et la confie à `FocusController`, qui seul modifie le chrono — c'est ce qui
/// garantit que l'îlot, le dock et l'écran Focus disent la même chose.
///
/// Posé une fois au lancement. `LiveActivityIntent` lance l'app avant
/// d'exécuter la commande, donc le gestionnaire existe quand elle arrive.
enum FocusTimerCommandHandler {

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
        container.focus.perform(command)
    }
}
