import SwiftUI
import SwiftData
import Charts

/// Le bilan du Mac : le temps d'étude jour par jour, par nature de travail et
/// par cours, puis les sessions — les mêmes chiffres que sur l'iPhone.
struct MacStatsView: View {
    enum Period: String, CaseIterable, Identifiable {
        case week = "Semaine", month = "30 jours"
        var id: String { rawValue }
    }

    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @State private var period: Period = .week
    @State private var weekOffset = 0
    @State private var editing: StudySession?
    /// Une session ajoutée à la main : « Annuler » la retire.
    @State private var creating: StudySession?

    private var range: (start: Date, end: Date) {
        switch period {
        case .week:
            let start = DateUtils.addDays(7 * weekOffset, to: DateUtils.startOfWeek(Date()))
            return (start, DateUtils.addDays(7, to: start))
        case .month:
            let end = DateUtils.addDays(1, to: DateUtils.startOfDay(Date()))
            return (DateUtils.addDays(-30, to: end), end)
        }
    }

    /// L'étude seulement : une session « amphi » saisie à la main n'en est pas.
    private var studySessions: [StudySession] {
        let r = range
        return sessions.filter { $0.startedAt >= r.start && $0.startedAt < r.end && $0.taskType.canonical != .lecture }
    }

    private struct Bar: Identifiable {
        let day: Date
        let category: String
        let hours: Double
        var id: String { "\(day.timeIntervalSince1970)\(category)" }
    }

    private struct CourseSlice: Identifiable {
        let code: String
        let color: Color
        let seconds: Int
        var id: String { code }
    }

    private var bars: [Bar] {
        var totals: [Date: [String: Int]] = [:]
        for session in studySessions {
            totals[DateUtils.startOfDay(session.startedAt), default: [:]][session.taskType.canonical.label, default: 0] += session.durationSeconds
        }
        return totals.flatMap { day, byType in byType.map { Bar(day: day, category: $0.key, hours: Double($0.value) / 3600) } }
    }

    private var slices: [CourseSlice] {
        var seconds: [String: Int] = [:]
        var colors: [String: Color] = [:]
        for session in studySessions {
            let code = session.course?.displayCode ?? "Sans cours"
            seconds[code, default: 0] += session.durationSeconds
            colors[code] = session.course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkTertiary
        }
        return seconds.map { CourseSlice(code: $0.key, color: colors[$0.key] ?? .gray, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    @Environment(MacSettings.self) private var settings

    var body: some View {
        let total = studySessions.reduce(0) { $0 + $1.durationSeconds }
        let dayTotals = Dictionary(grouping: studySessions, by: { DateUtils.startOfDay($0.startedAt) })
            .mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }
        let days = dayTotals.count
        let goalDays = dayTotals.values.filter { $0 >= settings.dailyGoalSeconds }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker("Bilan")
                        Text(rangeTitle).font(Carnet.serif(32)).foregroundStyle(Carnet.ink)
                    }
                    Spacer()
                    Button {
                        let session = StudySession(course: nil, taskType: .exercise,
                                                   startedAt: Date().addingTimeInterval(-3600),
                                                   durationSeconds: 3600, isManual: true)
                        context.insert(session)
                        creating = session
                    } label: {
                        Label("Ajouter", systemImage: "plus")
                    }
                    .buttonStyle(.paper)
                    .help("Ajouter une session")
                }
                HStack(spacing: 36) {
                    figure(DateUtils.hoursLabel(seconds: total), "d'étude")
                    figure(days > 0 ? DateUtils.hoursLabel(seconds: total / days) : "—", "par jour actif")
                    figure("\(days)", days > 1 ? "jours actifs" : "jour actif")
                    figure("\(goalDays)", "objectif atteint")
                    Spacer()
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        dayChart.frame(minWidth: 420)
                        subjectCard.frame(width: 340)
                    }
                    VStack(spacing: 18) {
                        dayChart
                        subjectCard
                    }
                }

                sessionsCard
            }
            .padding(Carnet.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Bilan")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Période", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            ToolbarItemGroup(placement: .navigation) {
                Button { weekOffset -= 1 } label: { Label("Semaine précédente", systemImage: "chevron.left") }
                    .disabled(period != .week)
                    .help("Semaine précédente")
                Button { weekOffset += 1 } label: { Label("Semaine suivante", systemImage: "chevron.right") }
                    .disabled(period != .week || weekOffset >= 0)
                    .help("Semaine suivante")
            }
        }
        .onChange(of: period) { _, _ in weekOffset = 0 }
        .sheet(item: $editing) { SessionEditor(session: $0) }
        .sheet(item: $creating) { SessionEditor(session: $0, isNew: true) }
    }

    private static let categories = TaskType.reportCategories.filter { $0 != .lecture }

    private var rangeTitle: String {
        if period == .month { return "30 derniers jours" }
        if weekOffset == 0 { return "Cette semaine" }
        if weekOffset == -1 { return "La semaine dernière" }
        let r = range
        return "\(DateUtils.shortDay.string(from: r.start)) – \(DateUtils.shortDay.string(from: DateUtils.addDays(-1, to: r.end)))"
    }

    private var dayChart: some View {
        let goal = Double(settings.dailyGoalSeconds) / 3600
        return card("Jour par jour") {
            Chart {
                ForEach(bars) { bar in
                    BarMark(x: .value("Jour", bar.day, unit: .day), y: .value("Heures", bar.hours))
                        .foregroundStyle(by: .value("Travail", bar.category))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Objectif", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(MacStyle.goalTint)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("objectif").font(.caption2).foregroundStyle(Carnet.inkSecondary)
                    }
            }
            .chartXScale(domain: range.start...range.end)
            // Une couleur par travail, toujours la même (celles de l'iPhone).
            .chartForegroundStyleScale(domain: Self.categories.map(\.label), range: Self.categories.map(\.tint))
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: period == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h)) h") } }
            } }
            .frame(height: 220)
        }
    }

    private var subjectCard: some View {
        card("Par matière") {
            if slices.isEmpty {
                Text("Rien sur cette période.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 220)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("Temps", slice.seconds), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(slice.color)
                            .cornerRadius(3)
                    }
                    .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(slices) { slice in
                            HStack(spacing: 6) {
                                Circle().fill(slice.color).frame(width: 8, height: 8)
                                Text(slice.code).lineLimit(1).fixedSize()
                                Spacer(minLength: 6)
                                Text(DateUtils.hoursLabel(seconds: slice.seconds))
                                    .monospacedDigit().foregroundStyle(.secondary).fixedSize()
                            }
                            .font(.callout)
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
    }

    private var sessionsCard: some View {
        card("Sessions") {
            let groups = SessionStats.groupedByDay(Array(studySessions.prefix(80)))
            if groups.isEmpty {
                Text("Rien sur cette période.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                HStack(alignment: .firstTextBaseline) {
                    Text(dayLabel(group.day)).font(Carnet.serif(.callout, weight: .semibold)).foregroundStyle(Carnet.ink)
                    Spacer()
                    Text(DateUtils.hoursLabel(seconds: group.totalSeconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session)
                            .padding(.horizontal, 8)
                            .hoverRow()
                            .onTapGesture(count: 2) { editing = session }
                            .contextMenu {
                                Button("Modifier…") { editing = session }
                                Divider()
                                Button("Supprimer", role: .destructive) {
                                    context.delete(session)
                                    try? context.save()
                                }
                            }
                    }
                }
            }
            Text("Double-clic pour corriger.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    @Environment(\.modelContext) private var context

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        let label = cal.isDateInToday(day) || cal.isDateInYesterday(day) ? DateUtils.relativeLabel(day) : DateUtils.fullDayLabel(day)
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(MacStyle.clock(30)).foregroundStyle(Carnet.ink)
            Text(caption).font(.callout).foregroundStyle(Carnet.inkSecondary)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: title)
            content()
        }
        .macCard()
    }
}

/// Corriger une session : sa durée, sa date, son cours — ou la supprimer.
private struct SessionEditor: View {
    @Bindable var session: StudySession
    var isNew = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var minutes = 0

    var body: some View {
        Form {
            Picker("Cours", selection: Binding(get: { session.course?.id },
                                              set: { id in session.course = courses.first { $0.id == id } })) {
                Text("Sans cours").tag(UUID?.none)
                ForEach(courses.filter(\.isTracked)) { Text("\($0.displayCode) — \($0.name)").tag(UUID?.some($0.id)) }
            }
            Picker("Travail", selection: Binding(get: { session.taskType.canonical }, set: { session.taskType = $0 })) {
                ForEach(TaskType.choices) { Text($0.label).tag($0) }
            }
            DatePicker("Début", selection: $session.startedAt)
            Stepper("Durée : \(DateUtils.durationLabel(seconds: minutes * 60))", value: $minutes, in: 1...720, step: 5)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { minutes = max(1, session.durationSeconds / 60) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isNew {
                    Button("Annuler") {
                        context.delete(session)
                        try? context.save()
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                if !isNew {
                Button("Supprimer", role: .destructive) {
                    context.delete(session)
                    try? context.save()
                    dismiss()
                }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") {
                    session.durationSeconds = minutes * 60
                    try? context.save()
                    dismiss()
                }
            }
        }
    }
}
