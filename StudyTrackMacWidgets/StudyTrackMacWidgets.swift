import SwiftUI
import WidgetKit

/// Les widgets du bureau : le chrono, la journée, la semaine.
@main
struct StudyTrackMacWidgets: WidgetBundle {
    var body: some Widget {
        TimerWidget()
        TodayWidget()
        WeekWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: MacWidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = MacWidgetSnapshot.load()
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview && snapshot.courses.isEmpty ? .preview : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // L'app recharge les widgets à chaque changement ; ce rappel ne sert
        // qu'à passer minuit (« aujourd'hui » repart à zéro).
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [SnapshotEntry(date: Date(), snapshot: MacWidgetSnapshot.load())], policy: .after(next)))
    }
}

// MARK: - Chrono

struct TimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mac.timer", provider: SnapshotProvider()) { entry in
            TimerWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Chrono")
        .description("La session en cours, ou le temps du jour.")
        .supportedFamilies([.systemSmall])
    }
}

struct TimerWidgetView: View {
    let snapshot: MacWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let timer = snapshot.timer {
                HStack(spacing: 6) {
                    Circle().fill(Color(widgetHex: timer.colorHex)).frame(width: 8, height: 8)
                    Text(timer.courseCode.isEmpty ? "Session" : timer.courseCode).font(.caption.weight(.semibold))
                }
                Spacer(minLength: 0)
                if let end = timer.breakEndsAt, end > Date() {
                    Text(end, style: .timer)
                        .font(.system(size: 30, weight: .light, design: .serif)).monospacedDigit()
                    Text("Pause").font(.caption).foregroundStyle(.secondary)
                } else if let start = timer.counterStart {
                    Text(start, style: .timer)
                        .font(.system(size: 30, weight: .light, design: .serif)).monospacedDigit()
                    Text(timer.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(Duration.seconds(timer.accumulated).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 30, weight: .light, design: .serif)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("En pause").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Aujourd'hui", systemImage: "timer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(widgetHours(snapshot.todaySeconds))
                    .font(.system(size: 30, weight: .light, design: .serif))
                Text("\(widgetHours(snapshot.weekSeconds)) cette semaine").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Aujourd'hui

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mac.today", provider: SnapshotProvider()) { entry in
            TodayWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("À faire")
        .description("Ce qu'il reste à faire, et le temps du jour.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayWidgetView: View {
    let snapshot: MacWidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("À faire").font(.headline)
                Spacer()
                if let timer = snapshot.timer, let start = timer.counterStart {
                    Label { Text(start, style: .timer).monospacedDigit() } icon: { Image(systemName: "timer") }
                        .font(.caption)
                        .foregroundStyle(Color(widgetHex: timer.colorHex))
                } else {
                    Text(widgetHours(snapshot.todaySeconds)).font(.caption).foregroundStyle(.secondary)
                }
            }
            let todos = snapshot.todos.prefix(family == .systemLarge ? 8 : 3)
            if todos.isEmpty {
                Spacer()
                Text("Rien en attente.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(Array(todos)) { todo in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(widgetHex: todo.colorHex)).frame(width: 3, height: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(todo.title).font(.callout).lineLimit(1)
                            Text(todo.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: todo.icon).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Semaine

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mac.week", provider: SnapshotProvider()) { entry in
            WeekWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Semaine")
        .description("Chaque cours : ce qui est fait cette semaine.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct WeekWidgetView: View {
    let snapshot: MacWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.week > 0 ? "Semaine \(snapshot.week)" : "Cette semaine").font(.headline)
                Spacer()
                Text(widgetHours(snapshot.weekSeconds)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.courses.prefix(6)) { course in
                HStack(spacing: 8) {
                    Text(course.code).font(.caption.weight(.semibold)).frame(width: 70, alignment: .leading)
                    ProgressView(value: Double(course.done), total: Double(max(course.total, 1)))
                        .tint(Color(widgetHex: course.colorHex))
                    Text("\(course.done)/\(course.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    if course.late > 0 {
                        Text("\(course.late)").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

extension MacWidgetSnapshot {
    static let preview = MacWidgetSnapshot(
        updatedAt: Date(), todaySeconds: 7800, weekSeconds: 44_000, week: 4,
        timer: Timer(courseCode: "MATH-101", colorHex: "#3E7CB1", label: "Exercice 4.2",
                     runningSince: Date().addingTimeInterval(-900), accumulated: 600, breakEndsAt: nil),
        todos: [
            Todo(id: "1", title: "Exercice 3.4", detail: "CS-107 · À refaire", colorHex: "#C0504D", icon: "arrow.counterclockwise"),
            Todo(id: "2", title: "Série 4", detail: "MATH-101 · Exercice", colorHex: "#3E7CB1", icon: "list.number"),
            Todo(id: "3", title: "Théorie 4.1", detail: "PHYS-101 · Théorie", colorHex: "#4F9D69", icon: "play.rectangle"),
        ],
        courses: [
            CourseWeek(id: "a", code: "MATH-101", colorHex: "#3E7CB1", done: 3, total: 5, late: 0),
            CourseWeek(id: "b", code: "CS-107", colorHex: "#C0504D", done: 1, total: 4, late: 2),
            CourseWeek(id: "c", code: "PHYS-101", colorHex: "#4F9D69", done: 4, total: 4, late: 0),
        ])
}
