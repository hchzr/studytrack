import SwiftUI
import SwiftData

/// La fenêtre : à gauche Aujourd'hui, le Bilan et les cours ; à droite la page.
struct MacRootView: View {
    enum Page: Hashable {
        case today, stats
        case course(UUID)
    }

    @Query(sort: \Course.code) private var courses: [Course]
    @SceneStorage("mac.page") private var storedPage: String = "today"
    @State private var page: Page? = .today

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    Label("Aujourd'hui", systemImage: "sun.max").tag(Page.today)
                    Label("Bilan", systemImage: "chart.bar.xaxis").tag(Page.stats)
                }
                Section("Cours") {
                    ForEach(tracked) { course in
                        CourseSidebarRow(course: course).tag(Page.course(course.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                SyncFooter()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } detail: {
            switch page ?? .today {
            case .today:
                MacTodayView { page = .course($0) }
            case .stats:
                MacStatsView()
            case .course(let id):
                if let course = courses.first(where: { $0.id == id }) {
                    MacCourseView(course: course)
                        .id(course.id)
                } else {
                    ContentUnavailableView("Cours introuvable", systemImage: "books.vertical")
                }
            }
        }
        .onAppear { page = Self.decode(storedPage) }
        .onChange(of: page) { _, value in storedPage = Self.encode(value) }
        .overlay {
            if tracked.isEmpty {
                ContentUnavailableView {
                    Label("Tes cours arrivent de l'iPhone", systemImage: "icloud.and.arrow.down")
                } description: {
                    Text("Importe-les dans StudyTrack sur l'iPhone : iCloud les apporte ici.")
                }
                .background(.background)
            }
        }
    }

    private static func encode(_ page: Page?) -> String {
        switch page {
        case .stats?: return "stats"
        case .course(let id)?: return id.uuidString
        default: return "today"
        }
    }

    private static func decode(_ raw: String) -> Page {
        if raw == "stats" { return .stats }
        if let id = UUID(uuidString: raw) { return .course(id) }
        return .today
    }
}

/// L'état d'iCloud, en une ligne au pied de la barre latérale.
private struct SyncFooter: View {
    @Environment(MacStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Label(text(now: context.date), systemImage: icon)
                .font(.caption)
                .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(2)
        }
    }

    private var isFailure: Bool {
        if case .failed = store.syncState { return true }
        return false
    }

    private var icon: String {
        guard store.isCloudSynced else { return "icloud.slash" }
        switch store.syncState {
        case .working: return "arrow.triangle.2.circlepath.icloud"
        case .failed: return "exclamationmark.icloud"
        default: return "checkmark.icloud"
        }
    }

    private func text(now: Date) -> String {
        guard store.isCloudSynced else { return "iCloud indisponible : données de ce Mac seulement" }
        switch store.syncState {
        case .idle: return "iCloud"
        case .working(let kind): return "iCloud : \(kind)…"
        case .failed(let message): return "iCloud : \(message)"
        case .synced(let date):
            return "Synchronisé " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        }
    }
}

private struct CourseSidebarRow: View {
    let course: Course

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: course.colorHex)).frame(width: 4, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(course.displayCode).font(.callout.weight(.semibold))
                Text(course.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(Int((progress.completion * 100).rounded())) %")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Aujourd'hui

/// La semaine en un coup d'œil : où en est chaque cours, et le temps.
struct MacTodayView: View {
    var openCourse: (UUID) -> Void

    @Environment(MacTimer.self) private var timer
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    private var tracked: [Course] { courses.filter(\.isTracked) }

    private var weekSessions: [StudySession] {
        let start = DateUtils.startOfWeek(Date())
        return sessions.filter { $0.startedAt >= start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(tracked) { course in
                        Button { openCourse(course.id) } label: { WeekCourseCard(course: course) }
                            .buttonStyle(.plain)
                    }
                }
                todaySessions
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Aujourd'hui")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DateUtils.fullDayLabel(Date()).capitalized)
                    .font(.system(size: 28, weight: .regular, design: .serif))
                if let week = tracked.first?.currentWeek, week > 0 {
                    Text("Semaine \(week)").foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(DateUtils.hoursLabel(seconds: weekSessions.reduce(0) { $0 + $1.durationSeconds }))
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .monospacedDigit()
                Text("depuis lundi").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var todaySessions: some View {
        let today = sessions.filter { Calendar.current.isDateInToday($0.startedAt) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions du jour").font(.system(.title3, design: .serif))
            if today.isEmpty {
                Text(timer.phase == .idle ? "Rien encore. Le chrono est dans la barre des menus." : "Une session est en cours.")
                    .foregroundStyle(.secondary)
            } else {
                GroupBox {
                    ForEach(today) { session in
                        SessionRow(session: session)
                        if session.id != today.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

/// Un cours dans la semaine : théorie et exercices de la semaine, le retard.
private struct WeekCourseCard: View {
    let course: Course

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
                    Text("À jour").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(course.name).font(.system(.title3, design: .serif)).lineLimit(2)
            HStack(spacing: 14) {
                meter("Théorie", week.watchedCount, week.videoCount, tint)
                meter("Exercices", week.doneCount, week.exerciseCount, tint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .contentShape(Rectangle())
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.taskType.icon)
                .foregroundStyle(session.course.map { Color(hex: $0.colorHex) } ?? .secondary)
                .frame(width: 20)
            Text(session.course?.displayCode ?? "Sans cours").fontWeight(.medium)
            Text(session.taskType.label).foregroundStyle(.secondary)
            if let target = session.targetLabel {
                Text(target).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(DateUtils.time.string(from: session.startedAt)).foregroundStyle(.secondary).monospacedDigit()
            Text(session.durationLabel).monospacedDigit().frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
