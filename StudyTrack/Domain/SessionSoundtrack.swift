import Foundation

/// La bande-son d'une session : une playlist qui démarre avec le mode étude,
/// se tait pendant les pauses et s'éteint à la fin.
///
/// La décision est ici, pure et testée ; jouer, baisser le volume, mettre en
/// pause est dans `StudyKit/Music/StudySoundtrack.swift`.
enum SessionSoundtrack {

    /// Une playlist ou un album choisi pour les sessions.
    struct Choice: Codable, Equatable {
        enum Kind: String, Codable { case playlist, album }
        var kind: Kind
        var id: String
        var title: String
        var shuffled = true
    }

    /// Ce que fait la musique pendant une pause (Pomodoro, pause du cours).
    enum BreakPolicy: String, Codable, CaseIterable {
        case pause, lower, keep
    }

    /// Où en est la session, vue de la musique.
    enum Phase: Equatable {
        case running, onBreak, paused, ended
    }

    enum Action: Equatable {
        case none
        /// Lancer la playlist choisie.
        case start
        case fadeOutAndPause
        case resumeAndFadeIn
        case lower
        case restoreVolume
        case fadeOutAndStop
    }

    /// Ce qu'il faut faire quand la session passe de `previous` à `current`.
    ///
    /// - Jamais pendant un cours : on écoute le cours.
    /// - Rien sans playlist choisie.
    /// - On n'arrête que la musique qu'on a lancée : si elle jouait déjà avant la
    ///   session (la sienne), on la laisse.
    /// - Une pause manuelle ne touche pas à la musique ; seule la pause du
    ///   rythme (Pomodoro, cours) la suit.
    static func action(from previous: Phase?, to current: Phase, moment: DeskMoment, hasChoice: Bool,
                       ownsPlayback: Bool, policy: BreakPolicy) -> Action {
        guard moment != .lecture, hasChoice else {
            // La session finit : si la musique est la nôtre, elle s'éteint quand même.
            return current == .ended && ownsPlayback ? .fadeOutAndStop : .none
        }
        switch (previous, current) {
        case (_, .ended):
            return ownsPlayback ? .fadeOutAndStop : .none
        case (nil, .running), (.ended?, .running):
            return .start
        case (.running?, .onBreak):
            switch policy {
            case .pause: return ownsPlayback ? .fadeOutAndPause : .none
            case .lower: return ownsPlayback ? .lower : .none
            case .keep: return .none
            }
        case (.onBreak?, .running):
            switch policy {
            case .pause: return ownsPlayback ? .resumeAndFadeIn : .none
            case .lower: return ownsPlayback ? .restoreVolume : .none
            case .keep: return .none
            }
        default:
            return .none
        }
    }

    /// Les paliers d'un fondu : `steps` valeurs de `from` à `to` (la dernière est `to`).
    static func fade(from: Double, to: Double, steps: Int) -> [Double] {
        guard steps > 0 else { return [to] }
        return (1...steps).map { from + (to - from) * Double($0) / Double(steps) }
    }

    static func encode(_ choice: Choice?) -> Data? {
        choice.flatMap { try? JSONEncoder().encode($0) }
    }

    static func decode(_ data: Data?) -> Choice? {
        data.flatMap { try? JSONDecoder().decode(Choice.self, from: $0) }
    }
}
