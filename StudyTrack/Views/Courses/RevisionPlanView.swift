import SwiftUI
import SwiftData

/// Le plan de révision d'un cours, jour par jour, jusqu'à l'évaluation.
///
/// L'app savait dire ce qu'il restait ; elle ne disait pas **quand** le faire. Un
/// examen dans douze jours avec trente éléments restants se planifie autrement
/// qu'un examen dans deux jours.
struct RevisionPlanView: View {
    let course: Course

    @Environment(AppContainer.self) private var app
    @State private var minutesPerDay = 90

    private var plan: RevisionPlan? {
        RevisionBuilder.plan(for: course, minutesPerDay: minutesPerDay)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                if let plan {
                    if plan.isEmpty && plan.days.allSatisfy(\.isEmpty) {
                        EmptyCard(icon: "checkmark.seal.fill",
                                  title: "Rien à planifier",
                                  message: "Tout est fait et corrigé.",
                                  actionTitle: nil,
                                  action: nil)
                    } else {
                        header(plan)
                        dailyBudget
                        if let warning = plan.warning { warningCard(warning) }
                        days(plan)
                    }
                } else {
                    EmptyCard(icon: "calendar.badge.questionmark",
                              title: "Aucune échéance",
                              message: "Ajoute un examen pour calculer le plan.",
                              actionTitle: nil,
                              action: nil)
                }
            }
            .padding()
            .adaptiveColumn()
        }
        .background(Carnet.ground.ignoresSafeArea())
        .carnetBackground()
        .navigationTitle("Plan de révision")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: En-tête

    private func header(_ plan: RevisionPlan) -> some View {
        Card(title: plan.examTitle, icon: "target") {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(alignment: .firstTextBaseline, spacing: Layout.control) {
                    Text("\(plan.totalItems)")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Text(plan.totalItems > 1 ? "éléments restants" : "élément restant")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Layout.inline)
                    Pill(text: DateUtils.countdownLabel(to: plan.examDate), color: Theme.accent)
                }

                Text("\(DateUtils.fullDay.string(from: plan.examDate)) · \(plan.usableDays) jour\(plan.usableDays > 1 ? "s" : "") pour s'y préparer, dont \(RevisionEngine.reviewDayCount(usableDays: plan.usableDays)) de relecture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if plan.perDay > 0 {
                    LabeledProgress(title: "Par jour",
                                    progress: min(1, plan.perDay / max(plan.perDay, 1)),
                                    color: Theme.accent,
                                    countLabel: String(format: "%.1f éléments", plan.perDay))
                }
            }
        }
    }

    /// Combien de temps on peut y consacrer : c'est ce qui rend le plan réaliste
    /// ou non, et ça se règle.
    private var dailyBudget: some View {
        Card(title: "Temps disponible", icon: "clock") {
            VStack(alignment: .leading, spacing: Layout.block) {
                Stepper(value: $minutesPerDay, in: 15...480, step: 15) {
                    HStack {
                        Text("Par jour")
                        Spacer()
                        Text(DateUtils.durationLabel(seconds: minutesPerDay * 60))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.accentInk)
                    }
                }
            }
        }
    }

    private func warningCard(_ text: String) -> some View {
        Card {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.orange.accessibleInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Jours

    private func days(_ plan: RevisionPlan) -> some View {
        Card(title: "Jour par jour", icon: "calendar") {
            VStack(spacing: 0) {
                ForEach(Array(plan.days.enumerated()), id: \.element.id) { index, day in
                    dayRow(day, number: index + 1)
                    if day.id != plan.days.last?.id {
                        Divider().padding(.vertical, Layout.snug)
                    }
                }
            }
        }
    }

    private func dayRow(_ day: RevisionDay, number: Int) -> some View {
        VStack(alignment: .leading, spacing: Layout.snug) {
            HStack(spacing: Layout.snug) {
                Text("J\(number)")
                    .font(.caption.weight(.bold))
                    .frame(width: 26)
                    .foregroundStyle(day.isReview ? Color.orange.accessibleInk : Theme.accentInk)
                Text(DateUtils.shortDay.string(from: day.date))
                    .font(.subheadline.weight(.medium))
                if day.isReview { Pill(text: "relecture", color: .orange) }
                Spacer(minLength: Layout.inline)
                if !day.items.isEmpty {
                    Text("\(day.items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if day.isReview {
                Text("Relire les résumés et refaire ce qui a raté. Rien de nouveau la veille d'un examen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if day.items.isEmpty {
                Text("Rien de prévu.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(day.items) { item in
                        HStack(alignment: .top, spacing: Layout.snug) {
                            Image(systemName: item.kind.icon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text(item.label)
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Jour \(number), \(DateUtils.shortDay.string(from: day.date)), \(day.items.count) éléments")
    }
}
