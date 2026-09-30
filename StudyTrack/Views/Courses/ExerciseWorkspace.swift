import SwiftUI
import SwiftData
import WebKit

// MARK: - Étape et correction

/// L'étape d'un exercice, en un glyphe : cercle vide (à faire), anneau qui se
/// remplit (questions en cours), coche (fait, à corriger), puis la **couleur de
/// la correction** — vert juste, orange moyen, rouge faux — et ↺ à refaire.
/// La teinte ne porte jamais le sens seule : chaque état a son glyphe.
struct ExerciseStageMark: View {
    let stage: ExerciseStage
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            switch stage {
            case .toDo:
                Circle().strokeBorder(Carnet.inkTertiary, lineWidth: 1.8)
            case .inProgress(let done, let total):
                Circle().stroke(Carnet.rule, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: Double(done) / Double(max(total, 1)))
                    .stroke(Carnet.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            case .toCorrect:
                filled(Carnet.ink, glyph: "checkmark")
            case .corrected(let result):
                filled(Carnet.color(for: result), glyph: result.glyph)
            case .redo:
                Circle().strokeBorder(Carnet.wrong, lineWidth: 2)
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Carnet.wrong)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: stage)
    }

    private func filled(_ tint: Color, glyph: String) -> some View {
        ZStack {
            Circle().fill(tint)
            Image(systemName: glyph)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Carnet.sheet)
        }
    }
}

extension Correctness {
    /// Le glyphe de la pastille : ✓, ~, ✗.
    var glyph: String {
        switch self {
        case .correct: return "checkmark"
        case .partial: return "minus"
        case .wrong: return "xmark"
        }
    }
}

extension ExerciseStage {
    /// La teinte du libellé d'étape.
    var tint: Color {
        switch self {
        case .toDo: return .secondary
        case .inProgress: return TaskType.exercise.tint
        case .toCorrect: return TaskType.correction.tint
        case .corrected(let result): return result.color
        case .redo: return .red
        }
    }
}

/// Les trois pastilles de correction d'une ligne : vert, orange, rouge.
///
/// Toujours au même endroit, à droite de l'exercice, et **un** toucher corrige :
/// pas de fiche à ouvrir. Toucher la pastille déjà choisie retire la
/// correction. Chaque pastille porte son glyphe (✓ ~ ✗) : vert-orange-rouge est
/// exactement la triade que le daltonisme confond.
struct CorrectionDots: View {
    var value: Correctness?
    var onChange: (Correctness?) -> Void

    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 22

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Correctness.allCases) { option in
                let isOn = value == option
                Button {
                    Haptics.soft()
                    onChange(isOn ? nil : option)
                } label: {
                    ZStack {
                        Circle().fill(isOn ? Carnet.color(for: option) : Carnet.color(for: option).opacity(0.14))
                        Image(systemName: option.glyph)
                            .font(.system(size: dot * 0.45, weight: .bold))
                            .foregroundStyle(isOn ? Carnet.sheet : Carnet.color(for: option))
                    }
                    .frame(width: dot, height: dot)
                    .opacity(value == nil || isOn ? 1 : 0.45)
                    .frame(width: dot + 12, height: Layout.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Correction : \(option.label)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .animation(Motion.snappy, value: value)
    }
}

/// La même chose en grand, pour la fiche d'un exercice.
struct CorrectionPicker: View {
    var value: Correctness?
    var onChange: (Correctness?) -> Void

    var body: some View {
        HStack(spacing: Layout.inline) {
            ForEach(Correctness.allCases) { option in
                let isOn = value == option
                Button {
                    Haptics.soft()
                    onChange(isOn ? nil : option)
                } label: {
                    HStack(spacing: Layout.snug) {
                        Image(systemName: option.glyph).font(.caption.weight(.bold))
                        Text(option.lineLabel.capitalizedFirst).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(isOn ? Carnet.color(for: option) : Carnet.sheet,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(isOn ? Carnet.sheet : Carnet.color(for: option))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .accessibilityLabel("Correction : \(option.label)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Sous-questions

/// Une sous-question, cochable d'un toucher sur toute la ligne, avec son texte.
struct SubQuestionRow: View {
    let question: SubQuestion
    var fullText = false
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.inline) {
                Image(systemName: question.isDone ? "checkmark.circle.fill" : "circle")
                    .font(question.parent == nil ? .body : .subheadline)
                    .foregroundStyle(question.isDone ? Color.green.accessibleMark : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(question.isDone ? .secondary : .primary)
                if !question.text.isEmpty {
                    MathText(question.text, font: .subheadline)
                        .foregroundStyle(question.isDone ? .tertiary : .secondary)
                        .lineLimit(fullText ? nil : 2)
                        .fixedSize(horizontal: false, vertical: fullText)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, question.parent == nil ? 0 : 26)
            .padding(.vertical, 5)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(MathMarkup.plain(question.text))")
        .accessibilityValue(question.isDone ? "fait" : "à faire")
    }

    /// « 1. », « (a) », « Partie » pour une partie sans numéro ; « Question 1 »
    /// quand le libellé est seul (il n'y a pas de texte pour le compléter).
    private var label: String {
        if question.kind == .part { return "Partie" }
        let shown = question.displayLabel
        guard question.text.isEmpty else { return shown }
        let bare = shown.trimmingCharacters(in: CharacterSet(charactersIn: ".) ("))
        return bare.allSatisfy(\.isNumber) ? "Question \(bare)" : shown
    }
}

// MARK: - Ligne d'exercice

/// Un exercice dans la liste, **avec** ses sous-questions.
///
/// Tout le suivi se fait ici, sans ouvrir de fiche : la coche (fait / à faire),
/// les questions (cochables une par une, avec leur texte), et à droite les
/// trois pastilles de **correction**, qui apparaissent dès que l'exercice est
/// fait. Les questions d'un exercice fini se replient en « 4/4 » ; un toucher
/// les rouvre. Le numéro et le titre ouvrent la fiche (énoncé complet, liens,
/// indication, solution, remarque, chrono).
struct ExerciseRow: View {
    let exercise: Exercise
    var seconds: Int = 0
    var showsQuestions: Bool
    var onToggleDone: () -> Void
    var onCorrect: (Correctness?) -> Void
    var onToggleQuestions: () -> Void
    var onToggleQuestion: (SubQuestion) -> Void
    var onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    private var stage: ExerciseStage { ExerciseStage(exercise) }
    private var showsCorrection: Bool { exercise.isDone || exercise.isCorrected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Button(action: onToggleDone) {
                    ExerciseStageMark(stage: stage)
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(exercise.isDone ? "Marquer \(exercise.displayNumber) à faire" : "Marquer \(exercise.displayNumber) fait")
                .accessibilityValue(stage.label)

                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Layout.snug) {
                            Text(exercise.exerciseNumber)
                                .font(.body.weight(.semibold).monospacedDigit())
                            if exercise.isBonus {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.orange.accessibleMark)
                                    .accessibilityLabel("bonus")
                            }
                            if exercise.redoRequired {
                                Pill(text: "à refaire", color: .red, icon: "arrow.counterclockwise")
                            }
                            if seconds >= 60 {
                                Text(DateUtils.durationLabel(seconds: seconds))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if let summary {
                            MathText(summary, font: .subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.top, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Ouvre l'exercice : énoncé, liens, solution, chrono")

                if showsCorrection, !typeSize.isAccessibilitySize {
                    CorrectionDots(value: exercise.correctness, onChange: onCorrect)
                }
            }

            if showsCorrection, typeSize.isAccessibilitySize {
                CorrectionDots(value: exercise.correctness, onChange: onCorrect)
                    .padding(.leading, Layout.minTouch)
            }

            if exercise.hasSubQuestions {
                if showsQuestions {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(exercise.sortedSubQuestions) { question in
                            SubQuestionRow(question: question) { onToggleQuestion(question) }
                            ForEach(question.sortedChildren) { child in
                                SubQuestionRow(question: child) { onToggleQuestion(child) }
                            }
                        }
                    }
                    .padding(.leading, Layout.minTouch)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Button(action: onToggleQuestions) {
                    HStack(spacing: Layout.snug) {
                        Image(systemName: showsQuestions ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                        Text(showsQuestions ? "Replier"
                                            : "\(exercise.subQuestionDoneCount)/\(exercise.leafSubQuestions.count) questions")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, Layout.minTouch)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Layout.micro)
    }

    /// Le titre, sinon le début de l'énoncé : ce dont parle l'exercice.
    private var summary: String? {
        if !exercise.title.isEmpty { return exercise.title }
        if !exercise.statement.isEmpty { return exercise.statement }
        return nil
    }
}

// MARK: - Fiche d'un exercice

/// La fiche ouverte sur un exercice précis — depuis l'accueil, la progression
/// ou la recherche, qui ne connaissent que l'exercice.
struct ExerciseSheet: View {
    let exercise: Exercise

    var body: some View {
        if let series = exercise.series {
            ExerciseWorkspace(series: series, start: exercise)
        }
    }
}

/// La fiche d'un exercice, dans sa série : ⌃ ⌄ passent au voisin.
///
/// Ce n'est plus là que se fait le suivi (la liste suffit) : c'est là qu'on
/// **lit** — l'énoncé entier et ses questions, les liens vers l'énoncé, le
/// corrigé et la théorie de la semaine, l'indication, la solution quand elle
/// est publiée — et qu'on travaille au chrono. Le chrono suit l'exercice
/// affiché : passer au suivant attribue le temps déjà compté au précédent.
struct ExerciseWorkspace: View {
    let series: ExerciseSeries
    @State private var selection: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    @State private var editingSeries = false
    @State private var deleting: Exercise?
    @State private var browsing: BrowsedLink?

    init(series: ExerciseSeries, start: Exercise? = nil) {
        self.series = series
        let first = start ?? ExerciseFlow.resumePoint(in: series.exercises) ?? series.sortedExercises.first
        _selection = State(initialValue: first?.id ?? UUID())
    }

    private var exercises: [Exercise] { series.sortedExercises }
    private var current: Exercise? { exercises.first { $0.id == selection } }
    private var index: Int { exercises.firstIndex { $0.id == selection } ?? 0 }
    private var course: Course? { series.course }

    var body: some View {
        NavigationStack {
            Group {
                if let current {
                    ExerciseDetailContent(exercise: current,
                                          sessions: sessions,
                                          onOpenLink: { browsing = $0 })
                        .id(current.id)
                } else {
                    ContentUnavailableView("Aucun exercice", systemImage: TaskType.exercise.icon)
                }
            }
            .background(Carnet.sheet.ignoresSafeArea())
            .navigationTitle(current.map { "\($0.exerciseNumber) · \(index + 1)/\(exercises.count)" } ?? series.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { step(-1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                        .accessibilityLabel("Exercice précédent")
                    Button { step(1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index >= exercises.count - 1)
                        .accessibilityLabel("Exercice suivant")
                    Menu {
                        Button { editingSeries = true } label: {
                            Label("Modifier la série…", systemImage: "pencil")
                        }
                        if let current {
                            Button(role: .destructive) { deleting = current } label: {
                                Label("Supprimer l'exercice \(current.exerciseNumber)", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Actions")
                }
            }
            .onChange(of: selection) { _, id in follow(id) }
            .onAppear { follow(selection) }
            .sheet(isPresented: $editingSeries) {
                if let course { SeriesEditorSheet(course: course, series: series) }
            }
            .sheet(item: $browsing) { link in
                InAppBrowser(link: link)
            }
            .confirmationDialog("Supprimer l'exercice \(deleting?.exerciseNumber ?? "") ?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible,
                                presenting: deleting) { exercise in
                Button("Supprimer", role: .destructive) { delete(exercise) }
            } message: { exercise in
                Text(exercise.isDone ? "Il est marqué fait : son avancement sera perdu." : "Ses questions seront supprimées avec lui.")
            }
        }
    }

    private func step(_ delta: Int) {
        let target = min(max(0, index + delta), exercises.count - 1)
        guard exercises.indices.contains(target) else { return }
        withAnimation(Motion.snappy) { selection = exercises[target].id }
        Haptics.soft()
    }

    /// Le chrono suit l'exercice affiché — s'il tourne **sur ce cours**, pour
    /// des exercices ou leur correction. Une session sur un autre cours, ou sur
    /// de la théorie, n'est jamais déplacée par une simple navigation.
    private func follow(_ id: UUID) {
        let focus = app.focus
        guard focus.hasSession, let state = focus.state,
              let course, state.courseID == course.id,
              [.exercise, .correction].contains(state.taskType.canonical),
              state.targetID != id,
              exercises.contains(where: { $0.id == id }) else { return }
        focus.updateContext(targetID: .some(id), label: "")
    }

    private func delete(_ exercise: Exercise) {
        if let next = ExerciseFlow.next(after: exercise, in: exercises) ?? exercises.first(where: { $0.id != exercise.id }) {
            selection = next.id
        } else {
            dismiss()
        }
        context.delete(exercise)
        try? context.save()
        Haptics.removed()
    }
}

/// Le contenu de la fiche : **l'énoncé en grand**, puis tout ce qui aide à le
/// faire ; les commandes flottent en bas, dans une barre de verre.
///
/// On ouvre un exercice pour le lire et le faire, pas pour remplir un
/// formulaire : l'ancienne fiche était une liste de réglages (questions,
/// correction, aide, liens, chrono) où l'énoncé n'était qu'une ligne de
/// l'en-tête. Désormais :
///   • l'énoncé occupe l'écran — le texte lu dans la série, formules comprises,
///     la sous-question en cours surlignée ; sans texte, le document d'origine
///     lui-même (la page Botafogo de l'exercice, le PDF de la série) ;
///   • la barre de verre porte le geste suivant : cocher la sous-question en
///     cours, marquer l'exercice fait, puis le corriger (juste · à revoir ·
///     faux) — et le chrono, et le corrigé ;
///   • l'indication, la solution, les notes de correction, la théorie de la
///     semaine et le temps passé suivent l'énoncé, plus bas.
private struct ExerciseDetailContent: View {
    @Bindable var exercise: Exercise
    let sessions: [StudySession]
    var onOpenLink: (BrowsedLink) -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var note = ""
    @State private var scoreText = ""
    @State private var maxScoreText = ""
    @State private var showingHint = false
    @State private var showingSolution = false
    @State private var showingDetails = false
    @StateObject private var document = BrowserModel()

    private var stage: ExerciseStage { ExerciseStage(exercise) }
    private var course: Course? { exercise.series?.course }
    private var hasText: Bool {
        !exercise.statement.isEmpty || exercise.sortedSubQuestions.contains { !$0.text.isEmpty }
    }

    /// Le document d'origine : l'énoncé de l'exercice, sinon celui de la série.
    private var documentURL: URL? {
        ExerciseLinks.web(exercise.statementURLString) ?? exercise.series.flatMap { ExerciseLinks.web($0.urlString) }
    }

    private var currentQuestion: SubQuestion? {
        exercise.leafSubQuestions.first { !$0.isDone }
    }

    var body: some View {
        Group {
            if hasText || documentURL == nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        statementPage
                        extras
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: Layout.readableWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Carnet.sheet.ignoresSafeArea())
            } else if let documentURL {
                // Pas de texte lu : le document lui-même, en pleine page.
                WebView(model: document, initialURL: documentURL)
                    .overlay(alignment: .top) {
                        if document.isLoading {
                            ProgressView(value: document.progress).progressViewStyle(.linear).tint(Carnet.ink)
                        }
                    }
                    .background(Carnet.sheet.ignoresSafeArea())
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExerciseControlBar(exercise: exercise,
                               sessions: sessions,
                               onToggle: toggle,
                               onCorrect: setCorrection,
                               onSolution: openSolution,
                               onDetails: hasText || documentURL == nil ? nil : { showingDetails = true })
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    extras.padding(20)
                }
                .background(Carnet.ground.ignoresSafeArea())
                .navigationTitle(exercise.displayNumber)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("OK") { showingDetails = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            note = exercise.correctionNote ?? ""
            scoreText = exercise.score.map { String(format: "%g", $0) } ?? ""
            maxScoreText = exercise.maxScore.map { String(format: "%g", $0) } ?? ""
        }
        .onChange(of: note) { _, _ in persist() }
        .onChange(of: scoreText) { _, _ in persist() }
        .onChange(of: maxScoreText) { _, _ in persist() }
    }

    // MARK: L'énoncé

    private var statementPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            CarnetKicker([course?.displayCode, exercise.series.map { "Série \($0.seriesNumber)" },
                          exercise.isBonus ? "bonus" : nil, stage.label]
                            .compactMap { $0 }.joined(separator: " · "),
                         color: course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkSecondary)
            Text(exercise.title.isEmpty ? exercise.displayNumber : MathMarkup.plain(exercise.title))
                .font(Carnet.serif(.title))
                .foregroundStyle(Carnet.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !exercise.statement.isEmpty {
                MathText(exercise.statement, font: .system(.title3, design: .serif))
                    .foregroundStyle(Carnet.ink)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(exercise.sortedSubQuestions) { question in
                questionBlock(question, depth: 0)
                ForEach(question.sortedChildren) { child in
                    questionBlock(child, depth: 1)
                }
            }
            if let documentURL {
                Button {
                    onOpenLink(BrowsedLink(title: "Énoncé d'origine", url: documentURL, icon: "doc.richtext"))
                } label: {
                    Label("Voir l'énoncé d'origine", systemImage: "doc.richtext")
                        .font(.subheadline)
                }
                .buttonStyle(.carnetSecondary)
                .padding(.top, 4)
            }
        }
    }

    /// Une sous-question dans le texte : cochée, en cours (surlignée), ou à venir.
    private func questionBlock(_ question: SubQuestion, depth: Int) -> some View {
        let isCurrent = question.id == currentQuestion?.id
        return Button { toggle(question) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: question.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(question.isDone ? Carnet.correct : Carnet.inkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    if question.text.isEmpty {
                        Text(question.displayLabel)
                            .font(.system(.title3, design: .serif))
                    } else {
                        MathText("(\(question.label)) " + question.text, font: .system(.title3, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(question.isDone ? Carnet.inkSecondary : Carnet.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isCurrent ? Carnet.marker : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -8)
            .padding(.leading, CGFloat(depth) * 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sous-question \(question.displayLabel)")
        .accessibilityValue(question.isDone ? "faite" : "à faire")
    }

    // MARK: Plus bas

    @ViewBuilder
    private var extras: some View {
        if !exercise.hint.isEmpty || !exercise.solution.isEmpty { helpBlock }
        correctionBlock
        weekTheoryBlock
        timeBlock
    }

    private var helpBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Aide")
            VStack(alignment: .leading, spacing: 12) {
                if !exercise.hint.isEmpty {
                    DisclosureGroup(isExpanded: $showingHint) {
                        MathText(exercise.hint, font: .body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    } label: {
                        Label("Indication", systemImage: "lightbulb").foregroundStyle(Carnet.ink)
                    }
                }
                if !exercise.solution.isEmpty {
                    if let date = exercise.series?.solutionsAt, date > Date() {
                        Label("Solution publiée le \(DateUtils.shortDay.string(from: date))", systemImage: "lock")
                            .foregroundStyle(Carnet.inkSecondary)
                    } else {
                        DisclosureGroup(isExpanded: $showingSolution) {
                            MathText(exercise.solution, font: .body)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 6)
                        } label: {
                            Label("Solution", systemImage: "checkmark.seal").foregroundStyle(Carnet.ink)
                        }
                    }
                }
            }
            .tint(Carnet.ink)
            .padding(14)
            .background(Carnet.ground, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
    }

    private var correctionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Correction")
            VStack(alignment: .leading, spacing: 12) {
                CorrectionPicker(value: exercise.correctness) { setCorrection($0) }
                Toggle("À refaire", isOn: Binding(get: { exercise.redoRequired },
                                                  set: { exercise.redoRequired = $0; try? context.save() }))
                    .tint(Carnet.ink)
                TextField("Ce qu'il faut retenir", text: $note, axis: .vertical)
                    .lineLimit(1...5)
                HStack {
                    TextField("Points", text: $scoreText).keyboardType(.decimalPad)
                    Text("/").foregroundStyle(Carnet.inkSecondary)
                    TextField("sur", text: $maxScoreText).keyboardType(.decimalPad)
                }
            }
            .padding(14)
            .background(Carnet.ground, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            Text("Juste : c'est acquis. À revoir : à moitié. Faux : l'exercice passe « à refaire ».")
                .font(.footnote)
                .foregroundStyle(Carnet.inkSecondary)
                .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private var weekTheoryBlock: some View {
        if let series = exercise.series, let course, series.plannedWeek > 0 {
            let theory = course.sortedTheoryItems.filter { $0.plannedWeek == series.plannedWeek }
            let links = ExerciseLinks.links(for: exercise)
            if !theory.isEmpty || !links.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CarnetSectionTitle("Pour s'aider") { Text("semaine \(series.plannedWeek)") }
                    VStack(spacing: 0) {
                        ForEach(links) { link in
                            Button { onOpenLink(link) } label: {
                                CarnetRow(icon: link.icon, tint: Carnet.inkSecondary, title: link.title)
                            }
                            .buttonStyle(.plain)
                            CarnetRule()
                        }
                        ForEach(theory.prefix(12)) { item in
                            TheoryLinkRow(item: item, onOpen: onOpenLink)
                                .padding(.horizontal, Carnet.rowInset)
                                .padding(.vertical, 8)
                            if item.id != theory.prefix(12).last?.id { CarnetRule() }
                        }
                    }
                    .background(Carnet.ground, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
                }
            }
        }
    }

    private var timeBlock: some View {
        let spent = ExerciseFlow.seconds(on: exercise.id, sessions: sessions, live: 0)
        return Group {
            if spent >= 60 {
                Text("\(DateUtils.durationLabel(seconds: spent)) passées sur cet exercice")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
                    .padding(.horizontal, 6)
            }
        }
    }

    // MARK: Actions

    private func toggle(_ question: SubQuestion) {
        question.toggle()
        Haptics.tap()
        try? context.save()
    }

    private func setCorrection(_ result: Correctness?) {
        if let result { exercise.correct(result) } else { exercise.clearCorrection() }
        try? context.save()
    }

    /// Le corrigé : la solution lue quand elle est là, sinon le document du corrigé.
    private func openSolution() {
        if !exercise.solution.isEmpty, !(exercise.series?.solutionsAt.map { $0 > Date() } ?? false) {
            showingSolution = true
            if !hasText, documentURL != nil { showingDetails = true }
            return
        }
        if let series = exercise.series, let url = ExerciseLinks.web(series.solutionURLString) {
            onOpenLink(BrowsedLink(title: "Corrigé · Série \(series.seriesNumber)", url: url, icon: "checkmark.seal"))
        }
    }

    private func persist() {
        exercise.correctionNote = note.isEmpty ? nil : note
        exercise.score = Double(scoreText.replacingOccurrences(of: ",", with: "."))
        exercise.maxScore = Double(maxScoreText.replacingOccurrences(of: ",", with: "."))
        try? context.save()
    }
}

/// La barre de verre d'un exercice : les sous-questions en pastilles, le chrono,
/// le corrigé, et **le** geste suivant.
///
/// Le bouton principal change avec l'avancement : « (b) terminée » tant qu'il
/// reste des sous-questions, « Exercice fait » ensuite, puis les trois verdicts
/// de correction (juste · à revoir · faux). Un seul bouton à chercher.
private struct ExerciseControlBar: View {
    @Bindable var exercise: Exercise
    let sessions: [StudySession]
    var onToggle: (SubQuestion) -> Void
    var onCorrect: (Correctness?) -> Void
    var onSolution: () -> Void
    var onDetails: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    private var stage: ExerciseStage { ExerciseStage(exercise) }
    private var course: Course? { exercise.series?.course }
    private var leaves: [SubQuestion] { exercise.leafSubQuestions }
    private var current: SubQuestion? { leaves.first { !$0.isDone } }
    private var workType: TaskType { stage == .toCorrect ? .correction : .exercise }
    private var hasSolution: Bool {
        !exercise.solution.isEmpty || !(exercise.series?.solutionURLString.isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                if !leaves.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(leaves) { question in
                                chip(question)
                            }
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                }
                timerPill
            }
            HStack(spacing: 8) {
                if let onDetails {
                    Button(action: onDetails) {
                        Image(systemName: "list.bullet").frame(width: 22)
                    }
                    .buttonStyle(.carnetSecondary)
                    .accessibilityLabel("Aide, correction et théorie")
                }
                if hasSolution {
                    Button("Corrigé", action: onSolution)
                        .buttonStyle(.carnetSecondary)
                }
                primary
            }
        }
        .padding(12)
        .carnetGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func chip(_ question: SubQuestion) -> some View {
        let isCurrent = question.id == current?.id
        return Button { onToggle(question) } label: {
            Text(question.displayLabel)
                .font(.subheadline.weight(isCurrent ? .semibold : .medium))
                .foregroundStyle(question.isDone ? Carnet.ground : Carnet.ink)
                .padding(.horizontal, 10)
                .frame(minWidth: 40, minHeight: 38)
                .background(question.isDone ? Carnet.correct : Carnet.sheet,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isCurrent ? Carnet.ink : .clear, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .accessibilityLabel("Sous-question \(question.displayLabel)")
        .accessibilityValue(question.isDone ? "faite" : "à faire")
    }

    /// Le chrono de l'exercice : démarrer, mettre en pause, ou le faire venir ici.
    private var timerPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let focus = app.focus
            let state = focus.state
            let onThis = focus.hasSession && state?.targetID == exercise.id
            let live = onThis ? (state?.allocation(at: timeline.date).first { $0.targetID == exercise.id }?.seconds ?? 0) : 0
            let spent = ExerciseFlow.seconds(on: exercise.id, sessions: sessions, live: live)
            Button {
                if onThis, let state {
                    if state.isRunning { focus.pause() } else { focus.resume() }
                } else if focus.hasSession {
                    focus.updateContext(courseID: .some(course?.id), taskType: workType,
                                        targetID: .some(exercise.id), label: "")
                } else {
                    focus.start(courseID: course?.id, taskType: workType, targetID: exercise.id)
                }
                Haptics.tap()
            } label: {
                HStack(spacing: 6) {
                    if onThis, state?.isRunning == true {
                        Circle().fill(Carnet.wrong).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: onThis ? "pause.fill" : "play.fill").font(.caption.weight(.bold))
                    }
                    Text(spent > 0 ? TimerText.clock(TimeInterval(spent)) : "Chrono")
                        .font(Carnet.mono(.subheadline, weight: .medium))
                }
                .foregroundStyle(Carnet.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .accessibilityLabel(onThis ? (state?.isRunning == true ? "Mettre le chrono en pause" : "Reprendre le chrono")
                                       : (focus.hasSession ? "Passer le chrono sur cet exercice" : "Démarrer le chrono"))
        }
    }

    @ViewBuilder
    private var primary: some View {
        if let current {
            Button("\(current.displayLabel) terminée") { onToggle(current) }
                .buttonStyle(.carnetPrimaryWide)
        } else if !exercise.isDone {
            Button("Exercice fait") {
                exercise.setDone(true)
                Haptics.success()
                try? context.save()
            }
            .buttonStyle(.carnetPrimaryWide)
        } else {
            HStack(spacing: 6) {
                ForEach(Correctness.allCases) { option in
                    let isOn = exercise.correctness == option
                    Button {
                        Haptics.soft()
                        onCorrect(isOn ? nil : option)
                    } label: {
                        Text(option.lineLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? Carnet.ground : Carnet.color(for: option))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(isOn ? Carnet.color(for: option) : Carnet.sheet, in: Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.96))
                    .accessibilityLabel("Correction : \(option.label)")
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
        }
    }
}

// MARK: - Liens

/// Les documents d'un exercice : son énoncé, celui de la série, le corrigé.
enum ExerciseLinks {
    static func links(for exercise: Exercise) -> [BrowsedLink] {
        var links: [BrowsedLink] = []
        if let url = web(exercise.statementURLString) {
            links.append(BrowsedLink(title: "Énoncé de l'exercice", url: url, icon: "doc.text"))
        }
        if let series = exercise.series {
            links.append(contentsOf: seriesLinks(series).filter { link in !links.contains { $0.url == link.url } })
        }
        return links
    }

    static func seriesLinks(_ series: ExerciseSeries) -> [BrowsedLink] {
        var links: [BrowsedLink] = []
        if let url = web(series.urlString) {
            links.append(BrowsedLink(title: "Énoncé de la série", url: url, icon: "doc.richtext"))
        }
        if let url = web(series.solutionURLString) {
            if let date = series.solutionsAt, date > Date() {
                links.append(BrowsedLink(title: "Corrigé (publié le \(DateUtils.shortDay.string(from: date)))", url: url, icon: "lock"))
            } else {
                links.append(BrowsedLink(title: "Corrigé", url: url, icon: "checkmark.seal"))
            }
        }
        return links
    }

    static func web(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { return nil }
        return SiteLinks.normalize(url)
    }
}

/// Un élément de théorie qui s'ouvre d'un toucher : section, vidéo, diapos.
struct TheoryLinkRow: View {
    let item: TheoryItem
    var onOpen: (BrowsedLink) -> Void

    var body: some View {
        Button {
            if let url = ExerciseLinks.web(item.urlString) {
                onOpen(BrowsedLink(title: "\(item.number) \(MathMarkup.plain(item.title))", url: url, icon: item.kind.icon))
            }
        } label: {
            HStack(spacing: Layout.control) {
                Image(systemName: item.isWatched ? "checkmark.circle.fill" : item.kind.icon)
                    .foregroundStyle(item.isWatched ? Color.green.accessibleMark : TaskType.theory.tint.accessibleMark)
                    .frame(width: 22)
                MathText("\(item.number) · \(item.title)", font: .subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if !item.urlString.isEmpty {
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(item.urlString.isEmpty)
    }
}

/// Un document à ouvrir : énoncé, corrigé, section de théorie, vidéo.
struct BrowsedLink: Identifiable, Hashable {
    var id: URL { url }
    var title: String
    var url: URL
    var icon: String = "doc.text"
}

/// Un document ouvert **dans l'app**, avec la session des sites de cours.
///
/// Safari ne connaît pas la connexion Moodle faite dans l'app : un lien Moodle
/// ouvert là-bas redemandait de se connecter. Le navigateur intégré partage le
/// magasin de cookies de l'import — un PDF de série s'ouvre directement.
struct InAppBrowser: View {
    let link: BrowsedLink

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserModel()

    var body: some View {
        NavigationStack {
            WebView(model: model, initialURL: link.url)
                .overlay(alignment: .top) {
                    if model.isLoading {
                        ProgressView(value: model.progress).progressViewStyle(.linear).tint(Theme.accent)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(link.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ShareLink(item: model.url ?? link.url) { Image(systemName: "square.and.arrow.up") }
                        Link(destination: model.url ?? link.url) { Image(systemName: "safari") }
                            .accessibilityLabel("Ouvrir dans Safari")
                    }
                }
        }
    }
}
