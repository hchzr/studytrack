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
        VStack(alignment: .leading, spacing: Layout.control) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cette semaine").font(.headline)
                Spacer()
                HStack(spacing: Layout.block) {
                    legend("Théorie", TaskType.theory.tint)
                    legend("Séries", TaskType.exercise.tint)
                }
            }
            .padding(.horizontal, Layout.micro)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    Button { onOpenCourse(row.course) } label: { rowView(row) }
                        .buttonStyle(.plain)
                    Divider().padding(.leading, 16)
                }
                Button(action: onOpenStats) {
                    HStack(spacing: Layout.inline) {
                        Image(systemName: "clock")
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
            .padding(Layout.gutter)
            .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: Layout.tight) {
            Capsule().fill(color.accessibleMark).frame(width: 10, height: 5)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let hours = DateUtils.hoursLabel(seconds: weekSeconds)
        return streak > 0 ? "\(hours) de travail sur 7 j · \(streak) j d'affilée" : "\(hours) de travail sur 7 j"
    }

    /// Un cours : son code, puis deux barres côte à côte — théorie et séries de
    /// **sa** semaine en cours. Les chiffres disent quoi, les barres combien.
    private func rowView(_ row: Row) -> some View {
        let tint = Color(hex: row.course.colorHex)
        let week = row.week
        return HStack(spacing: Layout.block) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(row.course.displayCode)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(status(row))
                    .font(.caption)
                    .foregroundStyle(row.total > 0 && row.remaining == 0 ? Color.green.accessibleInk : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)
            axis(week.watchedCount, week.videoCount, TaskType.theory.tint)
            axis(week.doneCount, week.exerciseCount, TaskType.exercise.tint)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Layout.control)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.course.displayCode) : théorie \(week.watchedCount) sur \(week.videoCount), séries \(week.doneCount) sur \(week.exerciseCount)")
    }

    private func axis(_ done: Int, _ total: Int, _ tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: Layout.tight) {
            Text(total == 0 ? "—" : "\(done)/\(total)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(total > 0 && done == total ? Color.green.accessibleInk : .primary)
            ProgressBar(progress: CourseProgress.ratio(done, total), color: tint, height: 5)
                .opacity(total == 0 ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    private func status(_ row: Row) -> String {
        guard row.total > 0 else { return "rien de prévu" }
        guard row.remaining > 0 else { return "à jour" }
        return "reste \(row.remaining)"
    }
}
