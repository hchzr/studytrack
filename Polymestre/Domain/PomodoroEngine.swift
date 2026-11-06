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

    /// « Bloc 3 », ou « Bloc 3 · 2 terminés » (traduit).
    var label: String { String(localized: "Bloc \(blockNumber)") }

    var remainingLabel: String {
        isBlockComplete
            ? String(localized: "bloc terminé")
            : String(localized: "reste \(DateUtils.durationLabel(seconds: Int(remaining.rounded(.up))))")
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

    /// Où en est-on après `elapsed` secondes de travail compté ? `origin` : le travail déjà
    /// compté quand le cycle a commencé (Pomodoro allumé en cours de séance).
    static func status(elapsed: TimeInterval, focusMinutes: Int, origin: TimeInterval = 0) -> PomodoroStatus {
        let block = blockDuration(minutes: focusMinutes)
        let safeElapsed = max(0, elapsed - origin)
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

}

// MARK: - Le cycle : travail, pause, travail

/// Ce que dure chaque temps du cycle, lu dans les réglages.
struct PomodoroSettings: Codable, Equatable {
    var focusMinutes: Int = 25
    var shortBreakMinutes: Int = 5
    var longBreakMinutes: Int = 15
    /// Une pause longue tous les `longBreakEvery` blocs.
    var longBreakEvery: Int = 4
    /// À la fin d'une pause, le bloc suivant démarre-t-il seul ?
    ///
    /// Non par défaut : revenir à sa table est un geste, et un chrono qui
    /// repartirait pendant qu'on est encore à la machine à café compterait du
    /// travail qui n'a pas eu lieu.
    var autoStartFocus: Bool = false

    var blockDuration: TimeInterval { PomodoroEngine.blockDuration(minutes: focusMinutes) }

    func breakDuration(_ kind: PomodoroBreak) -> TimeInterval {
        TimeInterval(max(1, kind == .long ? longBreakMinutes : shortBreakMinutes) * 60)
    }

    /// La pause qui suit le bloc numéro `completedBlocks`.
    func breakKind(afterBlock completedBlocks: Int) -> PomodoroBreak {
        let every = max(2, longBreakEvery)
        return completedBlocks > 0 && completedBlocks % every == 0 ? .long : .short
    }
}

enum PomodoroBreak: String, Codable, Equatable {
    case short, long

    var label: String { self == .long ? "Pause longue" : "Pause" }
}

/// Ce qui vient de se passer dans le cycle — pour l'haptique et le journal.
enum PomodoroEvent: Equatable {
    /// Un bloc de travail vient de finir ; la pause démarre.
    case blockEnded(block: Int, kind: PomodoroBreak)
    /// La pause est finie ; le bloc suivant attend (ou démarre, si réglé ainsi).
    case breakEnded(nextBlock: Int)
}

/// Où en est une session, du point de vue de ce qu'il faut afficher.
///
/// Déduit de l'état persisté, jamais stocké : il ne peut pas diverger.
enum FocusPhase: Equatable {
    /// Rien n'a encore été compté.
    case idle
    /// Le travail est compté.
    case working
    /// Le travail est suspendu, en dehors de toute pause Pomodoro.
    case paused
    /// Une pause Pomodoro décompte jusqu'à `endsAt`.
    case onBreak(PomodoroBreak, startedAt: Date, endsAt: Date)
    /// La pause est finie : le bloc suivant attend un geste.
    case readyForBlock(Int)

    var isBreak: Bool {
        if case .onBreak = self { return true }
        return false
    }
}

extension FocusTimerState {

    /// La pause en cours, s'il y en a une.
    var currentBreak: (kind: PomodoroBreak, startedAt: Date, endsAt: Date)? {
        guard let raw = breakKindRaw, let kind = PomodoroBreak(rawValue: raw),
              let start = breakStartedAt, let end = breakEndsAt else { return nil }
        return (kind, start, end)
    }

    /// La phase à afficher à l'instant `now`, **après** `advance`.
    func phase(settings: PomodoroSettings, at now: Date = Date()) -> FocusPhase {
        if let current = currentBreak {
            return .onBreak(current.kind, startedAt: current.startedAt, endsAt: current.endsAt)
        }
        if isRunning { return .working }
        let total = elapsed(at: now)
        guard total >= 1 else { return .idle }
        if pomodoro {
            let block = settings.blockDuration
            let relative = max(0, total - cycleOriginSeconds)
            let completed = Int((relative / block).rounded(.down))
            // Pile sur une frontière de bloc, à l'arrêt : c'est la fin d'une pause.
            if completed > 0, abs(relative - Double(completed) * block) < 0.5 {
                return .readyForBlock(completed + 1)
            }
        }
        return .paused
    }

    /// Fait avancer le cycle jusqu'à `now`, et dit ce qui s'est passé.
    ///
    /// **Tout se déduit des dates.** Une app fermée pendant la fin d'un bloc ne
    /// rate rien : au retour, on retrouve l'instant exact où le bloc a fini, le
    /// travail est coupé **à cet instant** — les minutes passées en pause ne sont
    /// pas comptées comme du travail — et la pause a commencé là.
    ///
    /// Hors Pomodoro, la fonction ne fait rien.
    @discardableResult
    mutating func advance(settings: PomodoroSettings, to now: Date = Date()) -> [PomodoroEvent] {
        guard pomodoro else {
            clearBreak()
            return []
        }
        var events: [PomodoroEvent] = []
        let block = settings.blockDuration
        // Borne de sécurité : une session ne compte jamais des centaines de
        // cycles, mais une date corrompue ne doit pas faire boucler l'app.
        for _ in 0..<64 {
            if let current = currentBreak {
                guard now >= current.endsAt else { break }
                clearBreak()
                let next = Int((cycleAccumulated / block).rounded(.down)) + 1
                events.append(.breakEnded(nextBlock: next))
                if settings.autoStartFocus {
                    runningSince = current.endsAt
                    continue
                }
                break
            }
            guard let since = runningSince else { break }
            let relative = cycleAccumulated
            let nextBoundary = ((relative / block).rounded(.down) + 1) * block
            let boundaryDate = since.addingTimeInterval(nextBoundary - relative)
            guard now >= boundaryDate else { break }
            accumulated = cycleOriginSeconds + nextBoundary
            runningSince = nil
            let completed = Int((nextBoundary / block).rounded())
            let kind = settings.breakKind(afterBlock: completed)
            breakKindRaw = kind.rawValue
            breakStartedAt = boundaryDate
            breakEndsAt = boundaryDate.addingTimeInterval(settings.breakDuration(kind))
            events.append(.blockEnded(block: completed, kind: kind))
        }
        return events
    }

    /// Termine la pause maintenant et relance le travail.
    mutating func skipBreak(at now: Date = Date()) {
        guard currentBreak != nil else { return }
        clearBreak()
        start(at: now)
    }

    /// Allonge la pause en cours.
    mutating func extendBreak(by seconds: TimeInterval) {
        guard let end = breakEndsAt else { return }
        breakEndsAt = end.addingTimeInterval(seconds)
    }

    mutating func clearBreak() {
        breakKindRaw = nil
        breakStartedAt = nil
        breakEndsAt = nil
    }

    /// Quand le bloc en cours finira, si le travail est compté.
    func blockEndDate(settings: PomodoroSettings) -> Date? {
        guard pomodoro, let since = runningSince else { return nil }
        let block = settings.blockDuration
        let relative = cycleAccumulated
        let nextBoundary = ((relative / block).rounded(.down) + 1) * block
        return since.addingTimeInterval(nextBoundary - relative)
    }

    // MARK: Le cycle compté depuis son début

    /// Le travail compté à l'entrée du cycle (voir `cycleOrigin`).
    var cycleOriginSeconds: TimeInterval { cycleOrigin ?? 0 }

    /// Le travail arrêté **dans le cycle** : ce que `accumulated` valait depuis son début.
    var cycleAccumulated: TimeInterval { max(0, accumulated - cycleOriginSeconds) }

    /// Le travail compté dans le cycle à l'instant `now`.
    func cycleElapsed(at now: Date = Date()) -> TimeInterval { max(0, elapsed(at: now) - cycleOriginSeconds) }

    /// Allume ou coupe le Pomodoro **en cours de séance**. Allumé, le premier bloc part
    /// de maintenant (le temps déjà travaillé n'est pas perdu : il reste compté, hors cycle) ;
    /// coupé, la pause en cours s'arrête et le travail reprend.
    mutating func setPomodoro(_ enabled: Bool, at now: Date = Date()) {
        guard enabled != pomodoro else { return }
        if enabled {
            // Le temps qui court est mis dans le compte, pour que l'origine soit exacte.
            if let since = runningSince {
                accumulated += max(0, now.timeIntervalSince(since))
                runningSince = now
            }
            cycleOrigin = accumulated
        } else {
            let wasOnBreak = currentBreak != nil
            clearBreak()
            cycleOrigin = nil
            if wasOnBreak { start(at: now) }
        }
        pomodoro = enabled
    }
}
