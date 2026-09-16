import SwiftUI
import SwiftData

/// Progression : pourcentages, semaines, charge EPFL, récompenses.
struct ProgressTabView: View {
    let course: Course

    @Environment(AppContainer.self) private var app

    private var progress: CourseProgress { ProgressEngine.progress(for: course) }
    private var weeks: [WeeklyProgress] { ProgressEngine.weeklyProgress(for: course) }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            percentageCard
            weeklyCard
            workloadCard
            rewardsCard
        }
    }

    // MARK: Pourcentages

    private var percentageCard: some View {
        Card(title: "Pourcentages", icon: "percent") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProgressRing(progress: progress.theoryPercent,
                                 color: TaskType.video.tint, size: 62, lineWidth: 7)
                    ProgressRing(progress: progress.exercisePercent,
                                 color: TaskType.exercise.tint, size: 62, lineWidth: 7)
                    ProgressRing(progress: progress.correctionPercent,
                                 color: TaskType.correction.tint, size: 62, lineWidth: 7)
                }
                ProgressStack(progress: progress)

                if progress.bonusCount > 0 {
                    Divider()
                    LabeledProgress(title: "Bonus",
                                    progress: CourseProgress.ratio(progress.bonusDoneCount, progress.bonusCount),
                                    color: .orange,
                                    countLabel: "\(progress.bonusDoneCount)/\(progress.bonusCount) faits")
                }

                if progress.wrongOrRedoCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.red.accessibleMark)
                        Text("\(progress.wrongOrRedoCount) exercice(s) faux ou à refaire")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Semaines

    private var weeklyCard: some View {
        Card(title: "Par semaine", icon: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: 14) {
                if weeks.isEmpty {
                    Text("Aucune donnée hebdomadaire : planifie des vidéos ou des séries.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Défilement horizontal : un semestre EPFL fait 14 semaines,
                    // elles ne tiennent pas sur une largeur d'iPhone.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: 14) {
                            ForEach(weeks) { week in
                                weekColumn(week)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }

                    HStack(spacing: 16) {
                        legendItem("Théorie", TaskType.video.tint)
                        legendItem("Exercices", TaskType.exercise.tint)
                        legendItem("Corrections", TaskType.correction.tint)
                    }

                    Text("Fais défiler horizontalement pour voir toutes les semaines.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func weekColumn(_ week: WeeklyProgress) -> some View {
        let isCurrent = course.isTermRunning && week.week == course.currentWeek
        return VStack(spacing: 6) {
            Text("\(Int((week.overallPercent * 100).rounded()))%")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isCurrent ? Theme.accentInk : .secondary)
                .monospacedDigit()

            HStack(alignment: .bottom, spacing: Layout.tight) {
                bar(week.theoryPercent, TaskType.video.tint)
                bar(week.exercisePercent, TaskType.exercise.tint)
                bar(week.correctionPercent, TaskType.correction.tint)
            }
            .frame(height: 84)

            Text("S\(week.week)")
                .font(.caption2.weight(isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? Theme.accentInk : .secondary)

            if week.remainingVideoSeconds > 0 {
                Text(DateUtils.durationLabel(seconds: week.remainingVideoSeconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(" ").font(.caption2)
            }
        }
        .frame(width: 46)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? Theme.accent.opacity(0.08) : Color.clear)
        )
    }

    private func bar(_ value: Double, _ color: Color) -> some View {
        VStack {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2)
                .fill(color.accessibleMark)
                .frame(width: 9, height: max(3, 84 * min(1, max(0, value))))
        }
    }

    private func legendItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: Layout.tight) {
            RoundedRectangle(cornerRadius: 2).fill(color.accessibleMark).frame(width: 9, height: 9)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Charge EPFL

    private var workloadCard: some View {
        let weekStart = DateUtils.startOfWeek(Date())
        let weekly = WorkloadEngine.weeklyDelta(for: course,
                                                hoursPerCredit: app.settings.hoursPerCredit,
                                                from: weekStart,
                                                to: DateUtils.addWeeks(1, to: weekStart))
        let semester = WorkloadEngine.expectedToDate(for: course, hoursPerCredit: app.settings.hoursPerCredit)
        return Card(title: "Charge EPFL", icon: "scalemass.fill") {
            VStack(alignment: .leading, spacing: 14) {
                // D'abord la semaine — la seule échelle qui se traduise en action.
                LabeledProgress(title: "Cette semaine",
                                progress: weekly.completion,
                                color: weekly.isBehind ? .red : (weekly.isOnTrack ? .green : .orange),
                                countLabel: "\(weekly.actualLabel) / \(weekly.expectedLabel)")
                HStack(spacing: 12) {
                    workloadStat("Attendu / sem.", weekly.expectedLabel, .blue)
                    workloadStat("Fait / sem.", weekly.actualLabel, .purple)
                    workloadStat("Écart", weekly.deltaLabel, weekly.isBehind ? .red : .green)
                }

                Divider()

                // Puis le cumul depuis le début du semestre, en retrait.
                LabeledProgress(title: "Depuis le début du semestre",
                                progress: semester.completion,
                                color: .secondary,
                                countLabel: "\(semester.actualLabel) / \(semester.expectedLabel)")

                VStack(spacing: 10) {
                    DetailRow(icon: "building.columns.fill",
                              label: course.hasLectures ? "Heures de cours suivies" : "Heures de cours (sans amphi)",
                              value: DateUtils.hoursLabel(seconds: semester.classSeconds),
                              tint: .blue)
                    DetailRow(icon: "person.fill",
                              label: "Travail personnel enregistré",
                              value: DateUtils.hoursLabel(seconds: WorkloadEngine.studySeconds(for: course)),
                              tint: .purple)
                    DetailRow(icon: "target",
                              label: "Objectif perso / semaine",
                              value: DateUtils.hoursLabel(hours: WorkloadEngine.weeklySelfStudyHours(for: course, hoursPerCredit: app.settings.hoursPerCredit)),
                              tint: .secondary)
                }

                Text(course.hasLectures
                     ? "Hypothèse : \(Int(app.settings.hoursPerCredit)) h de travail par crédit ECTS, dont les heures d'amphi déclarées. Marque ta présence dans l'onglet Agenda pour compter les cours réels."
                     : "Ce cours est déclaré sans amphi : aucune heure de cours n'est attendue, seules comptent les heures d'exercices et le travail personnel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func workloadStat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(tint.accessibleInk).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Récompenses

    private var rewardsCard: some View {
        let xp = GamificationEngine.xp(for: course)
        let level = GamificationEngine.level(forXP: xp)
        let sessionSeconds = course.sessions.reduce(0) { $0 + $1.durationSeconds }
        let badges = GamificationEngine.earnedBadges(courses: [course], sessions: course.sessions)
        return Card(title: "Récompenses", icon: "trophy.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    workloadStat("XP du cours", "\(xp)", .yellow)
                    workloadStat("Niveau", "\(level)", Theme.accent)
                    workloadStat("Temps passé", DateUtils.hoursLabel(seconds: sessionSeconds), .blue)
                }
                LabeledProgress(title: "Vers le niveau \(level + 1)",
                                progress: GamificationEngine.levelProgress(forXP: xp),
                                color: Theme.accent)

                if badges.isEmpty {
                    Text("Aucun badge pour l'instant — continue !")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(badges) { badge in
                            VStack(spacing: Layout.tight) {
                                Image(systemName: badge.icon)
                                    .font(.title3)
                                    .foregroundStyle(badge.color.accessibleMark)
                                Text(badge.title)
                                    .font(.caption2)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(9)
                            .background(badge.color.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}
