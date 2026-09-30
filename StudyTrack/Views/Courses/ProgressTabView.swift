import SwiftUI
import SwiftData

/// Progression d'un cours : **semaine par semaine**, Théorie et Séries.
///
/// L'ancienne page empilait trois anneaux, un histogramme à faire défiler de
/// côté (trois barres par semaine, lisibles seulement avec la légende), la
/// charge EPFL et des badges. On y cherchait « où j'en suis cette semaine, et
/// qu'est-ce qui traîne des semaines passées » sans le trouver. La page est
/// désormais un calendrier : une ligne par semaine, deux barres, et ce qui
/// reste se déplie sous la semaine.
struct ProgressTabView: View {
    let course: Course

    @Environment(AppContainer.self) private var app
    @State private var expanded: Set<Int> = []
    @State private var openedVideo: TheoryItem?
    @State private var openedExercise: Exercise?

    private var weeks: [WeeklyProgress] { ProgressEngine.semesterWeeks(for: course) }
    private var current: Int { course.isTermRunning ? course.currentWeek : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            semesterCard
            weeksSection
            unplannedCard
            workloadCard
        }
        .onAppear { if current > 0 { expanded.insert(current) } }
        .sheet(item: $openedVideo) { VideoDetailSheet(video: $0) }
        .sheet(item: $openedExercise) { ExerciseSheet(exercise: $0) }
    }

    // MARK: Semestre

    private var semesterCard: some View {
        let progress = ProgressEngine.progress(for: course)
        let behind = weeks.filter { $0.week < current && $0.remainingCount > 0 }
        return Card(title: "Tout le semestre", icon: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: Layout.block) {
                WeekAxisRow(title: "Théorie", done: progress.watchedCount, total: progress.videoCount,
                            tint: TaskType.theory.tint)
                WeekAxisRow(title: "Séries", done: progress.doneCount, total: progress.exerciseCount,
                            tint: TaskType.exercise.tint)
                WeekAxisRow(title: "Corrections", done: progress.correctedCount, total: progress.doneCount,
                            tint: TaskType.correction.tint)
                if !behind.isEmpty || progress.wrongOrRedoCount > 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        if !behind.isEmpty {
                            Label("En retard sur " + behind.map { "S\($0.week)" }.joined(separator: ", "),
                                  systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(Color.orange.accessibleInk)
                        }
                        if progress.wrongOrRedoCount > 0 {
                            Label("\(progress.wrongOrRedoCount) exercice\(progress.wrongOrRedoCount > 1 ? "s" : "") faux ou à refaire",
                                  systemImage: "arrow.counterclockwise")
                                .foregroundStyle(Color.red.accessibleInk)
                        }
                    }
                    .font(.footnote.weight(.medium))
                }
            }
        }
    }

    // MARK: Semaines

    private var weeksSection: some View {
        VStack(alignment: .leading, spacing: Layout.control) {
            SectionHeader(title: "Semaine par semaine", trailing: nil)
            if weeks.allSatisfy({ !$0.hasItems }) {
                EmptyCard(icon: "calendar",
                          title: "Rien de planifié",
                          message: "Importe la théorie et les séries du cours : chaque élément est rangé dans sa semaine.",
                          actionTitle: "Importer du contenu") {
                    app.router.openContentImport(courseID: course.id)
                }
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(weeks) { week in
                            weekRow(week)
                            if week.week != weeks.last?.week {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                }
            }
        }
    }

    private func weekRow(_ week: WeeklyProgress) -> some View {
        let isCurrent = week.week == current
        let isPast = current > 0 && week.week < current
        let isOpen = expanded.contains(week.week)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard week.hasItems else { return }
                withAnimation(Motion.snappy) {
                    if isOpen { expanded.remove(week.week) } else { expanded.insert(week.week) }
                }
                Haptics.soft()
            } label: {
                HStack(alignment: .center, spacing: Layout.block) {
                    weekBadge(week, isCurrent: isCurrent, isPast: isPast)
                    if week.hasItems {
                        VStack(alignment: .leading, spacing: Layout.snug) {
                            miniAxis("Théorie", week.watchedCount, week.videoCount, TaskType.theory.tint)
                            miniAxis(week.seriesNumbers.isEmpty ? "Séries" : "Série " + week.seriesNumbers.map(String.init).joined(separator: ", "),
                                     week.doneCount, week.exerciseCount, TaskType.exercise.tint)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    } else {
                        Text("Rien de prévu")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .padding(.vertical, Layout.control)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(weekAccessibility(week, isCurrent: isCurrent))

            if isOpen {
                weekDetail(week)
                    .padding(.leading, 52)
                    .padding(.bottom, Layout.control)
                    .transition(.opacity)
            }
        }
    }

    /// « S5 » dans une pastille : pleine pour la semaine en cours, verte quand
    /// la semaine est bouclée, cerclée d'orange quand une semaine passée traîne.
    private func weekBadge(_ week: WeeklyProgress, isCurrent: Bool, isPast: Bool) -> some View {
        let late = isPast && week.remainingCount > 0
        return ZStack {
            if isCurrent {
                Circle().fill(Theme.accent.accessibleMark)
            } else if week.isComplete {
                Circle().fill(Color.green.badgeFill)
            } else if late {
                Circle().strokeBorder(Color.orange.accessibleMark, lineWidth: 1.5)
            } else {
                Circle().fill(Color(.tertiarySystemFill))
            }
            Text("S\(week.week)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? Theme.knockedOutInk
                                 : (week.isComplete ? Color.green.badgeInk
                                    : (late ? Color.orange.accessibleInk : .primary)))
        }
        .frame(width: 40, height: 40)
        .opacity(week.hasItems || isCurrent ? 1 : 0.5)
    }

    private func miniAxis(_ title: String, _ done: Int, _ total: Int, _ tint: Color) -> some View {
        HStack(spacing: Layout.inline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            ProgressBar(progress: CourseProgress.ratio(done, total), color: tint, height: 6)
                .opacity(total == 0 ? 0.3 : 1)
            Text(total == 0 ? "—" : "\(done)/\(total)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(total > 0 && done == total ? Color.green.accessibleInk : .primary)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    /// Ce que contient la semaine : la théorie, puis les exercices, cochés ou non.
    @ViewBuilder
    private func weekDetail(_ week: WeeklyProgress) -> some View {
        let theory = course.sortedTheoryItems.filter { $0.plannedWeek == week.week }
        let exercises = course.sortedSeries.filter { $0.plannedWeek == week.week }.flatMap(\.sortedExercises)
        VStack(alignment: .leading, spacing: Layout.snug) {
            ForEach(theory) { item in
                Button { openedVideo = item } label: {
                    detailLine(done: item.isWatched, icon: item.kind.icon, tint: TaskType.theory.tint,
                               text: item.numberAndTitle, trailing: item.videoCount > 1 ? "\(item.videoCount) vidéos" : nil)
                }
                .buttonStyle(.plain)
            }
            ForEach(exercises) { exercise in
                Button { openedExercise = exercise } label: {
                    detailLine(done: exercise.isDone, icon: TaskType.exercise.icon, tint: TaskType.exercise.tint,
                               text: exercise.displayNumber + (exercise.isBonus ? " (bonus)" : ""),
                               trailing: exercise.isCorrected ? exercise.correctness?.shortLabel : nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detailLine(done: Bool, icon: String, tint: Color, text: String, trailing: String?) -> some View {
        HStack(spacing: Layout.inline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.footnote)
                .foregroundStyle(done ? tint.accessibleMark : Color.secondary)
            MathText(text, font: .footnote)
                .foregroundStyle(done ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: Layout.inline)
            if let trailing {
                Text(trailing).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func weekAccessibility(_ week: WeeklyProgress, isCurrent: Bool) -> String {
        guard week.hasItems else { return "Semaine \(week.week), rien de prévu" }
        return "Semaine \(week.week)\(isCurrent ? ", en cours" : ""). Théorie \(week.watchedCount) sur \(week.videoCount). Séries \(week.doneCount) sur \(week.exerciseCount)."
    }

    // MARK: Non planifié

    @ViewBuilder
    private var unplannedCard: some View {
        let items = ProgressEngine.unplannedTheory(for: course)
        if !items.isEmpty {
            Card(title: "Sans semaine", icon: "tray", trailing: "\(items.count)") {
                VStack(alignment: .leading, spacing: Layout.inline) {
                    Text("Ces éléments n'entrent dans aucune semaine. Ouvre-en un pour lui en donner une.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(items.prefix(8)) { item in
                        Button { openedVideo = item } label: {
                            detailLine(done: item.isWatched, icon: item.kind.icon, tint: TaskType.theory.tint,
                                       text: item.numberAndTitle, trailing: nil)
                        }
                        .buttonStyle(.plain)
                    }
                    if items.count > 8 {
                        Text("+ \(items.count - 8) autres").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Temps de travail

    private var workloadCard: some View {
        let weekStart = DateUtils.startOfWeek(Date())
        let weekly = WorkloadEngine.weeklyDelta(for: course,
                                                hoursPerCredit: app.settings.hoursPerCredit,
                                                from: weekStart,
                                                to: DateUtils.addWeeks(1, to: weekStart))
        let byType = Dictionary(grouping: course.sessions.filter { $0.startedAt >= weekStart }) { $0.taskType.canonical }
            .mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }
        return Card(title: "Temps cette semaine", icon: "clock") {
            VStack(alignment: .leading, spacing: Layout.block) {
                LabeledProgress(title: "Objectif EPFL",
                                progress: weekly.completion,
                                color: weekly.isBehind ? .orange : (weekly.isOnTrack ? .green : Theme.accent),
                                countLabel: "\(weekly.actualLabel) / \(weekly.expectedLabel)")
                if !byType.isEmpty {
                    HStack(spacing: Layout.block) {
                        ForEach(TaskType.reportCategories.filter { byType[$0] != nil }, id: \.self) { type in
                            VStack(alignment: .leading, spacing: Layout.micro) {
                                Label(type.shortLabel, systemImage: type.icon)
                                    .font(.caption)
                                    .foregroundStyle(type.tint.accessibleInk)
                                Text(DateUtils.durationLabel(seconds: byType[type] ?? 0))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                Text("Objectif : \(Int(app.settings.hoursPerCredit)) h par crédit ECTS, heures encadrées comprises. Le temps Anki est relevé tout seul quand Anki est connecté.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
