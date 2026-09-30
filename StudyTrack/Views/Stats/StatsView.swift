import SwiftUI
import SwiftData
import Charts

/// Le bilan : le temps (étude **et** amphi, jamais confondus), où il est allé,
/// quand, et ce qu'il a produit — théorie vue, exercices faits, corrections.
///
/// Chaque graphique se touche : glisser le doigt sur les barres montre le
/// détail du jour, de la semaine ou du cours visé.
struct StatsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @Query private var terms: [AcademicTerm]
    @Query private var events: [LinkedCalendarEvent]

    @State private var period: Period = .week
    /// Décalage en semaines (période « Semaine ») : 0 = cette semaine.
    @State private var weekOffset = 0
    @State private var selectedDay: Date?
    @State private var selectedCourse: String?
    @State private var selectedVerdict: Int?
    @State private var selectedHour: Int?

    enum Period: String, CaseIterable, Identifiable {
        case week, month, semester
        var id: String { rawValue }
        var label: String {
            switch self {
            case .week: return "Semaine"
            case .month: return "30 jours"
            case .semester: return "Semestre"
            }
        }
    }

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var term: AcademicTerm? { AcademicTerm.resolve(from: tracked.compactMap(\.term)) }

    // MARK: Fenêtre

    private var range: (start: Date, end: Date) {
        let today = DateUtils.startOfDay(Date())
        switch period {
        case .week:
            let start = DateUtils.addWeeks(weekOffset, to: DateUtils.startOfWeek(Date()))
            return (start, DateUtils.addDays(7, to: start))
        case .month:
            return (DateUtils.addDays(-29, to: today), DateUtils.addDays(1, to: today))
        case .semester:
            let start = term.map { DateUtils.startOfWeek($0.startDate) } ?? DateUtils.addWeeks(-13, to: DateUtils.startOfWeek(Date()))
            return (start, DateUtils.addDays(1, to: today))
        }
    }

    /// En semestre, une barre par semaine ; sinon une par jour.
    private var binsByWeek: Bool { period == .semester }

    private var rangeLabel: String {
        let r = range
        let last = DateUtils.addDays(-1, to: r.end)
        switch period {
        case .week:
            if weekOffset == 0 { return "Cette semaine" }
            if weekOffset == -1 { return "La semaine dernière" }
            return "\(DateUtils.shortDay.string(from: r.start)) – \(DateUtils.shortDay.string(from: last))"
        case .month: return "\(DateUtils.shortDay.string(from: r.start)) – aujourd'hui"
        case .semester: return term?.displayName ?? "Depuis le début du semestre"
        }
    }

    // MARK: Données

    /// Les sessions d'**étude** de la période. Une session saisie « Cours en
    /// amphi » n'en est pas : elle rejoint les heures d'amphi.
    private var studySessions: [StudySession] {
        let r = range
        return sessions.filter { $0.startedAt >= r.start && $0.startedAt < r.end && $0.taskType.canonical != .lecture }
    }

    private struct LectureSlot {
        let date: Date
        let seconds: Int
        let course: Course?
    }

    /// Les heures d'amphi : les cours magistraux de l'horaire, finis et pas
    /// manqués, plus les sessions saisies comme amphi.
    private var lectures: [LectureSlot] {
        let r = range
        var slots = events
            .filter { $0.countsAsAttendedLecture && $0.startsAt >= r.start && $0.startsAt < r.end }
            .map { LectureSlot(date: $0.startsAt, seconds: $0.durationSeconds, course: $0.course) }
        slots += sessions
            .filter { $0.startedAt >= r.start && $0.startedAt < r.end && $0.taskType.canonical == .lecture }
            .map { LectureSlot(date: $0.startedAt, seconds: $0.durationSeconds, course: $0.course) }
        return slots
    }

    private var studySeconds: Int { studySessions.reduce(0) { $0 + $1.durationSeconds } }
    private var lectureSeconds: Int { lectures.reduce(0) { $0 + $1.seconds } }

    /// Une barre du graphique du temps : un jour (ou une semaine), une catégorie.
    private struct TimeBar: Identifiable {
        let bin: Date
        let category: String
        let seconds: Int
        var id: String { "\(bin.timeIntervalSince1970)-\(category)" }
        var hours: Double { Double(seconds) / 3600 }
    }

    private static let lectureCategory = "Amphi"

    private func bin(_ date: Date) -> Date {
        binsByWeek ? DateUtils.startOfWeek(date) : DateUtils.startOfDay(date)
    }

    private var timeBars: [TimeBar] {
        var totals: [Date: [String: Int]] = [:]
        for session in studySessions {
            totals[bin(session.startedAt), default: [:]][session.taskType.canonical.label, default: 0] += session.durationSeconds
        }
        for slot in lectures {
            totals[bin(slot.date), default: [:]][Self.lectureCategory, default: 0] += slot.seconds
        }
        return totals.flatMap { day, byCategory in
            byCategory.map { TimeBar(bin: day, category: $0.key, seconds: $0.value) }
        }
    }

    /// Les catégories dans l'ordre d'empilement : l'étude d'abord, l'amphi en haut.
    private var categoryOrder: [String] {
        TaskType.reportCategories.filter { $0 != .lecture }.map(\.label) + [Self.lectureCategory]
    }

    private var categoryColors: [Color] {
        categoryOrder.map { name in
            if name == Self.lectureCategory { return Carnet.inkTertiary.opacity(0.45) }
            let type = TaskType.reportCategories.first { $0.label == name } ?? .other
            return StatsPalette.color(for: type)
        }
    }

    private var bins: [Date] {
        var result: [Date] = []
        var cursor = bin(range.start)
        let end = min(range.end, DateUtils.addDays(1, to: DateUtils.startOfDay(Date())))
        while cursor < (period == .week ? range.end : end) {
            result.append(cursor)
            cursor = binsByWeek ? DateUtils.addWeeks(1, to: cursor) : DateUtils.addDays(1, to: cursor)
        }
        return result
    }

    // MARK: Corps

    var body: some View {
        CarnetScroll(spacing: 26) {
            periodBar
            totals
            timeChart
            courseChart
            progressSection
            correctionChart
            hoursChart
        }
        .navigationTitle("Bilan")
        .navigationBarTitleDisplayMode(.large)
        .animation(Motion.snappy, value: period)
        .animation(Motion.snappy, value: weekOffset)
    }

    // MARK: Période

    private var periodBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Period.allCases) { value in
                    Button {
                        period = value
                        weekOffset = 0
                        selectedDay = nil
                        Haptics.soft()
                    } label: {
                        CarnetChip(text: value.label, isSelected: period == value)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(rangeLabel)
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
                Spacer()
                if period == .week {
                    Button { weekOffset -= 1 } label: {
                        Image(systemName: "chevron.left").frame(width: 36, height: 32)
                    }
                    .accessibilityLabel("Semaine précédente")
                    Button { weekOffset += 1 } label: {
                        Image(systemName: "chevron.right").frame(width: 36, height: 32)
                    }
                    .disabled(weekOffset >= 0)
                    .accessibilityLabel("Semaine suivante")
                }
            }
            .foregroundStyle(Carnet.ink)
            .padding(.horizontal, 6)
        }
    }

    // MARK: Totaux

    /// L'étude, l'amphi, et leur somme — trois chiffres, jamais mélangés.
    private var totals: some View {
        HStack(spacing: 0) {
            total("Étude", seconds: studySeconds, detail: "\(studySessions.count) session\(studySessions.count > 1 ? "s" : "")")
            Rectangle().fill(Carnet.rule).frame(width: 1, height: 48)
            total("Amphi", seconds: lectureSeconds, detail: "\(lectures.count) cours")
            Rectangle().fill(Carnet.rule).frame(width: 1, height: 48)
            total("Total", seconds: studySeconds + lectureSeconds, detail: activeDaysLabel)
        }
        .padding(.vertical, 16)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    private var activeDaysLabel: String {
        let days = Set(studySessions.map { DateUtils.startOfDay($0.startedAt) }).count
        return "\(days) jour\(days > 1 ? "s" : "") actif\(days > 1 ? "s" : "")"
    }

    private func total(_ title: String, seconds: Int, detail: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Carnet.inkSecondary)
            Text(DateUtils.hoursLabel(seconds: seconds))
                .font(Carnet.serif(.title2))
                .foregroundStyle(Carnet.ink)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(Carnet.inkTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Le temps, jour par jour

    private var timeChart: some View {
        let bars = timeBars
        let selectedBin = selectedDay.map(bin)
        let selectedBars = bars.filter { $0.bin == selectedBin }
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(binsByWeek ? "Semaine par semaine" : "Jour par jour") {
                if selectedBin == nil {
                    Text("touche une barre")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if let selectedBin {
                    selectionSummary(bin: selectedBin, bars: selectedBars)
                } else {
                    legend
                }
                Chart {
                    ForEach(bars) { bar in
                        BarMark(x: .value("Jour", bar.bin, unit: binsByWeek ? .weekOfYear : .day),
                                y: .value("Heures", bar.hours))
                            .foregroundStyle(by: .value("Catégorie", bar.category))
                            .cornerRadius(3)
                            .opacity(selectedBin == nil || selectedBin == bar.bin ? 1 : 0.35)
                    }
                    if let selectedBin {
                        RuleMark(x: .value("Jour", selectedBin, unit: binsByWeek ? .weekOfYear : .day))
                            .foregroundStyle(Carnet.ink.opacity(0.12))
                            .lineStyle(StrokeStyle(lineWidth: binsByWeek ? 18 : 26))
                            .zIndex(-1)
                    }
                }
                .chartForegroundStyleScale(domain: categoryOrder, range: categoryColors)
                .chartLegend(.hidden)
                .chartXSelection(value: $selectedDay)
                .chartXScale(domain: range.start...range.end)
                .chartXAxis {
                    AxisMarks(values: .stride(by: binsByWeek ? .weekOfYear : .day,
                                              count: period == .month ? 5 : 1)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(axisLabel(date))
                                    .font(.caption2)
                                    .foregroundStyle(Carnet.inkSecondary)
                            }
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
                .frame(height: 190)
                .sensoryFeedback(.selection, trigger: selectedBin)
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }

    private func axisLabel(_ date: Date) -> String {
        if binsByWeek {
            if let term { return "S\(DateUtils.clampedWeek(for: date.addingTimeInterval(43_200), term: term))" }
            return DateUtils.shortDay.string(from: date)
        }
        if period == .week { return DateUtils.weekdayInitial(date) }
        return "\(Calendar.current.component(.day, from: date))"
    }

    private var legend: some View {
        let present = Set(timeBars.map(\.category))
        return FlowLayout(spacing: 12) {
            ForEach(Array(zip(categoryOrder, categoryColors)), id: \.0) { name, color in
                if present.contains(name) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                        Text(name).font(.caption).foregroundStyle(Carnet.inkSecondary)
                    }
                }
            }
        }
    }

    private func selectionSummary(bin: Date, bars: [TimeBar]) -> some View {
        let study = bars.filter { $0.category != Self.lectureCategory }.reduce(0) { $0 + $1.seconds }
        let lecture = bars.filter { $0.category == Self.lectureCategory }.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 4) {
            Text(binsByWeek ? "Semaine du \(DateUtils.shortDay.string(from: bin))" : DateUtils.fullDayLabel(bin))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Carnet.ink)
            Text("\(DateUtils.durationLabel(seconds: study)) d'étude" + (lecture > 0 ? " · \(DateUtils.durationLabel(seconds: lecture)) d'amphi" : ""))
                .font(.footnote)
                .foregroundStyle(Carnet.inkSecondary)
            Text(bars.filter { $0.category != Self.lectureCategory }
                    .sorted { $0.seconds > $1.seconds }
                    .map { "\($0.category) \(DateUtils.durationLabel(seconds: $0.seconds))" }
                    .joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Carnet.inkTertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
    }

    // MARK: Par cours

    private struct CourseTime: Identifiable {
        let code: String
        let color: Color
        let kind: String
        let seconds: Int
        var id: String { code + kind }
        var hours: Double { Double(seconds) / 3600 }
    }

    private var courseTimes: [CourseTime] {
        var study: [String: Int] = [:]
        var lecture: [String: Int] = [:]
        var colors: [String: Color] = [:]
        for session in studySessions {
            let code = session.course?.displayCode ?? "Sans cours"
            study[code, default: 0] += session.durationSeconds
            colors[code] = session.course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkTertiary
        }
        for slot in lectures {
            let code = slot.course?.displayCode ?? "Sans cours"
            lecture[code, default: 0] += slot.seconds
            colors[code] = slot.course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkTertiary
        }
        let codes = Set(study.keys).union(lecture.keys)
            .sorted { (study[$0] ?? 0) + (lecture[$0] ?? 0) > (study[$1] ?? 0) + (lecture[$1] ?? 0) }
        return codes.flatMap { code in
            [CourseTime(code: code, color: colors[code] ?? Carnet.ink, kind: "Étude", seconds: study[code] ?? 0),
             CourseTime(code: code, color: colors[code] ?? Carnet.ink, kind: "Amphi", seconds: lecture[code] ?? 0)]
        }
    }

    @ViewBuilder
    private var courseChart: some View {
        let data = courseTimes
        let codes = data.map(\.code).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Par cours") {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Carnet.ink).frame(width: 10, height: 10)
                        Text("étude")
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Carnet.ink.opacity(0.25)).frame(width: 10, height: 10)
                        Text("amphi")
                    }
                }
                .font(.caption)
            }
            VStack(alignment: .leading, spacing: 10) {
                if codes.isEmpty {
                    Text("Aucune session sur cette période.")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    if let selectedCourse,
                       let study = data.first(where: { $0.code == selectedCourse && $0.kind == "Étude" }),
                       let lecture = data.first(where: { $0.code == selectedCourse && $0.kind == "Amphi" }) {
                        Text("\(selectedCourse) : \(DateUtils.durationLabel(seconds: study.seconds)) d'étude · \(DateUtils.durationLabel(seconds: lecture.seconds)) d'amphi")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Carnet.ink)
                    }
                    Chart(data) { item in
                        BarMark(x: .value("Heures", item.hours),
                                y: .value("Cours", item.code))
                            .foregroundStyle(item.color.opacity(item.kind == "Amphi" ? 0.3 : 1))
                            .cornerRadius(3)
                            .opacity(selectedCourse == nil || selectedCourse == item.code ? 1 : 0.35)
                            .annotation(position: .trailing, alignment: .leading) {
                                if item.kind == "Amphi" {
                                    let total = data.filter { $0.code == item.code }.reduce(0) { $0 + $1.seconds }
                                    Text(DateUtils.hoursLabel(seconds: total))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Carnet.inkSecondary)
                                }
                            }
                    }
                    .chartYSelection(value: $selectedCourse)
                    .chartXScale(domain: 0...courseScaleMax(data))
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let code = value.as(String.self) {
                                    Text(code).font(.caption.weight(.semibold)).foregroundStyle(Carnet.ink)
                                }
                            }
                        }
                    }
                    .frame(height: CGFloat(max(codes.count, 1)) * 34 + 10)
                    .sensoryFeedback(.selection, trigger: selectedCourse)
                }
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }

    /// L'échelle laisse la place du total écrit au bout de la barre.
    private func courseScaleMax(_ data: [CourseTime]) -> Double {
        let totals = Dictionary(grouping: data, by: \.code).values.map { $0.reduce(0) { $0 + $1.hours } }
        return max(totals.max() ?? 1, 0.5) * 1.25
    }

    // MARK: Avancement

    private struct DonePoint: Identifiable {
        let week: Date
        let series: String
        let count: Int
        var id: String { "\(week.timeIntervalSince1970)-\(series)" }
    }

    /// Ce que le temps a produit : théorie vue et exercices faits, semaine par
    /// semaine sur tout le semestre.
    private var donePoints: [DonePoint] {
        let start = term.map { DateUtils.startOfWeek($0.startDate) } ?? DateUtils.addWeeks(-13, to: DateUtils.startOfWeek(Date()))
        var theory: [Date: Int] = [:]
        var exercises: [Date: Int] = [:]
        for course in tracked {
            for item in course.theoryItems {
                if let date = item.watchedAt, date >= start { theory[DateUtils.startOfWeek(date), default: 0] += 1 }
            }
            for exercise in course.allExercises {
                if let date = exercise.doneAt, date >= start { exercises[DateUtils.startOfWeek(date), default: 0] += 1 }
            }
        }
        var points: [DonePoint] = []
        var cursor = start
        while cursor <= Date() {
            points.append(DonePoint(week: cursor, series: "Théorie", count: theory[cursor] ?? 0))
            points.append(DonePoint(week: cursor, series: "Exercices", count: exercises[cursor] ?? 0))
            cursor = DateUtils.addWeeks(1, to: cursor)
        }
        return points
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Avancement")
            VStack(alignment: .leading, spacing: 16) {
                ForEach(tracked) { course in
                    courseProgressRow(course)
                    if course.id != tracked.last?.id { Rectangle().fill(Carnet.rule).frame(height: 1) }
                }
                if tracked.isEmpty {
                    Text("Aucun cours suivi.").font(.subheadline).foregroundStyle(Carnet.inkSecondary)
                }
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Fait par semaine").font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
                    Spacer()
                    HStack(spacing: 10) {
                        legendDot(StatsPalette.color(for: .theory), "théorie")
                        legendDot(StatsPalette.color(for: .exercise), "exercices")
                    }
                }
                Chart(donePoints) { point in
                    LineMark(x: .value("Semaine", point.week, unit: .weekOfYear),
                             y: .value("Faits", point.count))
                        .foregroundStyle(by: .value("Série", point.series))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    PointMark(x: .value("Semaine", point.week, unit: .weekOfYear),
                              y: .value("Faits", point.count))
                        .foregroundStyle(by: .value("Série", point.series))
                        .symbolSize(24)
                }
                .chartForegroundStyleScale(domain: ["Théorie", "Exercices"],
                                           range: [StatsPalette.color(for: .theory), StatsPalette.color(for: .exercise)])
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(term.map { "S\(DateUtils.clampedWeek(for: date.addingTimeInterval(43_200), term: $0))" }
                                     ?? DateUtils.shortDay.string(from: date))
                                    .font(.caption2).foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Carnet.rule)
                        AxisValueLabel().font(.caption2).foregroundStyle(Carnet.inkTertiary)
                    }
                }
                .frame(height: 150)
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(Carnet.inkSecondary)
        }
    }

    /// Un cours : théorie vue, exercices faits, et corrigés — sur le semestre.
    private func courseProgressRow(_ course: Course) -> some View {
        let progress = ProgressEngine.progress(for: course)
        let tint = Carnet.tint(course.colorHex)
        let late = ProgressEngine.lateCount(for: course)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(course.displayCode).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(course.name).font(.subheadline).foregroundStyle(Carnet.ink).lineLimit(1)
                Spacer()
                if late > 0 {
                    Text("\(late) en retard").font(.caption.weight(.semibold)).foregroundStyle(Carnet.wrong)
                }
            }
            HStack(spacing: 14) {
                progressAxis("Théorie", progress.watchedCount, progress.videoCount, tint)
                progressAxis("Exercices", progress.doneCount, progress.exerciseCount, tint)
                progressAxis("Corrigés", progress.correctedCount, progress.doneCount, tint)
            }
        }
    }

    private func progressAxis(_ title: String, _ done: Int, _ total: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(Carnet.inkSecondary)
                Spacer(minLength: 2)
                Text(total == 0 ? "—" : "\(done)/\(total)")
                    .font(Carnet.mono(.caption2, weight: .medium))
                    .foregroundStyle(Carnet.ink)
            }
            CarnetBar(value: CourseProgress.ratio(done, total), tint: tint, height: 4)
                .opacity(total == 0 ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Corrections

    private struct Verdict: Identifiable {
        let result: Correctness
        let count: Int
        let start: Int
        var id: String { result.rawValue }
    }

    private var verdicts: [Verdict] {
        let corrected = tracked.flatMap(\.allExercises).compactMap(\.correctness)
        var start = 0
        return Correctness.allCases.compactMap { result in
            let count = corrected.filter { $0 == result }.count
            guard count > 0 else { return nil }
            defer { start += count }
            return Verdict(result: result, count: count, start: start)
        }
    }

    @ViewBuilder
    private var correctionChart: some View {
        let data = verdicts
        let total = data.reduce(0) { $0 + $1.count }
        let selected = selectedVerdict.flatMap { value in data.first { value >= $0.start && value < $0.start + $0.count } }
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Corrections") { Text("\(total) exercice\(total > 1 ? "s" : "")") }
            HStack(spacing: 20) {
                ZStack {
                    Chart(data) { item in
                        SectorMark(angle: .value("Nombre", item.count),
                                   innerRadius: .ratio(0.64),
                                   angularInset: 2)
                            .foregroundStyle(Carnet.color(for: item.result))
                            .cornerRadius(4)
                            .opacity(selected == nil || selected?.result == item.result ? 1 : 0.35)
                    }
                    .chartAngleSelection(value: $selectedVerdict)
                    .frame(width: 130, height: 130)
                    VStack(spacing: 0) {
                        let shown = selected ?? data.first { $0.result == .correct }
                        Text(total == 0 ? "—" : "\(Int((Double(shown?.count ?? 0) / Double(max(total, 1)) * 100).rounded())) %")
                            .font(Carnet.serif(.title2))
                            .foregroundStyle(Carnet.ink)
                        Text(shown?.result.lineLabel ?? "juste")
                            .font(.caption)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Correctness.allCases) { result in
                        let count = data.first { $0.result == result }?.count ?? 0
                        HStack(spacing: 8) {
                            Circle().fill(Carnet.color(for: result)).frame(width: 9, height: 9)
                            Text(result.lineLabel.capitalizedFirst).font(.subheadline).foregroundStyle(Carnet.ink)
                            Spacer()
                            Text("\(count)").font(Carnet.mono(.subheadline)).foregroundStyle(Carnet.inkSecondary)
                        }
                    }
                    let redo = tracked.flatMap(\.allExercises).filter(\.redoRequired).count
                    if redo > 0 {
                        Text("\(redo) à refaire").font(.caption.weight(.semibold)).foregroundStyle(Carnet.wrong)
                    }
                }
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .sensoryFeedback(.selection, trigger: selected?.result)
        }
    }

    // MARK: Heures de la journée

    private struct HourBin: Identifiable {
        let hour: Int
        let seconds: Int
        var id: Int { hour }
    }

    /// Quand je travaille : l'étude de la période, répartie par heure de la
    /// journée (une session à cheval sur deux heures compte dans les deux).
    private var hourBins: [HourBin] {
        var totals = Array(repeating: 0, count: 24)
        let calendar = Calendar.current
        for session in studySessions {
            var cursor = session.startedAt
            var remaining = session.durationSeconds
            while remaining > 0 {
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.date(bySetting: .minute, value: 0, of: cursor.addingTimeInterval(3600)) ?? cursor.addingTimeInterval(3600)
                let chunk = min(remaining, max(60, Int(nextHour.timeIntervalSince(cursor))))
                totals[hour] += chunk
                remaining -= chunk
                cursor = cursor.addingTimeInterval(TimeInterval(chunk))
            }
        }
        return totals.enumerated().map { HourBin(hour: $0.offset, seconds: $0.element) }
    }

    private var hoursChart: some View {
        let data = hourBins
        let peak = data.max { $0.seconds < $1.seconds }
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Heures de la journée") {
                if let selectedHour, let bin = data.first(where: { $0.hour == selectedHour }) {
                    Text("\(selectedHour) h : \(DateUtils.durationLabel(seconds: bin.seconds))")
                } else if let peak, peak.seconds > 0 {
                    Text("surtout vers \(peak.hour) h")
                }
            }
            Chart(data) { bin in
                BarMark(x: .value("Heure", bin.hour), y: .value("Temps", Double(bin.seconds) / 3600))
                    .foregroundStyle(bin.hour == selectedHour ? Carnet.ink : Carnet.inkTertiary)
                    .cornerRadius(2)
            }
            .chartXSelection(value: $selectedHour)
            .chartXScale(domain: 0...23)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text("\(hour) h").font(.caption2).foregroundStyle(Carnet.inkSecondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 90)
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }
}

/// Les couleurs des catégories de travail, dans la palette du papier : des
/// teintes sourdes, qui ne rivalisent pas avec les verdicts de correction.
enum StatsPalette {
    static func color(for type: TaskType) -> Color {
        switch type.canonical {
        case .theory: return Carnet.tint("#4F6FB8")
        case .exercise: return Carnet.tint("#C08A2E")
        case .correction: return Carnet.tint("#5E9A6A")
        case .flashcards: return Carnet.tint("#A0567E")
        case .lecture: return Carnet.inkTertiary
        default: return Carnet.tint("#7A7468")
        }
    }
}
