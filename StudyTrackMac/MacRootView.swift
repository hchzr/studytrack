import SwiftUI
import SwiftData

/// La fenêtre : à gauche Aujourd'hui, le Chrono, le Bilan et les cours ; à
/// droite la page. ⌘K (ou ⌘F) ouvre la palette : chercher, ouvrir, chronométrer.
struct MacRootView: View {
    enum Page: Hashable {
        case today, focus, stats
        case course(UUID)
    }

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Course.code) private var courses: [Course]
    @SceneStorage("mac.page") private var storedPage: String = "today"
    @State private var page: Page? = .today
    @State private var showingPalette = false
    /// L'exercice ou l'élément de théorie à montrer à l'ouverture d'un cours
    /// (un résultat de recherche, une ligne « À faire »).
    @State private var focusTarget: UUID?

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    Label("Aujourd'hui", systemImage: "sun.max").tag(Page.today)
                    Label {
                        HStack {
                            Text("Chrono")
                            Spacer()
                            if timer.phase != .idle {
                                Text(timer.displayTime.clockLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "timer")
                    }
                    .tag(Page.focus)
                    Label("Bilan", systemImage: "chart.bar.xaxis").tag(Page.stats)
                }
                Section("Cours") {
                    ForEach(tracked) { course in
                        CourseSidebarRow(course: course, isTimed: timer.phase != .idle && timer.courseID == course.id)
                            .tag(Page.course(course.id))
                            .contextMenu {
                                Button("Chronométrer ce cours") { time(course) }
                                Button("Ouvrir") { page = .course(course.id) }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if timer.phase != .idle, page != .focus {
                        SidebarSessionCard { page = .focus }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    SyncFooter()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .animation(.smooth(duration: 0.3), value: timer.phase == .idle)
            }
        } detail: {
            Group {
                switch page ?? .today {
                case .today:
                    MacTodayView(open: open, goFocus: { page = .focus })
                case .focus:
                    MacFocusView()
                case .stats:
                    MacStatsView()
                case .course(let id):
                    if let course = courses.first(where: { $0.id == id }) {
                        MacCourseView(course: course, focusTarget: $focusTarget)
                            .id(course.id)
                    } else {
                        ContentUnavailableView("Cours introuvable", systemImage: "books.vertical")
                    }
                }
            }
            .toolbar {
                if page != .focus {
                    ToolbarItem(placement: .primaryAction) {
                        ToolbarTimer { page = .focus }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingPalette = true } label: {
                        Label("Rechercher", systemImage: "magnifyingglass")
                    }
                    .help("Chercher, ouvrir, chronométrer (⌘K)")
                }
            }
        }
        .overlay {
            if showingPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { showingPalette = false }
                    CommandPalette(navigate: navigate, dismiss: { showingPalette = false })
                        .padding(.top, 70)
                        .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.1), value: showingPalette)
        .onReceive(NotificationCenter.default.publisher(for: .macFocusSearch)) { _ in showingPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .macGoTo)) { note in
            guard let raw = note.object as? String else { return }
            if raw.hasPrefix("code:"), let course = tracked.first(where: { $0.displayCode == raw.dropFirst(5) }) {
                page = .course(course.id)
            } else {
                page = Self.decode(raw)
            }
        }
        .onAppear {
            page = Self.decode(storedPage)
            NSApp.setActivationPolicy(.regular)
            #if DEBUG
            if CommandLine.arguments.contains("-debugPanel") { openWindow(id: "debugPanel") }
            #endif
        }
        .onDisappear {
            // Fenêtre fermée : StudyTrack vit dans la barre des menus.
            if !settings.keepInDock { NSApp.setActivationPolicy(.accessory) }
        }
        .onChange(of: page) { _, value in storedPage = Self.encode(value) }
        .overlay {
            if tracked.isEmpty {
                ContentUnavailableView {
                    Label("Tes cours arrivent de l'iPhone", systemImage: "icloud.and.arrow.down")
                } description: {
                    Text("Importe-les dans StudyTrack sur l'iPhone : iCloud les apporte ici, en général en moins d'une minute.")
                }
                .background(.background)
            }
        }
    }

    private func open(_ courseID: UUID, _ target: UUID?) {
        focusTarget = target
        page = .course(courseID)
    }

    private func navigate(_ destination: CommandPalette.Destination) {
        switch destination {
        case .page(let value): page = value
        case .target(let course, let item): open(course, item)
        }
    }

    private func time(_ course: Course) {
        if timer.phase == .idle {
            timer.start(courseID: course.id, taskType: .exercise)
        } else {
            timer.retarget(courseID: course.id, taskType: timer.taskType)
        }
    }

    static func encode(_ page: Page?) -> String {
        switch page {
        case .stats?: return "stats"
        case .focus?: return "focus"
        case .course(let id)?: return id.uuidString
        default: return "today"
        }
    }

    static func decode(_ raw: String) -> Page {
        if raw == "stats" { return .stats }
        if raw == "focus" { return .focus }
        if let id = UUID(uuidString: raw) { return .course(id) }
        return .today
    }
}

/// Dans la barre d'outils : le chrono qui tourne (un clic ouvre la page
/// Chrono), ou « Démarrer ».
private struct ToolbarTimer: View {
    @Environment(MacTimer.self) private var timer
    @Query(sort: \Course.code) private var courses: [Course]
    var open: () -> Void

    var body: some View {
        let course = courses.first { $0.id == timer.courseID }
        let tint = timer.phase == .onBreak ? MacStyle.breakTint : MacTargets.tint(course)
        if timer.phase == .idle {
            Button { open() } label: {
                Label("Chrono", systemImage: "timer")
            }
            .help("Ouvrir le chrono (⌘2)")
        } else {
            HStack(spacing: 6) {
                Button { open() } label: {
                    HStack(spacing: 6) {
                        TimerRing(progress: timer.ringProgress, tint: tint, lineWidth: 2.5, draining: timer.phase == .onBreak)
                            .frame(width: 16, height: 16)
                        Text(timer.displayTime.clockLabel)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
                        Text(course?.displayCode ?? "Libre")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Ouvrir le chrono")
                Button { timer.phase == .onBreak ? timer.skipBreak() : timer.toggle() } label: {
                    Image(systemName: timer.phase == .running ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .help(timer.phase == .running ? "Pause (⌘T)" : "Reprendre (⌘T)")
            }
            .padding(.horizontal, 8)
        }
    }
}

/// Au pied de la barre latérale, pendant une session : où on en est.
private struct SidebarSessionCard: View {
    @Environment(MacTimer.self) private var timer
    @Query(sort: \Course.code) private var courses: [Course]
    var open: () -> Void

    var body: some View {
        let course = courses.first { $0.id == timer.courseID }
        let tint = timer.phase == .onBreak ? MacStyle.breakTint : MacTargets.tint(course)
        Button(action: open) {
            HStack(spacing: 10) {
                TimerRing(progress: timer.ringProgress, tint: tint, lineWidth: 3, draining: timer.phase == .onBreak)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timer.displayTime.clockLabel)
                        .font(MacStyle.clock(17, weight: .regular))
                        .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
                    Text(timer.statusLabel ?? MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CourseSidebarRow: View {
    let course: Course
    var isTimed = false

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        let late = ProgressEngine.lateCount(for: course)
        HStack(spacing: 8) {
            ProgressRingMini(value: progress.completion, tint: Color(hex: course.colorHex))
            VStack(alignment: .leading, spacing: 1) {
                Text(course.displayCode).font(.callout.weight(.semibold))
                Text(course.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isTimed {
                Image(systemName: "timer")
                    .font(.caption)
                    .foregroundStyle(Color(hex: course.colorHex))
                    .symbolEffect(.pulse)
                    .help("Chronométré en ce moment")
            }
            if late > 0 {
                Text("\(late)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
                    .help("\(late) en retard")
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProgressRingMini: View {
    let value: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: 3)
            Circle().trim(from: 0, to: value).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .help("\(Int((value * 100).rounded())) %")
    }
}

/// L'état d'iCloud, en une ligne au pied de la barre latérale.
struct SyncFooter: View {
    @Environment(MacStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Label(Self.describe(store.syncState, synced: store.isCloudSynced, now: context.date), systemImage: icon)
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

    static func describe(_ state: MacStore.SyncState, synced: Bool, now: Date) -> String {
        guard synced else { return "iCloud indisponible : données de ce Mac seulement" }
        switch state {
        case .idle: return "iCloud"
        case .working(let kind): return "iCloud : \(kind)…"
        case .failed(let message): return "iCloud : \(message)"
        case .synced(let date):
            let ago = now.timeIntervalSince(date)
            if ago < 60 { return "Synchronisé à l'instant" }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "fr_CH")
            return "Synchronisé " + formatter.localizedString(for: date, relativeTo: now)
        }
    }
}

