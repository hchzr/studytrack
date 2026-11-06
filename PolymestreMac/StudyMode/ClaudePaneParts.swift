import SwiftUI
import SwiftData

// MARK: - Ce que Claude sait

/// Ce que Claude a sous les yeux, en clair : le projet et sa compétence, la
/// série (et son énoncé), l'exercice en cours, ta copie (et de quand elle
/// date), les indices déjà donnés, les connecteurs, ce que coûte le contexte.
struct ClaudeContextPanel: View {
    struct Row: Identifiable {
        enum State { case ok, missing, warning, info }
        let id = UUID()
        var icon: String
        var title: String
        var detail: String?
        var state: State
        var help: String?
    }

    let rows: [Row]
    var refreshCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ce que Claude sait").font(Carnet.serif(.title3, weight: .medium)).foregroundStyle(Carnet.ink)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: row.icon)
                            .frame(width: 18)
                            .foregroundStyle(color(row.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).foregroundStyle(Carnet.ink)
                            if let detail = row.detail {
                                Text(detail).font(.caption).foregroundStyle(row.state == .warning ? Carnet.review : Carnet.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: mark(row.state)).font(.caption).foregroundStyle(color(row.state))
                    }
                    .help(row.help ?? "")
                }
            }
            if let refreshCopy {
                Button("Relire mes notes", systemImage: "arrow.clockwise", action: refreshCopy)
                    .buttonStyle(.paper)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 360)
    }

    private func color(_ state: Row.State) -> Color {
        switch state {
        case .ok: return Carnet.correct
        case .missing: return Carnet.inkTertiary
        case .warning: return Carnet.review
        case .info: return Carnet.inkSecondary
        }
    }

    private func mark(_ state: Row.State) -> String {
        switch state {
        case .ok: return "checkmark"
        case .missing: return "minus"
        case .warning: return "exclamationmark.triangle"
        case .info: return "info"
        }
    }
}

// MARK: - Le rapport d'une série

/// Ce qu'un post-mortem propose de noter — corrections, erreurs, exercices à
/// refaire — en une carte, et un seul geste pour tout noter.
struct ReviewCard: View {
    let report: SeriesReview.Report
    let series: ExerciseSeries
    let features: SeriesReview.Features
    let ladder: RedoLadder.Config
    @Environment(\.modelContext) private var context
    @State private var result: SeriesReview.Applied?

    private func exercise(_ label: String) -> Exercise? { SeriesReview.exercise(label, in: series) }

    /// Tout est déjà dans Polymestre (la conversation relue plus tard).
    private var alreadyApplied: Bool {
        let verdicts = report.verdicts.allSatisfy { verdict in exercise(verdict.exercise).map { $0.correctness == verdict.result && $0.isCorrected } ?? true }
        let mistakes = !features.mistakes || report.mistakes.allSatisfy { note in
            exercise(note.exercise)?.mistakes.contains { $0.summary == note.summary } ?? true
        }
        let redo = !features.redo || report.admissions.allSatisfy { exercise($0.exercise).map { $0.isQueuedForRedo || $0.redoClearedAt != nil } ?? true }
        return verdicts && mistakes && redo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("À noter dans Polymestre", systemImage: "tray.and.arrow.down")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Carnet.ink)
                Spacer()
                if let result {
                    Label(result.summary, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Carnet.correct)
                        .lineLimit(2)
                } else if alreadyApplied {
                    Label("Déjà noté", systemImage: "checkmark").font(.caption).foregroundStyle(Carnet.inkSecondary)
                } else {
                    Button("Tout noter") { apply() }.buttonStyle(.ink)
                }
            }
            if !report.verdicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker("Corrections")
                    FlowLayout(spacing: 6) {
                        ForEach(Array(report.verdicts.enumerated()), id: \.offset) { _, verdict in
                            HStack(spacing: 5) {
                                Text(exercise(verdict.exercise)?.exerciseNumber ?? verdict.exercise).monospacedDigit()
                                Text(verdict.result.shortLabel).fontWeight(.medium)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(Carnet.color(for: verdict.result))
                            .background(Carnet.color(for: verdict.result).opacity(0.14), in: Capsule())
                        }
                    }
                }
            }
            if features.mistakes, !report.mistakes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Kicker("Carnet d'erreurs")
                    ForEach(Array(report.mistakes.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: note.kind.icon).foregroundStyle(Carnet.wrong).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(exercise(note.exercise)?.exerciseNumber ?? note.exercise).font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkSecondary)
                                    Text(note.kind.label).font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
                                    if !note.notion.isEmpty { Text("· \(note.notion)").font(.caption).foregroundStyle(Carnet.inkTertiary) }
                                }
                                MacMathText(note.summary, size: 13).foregroundStyle(Carnet.ink)
                                if !note.correction.isEmpty {
                                    MacMathText("→ " + note.correction, size: 12).foregroundStyle(Carnet.inkSecondary)
                                }
                            }
                        }
                    }
                }
            }
            if features.redo, !report.admissions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Kicker("À refaire sur papier · \(ladder.steps.first?.label ?? "")")
                    ForEach(Array(report.admissions.enumerated()), id: \.offset) { index, admission in
                        let over = index >= max(0, min(ladder.maxPerSeries, features.redoPerSeries) - series.exercises.filter(\.isQueuedForRedo).count)
                            && !(exercise(admission.exercise)?.isQueuedForRedo ?? false)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "arrow.counterclockwise").foregroundStyle(over ? Carnet.inkTertiary : Carnet.review).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exercise(admission.exercise)?.displayNumber ?? "Exercice \(admission.exercise)")
                                    .foregroundStyle(over ? Carnet.inkTertiary : Carnet.ink)
                                MacMathText(admission.why, size: 12).foregroundStyle(Carnet.inkSecondary)
                                Text(over ? "écarté : plafond de la série atteint" : "l'amorce reste cachée jusqu'à ta tentative")
                                    .font(.caption2).foregroundStyle(Carnet.inkTertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Carnet.rule))
        .padding(.leading, 38)
    }

    private func apply() {
        let examDate = series.course?.nextExam?.date
        withAnimation(.snappy) {
            result = SeriesReview.apply(report, to: series, features: features, ladder: ladder, examDate: examDate, context: context)
        }
    }
}

/// Un indice de Claude, noté sur son exercice.
struct HintChip: View {
    let hint: SeriesReview.Hint
    let series: ExerciseSeries?

    private var levelLabel: String {
        ["", "orientation", "outil", "amorce", "solution"][min(4, max(0, hint.level))]
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb.fill").foregroundStyle(Carnet.review)
            Text("Indice \(hint.level) · \(levelLabel) noté")
            if let series, let exercise = SeriesReview.exercise(hint.exercise, in: series) {
                Text("· \(exercise.displayNumber)").foregroundStyle(Carnet.inkTertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(Carnet.inkSecondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Carnet.sheetRaised.opacity(0.6), in: Capsule())
        .padding(.leading, 38)
    }
}

// MARK: - Les suggestions

/// Un geste proposé sous la conversation (trois au plus, selon le moment).
struct ClaudeSuggestion: Identifiable {
    let id: String
    var label: String
    var icon: String
    var primary = false
    var help: String?
    var action: () -> Void
}

struct SuggestionRow: View {
    let suggestions: [ClaudeSuggestion]
    let tint: Color
    var disabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(suggestions) { suggestion in
                Button(action: suggestion.action) {
                    Label(suggestion.label, systemImage: suggestion.icon)
                        .font(.callout.weight(suggestion.primary ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(suggestion.primary ? Carnet.ground : Carnet.ink)
                        .background(suggestion.primary ? AnyShapeStyle(tint) : AnyShapeStyle(Carnet.sheetRaised.opacity(0.8)), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(suggestion.help ?? "")
                .disabled(disabled)
            }
        }
    }
}
