import Foundation

/// Le temps d'un « maintiens pour finir » : où en est le doigt, et quand le
/// geste compte comme tenu.
///
/// C'est la seule partie du geste qui puisse se tromper au point qu'on ne
/// termine plus — le défaut signalé : « Maintiens pour finir » ne semblait pas
/// arrêter la session. Le geste est passé de `onLongPressGesture` (rendu au
/// défilement) à un suivi du contact à la milliseconde ; ce qui reste, le calcul
/// du temps et du relâchement, est ici, pur et testé.
struct HoldProgress: Equatable {
    /// Ce que le doigt doit tenir, en secondes. Zéro : un appui suffit.
    let duration: Double
    /// Au-delà de cette distance du point de contact, l'appui se relâche : un
    /// doigt qui glisse défile la page au lieu de terminer la session.
    static let slack: Double = 44

    init(duration: Double) {
        self.duration = max(0, duration)
    }

    /// La fraction tenue (0 → 1) au bout de `elapsed` secondes.
    func fraction(after elapsed: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(elapsed / duration, 0), 1)
    }

    /// Le geste est-il allé au bout ?
    func isComplete(after elapsed: Double) -> Bool { fraction(after: elapsed) >= 1 }

    /// Ce qu'il reste à tenir, pour le dire au doigt.
    func remaining(after elapsed: Double) -> Double {
        max(0, duration - elapsed)
    }

    /// Le contact est-il encore sur le bouton ?
    static func isOnButton(translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) <= slack
    }

    /// L'appui relâché trop tôt mérite-t-il d'être expliqué ? Oui dès que le
    /// doigt a commencé à tenir un geste qui demande du temps : un appui bref
    /// (taper, pas tenir) ne le mérite pas.
    func shouldExplainRelease(after elapsed: Double) -> Bool {
        duration > 0 && !isComplete(after: elapsed) && elapsed >= 0.08
    }
}
