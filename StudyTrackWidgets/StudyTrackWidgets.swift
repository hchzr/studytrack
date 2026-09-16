import WidgetKit
import ActivityKit
import SwiftUI
import UIKit

// MARK: - Timeline

struct StudyTrackEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?

    static var placeholder: StudyTrackEntry {
        StudyTrackEntry(date: Date(), snapshot: WidgetSnapshot(
            updatedAt: Date(),
            weekSeconds: 12 * 3600 + 1800,
            streak: 6,
            level: 3,
            xp: 240,
            todoCount: 7,
            todos: [
                WidgetTodo(id: "1", courseCode: "CS-250", title: "Vidéo 2.1 · Récurrences", kind: "Vidéo", colorHex: "#4F46E5"),
                WidgetTodo(id: "2", courseCode: "CS-250", title: "Exercice 2.2", kind: "Exercice", colorHex: "#4F46E5"),
                WidgetTodo(id: "3", courseCode: "MATH-101", title: "Vidéo 1.2 · Continuité", kind: "Vidéo", colorHex: "#0EA5E9")
            ],
            nextExamTitle: "Midterm",
            nextExamCourse: "CS-250",
            nextExamDate: Date().addingTimeInterval(12 * 86400)))
    }
}

struct StudyTrackProvider: TimelineProvider {
    func placeholder(in context: Context) -> StudyTrackEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (StudyTrackEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(StudyTrackEntry(date: Date(), snapshot: WidgetBridge.read()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StudyTrackEntry>) -> Void) {
        let entry = StudyTrackEntry(date: Date(), snapshot: WidgetBridge.read())
        // L'app recharge explicitement les timelines ; ce rafraîchissement périodique
        // n'est qu'un filet de sécurité.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widgets

struct StudyTrackWidget: Widget {
    let kind = "StudyTrackWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            StudyTrackWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // Un tap ouvre « Aujourd'hui » : c'est là que la liste continue.
                .widgetURL(WidgetLink.today)
        }
        .configurationDisplayName("Cette semaine")
        .description("Ce qu'il te reste à faire et ton temps de travail.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Widget de la session en cours (chrono lancé depuis l'app).
struct StudyTrackTimerWidget: Widget {
    let kind = "StudyTrackTimerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StudyTrackProvider()) { entry in
            StudyTrackTimerWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // Le widget « temps » mène au chrono, pas à la liste.
                .widgetURL(WidgetLink.focus)
        }
        .configurationDisplayName("Temps de travail")
        .description("Ton temps travaillé sur les 7 derniers jours.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Live Activity : le chrono en cours

/// Chrono en cours, sur l'écran verrouillé et dans l'îlot dynamique.
///
/// Le compteur s'appuie sur `Text(timerInterval:)` : c'est le **système** qui le
/// fait avancer, chaque seconde, sans que l'app envoie quoi que ce soit. Une Live
/// Activity qui recevrait une mise à jour par seconde coûterait de la batterie et
/// du réseau pour un résultat identique.
struct StudyActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyActivityAttributes.self) { context in
            StudyActivityLockView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Les régions leading/trailing sont courtes par construction : y
                // mettre le compteur et l'état évite d'élargir l'îlot, et le texte
                // long va dans la région basse, qui occupe toute la largeur.
                DynamicIslandExpandedRegion(.leading) {
                    StudyActivityTimer(state: context.state, font: .title3)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StudyActivityState(state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(context.attributes.courseCode)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            Text(context.attributes.courseName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Image(systemName: context.attributes.taskIcon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(context.attributes.taskLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let target = context.attributes.target {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(target)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                // Le cours plutôt qu'une icône générique : c'est l'information qui
                // manquait dans la forme compacte.
                Text(context.attributes.courseCode)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } compactTrailing: {
                StudyActivityTimer(state: context.state, font: .caption2)
            } minimal: {
                StudyActivityTimer(state: context.state, font: .caption2)
            }
            .keylineTint(context.state.runningSince != nil ? .indigo : .orange)
        }
    }
}

/// Pastille d'état : le chrono tourne-t-il, ou est-il en pause ?
///
/// Sans elle, rien ne distinguait une session en cours d'une session suspendue :
/// le compteur affichait la même chose dans les deux cas.
struct StudyActivityState: View {
    let state: StudyActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.runningSince != nil ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(state.runningSince != nil ? "en cours" : "en pause")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.runningSince != nil ? "Chrono en cours" : "Chrono en pause")
    }
}

/// Vue de l'écran verrouillé et de la bannière.
struct StudyActivityLockView: View {
    let context: ActivityViewContext<StudyActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(context.attributes.courseCode)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(context.attributes.taskLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let target = context.attributes.target {
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(context.attributes.courseName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StudyActivityTimer(state: context.state, font: .title2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Le compteur : vivant tant que la session tourne, figé en pause.
struct StudyActivityTimer: View {
    let state: StudyActivityAttributes.ContentState
    var font: Font

    var body: some View {
        Group {
            if let since = state.runningSince {
                // Le système fait avancer ce texte tout seul.
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
            } else {
                Text(Self.frozen(state.accumulated))
            }
        }
        .font(font.monospacedDigit().weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private static func frozen(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

@main
struct StudyTrackWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StudyTrackWidget()
        StudyTrackTimerWidget()
        StudyActivityWidget()
    }
}

// MARK: - Vues

struct StudyTrackWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StudyTrackEntry

    // Tailles conservées, mais elles suivent la taille de texte du lecteur.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSmall: CGFloat = 30
    @ScaledMetric(relativeTo: .title) private var heroMedium: CGFloat = 26
    @ScaledMetric(relativeTo: .title2) private var heroLarge: CGFloat = 22

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.hasContent {
            switch family {
            case .systemSmall: small(snapshot)
            case .systemLarge: large(snapshot)
            default: medium(snapshot)
            }
        } else {
            emptyState
        }
    }

    // MARK: Vide

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Ouvre StudyTrack")
                .font(.caption.weight(.semibold))
            Text("Tes données apparaîtront ici.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Small

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(snapshot)
            Spacer(minLength: 0)
            Text(WidgetFormat.hours(snapshot.weekSeconds))
                .font(.system(size: heroSmall, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("cette semaine")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            footer(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Medium

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header(snapshot)
                Spacer(minLength: 0)
                Text(WidgetFormat.hours(snapshot.weekSeconds))
                    .font(.system(size: heroMedium, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("cette semaine")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                footer(snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            todoList(snapshot, limit: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Large

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                header(snapshot)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(WidgetFormat.hours(snapshot.weekSeconds))
                        .font(.system(size: heroLarge, weight: .bold, design: .rounded))
                    Text("cette semaine")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            todoList(snapshot, limit: 5)

            if let title = snapshot.nextExamTitle, let date = snapshot.nextExamDate {
                Spacer(minLength: 0)
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.orange.widgetInk)
                    Text([snapshot.nextExamCourse, title].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(WidgetFormat.countdown(to: date))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.orange.widgetInk)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Fragments

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.caption2)
                .foregroundStyle(.tint)
            Text("StudyTrack")
                .font(.caption.weight(.bold))
            Spacer(minLength: 4)
            if snapshot.streak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill").font(.caption2)
                    Text("\(snapshot.streak)").font(.caption2.weight(.bold))
                }
                .foregroundStyle(Color.orange.widgetInk)
            }
        }
    }

    private func footer(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot.todoCount == 0 ? "checkmark.circle.fill" : "list.bullet")
                .font(.caption2)
            Text(snapshot.todoCount == 0 ? "À jour" : "\(snapshot.todoCount) à faire")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(snapshot.todoCount == 0 ? Color.green.widgetInk : Color.secondary)
    }

    private func todoList(_ snapshot: WidgetSnapshot, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if snapshot.todos.isEmpty {
                Text("Rien à faire cette semaine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.todos.prefix(limit)) { todo in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hexString: todo.colorHex))
                            .frame(width: 3, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(todo.courseCode)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color(hexString: todo.colorHex).widgetInk)
                            Text(todo.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if snapshot.todoCount > limit {
                    Text("+ \(snapshot.todoCount - limit) autres")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Widget compact centré sur le temps de travail.
struct StudyTrackTimerWidgetView: View {
    let entry: StudyTrackEntry

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 32

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.hasContent {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                    Text("7 derniers jours")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(WidgetFormat.hours(snapshot.weekSeconds))
                    .font(.system(size: heroSize, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    if snapshot.streak > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill").font(.caption2)
                            Text("\(snapshot.streak) j").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(Color.orange.widgetInk)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.caption2)
                        Text("Niv. \(snapshot.level)").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(Color.yellow.widgetInk)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Ouvre StudyTrack")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Aides locales (le widget ne dépend pas des types de l'app)

extension Color {
    /// Encre lisible pour du texte de cette teinte, sur le fond du widget.
    ///
    /// L'extension ne peut pas importer la couche `Palette` de l'app : elle
    /// utilise le solveur partagé et sa propre surface de référence.
    var widgetInk: Color {
        Color(uiColor: UIColor { traits in
            let style = traits.userInterfaceStyle
            let tc = UITraitCollection(userInterfaceStyle: style)
            let hue = UIColor(self).resolvedColor(with: tc).contrastRGB
            let surface = ContrastSurface.widgetRGB(for: style)
            return ColorContrast.accessibleVariant(of: hue,
                                                   against: surface,
                                                   target: ColorContrast.textTarget).uiColor
        })
    }
}

extension Color {
    /// Équivalent local de `Color(hex:)` de l'app.
    init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = 0.4; g = 0.35; b = 0.9
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
