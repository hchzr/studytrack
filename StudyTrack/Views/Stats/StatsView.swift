import SwiftUI
import SwiftData

/// Récap visuel du temps de travail + gamification + charge EPFL.
struct StatsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @Query private var terms: [AcademicTerm]
    @Query private var events: [LinkedCalendarEvent]
    @Query(sort: \AcademicMilestone.date) private var milestones: [AcademicMilestone]

    @State private var period: StatsPeriod = .week
    @State private var showingCoverage = false
    @State private var showingLife = false

    private var periodSessions: [StudySession] {
        let range = DateUtils.dateRange(days: period.days)
        return sessions.filter { $0.startedAt >= range.start && $0.startedAt < range.end }
    }

    private var totalSeconds: Int {
        periodSessions.reduce(0) { $0 + $1.durationSeconds }
    }

    private var byTaskType: [(type: TaskType, seconds: Int)] {
        // Trois catégories et Anki : une ancienne session « Vidéo » compte
        // dans la théorie, pas dans une ligne à part.
        TaskType.reportCategories.compactMap { type in
            let seconds = periodSessions.filter { $0.taskType.canonical == type }
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
                // Ce pour quoi on ouvre les statistiques d'abord — le temps —,
                // puis la charge, et seulement ensuite le calendrier de l'école
                // et l'audit du suivi, qui ne changent pas d'un jour à l'autre.
                periodPicker
                totalsCard
                dailyCard
                taskTypeCard
                courseCard
                workloadCard
                epflLifeCard
                coverageCard
                gamificationCard
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Statistiques")
        .navigationDestination(isPresented: $showingCoverage) {
            CoverageView()
        }
        .navigationDestination(isPresented: $showingLife) {
            EPFLLifeView()
        }
        .onAppear {
            #if DEBUG
            if PreviewLaunch.isSet(PreviewLaunch.coverageFlag) { showingCoverage = true }
            if PreviewLaunch.isSet(PreviewLaunch.epflLifeFlag) { showingLife = true }
            #endif
        }
    }

    // MARK: Vie de l'EPFL

    /// La prochaine échéance de l'école : fin des cours, examens, délai.
    ///
    /// Un étudiant doit voir arriver « fin des enseignements » et « début des
    /// examens » sans avoir à ouvrir un navigateur.
    private var epflLifeCard: some View {
        let upcoming = AcademicCalendarService.upcoming(milestones)
        let next = AcademicCalendarService.nextStructural(milestones)
        return NavigationLink {
            EPFLLifeView()
        } label: {
            Card(title: "Vie de l'EPFL", icon: "building.columns.fill") {
                VStack(alignment: .leading, spacing: Layout.block) {
                    if let next {
                        HStack(alignment: .top, spacing: Layout.control) {
                            Image(systemName: next.kind.icon)
                                .foregroundStyle(Theme.accent.accessibleMark)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(next.title)
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(DateUtils.shortDay.string(from: next.date)) · \(next.value.countdown())")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Layout.inline)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("Aucune échéance connue. Ouvre l'écran pour actualiser depuis la page de l'EPFL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(upcoming.isEmpty
                         ? "Calendrier académique officiel"
                         : "\(upcoming.count) échéance\(upcoming.count > 1 ? "s" : "") à venir · calendrier académique officiel")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(next.map { "Vie de l'EPFL. \($0.title), \($0.value.countdown())" } ?? "Vie de l'EPFL")
    }

    // MARK: Couverture

    /// Ce qui échappe au suivi, en tête des statistiques.
    ///
    /// Un compte de temps ne sert à rien s'il manque la moitié des exercices : la
    /// première question est « qu'est-ce que je ne suis pas en train de suivre ? ».
    private var coverageCard: some View {
        let report = CoverageBuilder.report(courses: courses,
                                            term: AcademicTerm.resolve(from: terms),
                                            hasTimetable: !events.isEmpty)
        return NavigationLink {
            CoverageView()
        } label: {
            Card(title: "Couverture du suivi", icon: "checklist") {
                VStack(alignment: .leading, spacing: Layout.block) {
                    HStack(alignment: .firstTextBaseline, spacing: Layout.control) {
                        Text("\(Int((report.coverage * 100).rounded())) %")
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(coverageInk(report.coverage))
                        Spacer(minLength: Layout.inline)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    LabeledProgress(title: "Cours sans aucun manque",
                                    progress: report.coverage,
                                    color: coverageInk(report.coverage),
                                    countLabel: "\(report.healthyCourses)/\(report.trackedCount)")
                    Text(coverageSubtitle(report))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Couverture du suivi, \(Int((report.coverage * 100).rounded())) pour cent, \(report.healthyCourses) cours sur \(report.trackedCount) sans manque")
    }

    private func coverageInk(_ value: Double) -> Color {
        switch value {
        case 1: return .green
        case 0.6...: return .yellow
        default: return .orange
        }
    }

    private func coverageSubtitle(_ report: CoverageReport) -> String {
        if report.trackedCount == 0 { return "Aucun cours suivi pour l'instant." }
        if report.isComplete { return "Tout est suivi : rien ne manque." }
        var parts: [String] = []
        if report.count(.blocking) > 0 { parts.append("\(report.count(.blocking)) à corriger") }
        if report.count(.warning) > 0 { parts.append("\(report.count(.warning)) incomplets") }
        if report.count(.info) > 0 { parts.append("\(report.count(.info)) à compléter") }
        return parts.joined(separator: " · ")
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
        // Des tuiles posées sur la page, pas dans une carte : une tuile de la
        // couleur de la carte qui la contient disparaissait.
        VStack(alignment: .leading, spacing: Layout.control) {
            SectionHeader(title: period.rangeLabel)
            HStack(alignment: .top, spacing: Layout.control) {
                StatCard(icon: "clock.fill",
                         value: DateUtils.hoursLabel(seconds: totalSeconds),
                         title: "Temps total")
                StatCard(icon: "list.bullet",
                         value: "\(periodSessions.count)",
                         title: "Sessions")
                StatCard(icon: "calendar",
                         value: "\(Set(periodSessions.map { Calendar.current.startOfDay(for: $0.startedAt) }).count)",
                         title: "Jours actifs")
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
        Card(title: "Par catégorie", icon: "square.stack.3d.up.fill") {
            if byTaskType.isEmpty {
                Text("Aucune session sur cette période.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Une barre de composition : la part de chaque type d'un
                    // coup d'œil. Le petit histogramme qui la précédait répétait
                    // la liste juste en dessous, avec des barres minuscules sous
                    // un grand vide.
                    GeometryReader { geo in
                        let total = Double(max(totalSeconds, 1))
                        let gaps = CGFloat(max(0, byTaskType.count - 1)) * 2
                        HStack(spacing: 2) {
                            ForEach(byTaskType, id: \.type) { entry in
                                Rectangle()
                                    .fill(entry.type.tint.accessibleMark)
                                    .frame(width: max(3, (geo.size.width - gaps) * Double(entry.seconds) / total))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 12)
                    .accessibilityHidden(true)

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
        return Card(title: "Niveau et badges", icon: "trophy.fill") {
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
