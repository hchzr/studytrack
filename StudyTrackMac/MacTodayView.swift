import SwiftUI
import SwiftData
import Charts

/// La journée : par quoi commencer (un clic lance le chrono), ce qu'il y a à
/// faire, le temps du jour et de la semaine, chaque cours.
struct MacTodayView: View {
    var open: (UUID, UUID?) -> Void
    var goFocus: () -> Void

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        let todos = DailyPlanner.todos(for: tracked, limit: 9)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                nowCard(first: todos.first)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        todoColumn(Array(todos.dropFirst()))
                            .frame(minWidth: 400, maxWidth: .infinity, alignment: .topLeading)
                        VStack(spacing: 20) {
                            todaySessions
                            weekChart
                        }
                        .frame(width: 320)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        todoColumn(Array(todos.dropFirst()))
                        todaySessions
                        weekChart
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: weekTitle)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                        ForEach(tracked) { course in
                            Button { open(course.id, nil) } label: { WeekCourseCard(course: course) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Aujourd'hui")
    }

    // MARK: En-tête

    /// « Dimanche 4 octobre » : la majuscule au premier mot seulement.
    private static var dayTitle: String {
        let label = DateUtils.fullDayLabel(Date())
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private var weekTitle: String {
        if let week = tracked.first?.currentWeek, week > 0 { return "Semaine \(week)" }
        return "Cette semaine"
    }

    private var weekSeconds: Int {
        let start = DateUtils.startOfWeek(Date())
        return sessions.filter { $0.startedAt >= start }.reduce(0) { $0 + $1.durationSeconds }
    }

    private var header: some View {
        let today = TodayTotal.seconds(sessions, timer: timer)
        let goal = settings.dailyGoalSeconds
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dayTitle).font(MacStyle.title(30))
                Text("\(weekTitle) · \(DateUtils.hoursLabel(seconds: weekSeconds + (timer.phase == .idle ? 0 : Int(timer.elapsed)))) depuis lundi")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(DateUtils.hoursLabel(seconds: today))
                        .font(MacStyle.clock(26, weight: .regular))
                    Text("sur \(DateUtils.hoursLabel(seconds: goal)) aujourd'hui")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ZStack {
                    TimerRing(progress: Double(today) / Double(max(goal, 1)), tint: today >= goal ? .green : MacStyle.goalTint, lineWidth: 6)
                    if today >= goal {
                        Image(systemName: "checkmark").font(.headline).foregroundStyle(.green)
                    }
                }
                .frame(width: 50, height: 50)
            }
            .help("Objectif du jour, modifiable dans les Réglages")
        }
    }

    // MARK: Maintenant

    @ViewBuilder
    private func nowCard(first: StudyTodo?) -> some View {
        if timer.phase != .idle {
            RunningNowCard(open: goFocus)
        } else if let todo = first {
            let tint = Color(hex: todo.colorHex)
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 3).fill(tint.gradient).frame(width: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pour commencer")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(tint)
                    Text(todo.title).font(MacStyle.title(22)).lineLimit(1)
                    Text([todo.courseName, todo.kind.label, todo.durationLabel].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Autre chose…", action: goFocus)
                    .buttonStyle(.borderless)
                Button {
                    timer.start(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID, label: todo.title)
                } label: {
                    Label("Démarrer", systemImage: "play.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.large)
                .help("Démarrer le chrono là-dessus")
            }
            .fixedSize(horizontal: false, vertical: true)
            .macCard(padding: 18)
            .contextMenu {
                Button("Ouvrir dans le cours") { open(todo.courseID, todo.targetID) }
            }
        } else {
            HStack {
                Label("Rien en retard ni pour cette semaine. Bien joué.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Session libre", action: goFocus)
            }
            .macCard(padding: 18)
        }
    }

    // MARK: À faire

    @ViewBuilder
    private func todoColumn(_ todos: [StudyTodo]) -> some View {
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Ensuite")
                VStack(spacing: 0) {
                    ForEach(todos) { todo in
                        TodoRow(todo: todo,
                                isTimed: timer.phase != .idle && timer.targetID == todo.targetID,
                                open: { open(todo.courseID, todo.targetID) },
                                start: { start(todo) },
                                complete: { complete(todo) })
                        if todo.id != todos.last?.id { Divider().padding(.leading, 40) }
                    }
                }
                .macCard(padding: 6)
            }
        }
    }

    private func start(_ todo: StudyTodo) {
        if timer.phase == .idle {
            timer.start(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID, label: todo.title)
        } else {
            timer.retarget(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID)
        }
    }

    /// Cocher depuis « À faire » : l'exercice est fait, la théorie vue.
    private func complete(_ todo: StudyTodo) {
        guard let course = tracked.first(where: { $0.id == todo.courseID }) else { return }
        withAnimation(.smooth(duration: 0.3)) {
            if let exercise = course.allExercises.first(where: { $0.id == todo.targetID }) {
                if todo.kind == .redo {
                    exercise.redoRequired = false
                } else if todo.kind == .correction {
                    exercise.correct(.correct)
                } else {
                    exercise.setDone(true)
                }
            } else if let item = course.theoryItems.first(where: { $0.id == todo.targetID }) {
                item.watchedAt = item.watchedAt ?? Date()
            }
            try? context.save()
        }
    }

    // MARK: Temps

    @ViewBuilder
    private var todaySessions: some View {
        let today = sessions.filter { Calendar.current.isDateInToday($0.startedAt) }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Sessions du jour",
                         trailing: today.isEmpty ? nil : DateUtils.hoursLabel(seconds: today.reduce(0) { $0 + $1.durationSeconds }))
            VStack(spacing: 0) {
                if today.isEmpty {
                    Text(timer.phase == .idle ? "Pas encore de session. ⌃⌥Espace lance le chrono, d'où que tu sois." : "Une session est en cours.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                ForEach(today) { session in
                    SessionRow(session: session, compact: true)
                        .padding(.horizontal, 8)
                    if session.id != today.last?.id { Divider() }
                }
            }
            .macCard(padding: 6)
        }
    }

    private var weekChart: some View {
        let days = SessionStats.dailyTotals(sessions.filter { $0.taskType.canonical != .lecture }, days: 7)
        let goalHours = Double(settings.dailyGoalSeconds) / 3600
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "7 derniers jours")
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value("Jour", day.day, unit: .day), y: .value("Heures", Double(day.seconds) / 3600))
                        .foregroundStyle(Double(day.seconds) / 3600 >= goalHours ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(MacStyle.goalTint.opacity(0.75).gradient))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Objectif", goalHours))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h)) h") } }
                }
            }
            .frame(height: 120)
            .macCard(padding: 14)
        }
    }
}

/// La session en cours, en grand, sur Aujourd'hui.
private struct RunningNowCard: View {
    @Environment(MacTimer.self) private var timer
    @Query(sort: \Course.code) private var courses: [Course]
    var open: () -> Void

    var body: some View {
        let course = courses.first { $0.id == timer.courseID }
        let tint = timer.phase == .onBreak ? MacStyle.breakTint : MacTargets.tint(course)
        HStack(spacing: 16) {
            ZStack {
                TimerRing(progress: timer.ringProgress, tint: tint, lineWidth: 5, draining: timer.phase == .onBreak)
            }
            .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(timer.statusLabel ?? "En cours")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(tint)
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(MacStyle.title(22))
                    .lineLimit(1)
                Text(course?.name ?? "Session libre").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(timer.displayTime.clockLabel)
                .font(MacStyle.clock(36))
                .contentTransition(.numericText())
                .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
            TimerControls(size: 40, tint: tint)
            Button("Ouvrir", action: open).buttonStyle(.borderless)
        }
        .macCard(padding: 18)
    }
}

private struct TodoRow: View {
    let todo: StudyTodo
    let isTimed: Bool
    var open: () -> Void
    var start: () -> Void
    var complete: () -> Void
    @State private var hovering = false
    @State private var checked = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { checked = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    complete()
                }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checked ? AnyShapeStyle(Color(hex: todo.colorHex)) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(todo.kind == .correction ? "Corrigé juste" : "Marquer comme fait")
            VStack(alignment: .leading, spacing: 1) {
                Text(todo.title).lineLimit(1)
                    .strikethrough(checked)
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: todo.colorHex)).frame(width: 6, height: 6)
                    Text([todo.courseCode, todo.kind.label, todo.durationLabel].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(todo.kind == .redo ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .font(.caption)
            }
            Spacer()
            if isTimed {
                Label("En cours", systemImage: "timer").font(.caption).foregroundStyle(.secondary)
            } else if hovering {
                Button(action: open) { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Ouvrir dans le cours")
                Button(action: start) {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: todo.colorHex))
                .help("Démarrer le chrono là-dessus")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .hoverRow()
        .opacity(checked ? 0.5 : 1)
        .help(todo.detail)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Démarrer le chrono", action: start)
            Button("Ouvrir dans le cours", action: open)
            Divider()
            Button(todo.kind == .correction ? "Corrigé juste" : "Marquer comme fait", action: complete)
        }
    }
}

/// Un cours dans la semaine : théorie et exercices de la semaine, le retard.
private struct WeekCourseCard: View {
    let course: Course
    @State private var hovering = false

    var body: some View {
        let week = ProgressEngine.weekProgress(for: course, week: course.currentWeek)
        let late = ProgressEngine.lateCount(for: course)
        let tint = Color(hex: course.colorHex)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(course.displayCode).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                if late > 0 {
                    Text("\(late) en retard").font(.caption.weight(.semibold)).foregroundStyle(.red)
                } else {
                    Label("À jour", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(course.name).font(MacStyle.title(18)).lineLimit(2, reservesSpace: true)
            HStack(spacing: 14) {
                meter("Théorie", week.watchedCount, week.videoCount, tint)
                meter("Exercices", week.doneCount, week.exerciseCount, tint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: MacStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MacStyle.cardRadius, style: .continuous)
            .strokeBorder(hovering ? AnyShapeStyle(tint.opacity(0.6)) : AnyShapeStyle(.separator.opacity(0.6))))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: 8, y: 3)
        .scaleEffect(hovering ? 1.01 : 1)
        .contentShape(Rectangle())
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
    }

    private func meter(_ title: String, _ done: Int, _ total: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(done)/\(total)").font(.caption.monospacedDigit())
            }
            ProgressView(value: Double(done), total: Double(max(total, 1))).tint(tint)
        }
    }
}

struct SessionRow: View {
    let session: StudySession
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.taskType.icon)
                .foregroundStyle(session.course.map { Color(hex: $0.colorHex) } ?? .secondary)
                .frame(width: 20)
            Text(session.course?.displayCode ?? "Sans cours").fontWeight(.medium)
            if !compact { Text(session.taskType.label).foregroundStyle(.secondary) }
            if let target = session.targetLabel {
                Text(target).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(DateUtils.time.string(from: session.startedAt)).foregroundStyle(.secondary).monospacedDigit()
            Text(session.durationSeconds < 60 ? "< 1 min" : session.durationLabel)
                .monospacedDigit()
                .foregroundStyle(session.durationSeconds < 60 ? .secondary : .primary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
