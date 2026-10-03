import SwiftUI
import SwiftData

/// Dans la barre des menus : une icône au repos ; le temps qui court pendant
/// une session (« 24:13 »), ou ce qui reste du bloc en Pomodoro.
struct MenuBarLabel: View {
    @Environment(MacTimer.self) private var timer

    var body: some View {
        switch timer.phase {
        case .idle:
            Image(systemName: "timer")
        case .running, .paused:
            HStack(spacing: 4) {
                Image(systemName: timer.phase == .paused ? "pause.fill" : "timer")
                Text((timer.pomodoroRemaining ?? timer.elapsed).clockLabel)
                    .monospacedDigit()
            }
        }
    }
}

/// Le panneau du chrono : sur quoi, combien, et les trois gestes.
struct MenuBarTimerView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var course: Course? { tracked.first { $0.id == timer.courseID } }

    private var todaySeconds: Int {
        sessions.prefix(60).filter { Calendar.current.isDateInToday($0.startedAt) }.reduce(0) { $0 + $1.durationSeconds }
    }

    var body: some View {
        @Bindable var timer = timer
        VStack(alignment: .leading, spacing: 14) {
            dial

            if timer.phase == .idle {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Cours", selection: $timer.courseID) {
                        Text("Sans cours").tag(UUID?.none)
                        ForEach(tracked) { course in
                            Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                        }
                    }
                    Picker("Travail", selection: $timer.taskType) {
                        ForEach(TaskType.choices) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle("Pomodoro (\(timer.pomodoroMinutes) min)", isOn: $timer.pomodoro)
                        .toggleStyle(.checkbox)
                }
                Button {
                    timer.start()
                } label: {
                    Label("Démarrer", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 8) {
                    Button {
                        timer.toggle()
                    } label: {
                        Label(timer.phase == .running ? "Pause" : "Reprendre",
                              systemImage: timer.phase == .running ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    Button {
                        timer.stop(context: context)
                    } label: {
                        Label("Terminer", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                if timer.elapsed < 60 {
                    Text("Moins d'une minute : rien ne sera enregistré.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Text("Aujourd'hui")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(DateUtils.hoursLabel(seconds: todaySeconds + (timer.phase == .idle ? 0 : Int(timer.elapsed))))
                    .monospacedDigit()
            }
            .font(.callout)

            HStack {
                Button("Ouvrir StudyTrack") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                if timer.phase != .idle {
                    Button("Annuler la session", role: .destructive) { timer.discard() }
                        .foregroundStyle(.secondary)
                }
                Button("Quitter") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Le temps, en grand ; sur quoi, dessous.
    private var dial: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((timer.pomodoroRemaining ?? timer.elapsed).clockLabel)
                .font(.system(size: 44, weight: .light, design: .serif))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
            HStack(spacing: 6) {
                if let course {
                    Circle().fill(Color(hex: course.colorHex)).frame(width: 8, height: 8)
                    Text(course.displayCode).fontWeight(.medium)
                }
                Text(timer.taskType.label).foregroundStyle(.secondary)
                if timer.pomodoro, timer.phase != .idle {
                    Text("· Pomodoro").foregroundStyle(.secondary)
                }
                if timer.phase == .paused {
                    Text("· en pause").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }
}
