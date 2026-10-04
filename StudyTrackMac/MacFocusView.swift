import SwiftUI
import SwiftData

/// La page Chrono : le cadran en grand, et tout ce qui tourne autour d'une
/// session — sur quoi, la suite, le temps par exercice, le récapitulatif.
struct MacFocusView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var course: Course? { tracked.first { $0.id == timer.courseID } }
    private var tint: Color { timer.phase == .onBreak ? MacStyle.breakTint : MacTargets.tint(course) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                dial
                    .padding(.top, 12)
                TimerControls(size: 64, tint: tint)
                VStack(spacing: 16) {
                    if let recap = timer.recap, timer.phase == .idle {
                        RecapCard(recap: recap, courses: tracked).macCard()
                    }
                    if timer.phase == .idle {
                        setupCard
                        suggestions
                    } else {
                        targetCard
                        segmentsCard
                    }
                    GoalBar(seconds: TodayTotal.seconds(sessions, timer: timer), goal: settings.dailyGoalSeconds)
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: 520)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Chrono")
        .animation(.smooth(duration: 0.3), value: timer.phase)
        .animation(.smooth(duration: 0.3), value: timer.recap)
    }

    // MARK: Cadran

    private var dial: some View {
        ZStack {
            TimerRing(progress: timer.ringProgress, tint: tint, lineWidth: 12, draining: timer.phase == .onBreak)
            VStack(spacing: 6) {
                Text(statusLine)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(tint)
                Text(timer.phase == .idle ? idleClock : timer.displayTime.clockLabel)
                    .font(MacStyle.clock(timer.displayTime >= 3600 ? 48 : 60))
                    .contentTransition(.numericText(countsDown: timer.phase == .onBreak || timer.state?.pomodoro == true))
                    .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 200)
                if let status = timer.pomodoroStatus, timer.phase != .idle {
                    PomodoroDots(completed: status.completedBlocks, every: settings.longBreakEvery, tint: tint)
                        .padding(.top, 4)
                }
            }
        }
        .frame(width: 280, height: 280)
    }

    private var idleClock: String {
        timer.pomodoro ? TimeInterval(settings.focusMinutes * 60).clockLabel : "00:00"
    }

    private var statusLine: String {
        switch timer.phase {
        case .idle: return timer.pomodoro ? "Pomodoro" : "Prêt"
        case .running: return timer.statusLabel ?? (course?.displayCode ?? "En cours")
        case .paused, .onBreak: return timer.statusLabel ?? "En pause"
        }
    }

    private var headline: String {
        let what = MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID)
        guard let course else { return what }
        return "\(course.displayCode) · \(what)"
    }

    // MARK: Au repos

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Nouvelle session")
            TimerSetup(courses: tracked)
        }
        .macCard()
    }

    @ViewBuilder
    private var suggestions: some View {
        let todos = DailyPlanner.todos(for: tracked, limit: 5)
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Ou directement")
                VStack(spacing: 0) {
                    ForEach(todos) { todo in
                        TodoStartRow(todo: todo) {
                            timer.start(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID, label: todo.title)
                        }
                    }
                }
            }
            .macCard(padding: 12)
        }
    }

    // MARK: En session

    @ViewBuilder
    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "Sur quoi")
                Spacer()
                if let course {
                    TargetMenu(course: course, taskType: timer.taskType, selection: Binding(
                        get: { timer.targetID },
                        set: { timer.retarget(courseID: course.id, taskType: timer.taskType, targetID: $0) }))
                }
            }
            if timer.targetID != nil {
                HStack {
                    Text("Sur cet exercice").foregroundStyle(.secondary)
                    Spacer()
                    Text(timer.targetElapsed.clockLabel).monospacedDigit()
                }
                .font(.callout)
            }
            if let course {
                Divider()
                Text("Ensuite").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                UpNextList(course: course)
            } else {
                Text("Session sans cours : choisis-en un pour répartir le temps.")
                    .font(.callout).foregroundStyle(.secondary)
                Menu("Choisir un cours") {
                    ForEach(tracked) { item in
                        Button(item.displayCode) { timer.retarget(courseID: item.id, taskType: timer.taskType) }
                    }
                }
                .fixedSize()
            }
        }
        .macCard()
    }

    @ViewBuilder
    private var segmentsCard: some View {
        let parts = timer.state?.allocation(at: timer.now) ?? []
        if parts.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Cette session")
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    let partCourse = tracked.first { $0.id == part.courseID }
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(MacTargets.tint(partCourse)).frame(width: 3, height: 14)
                        Text(MacTargets.headline(course: partCourse, taskType: part.taskType, targetID: part.targetID))
                            .lineLimit(1)
                        Spacer()
                        Text(part.seconds.clockLabel).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .macCard()
        }
    }
}
