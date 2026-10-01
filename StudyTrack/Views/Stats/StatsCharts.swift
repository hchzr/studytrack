import SwiftUI
import Charts

/// Les graphiques du bilan, chacun sur sa feuille de papier, chacun touchable.

/// Une part du temps : une catégorie (amphi, théorie…) ou un cours.
struct TimeSlice: Identifiable, Hashable {
    let name: String
    let detail: String
    let seconds: Int
    let color: Color
    var id: String { name }
    var hours: Double { Double(seconds) / 3600 }
}

private struct StatsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }
}

private func percent(_ part: Int, _ total: Int) -> String {
    total == 0 ? "—" : "\(Int((Double(part) / Double(total) * 100).rounded())) %"
}

/// « 1 h d'amphi → 0,8 h de théorie » : ce que deviennent les heures de cours.
private func ratioLabel(_ value: Double) -> String {
    String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
}

// MARK: - Répartition

/// Le temps en une barre : amphi, théorie, séries, correction, Anki — et les
/// rapports qui comptent (théorie par heure d'amphi, séries par heure de théorie).
struct SplitCard: View {
    let slices: [TimeSlice]
    @State private var selected: String?

    private var total: Int { slices.reduce(0) { $0 + $1.seconds } }
    private func seconds(_ name: String) -> Int { slices.first { $0.name == name }?.seconds ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Répartition") {
                if let selected, let slice = slices.first(where: { $0.name == selected }) {
                    Text("\(slice.name) · \(DateUtils.hoursLabel(seconds: slice.seconds)) · \(percent(slice.seconds, total))")
                }
            }
            StatsCard {
                if total == 0 {
                    Text("Rien sur cette période.").font(.subheadline).foregroundStyle(Carnet.inkSecondary)
                } else {
                    Chart(slices) { slice in
                        BarMark(x: .value("Heures", slice.hours), y: .value("Total", "total"), height: .fixed(26))
                            .foregroundStyle(slice.color)
                            .opacity(selected == nil || selected == slice.name ? 1 : 0.35)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartXSelection(value: Binding(
                        get: { nil as Double? },
                        set: { value in
                            guard let value else { selected = nil; return }
                            var cursor = 0.0
                            for slice in slices {
                                cursor += slice.hours
                                if value <= cursor { selected = slice.name; return }
                            }
                        }))
                    .frame(height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .sensoryFeedback(.selection, trigger: selected)

                    FlowLayout(spacing: 14) {
                        ForEach(slices) { slice in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(slice.color).frame(width: 10, height: 10)
                                Text(slice.name).font(.caption).foregroundStyle(Carnet.ink)
                                Text(percent(slice.seconds, total)).font(Carnet.mono(.caption)).foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                    }

                    Rectangle().fill(Carnet.rule).frame(height: 1)
                    HStack(spacing: 0) {
                        ratio(title: "Théorie par h d'amphi",
                              numerator: seconds("Théorie"), denominator: seconds("Amphi"),
                              hint: "h de théorie perso pour 1 h de cours")
                        Rectangle().fill(Carnet.rule).frame(width: 1, height: 44)
                        ratio(title: "Séries par h de théorie",
                              numerator: seconds("Séries"), denominator: seconds("Théorie"),
                              hint: "h d'exercices pour 1 h de théorie")
                        Rectangle().fill(Carnet.rule).frame(width: 1, height: 44)
                        ratio(title: "Corrigé / fait",
                              numerator: seconds("Correction"), denominator: seconds("Séries"),
                              hint: "h de correction pour 1 h d'exercices")
                    }
                }
            }
        }
    }

    private func ratio(title: String, numerator: Int, denominator: Int, hint: String) -> some View {
        VStack(spacing: 3) {
            Text(denominator == 0 ? "—" : ratioLabel(Double(numerator) / Double(denominator)))
                .font(Carnet.serif(.title2))
                .foregroundStyle(Carnet.ink)
            Text(title).font(.caption2).foregroundStyle(Carnet.inkSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
    }
}

// MARK: - Par matière (camembert)

struct CoursePieCard: View {
    let slices: [TimeSlice]
    @State private var angle: Double?

    private var total: Int { slices.reduce(0) { $0 + $1.seconds } }

    private var selected: TimeSlice? {
        guard let angle else { return nil }
        var cursor = 0.0
        for slice in slices {
            cursor += slice.hours
            if angle <= cursor { return slice }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Par matière") { Text("étude + amphi") }
            StatsCard {
                if total == 0 {
                    Text("Rien sur cette période.").font(.subheadline).foregroundStyle(Carnet.inkSecondary)
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        ZStack {
                            Chart(slices) { slice in
                                SectorMark(angle: .value("Heures", slice.hours),
                                           innerRadius: .ratio(0.58),
                                           outerRadius: selected?.name == slice.name ? .ratio(1) : .ratio(0.92),
                                           angularInset: 1.5)
                                    .foregroundStyle(slice.color)
                                    .cornerRadius(3)
                                    .opacity(selected == nil || selected?.name == slice.name ? 1 : 0.4)
                            }
                            .chartAngleSelection(value: $angle)
                            .frame(width: 150, height: 150)
                            VStack(spacing: 0) {
                                Text(DateUtils.hoursLabel(seconds: selected?.seconds ?? total))
                                    .font(Carnet.serif(.title3))
                                    .foregroundStyle(Carnet.ink)
                                Text(selected?.name ?? "au total")
                                    .font(.caption2)
                                    .foregroundStyle(Carnet.inkSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 80)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(slices) { slice in
                                HStack(spacing: 6) {
                                    Circle().fill(slice.color).frame(width: 9, height: 9)
                                    Text(slice.name).font(.caption.weight(.semibold)).foregroundStyle(Carnet.ink).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(percent(slice.seconds, total)).font(Carnet.mono(.caption)).foregroundStyle(Carnet.inkSecondary)
                                }
                                .opacity(selected == nil || selected?.name == slice.name ? 1 : 0.45)
                            }
                        }
                    }
                    if let selected {
                        Text("\(selected.name) — \(selected.detail)")
                            .font(.footnote)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selected?.name)
        }
    }
}

// MARK: - Par cours, par catégorie

struct CourseCategoryBar: Identifiable {
    let course: String
    let category: String
    let seconds: Int
    var id: String { course + category }
    var hours: Double { Double(seconds) / 3600 }
}

/// Chaque cours en une barre, découpée par nature de travail : on voit qu'un
/// cours n'a eu que de l'amphi, qu'un autre n'a eu que des séries.
struct CourseCategoryCard: View {
    let bars: [CourseCategoryBar]
    let categories: [String]
    let colors: [Color]
    @State private var selected: String?

    /// Les natures de travail présentes sur la période, dans l'ordre et leurs couleurs.
    private var present: [(String, Color)] {
        let used = Set(bars.filter { $0.seconds > 0 }.map(\.category))
        return zip(categories, colors).filter { used.contains($0.0) }.map { ($0.0, $0.1) }
    }

    private var courses: [String] {
        let totals = Dictionary(grouping: bars, by: \.course).mapValues { $0.reduce(0) { $0 + $1.seconds } }
        return totals.keys.sorted { totals[$0, default: 0] > totals[$1, default: 0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Cours par nature de travail")
            StatsCard {
                if bars.isEmpty {
                    Text("Rien sur cette période.").font(.subheadline).foregroundStyle(Carnet.inkSecondary)
                } else {
                    if let selected {
                        let rows = bars.filter { $0.course == selected && $0.seconds > 0 }
                        Text("\(selected) : " + rows.map { "\($0.category) \(DateUtils.durationLabel(seconds: $0.seconds))" }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(Carnet.ink)
                    }
                    Chart(bars) { bar in
                        BarMark(x: .value("Heures", bar.hours), y: .value("Cours", bar.course))
                            .foregroundStyle(by: .value("Nature", bar.category))
                            .opacity(selected == nil || selected == bar.course ? 1 : 0.35)
                    }
                    .chartForegroundStyleScale(domain: present.map(\.0), range: present.map(\.1))
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                    .chartYSelection(value: $selected)
                    .chartYScale(domain: courses)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(Carnet.rule)
                            AxisValueLabel {
                                if let hours = value.as(Double.self) {
                                    Text("\(Int(hours)) h").font(.caption2).foregroundStyle(Carnet.inkTertiary)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let code = value.as(String.self) {
                                    Text(code).font(.caption.weight(.semibold)).foregroundStyle(Carnet.ink)
                                }
                            }
                        }
                    }
                    .frame(height: CGFloat(max(courses.count, 1)) * 36 + 50)
                    .sensoryFeedback(.selection, trigger: selected)
                }
            }
        }
    }
}

// MARK: - Tendance

struct WeekPoint: Identifiable {
    let week: Date
    let series: String
    let hours: Double
    var id: String { "\(week.timeIntervalSince1970)-\(series)" }
}

/// Semaine après semaine, tout le semestre : l'étude, l'amphi, et la moyenne.
struct WeeklyTrendCard: View {
    let points: [WeekPoint]
    let weekLabel: (Date) -> String
    @State private var selected: Date?

    private var studyAverage: Double {
        let study = points.filter { $0.series == "Étude" }
        let active = study.filter { $0.hours > 0 }
        return active.isEmpty ? 0 : active.reduce(0) { $0 + $1.hours } / Double(active.count)
    }

    var body: some View {
        let selectedWeek = selected.map(DateUtils.startOfWeek)
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Par semaine") {
                if let selectedWeek {
                    let values = points.filter { $0.week == selectedWeek }
                    Text("\(weekLabel(selectedWeek)) : " + values.map { "\($0.series.lowercased()) \(String(format: "%.1f", $0.hours).replacingOccurrences(of: ".", with: ",")) h" }.joined(separator: ", "))
                } else if studyAverage > 0 {
                    Text("≈ \(String(format: "%.1f", studyAverage).replacingOccurrences(of: ".", with: ",")) h d'étude / sem.")
                }
            }
            StatsCard {
                Chart {
                    ForEach(points) { point in
                        AreaMark(x: .value("Semaine", point.week, unit: .weekOfYear),
                                 y: .value("Heures", point.hours),
                                 stacking: .unstacked)
                            .foregroundStyle(by: .value("Série", point.series))
                            .opacity(0.12)
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Semaine", point.week, unit: .weekOfYear),
                                 y: .value("Heures", point.hours))
                            .foregroundStyle(by: .value("Série", point.series))
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    if studyAverage > 0 {
                        RuleMark(y: .value("Moyenne", studyAverage))
                            .foregroundStyle(Carnet.inkTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if let selectedWeek {
                        RuleMark(x: .value("Semaine", selectedWeek, unit: .weekOfYear))
                            .foregroundStyle(Carnet.ink.opacity(0.25))
                    }
                }
                .chartForegroundStyleScale(domain: ["Étude", "Amphi"],
                                           range: [Carnet.ink, Carnet.inkTertiary])
                .chartLegend(position: .top, alignment: .leading)
                .chartXSelection(value: $selected)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel { Text(weekLabel(date)).font(.caption2).foregroundStyle(Carnet.inkSecondary) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Carnet.rule)
                        AxisValueLabel {
                            if let hours = value.as(Double.self) {
                                Text("\(Int(hours)) h").font(.caption2).foregroundStyle(Carnet.inkTertiary)
                            }
                        }
                    }
                }
                .frame(height: 170)
            }
        }
    }
}

// MARK: - Rythme

struct PaceRow: Identifiable {
    let code: String
    let color: Color
    /// Part du cours faite (théorie vue + exercices faits), 0…1.
    let done: Double
    /// Part du programme prévue jusqu'à cette semaine, 0…1.
    let expected: Double
    var id: String { code }
}

/// Fait contre prévu, cours par cours : la barre est ce qui est fait, le trait
/// ce qui devrait l'être à cette semaine du semestre.
struct PaceCard: View {
    let rows: [PaceRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Fait / prévu à ce jour")
            StatsCard {
                Chart(rows) { row in
                    BarMark(x: .value("Fait", row.done * 100), y: .value("Cours", row.code), height: .fixed(14))
                        .foregroundStyle(row.color)
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text("\(Int((row.done * 100).rounded())) %")
                                .font(Carnet.mono(.caption2))
                                .foregroundStyle(row.done + 0.05 < row.expected ? Carnet.wrong : Carnet.inkSecondary)
                        }
                    PointMark(x: .value("Prévu", row.expected * 100), y: .value("Cours", row.code))
                        .symbol { Capsule().fill(Carnet.ink).frame(width: 3, height: 22) }
                }
                .chartXScale(domain: 0...112)
                .chartXAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine().foregroundStyle(Carnet.rule)
                        AxisValueLabel {
                            if let number = value.as(Int.self) {
                                Text("\(number) %").font(.caption2).foregroundStyle(Carnet.inkTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let code = value.as(String.self) {
                                Text(code).font(.caption.weight(.semibold)).foregroundStyle(Carnet.ink)
                            }
                        }
                    }
                }
                .frame(height: CGFloat(max(rows.count, 1)) * 34 + 30)
                Text("Le trait : la part du programme prévue jusqu'à cette semaine. En rouge, un cours en dessous.")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
            }
        }
    }
}

// MARK: - Quand

struct HeatCell: Identifiable {
    /// 0 = lundi.
    let weekday: Int
    let hour: Int
    let seconds: Int
    var id: Int { weekday * 24 + hour }
}

/// Jour de la semaine × heure : quand je travaille vraiment.
struct HeatmapCard: View {
    let cells: [HeatCell]
    @State private var hour: Int?

    private static let days = ["L", "M", "M", "J", "V", "S", "D"]

    var body: some View {
        let peak = max(cells.map(\.seconds).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Quand") {
                if let hour {
                    let total = cells.filter { $0.hour == hour }.reduce(0) { $0 + $1.seconds }
                    Text("\(hour) h : \(DateUtils.durationLabel(seconds: total))")
                } else if let best = cells.max(by: { $0.seconds < $1.seconds }), best.seconds > 0 {
                    Text("surtout le \(Self.dayName(best.weekday)) vers \(best.hour) h")
                }
            }
            StatsCard {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 3) {
                            Text(Self.days[day])
                                .font(.caption2)
                                .foregroundStyle(Carnet.inkSecondary)
                                .frame(width: 14)
                            ForEach(Self.hours, id: \.self) { h in
                                let seconds = cells.first { $0.weekday == day && $0.hour == h }?.seconds ?? 0
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(seconds == 0 ? Carnet.sheetRaised
                                          : Carnet.ink.opacity(0.2 + 0.8 * Double(seconds) / Double(peak)))
                                    .overlay {
                                        if hour == h {
                                            RoundedRectangle(cornerRadius: 2).strokeBorder(Carnet.ink, lineWidth: 1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 14)
                                    .contentShape(Rectangle())
                                    .onTapGesture { hour = hour == h ? nil : h }
                            }
                        }
                    }
                    HStack(spacing: 3) {
                        Color.clear.frame(width: 14, height: 1)
                        ForEach(Self.hours, id: \.self) { h in
                            Text(h % 3 == 0 ? "\(h)" : "")
                                .font(.system(size: 9))
                                .foregroundStyle(Carnet.inkTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: hour)
            }
        }
    }

    private static let hours = Array(7...23)

    private static func dayName(_ index: Int) -> String {
        ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"][min(max(index, 0), 6)]
    }
}
