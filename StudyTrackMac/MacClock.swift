import SwiftUI

/// Ce qui bat chaque seconde — et **seulement** ça.
///
/// Le chrono ne publie plus l'heure : chaque affichage de secondes est une
/// petite vue sous un `TimelineView`, rafraîchie sur les frontières de seconde
/// de la session (`FocusTimerState.tickAnchor`, la même seconde que l'iPhone).
/// Le reste de la fenêtre — requêtes, planning, graphiques — ne bouge que
/// quand les données ou l'état changent. Une session en pause ne bat pas du
/// tout ; une fenêtre cachée non plus (le système suspend ses `TimelineView`).
struct TickSchedule: TimelineSchedule {
    var anchor: Date
    var interval: TimeInterval = 1
    var active: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard active else {
            var sent = false
            return AnyIterator {
                defer { sent = true }
                return sent ? nil : startDate
            }
        }
        // Mode basse fréquence (écran en veille, app en arrière-plan) : une
        // fois par minute suffit.
        let step = mode == .lowFrequency ? max(interval, 60) : interval
        let offset = startDate.timeIntervalSince(anchor).truncatingRemainder(dividingBy: step)
        var next = startDate.addingTimeInterval(offset >= 0 ? -offset : -(step + offset))
        var first = true
        return AnyIterator {
            if first {
                first = false
                return startDate
            }
            next = next.addingTimeInterval(step)
            return next
        }
    }
}

/// Une vue qui dépend de l'heure du chrono : rafraîchie chaque seconde quand
/// le temps avance, jamais sinon.
struct TimerTimeline<Content: View>: View {
    @Environment(MacTimer.self) private var timer
    /// `60` pour ce qui n'affiche que des minutes.
    var interval: TimeInterval = 1
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        let ticking = timer.phase == .running || timer.phase == .onBreak
        TimelineView(TickSchedule(anchor: FocusTimerState.tickAnchor(timer.state), interval: interval, active: ticking)) { context in
            content(context.date)
        }
    }
}

/// « 24:13 » : le temps du chrono, tel qu'il se lit en grand.
struct TimerClockText: View {
    @Environment(MacTimer.self) private var timer
    var font: Font
    var idle: String?

    var body: some View {
        TimerTimeline { date in
            Text(timer.phase == .idle ? (idle ?? "00:00") : timer.displayTime(at: date).clockLabel)
                .font(font)
                .foregroundStyle(timer.phase == .paused ? Carnet.inkSecondary : Carnet.ink)
                .lineLimit(1)
        }
    }
}

/// L'anneau du chrono, tenu à l'heure.
struct LiveTimerRing: View {
    @Environment(MacTimer.self) private var timer
    var tint: Color
    var lineWidth: CGFloat = 6
    var graduated = false

    var body: some View {
        TimerTimeline { date in
            TimerRing(progress: timer.ringProgress(at: date), tint: timer.phase == .onBreak ? MacStyle.breakTint : tint,
                      lineWidth: lineWidth, draining: timer.phase == .onBreak, graduated: graduated)
        }
    }
}

/// Le temps d'étude du jour, session en cours comprise — à la minute.
struct TodayStudyText: View {
    @Environment(MacTimer.self) private var timer
    let savedSeconds: Int
    var content: (Int) -> AnyView

    var body: some View {
        TimerTimeline(interval: 60) { date in
            content(savedSeconds + (timer.phase == .idle ? 0 : Int(timer.elapsed(at: date))))
        }
    }
}
