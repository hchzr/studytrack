import SwiftUI
import SwiftData

/// L'horloge de la barre des menus : elle seule bat, et seulement ce qu'il faut.
///
/// L'étiquette d'une `MenuBarExtra` ne suit pas un `TimelineView` de façon
/// fiable : elle relit l'état observé. Plutôt que de faire battre tout le chrono
/// (et avec lui la fenêtre), ce petit objet avance l'heure pour la seule
/// étiquette — chaque seconde si l'on veut les secondes, sinon chaque minute,
/// calée sur la minute de la session. Rien quand le chrono est arrêté.
@MainActor
@Observable
final class MenuBarClock {
    private(set) var now = Date()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored weak var timer: MacTimer?
    @ObservationIgnored weak var settings: MacSettings?

    func update() {
        ticker?.invalidate()
        ticker = nil
        now = Date()
        guard let timer, let settings, settings.showTimeInMenuBar || timer.phase == .onBreak,
              timer.phase == .running || timer.phase == .onBreak else { return }
        let step: TimeInterval = settings.menuBarSeconds ? 1 : 60
        let anchor = FocusTimerState.tickAnchor(timer.state)
        let offset = Date().timeIntervalSince(anchor).truncatingRemainder(dividingBy: step)
        let first = Date().addingTimeInterval(offset >= 0 ? step - offset : -offset)
        let ticker = Timer(fire: first, interval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        ticker.tolerance = step >= 60 ? 2 : 0.05
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }
}

/// Dans la barre des menus : un petit anneau qui se remplit avec le bloc (ou
/// se vide avec la pause), et le temps à côté.
struct MenuBarLabel: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(MenuBarClock.self) private var clock
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            // Toujours là, même fenêtre fermée : c'est d'ici que le mode étude
            // rouvre la fenêtre des cours.
            .onReceive(NotificationCenter.default.publisher(for: .macOpenMainWindow)) { _ in
                MacWindows.openMain(openWindow)
            }
    }

    @ViewBuilder
    private var label: some View {
        if timer.phase == .idle {
            Image(systemName: "timer")
        } else {
            let now = clock.now
            HStack(spacing: 4) {
                Image(nsImage: MenuBarRing.image(progress: timer.ringProgress(at: now), phase: timer.phase,
                                                 studying: timer.isStudying))
                if settings.showTimeInMenuBar {
                    Text(label(at: now)).monospacedDigit()
                }
            }
        }
    }

    private func label(at now: Date) -> String {
        let time = timer.displayTime(at: now)
        if settings.menuBarSeconds { return time.clockLabel }
        return time.minuteLabel(roundingUp: timer.countsDown)
    }
}

extension TimeInterval {
    /// « 24 min », « 1 h 05 » : le temps à la minute, pour la barre des menus.
    func minuteLabel(roundingUp: Bool) -> String {
        let minutes = Int((self / 60).rounded(roundingUp ? .up : .down))
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d", minutes / 60, minutes % 60)
    }
}

/// L'anneau de la barre des menus, dessiné en image « modèle » : le système
/// le teinte comme les autres icônes (clair, sombre, contraste accru).
enum MenuBarRing {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(progress: Double, phase: MacTimer.Phase, studying: Bool = false) -> NSImage {
        // 48 pas suffisent à l'œil, et l'image ne change qu'à chaque pas.
        let step = Int((max(0, min(1, progress)) * 48).rounded())
        let key = "\(step)-\(phase)-\(studying)"
        if let cached = cache[key] { return cached }
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 1.6
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let fraction = phase == .onBreak ? 1 - Double(step) / 48 : Double(step) / 48
            if fraction > 0 {
                let arc = NSBezierPath()
                let center = NSPoint(x: rect.midX, y: rect.midY)
                arc.appendArc(withCenter: center, radius: inset.width / 2, startAngle: 90,
                              endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            NSColor.black.setFill()
            if phase == .paused {
                NSBezierPath(rect: NSRect(x: rect.midX - 2.2, y: rect.midY - 2.5, width: 1.6, height: 5)).fill()
                NSBezierPath(rect: NSRect(x: rect.midX + 0.6, y: rect.midY - 2.5, width: 1.6, height: 5)).fill()
            } else if phase == .onBreak {
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.5, y: rect.midY - 1.5, width: 3, height: 3)).fill()
            } else if studying {
                // Le mode étude : un cadenas minuscule, un rond plein.
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 2.5, y: rect.midY - 2.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        if cache.count > 300 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// Le panneau du chrono.
///
/// Au repos : sur quoi travailler (un clic), le mode, « Démarrer », le mode
/// étude. Pendant une session : le cadran, les gestes, la suite du cours.
/// Après : le récapitulatif.
struct MenuBarTimerView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Course.code) private var courses: [Course]
    /// Le jour seulement : le panneau n'a pas à relire tout l'historique.
    @Query private var today: [StudySession]

    init() {
        let start = TodayTotal.startOfToday
        _today = Query(filter: #Predicate<StudySession> { $0.startedAt >= start })
    }

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var course: Course? { tracked.first { $0.id == timer.courseID } }
    private var tint: Color { timer.phase == .onBreak ? MacStyle.breakTint : MacTargets.tint(course) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if timer.phase == .idle {
                    idle
                } else {
                    running
                }
            }
            .padding(16)
            LiveGoalBar(sessions: today, goal: settings.dailyGoalSeconds)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            PaperRule()
            footer
        }
        .frame(width: 330)
        .background(Carnet.ground)
        .tint(Carnet.ink)
        .animation(.smooth(duration: 0.25), value: timer.phase)
    }

    // MARK: En session

    private var running: some View {
        VStack(spacing: 16) {
            ZStack {
                LiveTimerRing(tint: tint, lineWidth: 7, graduated: true)
                VStack(spacing: 3) {
                    TimerTimeline { date in
                        Text(timer.statusLabel(at: date) ?? course?.displayCode ?? "En cours")
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1)
                            .foregroundStyle(tint)
                    }
                    TimerClockText(font: MacStyle.clock(36))
                    if timer.state?.pomodoro == true {
                        TimerTimeline(interval: 60) { date in
                            if let status = timer.pomodoroStatus(at: date) {
                                PomodoroDots(completed: status.completedBlocks, every: settings.longBreakEvery, tint: tint)
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
            }
            .frame(width: 168, height: 168)
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(Carnet.serif(.headline))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                Text(course?.name ?? "Sans cours")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            TimerControls(size: 50, tint: tint)

            if timer.isStudying {
                Button {
                    StudyModeController.shared.present()
                } label: {
                    Label("Mode étude", systemImage: "moon.stars.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle())
            }

            if let course, timer.phase != .onBreak {
                VStack(alignment: .leading, spacing: 4) {
                    Kicker("Ensuite").padding(.horizontal, 8)
                    UpNextList(course: course, limit: 3)
                }
            }
        }
    }

    // MARK: Au repos

    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let recap = timer.recap {
                RecapCard(recap: recap, courses: tracked)
                PaperRule()
            }
            TimerSetup(courses: tracked, compact: true)
            HStack(spacing: 8) {
                Button {
                    timer.start()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Démarrer")
                        if let course {
                            Text("· \(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))")
                                .lineLimit(1)
                                .opacity(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle(tint: course.map { _ in tint }, large: true))
                .keyboardShortcut(.defaultAction)
                Button {
                    StudyModeController.shared.presentSetup(courseID: timer.courseID)
                } label: {
                    Image(systemName: "moon.stars")
                }
                .buttonStyle(PaperButtonStyle(large: true))
                .help("Mode étude")
            }

        }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                MacWindows.openMain(openWindow)
            } label: {
                Label("Ouvrir StudyTrack", systemImage: "macwindow")
            }
            .labelStyle(.titleAndIcon)
            Spacer()
            Button {
                settings.floatingTimer.toggle()
                MiniTimerPanel.shared.update()
            } label: {
                Image(systemName: settings.floatingTimer ? "pip.fill" : "pip")
            }
            .help(settings.floatingTimer ? "Masquer le chrono" : "Chrono flottant")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Réglages (⌘,)")
            Menu {
                Button("Quitter") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(Carnet.inkSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Ouvrir la fenêtre principale depuis n'importe où, l'app au premier plan
/// (et dans le Dock tant que la fenêtre est ouverte).
enum MacWindows {
    @MainActor
    static func openMain(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
