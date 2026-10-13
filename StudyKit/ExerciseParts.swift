import SwiftUI
import SwiftData
import PDFKit

// Les pièces de l'exercice, les mêmes sur l'iPhone et le Mac.

/// Le papier de nuit du mode étude : `Carnet` en apparence sombre, toujours.
///
/// La fenêtre du mode étude est forcée en sombre (`StudyModeView` et sa
/// fenêtre) : un écran plein qui éblouit fatigue, et le soir comme le jour le
/// travail se lit mieux crème sur encre. Les couleurs dynamiques de `Carnet`
/// prennent alors leurs valeurs de nuit ; ces noms disent l'intention.
enum StudyPalette {
    static let ground = Carnet.ground
    static let raised = Carnet.sheet
    static let raisedMore = Carnet.sheetRaised
    static let rule = Carnet.rule
    static let ink = Carnet.ink
    static let inkSecondary = Carnet.inkSecondary
    static let inkTertiary = Carnet.inkTertiary
}

/// Les sous-questions de l'exercice en cours : cocher sans quitter le chrono.
struct SubQuestionChecklist: View {
    @Bindable var exercise: Exercise
    var tint: Color
    var onDark = false

    var body: some View {
        let questions = exercise.leafSubQuestions
        let next = questions.first { !$0.isDone }?.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Kicker("Questions", color: onDark ? StudyPalette.inkSecondary : Carnet.inkSecondary)
                Spacer()
                Text("\(questions.filter(\.isDone).count)/\(questions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(onDark ? StudyPalette.inkSecondary : Carnet.inkSecondary)
            }
            ForEach(questions) { question in
                Button {
                    question.isDone.toggle()
                    question.doneAt = question.isDone ? Date() : nil
                    exercise.refreshCompletion()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: question.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(question.isDone ? tint : (onDark ? StudyPalette.inkTertiary : Carnet.inkTertiary))
                        Text(question.path).monospacedDigit()
                            .foregroundStyle(onDark ? StudyPalette.inkSecondary : Carnet.inkSecondary)
                        MacMathText(question.text.isEmpty ? " " : question.text, size: 13)
                            .lineLimit(2)
                            .foregroundStyle(onDark ? StudyPalette.ink : Carnet.ink)
                            .strikethrough(question.isDone, color: onDark ? StudyPalette.inkTertiary : Carnet.inkTertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(question.id == next ? (onDark ? StudyPalette.raised : Carnet.marker) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
    }
}

/// Fait / juste / moyen / faux, en une rangée.
struct ExerciseQuickMark: View {
    @Bindable var exercise: Exercise

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Fait", isOn: Binding(get: { exercise.isDone }, set: { exercise.setDone($0) }))
                .studyCheckbox()
            Spacer(minLength: 8)
            ForEach(Correctness.allCases) { result in
                let selected = exercise.correctness == result
                Button {
                    if selected { exercise.clearCorrection() } else { exercise.correct(result) }
                } label: {
                    Text(result.shortLabel)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? Carnet.color(for: result) : Carnet.color(for: result).opacity(0.12)))
                        .foregroundStyle(selected ? Carnet.ground : Carnet.color(for: result))
                }
                .buttonStyle(.plain)
                .help(result.label)
            }
        }
        .font(.callout)
    }
}

/// L'exercice, en feuille : l'énoncé (quand il n'y a pas de PDF), les
/// questions à cocher juste dessous, où on en est (fait, juste / moyen / faux,
/// à refaire), le corrigé quand il est publié, et les gestes (indice, faire
/// vérifier sa copie, exercice suivant).
struct ExerciseStudySheet: View {
    @Bindable var exercise: Exercise
    let series: ExerciseSeries
    /// Demander à Claude (la question, ta copie s'il y en a une).
    var ask: (String, ClaudeTutor.Attachment?) -> Void
    var tint: Color
    var showStatement: Bool
    /// Ta copie dans tes notes, si on la trouve : « Vérifier ma copie » l'envoie.
    var copy: NotesLibrary.Document?
    var next: (Exercise) -> Void

    private var nextExercise: Exercise? { ExerciseFlow.next(after: exercise, in: series.sortedExercises) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Kicker(series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title, color: tint)
                Text(exercise.displayNumber).font(Carnet.serif(showStatement ? 30 : 24)).foregroundStyle(Carnet.ink)
                if !exercise.title.isEmpty, exercise.title != exercise.displayNumber {
                    MacMathText(exercise.title, size: 14).foregroundStyle(Carnet.inkSecondary)
                }
            }
            if showStatement, !exercise.statement.isEmpty {
                MacMathText(exercise.statement, size: 16).foregroundStyle(Carnet.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !exercise.hint.isEmpty {
                DisclosureGroup("Indication") {
                    MacMathText(exercise.hint, size: 14).foregroundStyle(Carnet.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .foregroundStyle(Carnet.inkSecondary)
            }
            if exercise.hasSubQuestions {
                SubQuestionChecklist(exercise: exercise, tint: tint)
                    .padding(14)
                    .background(Carnet.sheetRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 10) {
                Kicker("Où j'en suis")
                ExerciseQuickMark(exercise: exercise)
                Toggle("À refaire", isOn: $exercise.redoRequired).studyCheckbox()
            }
            if !exercise.solution.isEmpty, series.solutionsAt.map({ $0 <= Date() }) ?? true {
                DisclosureGroup("Corrigé") {
                    MacMathText(exercise.solution, size: 14).foregroundStyle(Carnet.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .foregroundStyle(Carnet.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { ask(ClaudeTutor.QuickAction.hint.prompt, nil) } label: { Label("Un indice", systemImage: "lightbulb") }
                        .buttonStyle(.ink)
                    Button {
                        let attachment = copy.flatMap { copy in
                            NotesStore.shared.attachmentData(copy).map { ClaudeTutor.Attachment(kind: .pdf, data: $0, name: copy.title) }
                        }
                        ask(ClaudeTutor.QuickAction.check.prompt, attachment)
                    } label: { Label("Vérifier ma copie", systemImage: "checkmark.circle") }
                        .buttonStyle(.paper)
                        .help(copy.map { "Envoie « \($0.title) » à Claude" } ?? "Joins ta copie")
                }
                if let nextExercise {
                    Button { next(nextExercise) } label: {
                        Label("\(nextExercise.displayNumber)", systemImage: "arrow.right")
                    }
                    .buttonStyle(.paper)
                }
            }
        }
    }
}
