import Foundation

/// Garder le Mac éveillé pendant le mode étude — et seulement quand ça sert.
///
/// La décision est ici, pure et testée ; l'assertion d'énergie elle-même
/// (IOKit) vit dans l'app Mac (`MacKeepAwake`).
///
/// Le principe : la moindre dépense. On ne tient le Mac éveillé que pendant
/// que le chrono **tourne** — en pause, l'étudiant·e est parti·e et le Mac
/// dort comme d'habitude. L'écran ne reste allumé que si on l'a demandé, et
/// jamais en mode économie d'énergie ni sur une batterie presque vide : là,
/// seul le Mac reste éveillé (la musique continue, le verrou tient, l'écran
/// s'éteint). Fermer le capot endort toujours le Mac.
enum KeepAwakePolicy {

    /// Le réglage.
    enum Mode: String, CaseIterable, Identifiable {
        /// Le Mac dort comme d'habitude.
        case off
        /// Le Mac reste éveillé ; l'écran s'éteint comme d'habitude.
        case system
        /// Le Mac et l'écran restent allumés.
        case display

        var id: String { rawValue }
    }

    /// Ce qu'il faut tenir, maintenant.
    enum Hold: Equatable {
        case system
        case display
    }

    /// En dessous, sur batterie, l'écran n'est plus tenu allumé.
    static let lowBattery = 0.2

    /// Une session sans heure de fin : l'assertion expire d'elle-même au bout
    /// de ce délai, et se renouvelle tant que le chrono tourne. Un plantage ne
    /// peut donc pas laisser le Mac éveillé pour toujours.
    static let openEndedLease: TimeInterval = 2 * 3600
    /// La marge après l'heure de fin prévue (le temps de terminer, de prolonger).
    static let endMargin: TimeInterval = 5 * 60

    struct Power: Equatable {
        var lowPowerMode = false
        var onBattery = false
        /// 0…1, `nil` sans batterie (Mac de bureau).
        var batteryLevel: Double?

        static let plugged = Power()
    }

    static func hold(mode: Mode, studying: Bool, running: Bool, onBreak: Bool, power: Power) -> Hold? {
        guard mode != .off, studying, running || onBreak else { return nil }
        // Pause Pomodoro : on s'éloigne de l'écran, il peut s'éteindre.
        guard mode == .display, !onBreak else { return .system }
        let lowBattery = power.onBattery && (power.batteryLevel ?? 1) < Self.lowBattery
        return power.lowPowerMode || lowBattery ? .system : .display
    }

    /// Quand l'assertion doit expirer d'elle-même.
    static func expiry(until: Date?, now: Date = Date()) -> Date {
        guard let until, until > now else { return now.addingTimeInterval(openEndedLease) }
        return until.addingTimeInterval(endMargin)
    }
}
