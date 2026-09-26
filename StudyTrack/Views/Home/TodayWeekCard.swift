import SwiftUI

/// « Cette semaine », cours par cours : une barre et ce qui reste.
///
/// La carte précédente donnait trois chiffres globaux et la charge EPFL — utiles
/// au bilan, muets sur la question qu'on se pose en ouvrant l'app : **dans quel
/// cours** suis-je en retard ? Les chiffres et la charge vivent désormais dans le
/// Bilan ; ici, une ligne par cours, qui ouvre le cours.
struct TodayWeekCard: View {
    let courses: [Course]
    let weekSeconds: Int
    let streak: Int
    var onOpenCourse: (Course) -> Void
    var onOpenStats: () -> Void

    private struct Row: Identifiable {
        let course: Course
        let week: WeeklyProgress
        var id: UUID { course.id }
        var total: Int { week.videoCount + week.exerciseCount }
        var done: Int { week.watchedCount + week.doneCount }
        var remaining: Int { total - done }
    }

    private var rows: [Row] {
        courses
            .map { Row(course: $0, week: ProgressEngine.weekProgress(for: $0, week: $0.currentWeek)) }
            // Ce qui reste d'abord, le plus chargé en tête ; les cours à jour ensuite.
            .sorted { lhs, rhs in
                if (lhs.remaining > 0) != (rhs.remaining > 0) { return lhs.remaining > 0 }
                if lhs.remaining != rhs.remaining { return lhs.remaining > rhs.remaining }
                return lhs.course.displayCode < rhs.course.displayCode
            }
    }

    var body: some View {
        Card(title: "Cette semaine", icon: "calendar") {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    Button { onOpenCourse(row.course) } label: { rowView(row) }
                        .buttonStyle(.plain)
                    Divider().padding(.leading, 14)
                }
                Button(action: onOpenStats) {
                    HStack(spacing: Layout.inline) {
                        Image(systemName: "chart.bar.xaxis")
                            .foregroundStyle(Theme.accentInk)
                        Text(summary)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Layout.inline)
                        Text("Bilan")
                            .foregroundStyle(Theme.accentInk)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .padding(.top, Layout.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(summary). Ouvrir le bilan")
            }
        }
    }

    private var summary: String {
        let hours = DateUtils.hoursLabel(seconds: weekSeconds)
        return streak > 0 ? "\(hours) sur 7 j · \(streak) j d'affilée" : "\(hours) sur 7 j"
    }

    private func rowView(_ row: Row) -> some View {
        let tint = Color(hex: row.course.colorHex)
        return HStack(spacing: Layout.block) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: Layout.tight) {
                HStack(spacing: Layout.snug) {
                    Text(row.course.displayCode)
                        .font(.subheadline.weight(.semibold))
                    Text(detail(row))
                        .font(.caption)
                        .foregroundStyle(row.remaining == 0 ? Color.green.accessibleInk : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if row.total > 0 {
                        Text("\(row.done)/\(row.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: Double(row.done), total: Double(max(row.total, 1)))
                    .tint(tint)
                    .opacity(row.total == 0 ? 0.3 : 1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Layout.control)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.course.displayCode), \(detail(row))")
    }

    private func detail(_ row: Row) -> String {
        guard row.total > 0 else { return "rien de prévu" }
        guard row.remaining > 0 else { return "à jour" }
        var parts: [String] = []
        let theory = row.week.videoCount - row.week.watchedCount
        let exercises = row.week.exerciseCount - row.week.doneCount
        if theory > 0 { parts.append("\(theory) théorie") }
        if exercises > 0 { parts.append("\(exercises) exo\(exercises > 1 ? "s" : "")") }
        return "reste " + parts.joined(separator: " · ")
    }
}
