import WidgetKit
import AppIntents
import SwiftUI

// MARK: - La semaine

/// La semaine, sur l'écran d'accueil et l'écran verrouillé.
///
/// Petit : le temps de la semaine, l'attendu, et les sept jours. Moyen et
/// grand : en plus, chaque cours — théorie et exercices faits sur prévus, et
/// le retard. Sur l'écran verrouillé : un anneau (temps sur attendu) ou une
/// ligne. Le `kind` est celui de l'ancien widget « Cours de la semaine » : les
/// widgets déjà posés restent en place.
struct WeekCoursesWidget: Widget {
    let kind = "WeekCoursesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            WeekWidgetView(entry: entry)
                .containerBackground(Paper.ground, for: .widget)
                .widgetURL(WidgetLink.today)
        }
        .configurationDisplayName("La semaine")
        .description("Ton temps de la semaine et l'avancement de chaque cours.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct WeekWidgetView: View {
    let entry: StudyTrackEntry
    @Environment(\.widgetFamily) private var family

    private var week: WidgetWeek? { entry.snapshot?.week }
    private var courses: [WidgetCourse] { entry.snapshot?.courses ?? [] }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        case .systemSmall: small
        case .systemLarge: large
        default: medium
        }
    }

    // MARK: Écran verrouillé

    private var ratio: Double {
        guard let week, week.expectedSeconds > 0 else { return 0 }
        return min(1, Double(week.actualSeconds) / Double(week.expectedSeconds))
    }

    private var circular: some View {
        Gauge(value: ratio) {
            Text("h")
        } currentValueLabel: {
            Text(WidgetFormat.shortHours(week?.actualSeconds ?? 0))
                .font(.system(.body, design: .serif))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private var inline: some View {
        Text("\(WidgetFormat.hours(week?.actualSeconds ?? 0)) cette semaine")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(weekTitle).font(.headline).widgetAccentable()
            Text("\(WidgetFormat.hours(week?.actualSeconds ?? 0)) sur \(WidgetFormat.hours(week?.expectedSeconds ?? 0))")
                .font(.caption)
            ProgressView(value: ratio).progressViewStyle(.linear)
        }
    }

    // MARK: Écran d'accueil

    private var weekTitle: String {
        week?.number.map { "Semaine \($0)" } ?? "Cette semaine"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(weekTitle.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(Paper.inkSecondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(WidgetFormat.hours(week?.actualSeconds ?? 0))
                    .font(.system(.title, design: .serif))
                    .foregroundStyle(Paper.ink)
                    .minimumScaleFactor(0.7)
                if let expected = week?.expectedSeconds, expected > 0 {
                    Text("/ \(WidgetFormat.hours(expected))")
                        .font(.caption)
                        .foregroundStyle(Paper.inkSecondary)
                }
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            WidgetBar(value: ratio, tint: Paper.ink)
            Spacer(minLength: 0)
            WidgetDayStrip(days: week?.days ?? [], weekStart: week?.weekStart ?? Date(), height: 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                header
                Spacer(minLength: 0)
                WidgetDayStrip(days: week?.days ?? [], weekStart: week?.weekStart ?? Date(), height: 34)
            }
            .frame(width: 118)
            Rectangle().fill(Paper.rule).frame(width: 1)
            courseList(limit: 4, compact: true)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                header
                Spacer()
            }
            WidgetBar(value: ratio, tint: Paper.ink)
            WidgetDayStrip(days: week?.days ?? [], weekStart: week?.weekStart ?? Date(), height: 40)
            Rectangle().fill(Paper.rule).frame(height: 1)
            courseList(limit: 6, compact: false)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func courseList(limit: Int, compact: Bool) -> some View {
        if courses.isEmpty {
            Text("Aucun cours suivi")
                .font(.caption)
                .foregroundStyle(Paper.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                ForEach(courses.prefix(limit)) { course in
                    Link(destination: WidgetLink.course(course.id)) {
                        WidgetCourseLine(course: course, compact: compact)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Un cours dans le widget : son code à sa couleur, deux compteurs, le retard.
struct WidgetCourseLine: View {
    let course: WidgetCourse
    var compact: Bool

    var body: some View {
        let tint = Paper.tint(course.colorHex)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(course.code)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if !compact, let name = course.name, !name.isEmpty {
                    Text(name).font(.caption).foregroundStyle(Paper.ink).lineLimit(1)
                }
                Spacer(minLength: 2)
                if let late = course.late, late > 0 {
                    Text("\(late) en retard")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Paper.wrong)
                } else if course.total > 0, course.done == course.total {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Paper.correct)
                }
            }
            if course.total > 0 {
                HStack(spacing: 8) {
                    counter("Th.", course.theoryDone, course.theoryTotal)
                    counter("Ex.", course.exercisesDone, course.exercisesTotal)
                    WidgetBar(value: Double(course.done) / Double(max(course.total, 1)), tint: tint)
                }
            } else {
                Text("rien de prévu").font(.caption2).foregroundStyle(Paper.inkSecondary)
            }
        }
    }

    @ViewBuilder
    private func counter(_ label: String, _ done: Int?, _ total: Int?) -> some View {
        if let total, total > 0 {
            Text("\(label) \(done ?? 0)/\(total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Paper.inkSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Une barre fine, sur trait de papier.
struct WidgetBar: View {
    let value: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Paper.rule)
                Capsule().fill(tint).frame(width: proxy.size.width * max(0, min(value, 1)))
            }
        }
        .frame(height: 4)
    }
}

/// Les sept jours de la semaine en colonnes ; aujourd'hui à l'encre.
struct WidgetDayStrip: View {
    let days: [Int]
    let weekStart: Date
    var height: CGFloat

    var body: some View {
        let peak = max(days.max() ?? 0, 3600)
        let today = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: weekStart),
                                                    to: Calendar.current.startOfDay(for: Date())).day ?? 0
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                let seconds = days.indices.contains(index) ? days[index] : 0
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Paper.rule)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index == today ? Paper.ink : Paper.inkSecondary)
                            .frame(height: seconds == 0 ? 0 : max(3, height * CGFloat(seconds) / CGFloat(peak)))
                    }
                    .frame(height: height)
                    Text(["L", "M", "M", "J", "V", "S", "D"][index])
                        .font(.system(size: 9, weight: index == today ? .bold : .regular))
                        .foregroundStyle(index == today ? Paper.ink : Paper.inkSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Aujourd'hui

/// L'horaire du jour et les échéances : le prochain cours, la suite de la
/// journée, puis la prochaine évaluation. Sur l'écran verrouillé, le prochain
/// créneau — ou le chrono s'il tourne.
struct TodayScheduleWidget: Widget {
    let kind = "TodayScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(Paper.ground, for: .widget)
                .widgetURL(WidgetLink.agenda)
        }
        .configurationDisplayName("Aujourd'hui")
        .description("Tes cours du jour et les prochaines échéances.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayWidgetView: View {
    let entry: StudyTrackEntry
    @Environment(\.widgetFamily) private var family

    /// Les créneaux du jour de l'entrée, pas encore finis.
    private var upcoming: [WidgetEvent] {
        let calendar = Calendar.current
        return (entry.snapshot?.schedule ?? []).filter {
            calendar.isDate($0.start, inSameDayAs: entry.date) && ($0.end ?? $0.start) >= entry.date
        }
    }

    private var deadlines: [WidgetDeadline] {
        (entry.snapshot?.deadlines ?? []).filter { $0.date >= entry.date }
    }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemSmall: small
        default: medium
        }
    }

    private var rectangular: some View {
        Group {
            if let timer = entry.snapshot?.timer {
                VStack(alignment: .leading, spacing: 1) {
                    Text(timer.label).font(.headline).lineLimit(1).widgetAccentable()
                    if timer.isRunning {
                        Text(timerInterval: timer.effectiveStart...timer.effectiveStart.addingTimeInterval(86_400),
                             countsDown: false)
                            .font(.system(.title3, design: .serif).monospacedDigit())
                    } else {
                        Text("en pause").font(.caption)
                    }
                }
            } else if let next = upcoming.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeRange(next)).font(.caption).widgetAccentable()
                    Text(next.title).font(.headline).lineLimit(1)
                    if !next.subtitle.isEmpty { Text(next.subtitle).font(.caption).lineLimit(1) }
                }
            } else if let deadline = deadlines.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(countdown(deadline.date)).font(.caption).widgetAccentable()
                    Text(deadline.title).font(.headline).lineLimit(1)
                    Text(deadline.courseCode).font(.caption).lineLimit(1)
                }
            } else {
                Text("Rien à l'horaire").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        if let next = upcoming.first {
            return Text("\(time(next.start)) \(next.title)")
        }
        if let deadline = deadlines.first {
            return Text("\(deadline.title) \(countdown(deadline.date).lowercased())")
        }
        return Text("Rien à l'horaire")
    }

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CH")
        formatter.dateFormat = "EEEE d"
        return formatter.string(from: entry.date).capitalized
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateTitle.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(Paper.inkSecondary)
            if let next = upcoming.first {
                eventBlock(next, large: true)
                if upcoming.count > 1 {
                    Text("puis \(upcoming.count - 1) autre\(upcoming.count > 2 ? "s" : "")")
                        .font(.caption2)
                        .foregroundStyle(Paper.inkSecondary)
                }
            } else {
                Text("Plus rien à l'horaire")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(Paper.ink)
            }
            Spacer(minLength: 0)
            if let deadline = deadlines.first {
                deadlineLine(deadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dateTitle.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(Paper.inkSecondary)
                if upcoming.isEmpty {
                    Text("Plus rien à l'horaire aujourd'hui")
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Paper.ink)
                } else {
                    ForEach(upcoming.prefix(3)) { event in
                        eventBlock(event, large: false)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Paper.rule).frame(width: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("ÉCHÉANCES")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(Paper.inkSecondary)
                if deadlines.isEmpty {
                    Text("Aucune").font(.caption).foregroundStyle(Paper.inkSecondary)
                }
                ForEach(deadlines.prefix(3)) { deadline in
                    deadlineLine(deadline)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 118, alignment: .leading)
        }
    }

    private func eventBlock(_ event: WidgetEvent, large: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Paper.tint(event.colorHex))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(timeRange(event))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Paper.inkSecondary)
                Text(event.title)
                    .font(large ? .system(.headline, design: .serif) : .caption.weight(.semibold))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(large ? 2 : 1)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle)
                        .font(.caption2)
                        .foregroundStyle(Paper.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func deadlineLine(_ deadline: WidgetDeadline) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(countdown(deadline.date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(daysUntil(deadline.date) <= 3 ? Paper.wrong : Paper.tint(deadline.colorHex))
            Text("\(deadline.courseCode) · \(deadline.title)")
                .font(.caption2)
                .foregroundStyle(Paper.ink)
                .lineLimit(1)
        }
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }

    private func timeRange(_ event: WidgetEvent) -> String {
        guard let end = event.end else { return time(event.start) }
        return "\(time(event.start)) – \(time(end))"
    }

    private func daysUntil(_ date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.date),
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }

    private func countdown(_ date: Date) -> String {
        switch daysUntil(date) {
        case 0: return "Aujourd'hui"
        case 1: return "Demain"
        case let days: return "Dans \(days) j"
        }
    }
}

// MARK: - Centre de contrôle

/// Un bouton « Chrono » pour le Centre de contrôle, l'écran verrouillé et le
/// bouton Action : ouvre StudyTrack sur Focus, sans chercher l'app.
@available(iOS 18.0, *)
struct FocusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StudyTrackFocusControl") {
            ControlWidgetButton(action: OpenURLIntent(WidgetLink.focus)) {
                Label("Chrono StudyTrack", systemImage: "timer")
            }
        }
        .displayName("Chrono StudyTrack")
        .description("Ouvre le chrono de StudyTrack.")
    }
}

/// Un interrupteur pause / reprise pour la session en cours.
///
/// Il complète `FocusControl` au lieu de le remplacer : démarrer une session
/// demande de choisir un cours, donc l'app ; la mettre en pause, non. Sans
/// session, l'interrupteur le dit et ne fait rien.
@available(iOS 18.0, *)
struct FocusPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StudyTrackFocusPauseControl",
                                   provider: FocusTimerValueProvider()) { value in
            ControlWidgetToggle(isOn: value.isRunning, action: ToggleFocusTimerIntent()) {
                Text(value.label)
            } valueLabel: { isOn in
                Label(value.hasSession ? (isOn ? "En cours" : "En pause") : "Aucune session",
                      systemImage: isOn ? "pause.fill" : "play.fill")
            }
            .tint(.brown)
        }
        .displayName("Pause du chrono")
        .description("Met en pause ou relance la session en cours.")
    }
}

@available(iOS 18.0, *)
struct FocusTimerValue {
    var hasSession: Bool
    var isRunning: Bool
    var label: String
}

/// Lit le chrono dans l'instantané partagé, le même que les widgets.
@available(iOS 18.0, *)
struct FocusTimerValueProvider: ControlValueProvider {
    var previewValue: FocusTimerValue {
        FocusTimerValue(hasSession: true, isRunning: true, label: "CS-250 · Exercices")
    }

    func currentValue() async throws -> FocusTimerValue {
        guard let timer = WidgetBridge.read()?.timer else {
            return FocusTimerValue(hasSession: false, isRunning: false, label: "Chrono")
        }
        return FocusTimerValue(hasSession: true, isRunning: timer.isRunning, label: timer.label)
    }
}
