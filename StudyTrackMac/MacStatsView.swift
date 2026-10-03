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
            colors[code] = session.course.map { Color(hex: $0.colorHex) } ?? .gray
        }
        return seconds.map { CourseSlice(code: $0.key, color: colors[$0.key] ?? .gray, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        let total = studySessions.reduce(0) { $0 + $1.durationSeconds }
        let days = Set(studySessions.map { DateUtils.startOfDay($0.startedAt) }).count
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 32) {
                    figure(DateUtils.hoursLabel(seconds: total), "d'étude")
                    figure("\(studySessions.count)", studySessions.count > 1 ? "sessions" : "session")
                    figure("\(days)", days > 1 ? "jours actifs" : "jour actif")
                    Spacer()
                }

                HStack(alignment: .top, spacing: 18) {
                    card("Jour par jour") {
                        Chart(bars) { bar in
                            BarMark(x: .value("Jour", bar.day, unit: .day), y: .value("Heures", bar.hours))
                                .foregroundStyle(by: .value("Travail", bar.category))
                                .cornerRadius(3)
                        }
                        .chartXScale(domain: range.start...range.end)
                        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h)) h") } }
                        } }
                        .frame(height: 220)
                    }
                    card("Par matière") {
                        if slices.isEmpty {
                            Text("Rien sur cette période.").foregroundStyle(.secondary).frame(height: 220)
                        } else {
                            HStack(spacing: 18) {
                                Chart(slices) { slice in
                                    SectorMark(angle: .value("Temps", slice.seconds), innerRadius: .ratio(0.6), angularInset: 1.5)
                                        .foregroundStyle(slice.color)
                                        .cornerRadius(3)
                                }
                                .frame(width: 170, height: 170)
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(slices) { slice in
                                        HStack {
                                            Circle().fill(slice.color).frame(width: 8, height: 8)
                                            Text(slice.code)
                                            Spacer()
                                            Text(DateUtils.hoursLabel(seconds: slice.seconds)).monospacedDigit().foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .frame(height: 220)
                        }
                    }
                    .frame(maxWidth: 420)
                }

                card("Sessions") {
                    let shown = Array(studySessions.prefix(40))
                    if shown.isEmpty {
                        Text("Aucune session sur la période.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { session in
                        Button { editing = session } label: {
                            HStack {
                                Text(DateUtils.relativeLabel(session.startedAt)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                SessionRow(session: session)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if session.id != shown.last?.id { Divider() }
                    }
                }
            }
            .padding(28)
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
                .frame(width: 200)
            }
            if period == .week {
                ToolbarItemGroup {
                    Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
                        .help("Semaine précédente")
                    Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(weekOffset >= 0)
                        .help("Semaine suivante")
                }
            }
        }
        .onChange(of: period) { _, _ in weekOffset = 0 }
        .sheet(item: $editing) { SessionEditor(session: $0) }
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 30, weight: .regular, design: .serif)).monospacedDigit()
            Text(caption).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(.title3, design: .serif))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
    }
}

/// Corriger une session : sa durée, sa date, son cours — ou la supprimer.
private struct SessionEditor: View {
    @Bindable var session: StudySession
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
        .frame(width: 420)
        .onAppear { minutes = max(1, session.durationSeconds / 60) }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Supprimer", role: .destructive) {
                    context.delete(session)
                    try? context.save()
                    dismiss()
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
