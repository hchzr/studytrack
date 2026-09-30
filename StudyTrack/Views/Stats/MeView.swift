import SwiftUI
import SwiftData

/// L'onglet « Moi » : où j'en suis, à quoi l'app est reliée, et les réglages.
///
/// C'était une feuille « Profil & réglages » ouverte par l'avatar : un sommaire
/// de réglages d'abord, le bilan à un toucher de plus. On ouvre surtout cet
/// onglet pour **voir où on en est** — le bilan vient donc en premier ; les
/// liens (Moodle, calendrier, assistant) disent ensuite s'ils marchent ; les
/// réglages, inchangés, sont au bout d'une ligne.
struct MeView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @Query(sort: \LinkedTask.dueDate) private var tasks: [LinkedTask]
    /// `-settings` (captures) : ouvre les réglages à l'arrivée.
    @State private var debugSettings = false

    var body: some View {
        NavigationStack {
            CarnetScroll {
                identity
                weekStats
                weekChart
                perCourse
                links
                settingsLinks
            }
            .navigationTitle("Moi")
            .navigationDestination(isPresented: $debugSettings) { ProfileView(isEmbedded: true) }
            .onAppear {
                #if DEBUG
                if CommandLine.arguments.contains("-settings") { debugSettings = true }
                #endif
            }
        }
    }

    // MARK: Qui

    private var identity: some View {
        let name = app.settings.displayName.trimmingCharacters(in: .whitespaces)
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return NavigationLink {
            ProfileView(isEmbedded: true)
        } label: {
            HStack(spacing: 14) {
                Text(initials.isEmpty ? "?" : initials)
                    .font(Carnet.serif(.title3, weight: .semibold))
                    .foregroundStyle(Carnet.ground)
                    .frame(width: 52, height: 52)
                    .background(Carnet.ink, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Ton prénom" : name)
                        .font(Carnet.serif(.title3))
                        .foregroundStyle(name.isEmpty ? Carnet.inkTertiary : Carnet.ink)
                    Text(app.settings.section?.name ?? "Section non renseignée")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(14)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Bilan

    private var tracked: [Course] { courses.filter(\.isTracked) }

    private var weekSessions: [StudySession] {
        let start = DateUtils.startOfWeek(Date())
        return sessions.filter { $0.startedAt >= start }
    }

    private var weekStats: some View {
        let seconds = weekSessions.reduce(0) { $0 + $1.durationSeconds }
        let expected = tracked.reduce(0) { $0 + WorkloadEngine.expectedWeeklySeconds(for: $1, hoursPerCredit: app.settings.hoursPerCredit) }
        let progress = tracked.map { ProgressEngine.progress(for: $0) }
        let done = progress.reduce(0) { $0 + $1.watchedCount + $1.doneCount }
        let total = progress.reduce(0) { $0 + $1.videoCount + $1.exerciseCount }
        let corrected = tracked.flatMap(\.allExercises).filter { $0.correctness != nil }
        let right = corrected.filter { $0.correctness == .correct }.count
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Cette semaine") {
                NavigationLink("Bilan complet") { StatsView() }
            }
            HStack(spacing: 8) {
                CarnetStat(label: "Travail", value: DateUtils.hoursLabel(seconds: seconds),
                           detail: expected > 0 ? "objectif \(DateUtils.hoursLabel(seconds: expected))" : nil)
                CarnetStat(label: "Fait", value: "\(Int((CourseProgress.ratio(done, total) * 100).rounded())) %",
                           detail: "du semestre")
                CarnetStat(label: "Juste", value: corrected.isEmpty ? "—" : "\(Int((Double(right) / Double(corrected.count) * 100).rounded())) %",
                           detail: corrected.isEmpty ? "rien de corrigé" : "\(corrected.count) corrigés")
            }
        }
    }

    private var weekChart: some View {
        let days = SessionStats.dailyTotals(sessions, days: 7)
        let peak = max(days.map(\.seconds).max() ?? 0, 1)
        let byType = Dictionary(grouping: weekSessions, by: { $0.taskType.canonical })
            .mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Calendar.current.isDateInToday(day.day) ? Carnet.ink : Carnet.inkTertiary)
                            .frame(height: max(4, 70 * CGFloat(day.seconds) / CGFloat(peak)))
                        Text(DateUtils.weekdayInitial(day.day))
                            .font(.caption2)
                            .foregroundStyle(Carnet.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel("\(DateUtils.fullDayLabel(day.day)) : \(DateUtils.hoursLabel(seconds: day.seconds))")
                }
            }
            .frame(height: 92, alignment: .bottom)
            HStack(spacing: 14) {
                ForEach([TaskType.theory, .exercise, .correction], id: \.self) { type in
                    Text("\(type.label) \(DateUtils.hoursLabel(seconds: byType[type] ?? 0))")
                }
            }
            .font(.caption)
            .foregroundStyle(Carnet.inkSecondary)
        }
        .padding(14)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    @ViewBuilder
    private var perCourse: some View {
        if !tracked.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle("Par cours")
                CarnetSheet {
                    ForEach(Array(tracked.enumerated()), id: \.element.id) { index, course in
                        let seconds = weekSessions.filter { $0.course?.id == course.id }.reduce(0) { $0 + $1.durationSeconds }
                        let completion = ProgressEngine.progress(for: course).completion
                        Button {
                            app.router.openCourse(course.id)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2).fill(Carnet.tint(course.colorHex)).frame(width: 4, height: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(course.name).font(.body).foregroundStyle(Carnet.ink).lineLimit(1)
                                    CarnetBar(value: completion, tint: Carnet.tint(course.colorHex))
                                }
                                Text(DateUtils.hoursLabel(seconds: seconds))
                                    .font(Carnet.mono(.footnote))
                                    .foregroundStyle(Carnet.inkSecondary)
                                    .frame(minWidth: 52, alignment: .trailing)
                            }
                            .padding(.horizontal, Carnet.rowInset)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < tracked.count - 1 { CarnetRule(inset: 30) }
                    }
                }
            }
        }
    }

    // MARK: Liens

    private var links: some View {
        let settings = app.settings
        let moodle = courses.contains { MoodleCourseMatcher.linkedID(in: $0.contentSources) != nil }
        let refreshed = settings.contentLastRefresh.map { "lu \(DateUtils.relativeLabel($0))" }
        let tasksConnected = !settings.todoistToken.isEmpty || !settings.microsoftToken.isEmpty
            || !settings.googleRefreshToken.isEmpty || !settings.tickTickToken.isEmpty
            || !settings.notionToken.isEmpty || !settings.webhookURL.isEmpty || settings.thingsEnabled
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Relié à")
            CarnetSheet {
                linkRow(icon: "books.vertical", tint: Carnet.tint("#F97316"),
                        title: "Moodle · Courseware · Botafogo",
                        status: moodle ? (refreshed ?? "relié") : "à relier", ok: moodle) {
                    app.router.openContentImport()
                }
                CarnetRule()
                NavigationLink {
                    ProfileView(isEmbedded: true)
                } label: {
                    linkLabel(icon: "calendar", tint: Carnet.tint("#0EA5E9"), title: "Horaire IS-Academia",
                              status: settings.timetableURLString.isEmpty ? "à relier" : "relié",
                              ok: !settings.timetableURLString.isEmpty)
                }
                .buttonStyle(.plain)
                CarnetRule()
                NavigationLink {
                    TaskIntegrationsView()
                } label: {
                    linkLabel(icon: "checklist", tint: Carnet.tint("#10B981"), title: "Tâches et rappels",
                              status: tasksConnected ? "relié" : "Rappels iOS", ok: true)
                }
                .buttonStyle(.plain)
                CarnetRule()
                NavigationLink {
                    AssistantSettingsView()
                } label: {
                    linkLabel(icon: "sparkles", tint: Carnet.tint("#8B5CF6"), title: "Assistant IA (MCP)",
                              status: settings.assistantToken.isEmpty ? "à relier" : "relié",
                              ok: !settings.assistantToken.isEmpty)
                }
                .buttonStyle(.plain)
                CarnetRule()
                NavigationLink {
                    AnkiSettingsView()
                } label: {
                    linkLabel(icon: "rectangle.stack", tint: Carnet.tint("#EC4899"), title: "Anki",
                              status: settings.isAnkiConfigured ? "relié" : "facultatif", ok: settings.isAnkiConfigured)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func linkRow(icon: String, tint: Color, title: String, status: String, ok: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            linkLabel(icon: icon, tint: tint, title: title, status: status, ok: ok)
        }
        .buttonStyle(.plain)
    }

    private func linkLabel(icon: String, tint: Color, title: String, status: String, ok: Bool) -> some View {
        CarnetRow(icon: icon, tint: tint, title: title) {
            Text(status)
                .font(.footnote)
                .foregroundStyle(ok ? Carnet.correct : Carnet.inkTertiary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
        }
    }

    // MARK: Réglages

    private var settingsLinks: some View {
        CarnetSheet {
            NavigationLink {
                ProfileView(isEmbedded: true)
            } label: {
                CarnetRow(icon: "gearshape", tint: Carnet.inkSecondary, title: "Réglages",
                          subtitle: "Semestre, notifications, chrono, compte, données") {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
