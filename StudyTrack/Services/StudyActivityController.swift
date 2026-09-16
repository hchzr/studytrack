import ActivityKit
import Foundation

/// Pilote la Live Activity du chrono.
///
/// Volontairement tolérant : si les Live Activities sont désactivées dans les
/// réglages, refusées par le système, ou absentes de cette build, **le chrono
/// continue de fonctionner normalement**. Le suivi du temps ne doit jamais dépendre
/// d'un ornement d'écran verrouillé.
@MainActor
enum StudyActivityController {

    private static var current: Activity<StudyActivityAttributes>?

    /// Démarre l'activité si besoin, la met à jour sinon.
    ///
    /// Appelée à chaque changement d'état du chrono (démarrage, reprise, pause) :
    /// une seule entrée pour les deux cas évite d'avoir à suivre si une activité
    /// est déjà en cours.
    static func sync(attributes: StudyActivityAttributes,
                     state: StudyActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let current {
            Task { await current.update(content(state)) }
        } else {
            current = try? Activity.request(attributes: attributes,
                                            content: content(state),
                                            pushType: nil)
        }
    }

    static func end() {
        guard let activity = current else { return }
        current = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private static func content(_ state: StudyActivityAttributes.ContentState)
        -> ActivityContent<StudyActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: nil)
    }
}
