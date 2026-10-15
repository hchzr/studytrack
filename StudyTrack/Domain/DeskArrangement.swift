import Foundation

/// Comment le bureau s'arrange selon le moment.
///
/// `DeskMoment` ne choisissait que l'accueil. Ici : l'outil du centre, ce qu'on
/// garde à côté, et ce qui prend l'écran un instant (la pause, la fin qui
/// approche). Une décision pure et testée ; l'appliquer est dans le Mac
/// (`StudyDesk.apply`).
///
/// **Règle d'or : le bureau ne bouge jamais sous les mains.** Il ne se
/// réarrange qu'à un *changement de moment* (`signature`) ; un geste de
/// l'étudiant·e épingle la partie touchée jusqu'au changement suivant.
enum DeskArrangement {

    /// Ce que le bureau sait de la situation.
    struct Context: Equatable {
        var moment: DeskMoment
        /// Le travail est de la théorie (lire, regarder), pas des exercices.
        var isTheory = false
        var phase: SessionSoundtrack.Phase = .running
        /// Un exercice est visé.
        var hasTarget = false
        /// L'exercice visé est fait (à corriger).
        var targetDone = false
        var seriesComplete = false
        var solutionAvailable = false
        var hasCopy = false
        var hasCourseNotes = false
        /// Minutes restantes (`nil` : session sans fin).
        var minutesLeft: Int?
        /// La pause du cours (à +45 min) est en cours.
        var classBreak = false
    }

    /// Les outils du centre (les mêmes valeurs que `StudyDesk.Pane`).
    enum Center: String, Equatable {
        case desk, exercise, course, notes, calc, web, music
    }

    /// Ce qu'on peut garder à côté.
    enum Side: String, Equatable {
        case series, copy, solution, courseNotes, sheet
    }

    enum Takeover: String, Equatable {
        case none, onBreak, paused, wrapUp, classBreak
    }

    struct Layout: Equatable {
        var center: Center
        /// Le premier est ouvert ; les autres sont proposés.
        var side: [Side]
        var sideOpen: Bool
        var takeover: Takeover
        /// Clore la série avec Claude (la série est finie).
        var openClaude: Bool
    }

    /// Cinq minutes avant la fin : le bilan.
    static let wrapUpMinutes = 5

    static func layout(for c: Context) -> Layout {
        let takeover = takeover(for: c)
        var layout = Layout(center: .desk, side: [], sideOpen: false, takeover: takeover, openClaude: false)
        switch c.moment {
        case .lecture:
            // En cours : l'accueil du cours (la semaine, le repère). Rien à côté.
            break
        case .revision:
            layout.side = [.sheet]
            layout.sideOpen = true
        case .series, .together:
            if c.isTheory {
                layout.center = .course
                if c.hasCourseNotes { layout.side = [.courseNotes]; layout.sideOpen = true }
            } else if c.hasTarget {
                layout.center = .exercise
                if c.targetDone && c.solutionAvailable {
                    // Faire → corriger : le corrigé vient à côté de l'énoncé.
                    layout.side = [.solution]
                } else if c.hasCopy {
                    layout.side = [.copy]
                } else if c.hasCourseNotes {
                    layout.side = [.courseNotes]
                }
                layout.sideOpen = !layout.side.isEmpty
                layout.openClaude = c.seriesComplete
            }
        }
        return layout
    }

    static func takeover(for c: Context) -> Takeover {
        if c.classBreak { return .classBreak }
        switch c.phase {
        case .onBreak: return .onBreak
        case .paused: return .paused
        case .ended: return .none
        case .running:
            if let left = c.minutesLeft, left <= wrapUpMinutes { return .wrapUp }
            return .none
        }
    }

    /// La clé d'un moment : quand elle change, le bureau se réarrange. Ni les
    /// minutes qui passent, ni une pause (qu'on reprend) n'y sont : mettre en
    /// pause puis reprendre ne doit pas ramener le bureau à sa place.
    static func signature(_ c: Context) -> String {
        [c.moment.rawValue, c.isTheory ? "t" : "e", c.hasTarget ? "cible" : "-",
         c.targetDone ? "fait" : "-", c.seriesComplete ? "série" : "-", c.solutionAvailable ? "corrigé" : "-",
         c.hasCopy ? "copie" : "-"].joined(separator: "|")
    }

    /// Les parties du bureau qu'un geste a épinglées.
    struct Pins: Equatable {
        var center = false
        var side = false
        var claude = false

        var isEmpty: Bool { !center && !side && !claude }
    }

    /// À un changement de moment les épingles tombent, sinon elles restent.
    static func pins(_ pins: Pins, previous: String?, current: String) -> Pins {
        previous == current ? pins : Pins()
    }

    /// Ce qu'on peut appliquer : la mise en page, privée de ce que l'étudiant·e
    /// a épinglé.
    static func applicable(_ layout: Layout, pins: Pins) -> (center: Center?, side: [Side]?, claude: Bool) {
        (pins.center ? nil : layout.center, pins.side ? nil : layout.side, !pins.claude && layout.openClaude)
    }
}
