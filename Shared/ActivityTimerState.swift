import Foundation

/// Ce que la Live Activity doit afficher, et comment le temps s'y écoule.
///
/// **Type pur, sans ActivityKit** : c'est ce qui permet de le tester sur macOS,
/// sans simulateur ni écran verrouillé — et c'est précisément là que se trouvait
/// le bogue.
///
/// L'ancienne version portait `accumulated` **et** `runningSince`, et le compteur
/// système n'affichait que le second : après une pause, il repartait de zéro et
/// annonçait « 00:01 » au lieu d'une heure de travail. Ici, `countingSince` est
/// l'instant de départ **reculé du total déjà écoulé** — `Text(timerInterval:)`
/// affiche donc le total, et continue d'avancer.
struct ActivityTimerState: Codable, Hashable {
    /// Instant depuis lequel le **total** s'écoule. `nil` quand c'est en pause.
    var countingSince: Date?

    /// Le total, figé, quand le chrono est en pause.
    var frozenTotal: TimeInterval

    init(countingSince: Date?, frozenTotal: TimeInterval) {
        self.countingSince = countingSince
        self.frozenTotal = frozenTotal
    }

    /// Construit l'état à publier.
    ///
    /// - Parameters:
    ///   - elapsed: le total réel déjà travaillé.
    ///   - running: le chrono continue-t-il de s'écouler ?
    ///   - now: l'instant de référence, injectable pour les tests.
    static func make(elapsed: TimeInterval,
                     running: Bool,
                     now: Date = Date()) -> ActivityTimerState {
        let total = max(0, elapsed)
        return ActivityTimerState(countingSince: running ? now.addingTimeInterval(-total) : nil,
                                  frozenTotal: total)
    }

    var isRunning: Bool { countingSince != nil }

    /// Total écoulé à cet instant.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let countingSince else { return frozenTotal }
        return max(frozenTotal, now.timeIntervalSince(countingSince))
    }
}
