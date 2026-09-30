import SwiftUI
import SwiftData

/// L'étape d'un exercice, en un glyphe.
///
/// Remplace la coche **et** les trois pastilles de sureté de l'ancienne ligne :
/// un cercle vide (à faire), un anneau qui se remplit (questions en cours), puis
/// la couleur de la sureté, puis celle de la correction. La teinte ne porte
/// jamais le sens seule : chaque état a son glyphe (✓ = ? ✗ ↺).
struct ExerciseStageMark: View {
    let stage: ExerciseStage
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            switch stage {
            case .toDo:
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 2)
            case .inProgress(let done, let total):
                ProgressRing(progress: Double(done) / Double(max(total, 1)),
                             color: TaskType.exercise.tint,
                             size: size,
                             lineWidth: 3,
                             showsLabel: false)
            case .needsConfidence:
                filled(TaskType.exercise.tint, glyph: "checkmark")
            case .toCorrect(let level):
                filled(level.color, glyph: level.glyph)
            case .corrected(let result):
                filled(result.color, glyph: result.glyph)
            case .redo:
                Circle().strokeBorder(Color.red.accessibleMark, lineWidth: 2)
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Color.red.accessibleMark)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.snappy, value: stage)
    }

    private func filled(_ tint: Color, glyph: String) -> some View {
        ZStack {
            Circle().fill(tint.verdictFill)
            Image(systemName: glyph)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Theme.knockedOutInk)
        }
    }
}

extension Correctness {
    /// Le glyphe dans le cercle d'étape : ✓, ~, ✗.
    var glyph: String {
        switch self {
        case .correct: return "checkmark"
        case .partial: return "minus"
        case .wrong: return "xmark"
        }
    }
}

extension ConfidenceLevel {
    /// Le libellé d'un bouton de sureté, court et sans couleur.
    var choiceLabel: String {
        switch self {
        case .high: return "Sûr·e"
        case .medium: return "Moyen"
        case .low: return "Pas sûr·e"
        }
    }
}

extension ExerciseStage {
    /// La teinte du libellé d'étape dans la liste.
    var tint: Color {
        switch self {
        case .toDo: return .secondary
        case .inProgress: return TaskType.exercise.tint
        case .needsConfidence: return .orange
        case .toCorrect: return TaskType.correction.tint
        case .corrected(let result): return result.color
        case .redo: return .red
        }
    }
}

/// Trois boutons « Sûr·e / Moyen / Pas sûr·e », avec leur glyphe.
struct ConfidenceChoice: View {
    var value: ConfidenceLevel?
    var onChoose: (ConfidenceLevel) -> Void

    var body: some View {
        HStack(spacing: Layout.inline) {
            ForEach(ConfidenceLevel.allCases) { level in
                let isOn = value == level
                Button {
                    Haptics.soft()
                    onChoose(level)
                } label: {
                    HStack(spacing: Layout.snug) {
                        Image(systemName: level.glyph).font(.caption.weight(.bold))
                        Text(level.choiceLabel).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(isOn ? level.color.verdictFill : level.color.badgeFill,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(isOn ? Theme.knockedOutInk : level.color.badgeInk)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .accessibilityLabel("Sureté : \(level.label)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - L'espace de travail d'une série

/// Une série, exercice après exercice.
///
/// L'ancienne fiche d'exercice était un long formulaire isolé : on l'ouvrait,
/// on la refermait, on cherchait le suivant dans la liste, et le chrono, lui,
/// comptait « Exercices » sur le cours entier. Ici :
///   • on **glisse** d'un exercice au suivant, une bande en haut montre où l'on
///     en est dans la série ;
///   • chaque exercice se lit comme un parcours — faire (les questions), juger
///     (la sureté), corriger — avec l'étape en cours mise en avant ;
///   • **le chrono suit l'exercice affiché** : passer de 3.2 à 3.3 attribue le
///     temps déjà compté à 3.2 et continue sur 3.3, sans rien arrêter
///     (`FocusTimerState.switchContext`). Le temps passé s'affiche sur chaque
///     exercice.
struct ExerciseWorkspace: View {
    let series: ExerciseSeries
    @State private var selection: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    @State private var editingSeries = false
    @State private var deleting: Exercise?

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
            VStack(spacing: 0) {
                strip
                Divider()
                if exercises.isEmpty {
                    ContentUnavailableView("Aucun exercice",
                                           systemImage: TaskType.exercise.icon,
                                           description: Text("Modifie la série pour y ajouter ses exercices."))
                } else {
                    TabView(selection: $selection) {
                        ForEach(exercises) { exercise in
                            ExercisePage(exercise: exercise,
                                         sessions: sessions,
                                         onNext: { goNext(from: exercise) })
                                .tag(exercise.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { if !exercises.isEmpty { bottomBar } }
            .navigationTitle(series.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) {
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
                    .accessibilityLabel("Actions sur la série")
                }
            }
            .onChange(of: selection) { _, id in follow(id) }
            .onAppear { follow(selection) }
            .sheet(isPresented: $editingSeries) {
                if let course { SeriesEditorSheet(course: course, series: series) }
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

    // MARK: Bande des exercices

    /// Tous les exercices de la série, d'un coup d'œil : le glyphe d'étape de
    /// chacun, celui qu'on regarde souligné.
    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Layout.inline) {
                    ForEach(exercises) { exercise in
                        let isOn = exercise.id == selection
                        Button {
                            withAnimation(Motion.snappy) { selection = exercise.id }
                            Haptics.soft()
                        } label: {
                            HStack(spacing: Layout.snug) {
                                ExerciseStageMark(stage: ExerciseStage(exercise), size: 14)
                                Text(exercise.exerciseNumber)
                                    .font(.caption.weight(isOn ? .bold : .medium).monospacedDigit())
                                if exercise.isBonus {
                                    Image(systemName: "star.fill").font(.caption2)
                                        .foregroundStyle(Color.orange.accessibleMark)
                                }
                            }
                            .padding(.horizontal, Layout.control)
                            .frame(minHeight: 34)
                            .background(isOn ? Theme.accent.badgeFill : Theme.softBackground, in: Capsule())
                            .foregroundStyle(isOn ? Theme.accent.badgeInk : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(exercise.id)
                        .accessibilityLabel("\(exercise.displayNumber), \(ExerciseStage(exercise).label)")
                        .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, Layout.screenPadding)
                .padding(.vertical, Layout.control)
            }
            .onChange(of: selection) { _, id in
                withAnimation(Motion.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .background(.bar)
    }

    // MARK: Barre du bas

    private var bottomBar: some View {
        HStack(spacing: Layout.block) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
            }
            .disabled(index == 0)
            .accessibilityLabel("Exercice précédent")

            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Text("\(index + 1) sur \(exercises.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(bottomDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
            }
            .disabled(index >= exercises.count - 1)
            .accessibilityLabel("Exercice suivant")
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, Layout.tight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// « 1/2 faits · 1,5 h » — le temps seulement quand il y en a.
    private var bottomDetail: String {
        let spent = ExerciseFlow.seconds(on: series, sessions: sessions)
        let done = "\(series.doneCount)/\(series.requiredExercises.count) faits"
        return spent >= 60 ? "\(done) · \(DateUtils.hoursLabel(seconds: spent))" : done
    }

    // MARK: Gestes

    private func step(_ delta: Int) {
        let target = min(max(0, index + delta), exercises.count - 1)
        guard exercises.indices.contains(target) else { return }
        withAnimation(Motion.snappy) { selection = exercises[target].id }
        Haptics.soft()
    }

    private func goNext(from exercise: Exercise) {
        guard let next = ExerciseFlow.next(after: exercise, in: exercises) else {
            dismiss()
            return
        }
        withAnimation(Motion.snappy) { selection = next.id }
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
        }
        context.delete(exercise)
        try? context.save()
        Haptics.removed()
    }
}

/// L'espace de travail ouvert sur un exercice précis — depuis l'accueil, la
/// progression ou la recherche, qui ne connaissent que l'exercice.
struct ExerciseSheet: View {
    let exercise: Exercise

    var body: some View {
        if let series = exercise.series {
            ExerciseWorkspace(series: series, start: exercise)
        }
    }
}

// MARK: - Un exercice

/// Une page de l'espace de travail : l'énoncé, le chrono, puis les trois
/// étapes — faire, juger, corriger.
private struct ExercisePage: View {
    @Bindable var exercise: Exercise
    let sessions: [StudySession]
    var onNext: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var note = ""
    @State private var scoreText = ""
    @State private var maxScoreText = ""
    @State private var showingScore = false

    private var stage: ExerciseStage { ExerciseStage(exercise) }
    private var course: Course? { exercise.series?.course }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                header
                timerCard
                doStep
                confidenceStep
                correctionStep
                if stage.isDone, !(stage == .needsConfidence) {
                    Button(action: onNext) {
                        Label("Exercice suivant", systemImage: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Layout.tight)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(Layout.screenPadding)
            .adaptiveColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            note = exercise.correctionNote ?? ""
            scoreText = exercise.score.map { String(format: "%g", $0) } ?? ""
            maxScoreText = exercise.maxScore.map { String(format: "%g", $0) } ?? ""
            showingScore = exercise.score != nil
        }
        .onChange(of: note) { _, _ in persistCorrection() }
        .onChange(of: scoreText) { _, _ in persistCorrection() }
        .onChange(of: maxScoreText) { _, _ in persistCorrection() }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: Layout.inline) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.inline) {
                Text(exercise.displayNumber)
                    .font(.title2.weight(.bold))
                if exercise.isBonus {
                    Pill(text: "bonus", color: .orange, icon: "star.fill")
                }
                Spacer(minLength: 0)
                Text(stage.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stage.tint.accessibleInk)
            }
            if !exercise.title.isEmpty {
                MathText(exercise.title, font: .headline)
            }
            if !exercise.statement.isEmpty {
                MathText(exercise.statement, font: .subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = URL(string: exercise.statementURLString.isEmpty ? (exercise.series?.urlString ?? "") : exercise.statementURLString),
               url.scheme?.hasPrefix("http") == true {
                Link(destination: url) {
                    Label("Ouvrir l'énoncé", systemImage: "doc.text")
                        .font(.footnote.weight(.medium))
                }
            }
        }
    }

    // MARK: Chrono

    /// Le chrono, **sur place** : démarrer ne quitte pas l'exercice, et une
    /// session déjà en cours sur ce cours suit la page affichée.
    private var timerCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let focus = app.focus
            let state = focus.state
            let onThis = focus.hasSession && state?.targetID == exercise.id
            let live = onThis ? (state?.allocation(at: timeline.date).first { $0.targetID == exercise.id }?.seconds ?? 0) : 0
            let spent = ExerciseFlow.seconds(on: exercise.id, sessions: sessions, live: live)
            VStack(alignment: .leading, spacing: Layout.control) {
                if onThis, let state {
                    HStack(spacing: Layout.control) {
                        Circle()
                            .fill(state.isRunning ? Color.green.accessibleMark : Color.orange.accessibleMark)
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(state.isRunning ? "Le chrono est sur cet exercice" : "Chrono en pause")
                                .font(.subheadline.weight(.semibold))
                            Text("Séance : \(TimerText.clock(state.elapsed(at: timeline.date)))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(TimerText.clock(TimeInterval(live)))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .contentTransition(.numericText())
                        Button {
                            if state.isRunning { focus.pause() } else { focus.resume() }
                            Haptics.tap()
                        } label: {
                            Image(systemName: state.isRunning ? "pause.fill" : "play.fill")
                                .font(.body.weight(.semibold))
                                .frame(width: Layout.minTouch, height: Layout.minTouch)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel(state.isRunning ? "Mettre en pause" : "Reprendre")
                    }
                    Text("Glisse vers un autre exercice : le chrono le suit, et ce temps-ci reste à \(exercise.exerciseNumber).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if focus.hasSession, let state {
                    HStack(spacing: Layout.control) {
                        Image(systemName: "timer").foregroundStyle(.secondary)
                        Text("Chrono en cours ailleurs · \(TimerText.clock(state.elapsed(at: timeline.date)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        Button("Passer ici") {
                            focus.updateContext(courseID: .some(course?.id), taskType: workType,
                                                targetID: .some(exercise.id), label: "")
                            Haptics.tap()
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                } else {
                    Button {
                        focus.start(courseID: course?.id, taskType: workType, targetID: exercise.id)
                        Haptics.tap()
                    } label: {
                        Label(workType == .correction ? "Corriger \(exercise.exerciseNumber) au chrono"
                                                      : "Démarrer le chrono sur \(exercise.exerciseNumber)",
                              systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Layout.tight)
                    }
                    .buttonStyle(.bordered)
                }
                if spent >= 60 {
                    Label("\(DateUtils.durationLabel(seconds: spent)) passées sur cet exercice", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Un cadre seulement quand il y a un chrono à montrer : autour d'un
            // simple bouton « Démarrer », il n'encadrait que du vide.
            .padding(focusHasSession ? Layout.gutter : 0)
            .background(focusHasSession ? Theme.softBackground : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        }
    }

    private var focusHasSession: Bool { app.focus.hasSession }

    /// Faire ou corriger : un exercice fait et pas encore corrigé se chronomètre
    /// en correction.
    private var workType: TaskType {
        switch stage {
        case .toCorrect, .needsConfidence: return .correction
        default: return .exercise
        }
    }

    // MARK: 1. Faire

    private var doStep: some View {
        StepCard(number: 1, title: "Faire",
                 trailing: exercise.subQuestionLabel.map { "\($0) questions" },
                 isCurrent: !stage.isDone) {
            if exercise.hasSubQuestions {
                VStack(spacing: 0) {
                    ForEach(exercise.sortedSubQuestions) { question in
                        questionRow(question)
                        ForEach(question.sortedChildren) { child in
                            questionRow(child)
                        }
                    }
                }
            } else {
                Button {
                    toggleDone()
                } label: {
                    HStack(spacing: Layout.control) {
                        Image(systemName: exercise.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(exercise.isDone ? Color.green.accessibleMark : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                        Text(exercise.isDone ? "Fait" : "Marquer fait")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Layout.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if exercise.hasSubQuestions, !exercise.isDone {
                Button("Tout marquer fait") { toggleDone() }
                    .font(.footnote.weight(.medium))
                    .padding(.top, Layout.tight)
            }
        }
    }

    private func questionRow(_ question: SubQuestion) -> some View {
        Button {
            question.toggle()
            Haptics.tap()
            try? context.save()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Layout.control) {
                Image(systemName: question.isDone ? "checkmark.circle.fill" : "circle")
                    .font(question.parent == nil ? .title3 : .body)
                    .foregroundStyle(question.isDone ? Color.green.accessibleMark : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.kind == .part ? "Partie" : questionTitle(question))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !question.text.isEmpty {
                        MathText(question.text, font: .subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, question.parent == nil ? 0 : 30)
            .padding(.vertical, Layout.tight)
            .frame(minHeight: Layout.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(question.parent.map { "\($0.displayLabel) " } ?? "")\(question.displayLabel) \(question.text)")
        .accessibilityValue(question.isDone ? "fait" : "à faire")
    }

    /// « 1. » sans texte n'apprend rien : une question sans intitulé se lit
    /// « Question 1 ».
    private func questionTitle(_ question: SubQuestion) -> String {
        let label = question.displayLabel
        guard question.text.isEmpty else { return label }
        let bare = label.trimmingCharacters(in: CharacterSet(charactersIn: ".) "))
        return bare.allSatisfy(\.isNumber) ? "Question \(bare)" : label
    }

    // MARK: 2. Juger

    private var confidenceStep: some View {
        StepCard(number: 2, title: "Sureté de ta réponse",
                 trailing: nil,
                 isCurrent: stage == .needsConfidence) {
            ConfidenceChoice(value: exercise.confidence) { level in
                exercise.confidence = exercise.confidence == level ? nil : level
                if exercise.confidence != nil, !exercise.isDone {
                    exercise.setDone(true)
                    exercise.confidence = level
                }
                try? context.save()
            }
            Text(exercise.isDone ? "Honnêtement : ce qui est « pas sûr » revient dans « à revoir »."
                                 : "Choisir une sureté marque l'exercice fait.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 3. Corriger

    private var correctionStep: some View {
        StepCard(number: 3, title: "Correction",
                 trailing: exercise.correctedAt.map { "le \(DateUtils.shortDay.string(from: $0))" },
                 isCurrent: { if case .toCorrect = stage { return true }; return false }()) {
            CorrectnessControl(value: exercise.correctness) { result in
                exercise.correct(result)
                try? context.save()
            }
            Toggle("À refaire", isOn: Binding(
                get: { exercise.redoRequired },
                set: { exercise.redoRequired = $0; try? context.save() }
            ))
            .font(.subheadline)
            TextField("Ce qu'il faut retenir (ex : revoir la récurrence)", text: $note, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...5)
            if showingScore {
                HStack {
                    TextField("Points", text: $scoreText).keyboardType(.decimalPad)
                    Text("/").foregroundStyle(.secondary)
                    TextField("Max", text: $maxScoreText).keyboardType(.decimalPad)
                }
                .font(.subheadline)
            } else {
                Button("Ajouter des points") { showingScore = true }
                    .font(.footnote.weight(.medium))
            }
        }
    }

    // MARK: Actions

    private func toggleDone() {
        exercise.setDone(!exercise.isDone)
        if exercise.isDone { Haptics.success() } else { Haptics.soft() }
        try? context.save()
    }

    private func persistCorrection() {
        exercise.correctionNote = note.isEmpty ? nil : note
        exercise.score = Double(scoreText.replacingOccurrences(of: ",", with: "."))
        exercise.maxScore = Double(maxScoreText.replacingOccurrences(of: ",", with: "."))
        try? context.save()
    }
}

/// Une étape numérotée du parcours ; l'étape en cours est soulignée.
private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    var trailing: String?
    var isCurrent: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.control) {
            HStack(spacing: Layout.inline) {
                Text("\(number)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Theme.knockedOutInk : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(isCurrent ? Theme.accent.accessibleMark : Color(.tertiarySystemFill), in: Circle())
                Text(title).font(.headline)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(Layout.gutter)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(isCurrent ? Theme.accent.accessibleMark.opacity(0.6) : .clear, lineWidth: 1.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Étape \(number) : \(title)")
    }
}
