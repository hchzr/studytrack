import SwiftUI
import SwiftData

/// La fenêtre : à gauche Aujourd'hui, le Bilan et les cours ; à droite la page.
/// ⌘F cherche partout (cours, séries, exercices, théorie, évaluations).
struct MacRootView: View {
    enum Page: Hashable {
        case today, stats
        case course(UUID)
    }

    @Query(sort: \Course.code) private var courses: [Course]
    @SceneStorage("mac.page") private var storedPage: String = "today"
    @State private var page: Page? = .today
    @State private var query = ""
    /// L'exercice ou l'élément de théorie à montrer à l'ouverture d'un cours
    /// (un résultat de recherche, une ligne « À faire »).
    @State private var focusTarget: UUID?

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
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                SyncFooter()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } detail: {
            Group {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    MacSearchResults(query: query) { courseID, target in
                        focusTarget = target
                        page = .course(courseID)
                        query = ""
                    }
                } else {
                    switch page ?? .today {
                    case .today:
                        MacTodayView { courseID, target in
                            focusTarget = target
                            page = .course(courseID)
                        }
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
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Cours, série, exercice…")
        .modifier(SearchShortcut())
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

private struct CourseSidebarRow: View {
    let course: Course

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

// MARK: - Aujourd'hui

/// La journée : ce qu'il y a à faire (un clic pour s'y mettre), la semaine de
/// chaque cours, le temps.
struct MacTodayView: View {
    var open: (UUID, UUID?) -> Void

    @Environment(MacTimer.self) private var timer
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    private var tracked: [Course] { courses.filter(\.isTracked) }

    private var weekSessions: [StudySession] {
        let start = DateUtils.startOfWeek(Date())
        return sessions.filter { $0.startedAt >= start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                // Côte à côte quand la fenêtre est large, l'un sous l'autre sinon.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 22) {
                        todoColumn
                            .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
                        todaySessions
                            .frame(width: 300, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 26) {
                        todoColumn
                        todaySessions
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(weekTitle).font(.system(.title3, design: .serif))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
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

    /// « Dimanche 4 octobre » : la majuscule au premier mot seulement.
    private static var dayTitle: String {
        let label = DateUtils.fullDayLabel(Date())
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private var weekTitle: String {
        if let week = tracked.first?.currentWeek, week > 0 { return "Semaine \(week)" }
        return "Cette semaine"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.dayTitle)
                .font(.system(size: 30, weight: .regular, design: .serif))
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DateUtils.hoursLabel(seconds: weekSessions.reduce(0) { $0 + $1.durationSeconds }))
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .monospacedDigit()
                Text("depuis lundi").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: À faire

    private var todoColumn: some View {
        let todos = DailyPlanner.todos(for: tracked, limit: 8)
        return VStack(alignment: .leading, spacing: 10) {
            Text("À faire").font(.system(.title3, design: .serif))
            if todos.isEmpty {
                Text("Rien en retard ni pour cette semaine. Bien joué.")
                    .foregroundStyle(.secondary)
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(todos) { todo in
                            TodoRow(todo: todo,
                                    isTimed: timer.phase != .idle && timer.targetID == todo.targetID,
                                    open: { open(todo.courseID, todo.targetID) },
                                    start: {
                                        if timer.phase == .idle {
                                            timer.start(courseID: todo.courseID, taskType: todo.taskType,
                                                        targetID: todo.targetID, label: todo.title)
                                        } else {
                                            timer.retarget(courseID: todo.courseID, taskType: todo.taskType, targetID: todo.targetID)
                                        }
                                    },
                                    complete: { complete(todo) })
                            if todo.id != todos.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    /// Cocher depuis « À faire » : l'exercice est fait, la théorie vue.
    private func complete(_ todo: StudyTodo) {
        guard let course = tracked.first(where: { $0.id == todo.courseID }) else { return }
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

    @ViewBuilder
    private var todaySessions: some View {
        let today = sessions.filter { Calendar.current.isDateInToday($0.startedAt) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sessions du jour").font(.system(.title3, design: .serif))
                Spacer()
                Text(DateUtils.hoursLabel(seconds: today.reduce(0) { $0 + $1.durationSeconds }))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            if today.isEmpty {
                Text(timer.phase == .idle ? "Pas encore de session. ⌃⌥Espace lance le chrono." : "Une session est en cours.")
                    .foregroundStyle(.secondary)
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(today) { session in
                            SessionRow(session: session, compact: true)
                            if session.id != today.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }
}

private struct TodoRow: View {
    let todo: StudyTodo
    let isTimed: Bool
    var open: () -> Void
    var start: () -> Void
    var complete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: complete) {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(todo.kind == .correction ? "Corrigé juste" : "Marquer comme fait")
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: todo.colorHex)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(todo.title).lineLimit(1)
                Text([todo.courseCode, todo.kind.label, todo.durationLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(todo.kind == .redo ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer()
            if isTimed {
                Label("En cours", systemImage: "timer").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(action: start) {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: todo.colorHex))
                .opacity(hovering ? 1 : 0.35)
                .help("Démarrer le chrono là-dessus")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(hovering ? AnyShapeStyle(tint.opacity(0.6)) : AnyShapeStyle(.separator)))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: 8, y: 3)
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
            Text(session.durationLabel).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Recherche

/// Les résultats de ⌘F : un clic ouvre le cours, sur l'élément trouvé.
struct MacSearchResults: View {
    let query: String
    var open: (UUID, UUID?) -> Void

    @Query(sort: \Course.code) private var courses: [Course]

    var body: some View {
        let tracked = courses.filter(\.isTracked)
        let hits = SearchEngine.search(query, in: SearchIndexBuilder.documents(courses: tracked))
            .filter { [.course, .series, .exercise, .theory, .exam].contains($0.kind) }
        let groups = Dictionary(grouping: hits, by: \.kind)
        List {
            if hits.isEmpty {
                Text("Rien pour « \(query) ».").foregroundStyle(.secondary)
            }
            ForEach(groups.keys.sorted(), id: \.self) { kind in
                Section(kind.label) {
                    ForEach(groups[kind] ?? []) { hit in
                        Button {
                            if let target = resolve(hit, in: tracked) { open(target.course, target.item) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: kind.icon).foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hit.document.title)
                                    if !hit.document.subtitle.isEmpty {
                                        Text(hit.document.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let code = hit.document.courseCode {
                                    Text(code).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Recherche")
    }

    /// `exercise.<uuid>` → le cours et l'exercice.
    private func resolve(_ hit: SearchHit, in courses: [Course]) -> (course: UUID, item: UUID?)? {
        let parts = hit.document.id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch hit.kind {
        case .course: return (id, nil)
        case .series:
            return courses.first { $0.series.contains { $0.id == id } }.map { ($0.id, $0.series.first { $0.id == id }?.exercises.first?.id) }
        case .exercise:
            return courses.first { $0.allExercises.contains { $0.id == id } }.map { ($0.id, id) }
        case .theory:
            return courses.first { $0.theoryItems.contains { $0.id == id } }.map { ($0.id, id) }
        case .exam:
            return courses.first { $0.exams.contains { $0.id == id } }.map { ($0.id, nil) }
        default: return nil
        }
    }
}


/// ⌘F met le curseur dans la recherche (macOS 15 et plus).
private struct SearchShortcut: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($focused)
                .onReceive(NotificationCenter.default.publisher(for: .macFocusSearch)) { _ in focused = true }
        } else {
            content
        }
    }
}
