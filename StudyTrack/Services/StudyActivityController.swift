import ActivityKit
import Foundation
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

    private static func content(_ state: StudyActivityAttributes.ContentState)
        -> ActivityContent<StudyActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: nil)
    }
}
