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
            ForEach(visibleSections, id: \.self) { index in
                section(index)
            }
        }
        .navigationTitle("Bilan")
        .navigationBarTitleDisplayMode(.large)
        .animation(Motion.snappy, value: period)
        .animation(Motion.snappy, value: weekOffset)
    }

    /// L'ordre de lecture : combien, réparti comment, quand, puis ce que ça a produit.
    @ViewBuilder
    private func section(_ index: Int) -> some View {
        switch index {
        case 0: periodBar
        case 1: totals
        case 2: SplitCard(slices: splitSlices)
        case 3: CoursePieCard(slices: courseSlices)
        case 4: timeChart
        case 5: CourseCategoryCard(bars: courseCategoryBars, categories: categoryOrder, colors: categoryColors)
        case 6: WeeklyTrendCard(points: weeklyPoints, weekLabel: weekLabel)
        case 7: PaceCard(rows: paceRows)
        case 8: progressSection
        case 9: correctionChart
        default: HeatmapCard(cells: heatCells)
        }
    }

    private var visibleSections: [Int] {
        #if DEBUG
        // `-statsSkip 4` : les captures du simulateur ne défilent pas.
        if let skip = PreviewLaunch.int("-statsSkip") { return Array(skip...10) }
        #endif
        return Array(0...10)
    }

    // MARK: Données des graphiques

    /// Amphi, puis chaque nature de travail : la répartition de la période.
    private var splitSlices: [TimeSlice] {
        var slices = [TimeSlice(name: "Amphi", detail: "cours magistraux suivis", seconds: lectureSeconds,
                                color: Carnet.inkTertiary.opacity(0.55))]
        for type in TaskType.reportCategories where type != .lecture {
            let seconds = studySessions.filter { $0.taskType.canonical == type }.reduce(0) { $0 + $1.durationSeconds }
            slices.append(TimeSlice(name: type.label, detail: "", seconds: seconds, color: StatsPalette.color(for: type)))
        }
        return slices.filter { $0.seconds > 0 }
    }

    /// Le temps de chaque matière, étude et amphi confondus.
    private var courseSlices: [TimeSlice] {
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
        return Set(study.keys).union(lecture.keys)
            .map { code in
                TimeSlice(name: code,
                          detail: "\(DateUtils.durationLabel(seconds: study[code] ?? 0)) d'étude, \(DateUtils.durationLabel(seconds: lecture[code] ?? 0)) d'amphi",
                          seconds: (study[code] ?? 0) + (lecture[code] ?? 0),
                          color: colors[code] ?? Carnet.ink)
            }
            .sorted { $0.seconds > $1.seconds }
    }

    private var courseCategoryBars: [CourseCategoryBar] {
        var totals: [String: [String: Int]] = [:]
        for session in studySessions {
            totals[session.course?.displayCode ?? "Sans cours", default: [:]][session.taskType.canonical.label, default: 0] += session.durationSeconds
        }
        for slot in lectures {
            totals[slot.course?.displayCode ?? "Sans cours", default: [:]][Self.lectureCategory, default: 0] += slot.seconds
        }
        return totals.flatMap { course, byCategory in
            byCategory.map { CourseCategoryBar(course: course, category: $0.key, seconds: $0.value) }
        }
    }

    /// Tout le semestre, quelle que soit la période choisie.
    private var weeklyPoints: [WeekPoint] {
        let start = term.map { DateUtils.startOfWeek($0.startDate) } ?? DateUtils.addWeeks(-13, to: DateUtils.startOfWeek(Date()))
        var study: [Date: Int] = [:]
        var lecture: [Date: Int] = [:]
        for session in sessions where session.startedAt >= start {
            if session.taskType.canonical == .lecture {
                lecture[DateUtils.startOfWeek(session.startedAt), default: 0] += session.durationSeconds
            } else {
                study[DateUtils.startOfWeek(session.startedAt), default: 0] += session.durationSeconds
            }
        }
        for event in events where event.countsAsAttendedLecture && event.startsAt >= start {
            lecture[DateUtils.startOfWeek(event.startsAt), default: 0] += event.durationSeconds
        }
        var points: [WeekPoint] = []
        var cursor = start
        while cursor <= Date() {
            points.append(WeekPoint(week: cursor, series: "Étude", hours: Double(study[cursor] ?? 0) / 3600))
            points.append(WeekPoint(week: cursor, series: "Amphi", hours: Double(lecture[cursor] ?? 0) / 3600))
            cursor = DateUtils.addWeeks(1, to: cursor)
        }
        return points
    }

    private func weekLabel(_ date: Date) -> String {
        if let term { return "S\(DateUtils.clampedWeek(for: date.addingTimeInterval(43_200), term: term))" }
        return DateUtils.shortDay.string(from: date)
    }

    /// Fait (théorie vue + exercices faits) contre prévu jusqu'à cette semaine.
    private var paceRows: [PaceRow] {
        tracked.compactMap { course in
            let week = course.currentWeek
            let theory = course.theoryItems
            let exercises = course.series.flatMap(\.exercises).filter { !$0.isBonus }
            let total = theory.count + exercises.count
            guard total > 0 else { return nil }
            let due = theory.filter { $0.plannedWeek > 0 && $0.plannedWeek <= week }.count
                + course.series.filter { $0.plannedWeek > 0 && $0.plannedWeek <= week }
                    .flatMap(\.exercises).filter { !$0.isBonus }.count
            let done = theory.filter(\.isWatched).count + exercises.filter(\.isDone).count
            return PaceRow(code: course.displayCode, color: Carnet.tint(course.colorHex),
                           done: Double(done) / Double(total), expected: Double(due) / Double(total))
        }
    }

    /// L'étude de la période, par jour de la semaine et par heure.
    private var heatCells: [HeatCell] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let calendar = Calendar.current
        for session in studySessions {
            var cursor = session.startedAt
            var remaining = session.durationSeconds
            while remaining > 0 {
                let weekday = (calendar.component(.weekday, from: cursor) + 5) % 7
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.date(bySetting: .minute, value: 0, of: cursor.addingTimeInterval(3600)) ?? cursor.addingTimeInterval(3600)
                let chunk = min(remaining, max(60, Int(nextHour.timeIntervalSince(cursor))))
                grid[weekday][hour] += chunk
                remaining -= chunk
                cursor = cursor.addingTimeInterval(TimeInterval(chunk))
            }
        }
        return (0..<7).flatMap { day in (0..<24).map { HeatCell(weekday: day, hour: $0, seconds: grid[day][$0]) } }
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
