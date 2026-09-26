import Foundation

/// Où en est la session dans sa structure Pomodoro.
///
/// Le chrono compte le **travail** : une pause n'est pas du temps compté. La
/// structure se déduit donc du temps écoulé, elle ne le découpe pas. C'est ce qui
/// permet d'afficher « bloc 3, encore 12 min » sans tenir un second compteur qui
/// divergerait du premier.
struct PomodoroStatus: Equatable {
    /// Bloc en cours, à partir de 1.
    var blockNumber: Int
    /// Temps écoulé dans le bloc en cours.
    var elapsedInBlock: TimeInterval
    /// Temps restant avant la pause conseillée.
    var remaining: TimeInterval
    /// Blocs entièrement terminés.
    var completedBlocks: Int

    var progress: Double {
        let total = elapsedInBlock + remaining
        guard total > 0 else { return 0 }
        return min(1, max(0, elapsedInBlock / total))
    }

    /// Le bloc est fini : c'est le moment de proposer la pause.
    var isBlockComplete: Bool { remaining <= 0 }

    /// « Bloc 3 », ou « Bloc 3 · 2 terminés ».
    var label: String { "Bloc \(blockNumber)" }

    var remainingLabel: String {
        isBlockComplete
            ? "bloc terminé"
            : "reste \(DateUtils.durationLabel(seconds: Int(remaining.rounded(.up))))"
    }
}

/// Découpe une durée de travail en blocs Pomodoro.
enum PomodoroEngine {

    /// Durée d'un bloc, bornée à des valeurs utilisables.
    ///
    /// Un bloc de 0 minute rendrait `remaining` constamment nul et la boucle
    /// d'alerte se déclencherait sans fin ; une durée négative n'a pas de sens.
    static func blockDuration(minutes: Int) -> TimeInterval {
        TimeInterval(max(1, minutes) * 60)
    }

    /// Où en est-on après `elapsed` secondes de travail compté ?
    static func status(elapsed: TimeInterval, focusMinutes: Int) -> PomodoroStatus {
        let block = blockDuration(minutes: focusMinutes)
        let safeElapsed = max(0, elapsed)
        let completed = Int(safeElapsed / block)
        let inBlock = safeElapsed - Double(completed) * block

        // Un bloc exactement terminé (60 min pour un bloc de 60) compte comme fini,
        // pas comme le début du suivant : sinon la pause conseillée n'apparaîtrait
        // jamais à l'instant précis où elle est due.
        if inBlock == 0, completed > 0 {
            return PomodoroStatus(blockNumber: completed,
                                  elapsedInBlock: block,
                                  remaining: 0,
                                  completedBlocks: completed)
        }
        return PomodoroStatus(blockNumber: completed + 1,
                              elapsedInBlock: inBlock,
                              remaining: max(0, block - inBlock),
                              completedBlocks: completed)
    }

    /// Le nombre de blocs entiers restants pour atteindre un objectif de session.
    ///
    /// Sert à dire « encore 2 blocs », qui est plus parlant que « encore 47 min »
    /// quand on travaille par blocs.
    static func blocksRemaining(elapsed: TimeInterval,
                                targetBlocks: Int,
                                focusMinutes: Int) -> Int {
        let block = blockDuration(minutes: focusMinutes)
        let done = Int(max(0, elapsed) / block)
        return max(0, targetBlocks - done)
    }
}
