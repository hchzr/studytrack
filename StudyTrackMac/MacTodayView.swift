import SwiftUI
import SwiftData
import Charts

/// La journée : par quoi commencer (un clic lance le chrono, ou le mode
/// étude), l'horaire du jour, ce qu'il y a à faire, les échéances, le temps du
/// jour et de la semaine, chaque cours.
///
/// Cette page se recalculait **chaque seconde** pendant une session (elle lisait
/// l'heure du chrono) : planning, requête de toutes les sessions, graphique.
/// Elle ne relit plus que les données ; les secondes vivent dans de petites
/// vues à part (`MacClock.swift`).
struct MacTodayView: View {
    var open: (UUID, UUID?) -> Void
    var goFocus: () -> Void

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    /// Huit jours suffisent (aujourd'hui, la semaine, le graphique de 7 jours).
    @Query private var sessions: [StudySession]
    @Query private var events: [LinkedCalendarEvent]

    init(open: @escaping (UUID, UUID?) -> Void, goFocus: @escaping () -> Void) {
        self.open = open
        self.goFocus = goFocus
        let since = DateUtils.addDays(-8, to: DateUtils.startOfDay(Date()))
        _sessions = Query(filter: #Predicate<StudySession> { $0.startedAt >= since },
                          sort: \StudySession.startedAt, order: .reverse)
        let dayStart = DateUtils.startOfDay(Date())
        let dayEnd = DateUtils.addDays(1, to: dayStart)
        _events = Query(filter: #Predicate<LinkedCalendarEvent> { $0.startsAt >= dayStart && $0.startsAt < dayEnd },
                        sort: \LinkedCalendarEvent.startsAt)
    }

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        let todos = DailyPlanner.todos(for: tracked, limit: 9)
        let todayEvents = events.filter { $0.isAcademic && !$0.isSkipped }
        let deadlines = Deadline.upcoming(in: tracked, days: 14)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                nowCard(first: todos.first)
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 22) {
                        todoColumn(Array(todos.dropFirst()))
                        weekCourses
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 22) {
                        if !todayEvents.isEmpty { schedule(todayEvents) }
                        if !deadlines.isEmpty { deadlineList(deadlines) }
                        todaySessions
                        weekChart
                    }
                    .frame(width: 330)
                }
            }
            .padding(Carnet.pagePadding)
            .frame(maxWidth: 1180, alignment: .leading)
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
        return sessions.filter { $0.startedAt >= start && $0.taskType.canonical != .lecture }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    private var header: some View {
        let goal = settings.dailyGoalSeconds
        let week = weekSeconds
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Kicker(weekTitle)
                Text(Self.dayTitle).font(Carnet.serif(34)).foregroundStyle(Carnet.ink)
            }
            Spacer()
            TodayStudyText(savedSeconds: TodayTotal.saved(sessions)) { today in
                AnyView(
                    HStack(spacing: 14) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(DateUtils.hoursLabel(seconds: today))
                                .font(Carnet.clock(28))
                                .foregroundStyle(Carnet.ink)
                            Text("sur \(DateUtils.hoursLabel(seconds: goal)) · \(DateUtils.hoursLabel(seconds: week + (today - TodayTotal.saved(sessions)))) cette semaine")
                                .font(.caption)
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                        ZStack {
                            TimerRing(progress: Double(today) / Double(max(goal, 1)),
                                      tint: today >= goal ? Carnet.correct : MacStyle.goalTint, lineWidth: 5)
                            if today >= goal {
                                Image(systemName: "checkmark").font(.headline).foregroundStyle(Carnet.correct)
                            }
                        }
                        .frame(width: 50, height: 50)
                    }
                )
            }
            .help("Objectif du jour")
        }
    }

    // MARK: Maintenant

    @ViewBuilder
    private func nowCard(first: StudyTodo?) -> some View {
        if timer.phase != .idle {
            RunningNowCard(open: goFocus)
        } else if let todo = first {
            let tint = Carnet.tint(todo.colorHex)
            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4)
                VStack(alignment: .leading, spacing: 5) {
                    Kicker("Pour commencer", color: tint)
                    Text(todo.title).font(Carnet.serif(24)).foregroundStyle(Carnet.ink).lineLimit(1)
                    Text([todo.courseName, todo.kind.label, todo.durationLabel].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(Carnet.inkSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Autre chose…", action: goFocus)
                    .buttonStyle(.plain)
                    .foregroundStyle(Carnet.inkSecondary)
                Button {
                    StudyModeController.shared.presentSetup(courseID: todo.courseID, taskType: todo.taskType,
                                                            targetID: todo.targetID, label: todo.title)
                } label: {
                    Label("Mode étude", systemImage: "moon.stars")
                }
                .buttonStyle(.paperLarge)
                .help("Mode étude")
                Button {
                    timer.start(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID, label: todo.title)
                } label: {
                    Label("Démarrer", systemImage: "play.fill")
                }
                .buttonStyle(InkButtonStyle(tint: tint, large: true))
                .help("Chronométrer")
            }
            .fixedSize(horizontal: false, vertical: true)
            .paperSheet(padding: 20)
            .contextMenu {
                Button("Ouvrir") { open(todo.courseID, todo.targetID) }
            }
        } else {
            HStack {
                Label("Tout est à jour.", systemImage: "checkmark.seal")
                    .foregroundStyle(Carnet.inkSecondary)
                Spacer()
                Button("Session libre", action: goFocus).buttonStyle(.paper)
            }
            .paperSheet(padding: 20)
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
                        if todo.id != todos.last?.id { PaperRule(inset: 40) }
                    }
                }
                .paperSheet(padding: 6)
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

    // MARK: Les cours de la semaine

    private var weekCourses: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: weekTitle)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                ForEach(tracked) { course in
                    Button { open(course.id, nil) } label: { WeekCourseCard(course: course) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Colonne de droite

    private func schedule(_ events: [LinkedCalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Horaire du jour")
            VStack(spacing: 0) {
                ForEach(events) { event in
                    EventLine(event: event)
                    if event.id != events.last?.id { PaperRule(inset: 54) }
                }
            }
            .paperSheet(padding: 6)
        }
    }

    private func deadlineList(_ items: [Deadline]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Échéances", trailing: "14 jours")
            VStack(spacing: 0) {
                ForEach(items.prefix(6)) { item in
                    Button { open(item.courseID, item.targetID) } label: { DeadlineLine(item: item) }
                        .buttonStyle(.plain)
                    if item.id != items.prefix(6).last?.id { PaperRule(inset: 54) }
                }
            }
            .paperSheet(padding: 6)
        }
    }

    @ViewBuilder
    private var todaySessions: some View {
        let today = sessions.filter { Calendar.current.isDateInToday($0.startedAt) }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Sessions du jour",
                         trailing: today.isEmpty ? nil : DateUtils.hoursLabel(seconds: today.reduce(0) { $0 + $1.durationSeconds }))
            VStack(spacing: 0) {
                if today.isEmpty {
                    Text(timer.phase == .idle ? "Pas encore de session." : "Session en cours.")
                        .font(.callout)
                        .foregroundStyle(Carnet.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                ForEach(today) { session in
                    SessionRow(session: session, compact: true)
                        .padding(.horizontal, 10)
                    if session.id != today.last?.id { PaperRule() }
                }
            }
            .paperSheet(padding: 6)
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
                        .foregroundStyle(Double(day.seconds) / 3600 >= goalHours ? Carnet.correct : Carnet.ink.opacity(0.75))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Objectif", goalHours))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(MacStyle.goalTint)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Carnet.rule)
                    AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h)) h") } }
                }
            }
            .frame(height: 120)
            .paperSheet(padding: 14)
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
        let tint = MacTargets.tint(course)
        HStack(spacing: 18) {
            LiveTimerRing(tint: tint, lineWidth: 5)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                TimerTimeline { date in
                    Kicker(timer.isStudying ? "Mode étude" : (timer.statusLabel(at: date) ?? "En cours"), color: tint)
                }
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(Carnet.serif(24))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                Text(course?.name ?? "Session libre").foregroundStyle(Carnet.inkSecondary).lineLimit(1)
            }
            Spacer()
            TimerClockText(font: MacStyle.clock(38))
            TimerControls(size: 40, tint: tint)
            if timer.isStudying {
                Button("Mode étude") { StudyModeController.shared.present() }.buttonStyle(.paper)
            } else {
                Button("Ouvrir", action: open).buttonStyle(.paper)
            }
        }
        .paperSheet(padding: 20, highlighted: tint.opacity(0.5))
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
        let tint = Carnet.tint(todo.colorHex)
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
                    .foregroundStyle(checked ? tint : Carnet.inkTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(todo.kind == .correction ? "Corrigé juste" : "Marquer comme fait")
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title).lineLimit(1)
                    .foregroundStyle(Carnet.ink)
                    .strikethrough(checked)
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text([todo.courseCode, todo.kind.label, todo.durationLabel].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(todo.kind == .redo ? Carnet.wrong : Carnet.inkSecondary)
                        .lineLimit(1)
                }
                .font(.caption)
            }
            Spacer()
            if isTimed {
                Label("En cours", systemImage: "timer").font(.caption).foregroundStyle(Carnet.inkSecondary)
            } else if hovering {
                Button(action: open) { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Carnet.inkSecondary)
                    .help("Ouvrir")
                Button(action: start) {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .help("Chronométrer")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .hoverRow()
        .opacity(checked ? 0.5 : 1)
        .help(todo.detail)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Démarrer", action: start)
            Button("Mode étude…") {
                StudyModeController.shared.presentSetup(courseID: todo.courseID, taskType: todo.taskType,
                                                        targetID: todo.targetID, label: todo.title)
            }
            Button("Ouvrir", action: open)
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
        let tint = Carnet.tint(course.colorHex)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CourseTag(code: course.displayCode, tint: tint)
                Spacer()
                if late > 0 {
                    Text("\(late) en retard").font(.caption.weight(.semibold)).foregroundStyle(Carnet.wrong)
                } else {
                    Label("À jour", systemImage: "checkmark").font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
            }
            Text(course.name).font(Carnet.serif(18)).foregroundStyle(Carnet.ink).lineLimit(2, reservesSpace: true)
            HStack(spacing: 14) {
                meter("Théorie", week.watchedCount, week.videoCount, tint)
                meter("Exercices", week.doneCount, week.exerciseCount, tint)
            }
        }
        .paperSheet(padding: 16, highlighted: hovering ? tint.opacity(0.6) : nil)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func meter(_ title: String, _ done: Int, _ total: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Carnet.inkSecondary)
                Spacer()
                Text("\(done)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(Carnet.ink)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Carnet.rule)
                    Capsule().fill(tint).frame(width: proxy.size.width * min(1, Double(done) / Double(max(total, 1))))
                }
            }
            .frame(height: 4)
        }
    }
}

struct SessionRow: View {
    let session: StudySession
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.taskType.icon)
                .foregroundStyle(Carnet.tint(session.course))
                .frame(width: 20)
            Text(session.course?.displayCode ?? "Sans cours").fontWeight(.medium).foregroundStyle(Carnet.ink)
            if !compact { Text(session.taskType.label).foregroundStyle(Carnet.inkSecondary) }
            if let target = session.targetLabel {
                Text(target).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
            }
            Spacer()
            Text(DateUtils.time.string(from: session.startedAt)).foregroundStyle(Carnet.inkSecondary).monospacedDigit()
            Text(session.durationSeconds < 60 ? "< 1 min" : session.durationLabel)
                .monospacedDigit()
                .foregroundStyle(session.durationSeconds < 60 ? Carnet.inkSecondary : Carnet.ink)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}
