import SwiftUI
import SwiftData

/// Dans la barre des menus : une icône au repos ; le temps qui court pendant
/// une session (ou ce qui reste du bloc, de la pause).
struct MenuBarLabel: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings

    var body: some View {
        switch timer.phase {
        case .idle:
            Image(systemName: "timer")
        case .running, .paused, .onBreak:
            HStack(spacing: 4) {
                Image(systemName: icon)
                if settings.showTimeInMenuBar {
                    Text(timer.displayTime.clockLabel).monospacedDigit()
                }
            }
        }
    }

    private var icon: String {
        switch timer.phase {
        case .paused: return "pause.fill"
        case .onBreak: return "cup.and.saucer.fill"
        default: return "timer"
        }
    }
}

/// Le panneau du chrono.
///
/// Au repos : ce qu'il y a à faire, un clic pour s'y mettre. Pendant une
/// session : sur quoi, combien, et les gestes — passer à l'exercice suivant
/// sans couper le chrono.
struct MenuBarTimerView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var course: Course? { tracked.first { $0.id == timer.courseID } }
    private var todos: [StudyTodo] { DailyPlanner.todos(for: tracked, limit: 4) }

    private var todaySeconds: Int {
        sessions.prefix(80).filter { Calendar.current.isDateInToday($0.startedAt) }.reduce(0) { $0 + $1.durationSeconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dial
                .padding(16)
            Divider()
            if timer.phase == .idle {
                idleContent
            } else {
                sessionControls
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: Cadran

    private var dial: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: ringProgress)
                Image(systemName: timer.phase == .onBreak ? "cup.and.saucer.fill" : "timer")
                    .font(.title3)
                    .foregroundStyle(tint)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.phase == .idle ? "00:00" : timer.displayTime.clockLabel)
                    .font(.system(size: 34, weight: .light, design: .serif))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: timer.phase == .onBreak))
                    .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var tint: Color {
        if timer.phase == .onBreak { return .green }
        return course.map { Color(hex: $0.colorHex) } ?? .accentColor
    }

    /// Le bloc Pomodoro (ou la pause) qui s'écoule ; le quart d'heure sinon.
    private var ringProgress: CGFloat {
        guard let state = timer.state else { return 0 }
        if let pause = state.currentBreak {
            let total = pause.endsAt.timeIntervalSince(pause.startedAt)
            return total > 0 ? CGFloat(1 - timer.displayTime / total) : 0
        }
        let block = state.pomodoro ? settings.pomodoro.blockDuration : 3600
        return CGFloat(timer.elapsed.truncatingRemainder(dividingBy: block) / block)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let course { parts.append(course.displayCode) }
        if let target = targetLabel { parts.append(target) } else { parts.append(timer.taskType.label) }
        if let status = timer.statusLabel { parts.append(status) }
        if timer.phase == .idle, parts.count <= 1 { return "Prêt" }
        return parts.joined(separator: " · ")
    }

    private var targetLabel: String? {
        guard let id = timer.targetID, let course else { return nil }
        if let exercise = course.allExercises.first(where: { $0.id == id }) { return exercise.displayNumber }
        if let item = course.theoryItems.first(where: { $0.id == id }) { return item.number.isEmpty ? item.title : "Théorie \(item.number)" }
        return nil
    }

    // MARK: Au repos

    @ViewBuilder
    private var idleContent: some View {
        @Bindable var timer = timer
        VStack(alignment: .leading, spacing: 12) {
            if !todos.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("À faire").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                    ForEach(todos) { todo in
                        TodoStartRow(todo: todo) {
                            timer.start(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID, label: todo.title)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Session libre").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    Picker("Cours", selection: $timer.courseID) {
                        Text("Sans cours").tag(UUID?.none)
                        ForEach(tracked) { course in
                            Text(course.displayCode).tag(UUID?.some(course.id))
                        }
                    }
                    .labelsHidden()
                    Picker("Travail", selection: $timer.taskType) {
                        ForEach(TaskType.choices) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                HStack {
                    Toggle("Pomodoro", isOn: $timer.pomodoro)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                    Button {
                        timer.targetID = nil
                        timer.start()
                    } label: {
                        Label("Démarrer", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
    }

    // MARK: En session

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if timer.phase == .onBreak {
                    Button { timer.skipBreak() } label: {
                        Label("Reprendre le travail", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button { timer.toggle() } label: {
                        Label(timer.phase == .running ? "Pause" : "Reprendre",
                              systemImage: timer.phase == .running ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                Button { timer.finish() } label: {
                    Label("Terminer", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)

            if !todos.isEmpty {
                Menu {
                    ForEach(todos) { todo in
                        Button("\(todo.courseCode) · \(todo.title)") {
                            timer.retarget(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID)
                        }
                    }
                } label: {
                    Label("Passer à…", systemImage: "arrow.right.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Changer d'exercice sans couper le chrono : le temps déjà compté reste au précédent.")
            }
            if timer.elapsed < 60 {
                Text("Moins d'une minute : rien ne sera enregistré.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Aujourd'hui \(DateUtils.hoursLabel(seconds: todaySeconds + (timer.phase == .idle ? 0 : Int(timer.elapsed))))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Image(systemName: "macwindow")
            }
            .help("Ouvrir StudyTrack")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Réglages")
            Menu {
                if timer.phase != .idle {
                    Button("Abandonner la session", role: .destructive) { timer.discard() }
                    Divider()
                }
                Button("Quitter StudyTrack") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
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
                Image(systemName: todo.icon)
                    .foregroundStyle(todo.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(todo.title).lineLimit(1)
                    Text([todo.courseCode, todo.kind.label, todo.durationLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
