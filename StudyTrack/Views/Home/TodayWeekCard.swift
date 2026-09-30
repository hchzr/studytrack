import SwiftUI

/// Le temps de la semaine : ce qui est fait, ce que l'EPFL attend, et la
/// semaine jour par jour.
///
/// Un grand chiffre en serif (« 12,5 h »), l'attendu à côté, une barre, puis
/// sept colonnes du lundi au dimanche — aujourd'hui en encre, les jours à venir
/// en pointillé. Toucher la carte ouvre le bilan.
struct WeekTimeCard: View {
    let workload: WorkloadDelta
    /// Secondes d'étude enregistrées, du lundi au dimanche.
    let days: [Int]
    let weekStart: Date
    var onOpen: () -> Void

    private var todayIndex: Int {
        min(max(DateUtils.daysBetween(weekStart, Date()), 0), 6)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    CarnetKicker("Cette semaine")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Carnet.inkTertiary)
                }
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(hours(workload.actualSeconds))
                        .font(Carnet.serif(.largeTitle, weight: .regular))
                        .foregroundStyle(Carnet.ink)
                        .contentTransition(.numericText())
                    if workload.expectedSeconds > 0 {
                        Text("sur \(hours(workload.expectedSeconds))")
                            .font(.subheadline)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    Spacer(minLength: 8)
                    Text(standing)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(standingColor)
                        .multilineTextAlignment(.trailing)
                }
                if workload.expectedSeconds > 0 {
                    CarnetBar(value: workload.completion, tint: Carnet.ink, height: 5)
                }
                dayStrip
                Text(breakdown)
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cette semaine : \(hours(workload.actualSeconds)) sur \(hours(workload.expectedSeconds)) attendues. \(standing)")
        .accessibilityHint("Ouvre le bilan")
    }

    private var dayStrip: some View {
        let peak = max(days.max() ?? 0, 3600)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<7, id: \.self) { index in
                let seconds = days.indices.contains(index) ? days[index] : 0
                let isToday = index == todayIndex
                let isFuture = index > todayIndex
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Carnet.sheetRaised)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isToday ? Carnet.ink : Carnet.inkTertiary)
                            .frame(height: seconds == 0 ? 0 : max(4, 44 * CGFloat(seconds) / CGFloat(peak)))
                    }
                    .frame(height: 44)
                    .opacity(isFuture ? 0.5 : 1)
                    Text(DateUtils.weekdayInitial(DateUtils.addDays(index, to: weekStart)))
                        .font(.caption2.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Carnet.ink : Carnet.inkTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// « 1,5 h d'avance », « 4 h à rattraper », « dans le rythme ».
    ///
    /// L'attendu est celui de la semaine **entière** : le comparer au réel un
    /// mercredi donne toujours un retard. On le ramène aux jours écoulés.
    private var standing: String {
        guard workload.expectedSeconds > 0 else { return "" }
        let elapsedShare = Double(todayIndex + 1) / 7
        let expectedSoFar = Int(Double(workload.expectedSeconds) * elapsedShare)
        let delta = workload.actualSeconds - expectedSoFar
        if abs(delta) < 1800 { return "dans le rythme" }
        return delta > 0 ? "\(hours(delta)) d'avance" : "\(hours(-delta)) de retard"
    }

    private var standingColor: Color {
        guard workload.expectedSeconds > 0 else { return Carnet.inkSecondary }
        let expectedSoFar = Double(workload.expectedSeconds) * Double(todayIndex + 1) / 7
        let ratio = Double(workload.actualSeconds) / max(expectedSoFar, 1)
        if ratio >= 0.9 { return Carnet.correct }
        if ratio >= 0.6 { return Carnet.review }
        return Carnet.wrong
    }

    private var breakdown: String {
        var parts: [String] = []
        let study = workload.actualSeconds - workload.classSeconds
        parts.append("\(hours(study)) d'étude")
        if workload.classSeconds > 0 { parts.append("\(hours(workload.classSeconds)) en cours") }
        if workload.expectedSeconds > 0 { parts.append("attendu EPFL \(hours(workload.expectedSeconds))") }
        return parts.joined(separator: " · ")
    }

    private func hours(_ seconds: Int) -> String {
        DateUtils.hoursLabel(seconds: max(0, seconds))
    }
}

/// Un cours dans sa semaine : sa couleur, son nom, théorie et exercices faits
/// sur prévus, deux barres, et le retard en mots.
struct WeekCourseRow: View {
    let course: Course

    var body: some View {
        let week = ProgressEngine.weekProgress(for: course, week: course.currentWeek)
        let late = ProgressEngine.lateCount(for: course)
        let ahead = ProgressEngine.aheadCount(for: course)
        let tint = Carnet.tint(course.colorHex)
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(course.displayCode)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(course.name.isEmpty ? course.displayCode : course.name)
                        .font(.body)
                        .foregroundStyle(Carnet.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    standing(late: late, ahead: ahead, week: week)
                }
                if week.hasItems {
                    HStack(spacing: 14) {
                        axis("Théorie", done: week.watchedCount, total: week.videoCount, tint: tint)
                        axis("Exercices", done: week.doneCount, total: week.exerciseCount, tint: tint)
                    }
                } else {
                    Text("Rien de prévu cette semaine")
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkTertiary)
                }
                if let exam = course.nextExam, DateUtils.daysBetween(Date(), exam.date) <= 14 {
                    Label("\(exam.kind.label) \(DateUtils.countdownLabel(to: exam.date).lowercased())",
                          systemImage: exam.kind.icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DateUtils.daysBetween(Date(), exam.date) <= 3 ? Carnet.wrong : Carnet.inkSecondary)
                }
            }
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func axis(_ title: String, done: Int, total: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                Spacer(minLength: 2)
                Text(total == 0 ? "—" : "\(done)/\(total)")
                    .font(Carnet.mono(.caption, weight: .medium))
                    .foregroundStyle(total > 0 && done == total ? Carnet.correct : Carnet.ink)
            }
            CarnetBar(value: CourseProgress.ratio(done, total), tint: tint, height: 4)
                .opacity(total == 0 ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func standing(late: Int, ahead: Int, week: WeeklyProgress) -> some View {
        if late > 0 {
            Text("\(late) en retard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Carnet.wrong)
        } else if week.isComplete {
            Label("semaine faite", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Carnet.correct)
        } else if ahead > 0 {
            Text("\(ahead) d'avance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Carnet.correct)
        } else {
            Text("à jour")
                .font(.caption)
                .foregroundStyle(Carnet.inkSecondary)
        }
    }
}
