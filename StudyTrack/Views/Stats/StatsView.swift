import SwiftUI
import SwiftData

/// Récap visuel du temps de travail + gamification + charge EPFL.
struct StatsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    @State private var period: StatsPeriod = .week

    private var periodSessions: [StudySession] {
        let range = DateUtils.dateRange(days: period.days)
        return sessions.filter { $0.startedAt >= range.start && $0.startedAt < range.end }
    }

    private var totalSeconds: Int {
        periodSessions.reduce(0) { $0 + $1.durationSeconds }
    }

    private var byTaskType: [(type: TaskType, seconds: Int)] {
        TaskType.allCases.compactMap { type in
            let seconds = periodSessions.filter { $0.taskType == type }
                .reduce(0) { $0 + $1.durationSeconds }
            return seconds > 0 ? (type, seconds) : nil
        }
        .sorted { $0.seconds > $1.seconds }
    }

    private var byCourse: [(course: Course?, seconds: Int)] {
        let grouped = Dictionary(grouping: periodSessions, by: { $0.course?.id })
        return grouped.map { key, items in
            let course = courses.first { $0.id == key }
            return (course, items.reduce(0) { $0 + $1.durationSeconds })
        }
        .sorted { $0.seconds > $1.seconds }
    }

    /// Attendu **proportionnel à la période affichée**, dérivé de l'attendu
    /// hebdomadaire.
    ///
    /// Cette carte annonçait un total **semestriel** à côté d'un récapitulatif
    /// « aujourd'hui » : deux échelles de temps dans le même écran, dont aucune ne
    /// se comparait au réel affiché juste à côté.
    private var workload: WorkloadDelta {
        let range = DateUtils.dateRange(days: period.days)
        let weekly = WorkloadEngine.aggregateWeekly(courses: courses.filter(\.isTracked),
                                                    hoursPerCredit: app.settings.hoursPerCredit,
                                                    from: range.start,
                                                    to: range.end)
        var scaled = WorkloadDelta()
        let factor = Double(period.days) / 7.0
        scaled.expectedSeconds = Int((Double(weekly.expectedSeconds) * factor).rounded())
        scaled.lectureSeconds = Int((Double(weekly.lectureSeconds) * factor).rounded())
        scaled.exerciseSeconds = max(0, scaled.expectedSeconds - scaled.lectureSeconds)
        scaled.classSeconds = weekly.classSeconds
        scaled.actualSeconds = weekly.actualSeconds
        return scaled
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                periodPicker
                totalsCard
                dailyCard
                taskTypeCard
                courseCard
                workloadCard
                gamificationCard
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Statistiques")
    }

    // MARK: Période

    private var periodPicker: some View {
        Picker("Période", selection: $period) {
            ForEach(StatsPeriod.allCases) { value in
                Text(value.label).tag(value)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Totaux

    private var totalsCard: some View {
        Card {
            HStack(spacing: 12) {
                StatCard(icon: "clock.fill",
                         value: DateUtils.hoursLabel(seconds: totalSeconds),
                         title: "Temps total",
                         tint: .blue)
                StatCard(icon: "list.bullet",
                         value: "\(periodSessions.count)",
                         title: "Sessions",
                         tint: .purple)
                StatCard(icon: "flame.fill",
                         value: "\(GamificationEngine.currentStreak(sessions: sessions)) j",
                         title: "Série actuelle",
                         tint: .orange)
                StatCard(icon: "calendar",
                         value: "\(Set(periodSessions.map { Calendar.current.startOfDay(for: $0.startedAt) }).count)",
                         title: "Jours actifs",
                         tint: .green)
            }
        }
    }

    // MARK: Par jour

    /// Quatorze jours, un par colonne, les jours vides compris : c'est le rythme
    /// qu'on lit, pas seulement le total.
    private var dailyCard: some View {
        let totals = SessionStats.dailyTotals(sessions, days: 14)
        let top = max(totals.map(\.seconds).max() ?? 1, 1)
        let average = SessionStats.averageActiveDaySeconds(totals)
        let calendar = Calendar.current
        return Card(title: "14 derniers jours", icon: "chart.bar.fill",
                    trailing: average > 0 ? "≈ \(DateUtils.hoursLabel(seconds: average)) / jour actif" : nil) {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(alignment: .bottom, spacing: Layout.snug) {
                    ForEach(totals) { total in
                        let isToday = calendar.isDateInToday(total.day)
                        VStack(spacing: Layout.tight) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(total.isEmpty
                                      ? Color.secondary.badgeFill
                                      : (isToday ? Theme.accent : Theme.accent.badgeInk))
                                .frame(height: max(3, 72 * Double(total.seconds) / Double(top)))
                                .frame(maxWidth: .infinity)
                            Text(DateUtils.weekdayInitial(total.day))
                                .font(.caption2.weight(isToday ? .bold : .regular))
                                .foregroundStyle(isToday ? Theme.accentInk : .secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(DateUtils.shortDay.string(from: total.day)) : \(DateUtils.durationLabel(seconds: total.seconds))")
                    }
                }
                .frame(height: 96, alignment: .bottom)

                HStack(spacing: Layout.gutter) {
                    Text("Meilleur jour : \(DateUtils.durationLabel(seconds: top))")
                    Spacer()
                    Text("\(totals.filter { !$0.isEmpty }.count) / 14 jours actifs")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Par type

    private var taskTypeCard: some View {
        Card(title: "Par type de travail", icon: "square.stack.3d.up.fill") {
            if byTaskType.isEmpty {
                Text("Aucune session sur cette période.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(byTaskType, id: \.type) { entry in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(entry.type.tint.accessibleMark)
                                    .frame(width: 26,
                                           height: max(4, 90 * Double(entry.seconds) / Double(max(totalSeconds, 1))))
                                Image(systemName: entry.type.icon)
                                    .font(.caption2)
                                    .foregroundStyle(entry.type.tint.accessibleMark)
                                Text(entry.type.shortLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .frame(height: 140, alignment: .bottom)

                    Divider()

                    ForEach(byTaskType, id: \.type) { entry in
                        LabeledProgress(title: entry.type.label,
                                        progress: Double(entry.seconds) / Double(max(totalSeconds, 1)),
                                        color: entry.type.tint,
                                        countLabel: DateUtils.hoursLabel(seconds: entry.seconds))
                    }
                }
            }
        }
    }

    // MARK: Par cours

    private var courseCard: some View {
        Card(title: "Par matière", icon: "books.vertical.fill") {
            if byCourse.isEmpty {
                Text("Aucune session sur cette période.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(byCourse.enumerated()), id: \.offset) { _, entry in
                        let color = entry.course.map { Color(hex: $0.colorHex) } ?? .secondary
                        LabeledProgress(title: entry.course?.code ?? "Sans cours",
                                        progress: Double(entry.seconds) / Double(max(totalSeconds, 1)),
                                        color: color,
                                        countLabel: DateUtils.hoursLabel(seconds: entry.seconds))
                    }
                }
            }
        }
    }

    // MARK: Charge EPFL

    private var workloadCard: some View {
        Card(title: "EPFL attendu vs réel", icon: "scalemass.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    workloadStat(title: "Attendu (\(period.label.lowercased()))",
                                 value: workload.expectedLabel,
                                 tint: .blue)
                    workloadStat(title: "Réel (dont cours)",
                                 value: workload.actualLabel,
                                 tint: .purple)
                    workloadStat(title: "Écart",
                                 value: workload.deltaLabel,
                                 tint: workload.isBehind ? .red : .green)
                }
                Divider()
                HStack(spacing: 16) {
                    workloadStat(title: "Heures de cours",
                                 value: workload.classLabel,
                                 tint: .blue)
                    workloadStat(title: "Attendu cours",
                                 value: DateUtils.hoursLabel(seconds: workload.lectureSeconds),
                                 tint: .secondary)
                    workloadStat(title: "Attendu exos/perso",
                                 value: DateUtils.hoursLabel(seconds: workload.exerciseSeconds),
                                 tint: .secondary)
                }
                LabeledProgress(title: "Réel / attendu",
                                progress: workload.completion,
                                color: workload.isBehind ? .red : .green)
                Text("Hypothèse : \(String(format: "%.0f", app.settings.hoursPerCredit)) h de travail par crédit ECTS (réglable dans le profil).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func workloadStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint.accessibleInk)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Gamification

    private var gamificationCard: some View {
        let xp = GamificationEngine.totalXP(courses: courses, sessions: sessions)
        let level = GamificationEngine.level(forXP: xp)
        let badges = GamificationEngine.earnedBadges(courses: courses, sessions: sessions)
        return Card(title: "Gamification", icon: "trophy.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    workloadStat(title: "XP total", value: "\(xp)", tint: .yellow)
                    workloadStat(title: "Niveau", value: "\(level)", tint: Theme.accent)
                    workloadStat(title: "Meilleure série",
                                 value: "\(GamificationEngine.longestStreak(sessions: sessions)) j",
                                 tint: .orange)
                }
                LabeledProgress(title: "Vers le niveau \(level + 1)",
                                progress: GamificationEngine.levelProgress(forXP: xp),
                                color: Theme.accent)

                Divider()

                Text("Feuille récapitulative des cours")
                    .font(.subheadline.weight(.semibold))
                ForEach(courses.filter(\.isTracked)) { course in
                    let progress = ProgressEngine.progress(for: course)
                    HStack(spacing: 12) {
                        ProgressRing(progress: progress.overallPercent,
                                     color: Color(hex: course.colorHex),
                                     size: 40,
                                     lineWidth: 5)
                        VStack(alignment: .leading, spacing: Layout.tight) {
                            Text(course.displayCode).font(.subheadline.weight(.semibold))
                            Text("Théorie \(pct(progress.theoryPercent)) · Exos \(pct(progress.exercisePercent)) · Corr. \(pct(progress.correctionPercent))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(GamificationEngine.xp(for: course)) XP")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if !badges.isEmpty {
                    Divider()
                    Text("Badges (\(badges.count))")
                        .font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                        ForEach(badges) { badge in
                            VStack(spacing: 4) {
                                Image(systemName: badge.icon)
                                    .font(.title3)
                                    .foregroundStyle(badge.color.accessibleMark)
                                Text(badge.title)
                                    .font(.caption2)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(badge.color.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private func pct(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
