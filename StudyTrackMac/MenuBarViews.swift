import SwiftUI
import SwiftData

/// Dans la barre des menus : un petit anneau qui se remplit avec le bloc (ou
/// se vide avec la pause), et le temps à côté.
struct MenuBarLabel: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings

    var body: some View {
        if timer.phase == .idle {
            Image(systemName: "timer")
        } else {
            HStack(spacing: 4) {
                Image(nsImage: MenuBarRing.image(progress: timer.ringProgress, phase: timer.phase))
                if settings.showTimeInMenuBar {
                    Text(timer.displayTime.clockLabel).monospacedDigit()
                }
            }
        }
    }
}

/// L'anneau de la barre des menus, dessiné en image « modèle » : le système
/// le teinte comme les autres icônes (clair, sombre, contraste accru).
enum MenuBarRing {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(progress: Double, phase: MacTimer.Phase) -> NSImage {
        // 48 pas suffisent à l'œil, et l'image ne change qu'à chaque pas.
        let step = Int((max(0, min(1, progress)) * 48).rounded())
        let key = "\(step)-\(phase)"
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
            if phase == .paused {
                NSColor.black.setFill()
                NSBezierPath(rect: NSRect(x: rect.midX - 2.2, y: rect.midY - 2.5, width: 1.6, height: 5)).fill()
                NSBezierPath(rect: NSRect(x: rect.midX + 0.6, y: rect.midY - 2.5, width: 1.6, height: 5)).fill()
            } else if phase == .onBreak {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.5, y: rect.midY - 1.5, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        if cache.count > 200 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// Le panneau du chrono.
///
/// Au repos : sur quoi travailler (un clic), le mode, « Démarrer ». Pendant une
/// session : le cadran, les gestes, la suite du cours. Après : le récapitulatif.
struct MenuBarTimerView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

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
            GoalBar(seconds: TodayTotal.seconds(sessions, timer: timer), goal: settings.dailyGoalSeconds)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Divider()
            footer
        }
        .frame(width: 330)
        .animation(.smooth(duration: 0.25), value: timer.phase)
    }

    // MARK: En session

    private var running: some View {
        VStack(spacing: 16) {
            ZStack {
                TimerRing(progress: timer.ringProgress, tint: tint, lineWidth: 8, draining: timer.phase == .onBreak)
                VStack(spacing: 3) {
                    Text(timer.statusLabel ?? course?.displayCode ?? "En cours")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(tint)
                    Text(timer.displayTime.clockLabel)
                        .font(MacStyle.clock(timer.displayTime >= 3600 ? 30 : 36))
                        .contentTransition(.numericText(countsDown: timer.phase == .onBreak || timer.state?.pomodoro == true))
                        .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
                    if let status = timer.pomodoroStatus {
                        PomodoroDots(completed: status.completedBlocks, every: settings.longBreakEvery, tint: tint)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(width: 160, height: 160)
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(.headline)
                    .lineLimit(1)
                Text(course?.name ?? "Sans cours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            TimerControls(size: 50, tint: tint)

            if let course, timer.phase != .onBreak {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ensuite").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    UpNextList(course: course, limit: 3)
                }
            }
            if timer.elapsed < 60 {
                Text("Moins d'une minute : rien ne sera enregistré.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Au repos

    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let recap = timer.recap {
                RecapCard(recap: recap, courses: tracked)
                Divider()
            }
            TimerSetup(courses: tracked, compact: true)
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
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            let todos = DailyPlanner.todos(for: tracked, limit: 4)
            if !todos.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("À faire").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    ForEach(todos) { todo in
                        TodoStartRow(todo: todo) {
                            timer.start(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID, label: todo.title)
                        }
                    }
                }
                .padding(.horizontal, -8)
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
            .help(settings.floatingTimer ? "Ne plus afficher le chrono flottant" : "Afficher le chrono flottant pendant les sessions")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Réglages (⌘,)")
            Menu {
                Button("Quitter StudyTrack") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Une chose à faire, un clic pour démarrer le chrono dessus.
struct TodoStartRow: View {
    let todo: StudyTodo
    var start: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: start) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: todo.colorHex)).frame(width: 3, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(todo.title).lineLimit(1)
                    Text([todo.courseCode, todo.kind.label, todo.durationLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(todo.kind == .redo ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color(hex: todo.colorHex))
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(todo.detail.isEmpty ? "Démarrer le chrono là-dessus" : todo.detail)
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
