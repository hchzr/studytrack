import SwiftUI
import SwiftData

/// Exercices : séries, sous-exercices, bonus, sureté de réponse et correction.
///
/// Tout se gère **depuis la liste** : chaque série a son menu (modifier,
/// réimporter, tout cocher, supprimer), chaque exercice un appui long, et les
/// questions se cochent sur place sans ouvrir de fiche.
struct ExercisesTabView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @State private var selectedExercise: Exercise?
    @State private var editingSeries: SeriesEditTarget?
    @State private var showingPDFImport = false
    @State private var deletingSeries: ExerciseSeries?
    @State private var deletingExercise: Exercise?
    /// Séries terminées que l'étudiant·e a rouvertes.
    @State private var expandedSeries: Set<UUID> = []
    /// Exercices dont les questions sont dépliées dans la liste.
    @State private var expandedExercises: Set<UUID> = []

    /// Une série à modifier, ou une nouvelle (`series == nil`).
    struct SeriesEditTarget: Identifiable {
        let id = UUID()
        var series: ExerciseSeries?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if course.series.isEmpty {
                EmptyCard(icon: "checklist",
                          title: "Aucune série",
                          message: "Importe le PDF d'une série : exercices, questions et points (a)(b)(c) sont repérés tout seuls, et tu vérifies avant d'enregistrer.",
                          actionTitle: "Importer un PDF") {
                    showingPDFImport = true
                }
                Button {
                    editingSeries = SeriesEditTarget(series: nil)
                } label: {
                    Label("Créer une série à la main", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                // Les actions **en haut** : en semaine 12, importer la série 12
                // obligeait à faire défiler onze séries terminées.
                HStack(spacing: Layout.control) {
                    Button {
                        showingPDFImport = true
                    } label: {
                        Label("Importer un PDF", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        editingSeries = SeriesEditTarget(series: nil)
                    } label: {
                        Label("Nouvelle série", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline.weight(.medium))

                ForEach(course.sortedSeries) { series in
                    if isCollapsed(series) {
                        collapsedSeriesRow(series)
                    } else {
                        seriesCard(series)
                    }
                }

                // La légende ferme la liste au lieu de l'ouvrir : la structure
                // numérotée passe en premier, l'explication reste à portée.
                legend
            }
        }
        .sheet(item: $selectedExercise) { exercise in
            ExerciseDetailSheet(exercise: exercise)
        }
        #if DEBUG
        .onAppear {
            // Le simulateur ne sait pas taper : ce drapeau ouvre le détail d'un
            // exercice pour pouvoir le photographier.
            guard selectedExercise == nil,
                  let wanted = PreviewLaunch.string(PreviewLaunch.exerciseDetailFlag) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                selectedExercise = course.sortedSeries
                    .flatMap(\.sortedExercises)
                    .first { $0.exerciseNumber == wanted && $0.hasSubQuestions }
            }
        }
        #endif
        .sheet(item: $editingSeries) { target in
            SeriesEditorSheet(course: course, series: target.series)
        }
        .sheet(isPresented: $showingPDFImport) {
            SeriesImportSheet(course: course)
        }
        .confirmationDialog("Supprimer « \(deletingSeries?.title ?? "") » ?",
                            isPresented: Binding(get: { deletingSeries != nil }, set: { if !$0 { deletingSeries = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingSeries) { series in
            Button("Supprimer la série et ses \(series.exercises.count) exercices", role: .destructive) {
                context.delete(series)
                try? context.save()
                Haptics.warning()
            }
        } message: { series in
            let done = series.exercises.filter(\.isDone).count
            Text(done > 0 ? "\(done) exercice\(done > 1 ? "s" : "") déjà fait\(done > 1 ? "s" : "") seront perdus." : "Aucun exercice n'est encore fait.")
        }
        .confirmationDialog("Supprimer l'exercice \(deletingExercise?.exerciseNumber ?? "") ?",
                            isPresented: Binding(get: { deletingExercise != nil }, set: { if !$0 { deletingExercise = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingExercise) { exercise in
            Button("Supprimer", role: .destructive) {
                context.delete(exercise)
                try? context.save()
                Haptics.warning()
            }
        } message: { exercise in
            Text(exercise.isDone ? "Il est marqué fait : son avancement sera perdu." : "Ses questions seront supprimées avec lui.")
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: Layout.inline) {
            HStack(spacing: 16) {
                ForEach(ConfidenceLevel.allCases) { level in
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(level.color.verdictFill).frame(width: 14, height: 14)
                            Image(systemName: level.glyph)
                                .font(.caption2.weight(.bold))
                                .imageScale(.small)
                                .foregroundStyle(Theme.knockedOutInk)
                        }
                        Text(level.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text("Une pastille de sureté marque l'exercice fait. Appui long sur un exercice ou « ⋯ » sur une série pour modifier ou supprimer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Layout.micro)
    }

    /// Une série terminée — sans rien « à refaire » — se replie en une ligne :
    /// ce qui reste à faire remonte, ce qui est fait ne disparaît pas.
    private func isCollapsed(_ series: ExerciseSeries) -> Bool {
        series.isComplete
            && !series.exercises.contains(where: \.redoRequired)
            && !expandedSeries.contains(series.id)
    }

    private func collapsedSeriesRow(_ series: ExerciseSeries) -> some View {
        Button {
            withAnimation(.snappy) { _ = expandedSeries.insert(series.id) }
        } label: {
            HStack(spacing: Layout.control) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.green.accessibleMark)
                Text(series.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("semaine \(series.plannedWeek)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Layout.inline)
                Text("\(series.doneCount)/\(series.requiredExercises.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Layout.gutter)
            .padding(.vertical, Layout.block)
            .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { seriesMenuItems(series) }
        .accessibilityLabel("\(series.title), terminée")
        .accessibilityHint("Afficher les exercices")
    }

    private func seriesCard(_ series: ExerciseSeries) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: Layout.inline) {
                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text(series.title).font(.headline)
                        Text(seriesSubtitle(series))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Layout.inline)
                    Text("\(series.doneCount)/\(series.requiredExercises.count)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Menu {
                        seriesMenuItems(series)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(width: Layout.minTouch, height: Layout.minTouch)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Actions sur \(series.title)")
                }

                ProgressBar(progress: series.progress, color: TaskType.exercise.tint)

                if series.exercises.isEmpty {
                    Button {
                        editingSeries = SeriesEditTarget(series: series)
                    } label: {
                        Label("Ajouter des exercices", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }

                VStack(spacing: 0) {
                    ForEach(series.sortedExercises) { exercise in
                        ExerciseRow(exercise: exercise,
                                    isExpanded: expandedExercises.contains(exercise.id),
                                    onToggleDone: { toggleDone(exercise) },
                                    onConfidence: { level in setConfidence(level, on: exercise) },
                                    onOpen: { selectedExercise = exercise },
                                    onToggleExpanded: { toggleExpanded(exercise) },
                                    onToggleQuestion: { question in
                                        question.toggle()
                                        Haptics.tap()
                                        try? context.save()
                                    })
                        .contextMenu {
                            Button { selectedExercise = exercise } label: {
                                Label("Ouvrir", systemImage: "doc.text")
                            }
                            Button { editingSeries = SeriesEditTarget(series: series) } label: {
                                Label("Modifier la série…", systemImage: "pencil")
                            }
                            Button(role: .destructive) { deletingExercise = exercise } label: {
                                Label("Supprimer l'exercice", systemImage: "trash")
                            }
                        }
                        if exercise.id != series.sortedExercises.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private func seriesSubtitle(_ series: ExerciseSeries) -> String {
        var parts = ["Semaine \(series.plannedWeek)"]
        if let due = series.dueDate { parts.append("à rendre le \(DateUtils.shortDay.string(from: due))") }
        if !series.bonusExercises.isEmpty { parts.append("\(series.bonusExercises.count) bonus") }
        if series.isComplete { parts.append("terminée") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func seriesMenuItems(_ series: ExerciseSeries) -> some View {
        Button { editingSeries = SeriesEditTarget(series: series) } label: {
            Label("Modifier la série…", systemImage: "pencil")
        }
        Button { showingPDFImport = true } label: {
            Label("Réimporter un PDF…", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
        }
        if !series.exercises.isEmpty {
            if series.exercises.allSatisfy(\.isDone) {
                Button { setAll(series, done: false) } label: {
                    Label("Tout décocher", systemImage: "circle")
                }
            } else {
                Button { setAll(series, done: true) } label: {
                    Label("Tout marquer fait", systemImage: "checkmark.circle")
                }
            }
        }
        if isCollapsed(series) == false, series.isComplete, expandedSeries.contains(series.id) {
            Button { withAnimation(.snappy) { _ = expandedSeries.remove(series.id) } } label: {
                Label("Replier", systemImage: "chevron.up")
            }
        }
        Divider()
        Button(role: .destructive) { deletingSeries = series } label: {
            Label("Supprimer la série…", systemImage: "trash")
        }
    }

    private func setAll(_ series: ExerciseSeries, done: Bool) {
        for exercise in series.exercises {
            if exercise.hasSubQuestions {
                exercise.setSubQuestions(done: done)
            } else {
                exercise.doneAt = done ? (exercise.doneAt ?? Date()) : nil
            }
            if !done { exercise.confidence = nil }
        }
        Haptics.success()
        try? context.save()
    }

    private func toggleExpanded(_ exercise: Exercise) {
        withAnimation(.snappy) {
            if expandedExercises.contains(exercise.id) {
                expandedExercises.remove(exercise.id)
            } else {
                expandedExercises.insert(exercise.id)
            }
        }
        Haptics.tap()
    }

    private func toggleDone(_ exercise: Exercise) {
        if exercise.isDone {
            if exercise.hasSubQuestions { exercise.setSubQuestions(done: false) } else { exercise.doneAt = nil }
            exercise.confidence = nil
        } else {
            if exercise.hasSubQuestions { exercise.setSubQuestions(done: true) } else { exercise.doneAt = Date() }
            if exercise.confidence == nil { exercise.confidence = .medium }
        }
        Haptics.success()
        try? context.save()
    }

    /// Choisir une sureté sur un exercice **pas encore fait** le marque fait.
    ///
    /// « Fait » et « avec quelle sureté » sont une seule décision : demander deux
    /// gestes pour l'enregistrer, c'est un geste de trop, et la pastille grisée
    /// laissait croire qu'il fallait d'abord trouver la coche.
    private func setConfidence(_ level: ConfidenceLevel?, on exercise: Exercise) {
        if let level {
            exercise.confidence = level
            if exercise.doneAt == nil {
                if exercise.hasSubQuestions { exercise.setSubQuestions(done: true) } else { exercise.doneAt = Date() }
                Haptics.success()
            }
        } else {
            exercise.confidence = nil
        }
        try? context.save()
    }
}

/// Ligne d'exercice : coche, identifiant, sureté visible — et ses questions,
/// dépliables sur place.
///
/// Le code couleur n'est plus caché dans un menu : c'est un contrôle à trois
/// pastilles, toujours lisible.
struct ExerciseRow: View {
    let exercise: Exercise
    var isExpanded = false
    var onToggleDone: () -> Void
    var onConfidence: (ConfidenceLevel?) -> Void
    var onOpen: () -> Void
    var onToggleExpanded: () -> Void = {}
    var onToggleQuestion: (SubQuestion) -> Void = { _ in }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Aux tailles d'accessibilité, la rangée ne tient plus : la sureté passe
            // sous le texte au lieu de comprimer la colonne de lecture.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Layout.inline) {
                    HStack(spacing: 0) {
                        checkButton
                        textButton
                    }
                    confidenceControl
                        .padding(.leading, Layout.minTouch)
                }
            } else {
                HStack(spacing: 0) {
                    checkButton
                    textButton
                    confidenceControl
                }
            }
            if exercise.hasSubQuestions {
                questionsToggle
                if isExpanded {
                    questionList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.vertical, Layout.micro)
    }

    private var checkButton: some View {
        CheckCircleButton(isOn: exercise.isDone,
                          tint: TaskType.exercise.tint,
                          label: "Marquer \(exercise.displayNumber) fait",
                          action: onToggleDone)
    }

    private var textButton: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Layout.tight) {
                HStack(spacing: Layout.snug) {
                    // Le numéro seul : la liste est déjà celle des exercices, et
                    // « Exercice 1.3 » plus une pastille ne tenaient plus sur une
                    // ligne à côté des trois pastilles de sureté.
                    Text(exercise.exerciseNumber)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .accessibilityLabel(exercise.displayNumber)
                    if exercise.isBonus {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.orange.accessibleMark)
                            .accessibilityLabel("bonus")
                    }
                    if exercise.redoRequired {
                        Pill(text: "à refaire", color: .red, icon: "arrow.counterclockwise")
                    }
                }
                if !exercise.title.isEmpty {
                    MathText(exercise.title, font: .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // L'énoncé en une ligne : un exercice sans questions n'était
                // sinon qu'un numéro. Le détail l'affiche en entier.
                if !exercise.statement.isEmpty {
                    MathText(exercise.statement, font: .caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(exercise.hasSubQuestions ? 1 : 2)
                }
                if exercise.isDone, let correctness = exercise.correctness {
                    IconLabel(icon: correctness.icon,
                              text: correctness.label,
                              tint: correctness.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var confidenceControl: some View {
        ConfidenceControl(value: exercise.confidence,
                          isEnabled: true,
                          onChange: onConfidence)
            // Non fait : les pastilles restent tactiles mais en retrait, pour
            // que l'œil aille d'abord aux exercices déjà jugés.
            .opacity(exercise.isDone ? 1 : 0.55)
    }

    /// « 3/9 questions » + une barre : l'avancement se lit **sans ouvrir**, et
    /// un toucher déplie la liste.
    private var questionsToggle: some View {
        let leaves = exercise.leafSubQuestions
        let done = exercise.subQuestionDoneCount
        return Button(action: onToggleExpanded) {
            HStack(spacing: Layout.inline) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text("\(done)/\(leaves.count) questions")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(done), total: Double(max(leaves.count, 1)))
                    .tint(TaskType.exercise.tint)
                    .frame(maxWidth: 80)
                Spacer(minLength: 0)
            }
            .padding(.leading, Layout.minTouch)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(done) questions sur \(leaves.count) faites")
        .accessibilityHint(isExpanded ? "Replier les questions" : "Déplier pour cocher les questions")
    }

    private var questionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(exercise.sortedSubQuestions) { question in
                questionRow(question, depth: 0)
                ForEach(question.sortedChildren) { child in
                    questionRow(child, depth: 1)
                }
            }
        }
        .padding(.leading, Layout.minTouch)
        .padding(.bottom, Layout.tight)
    }

    private func questionRow(_ question: SubQuestion, depth: Int) -> some View {
        Button {
            onToggleQuestion(question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Layout.inline) {
                Image(systemName: question.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(question.isDone ? Color.green.accessibleMark : .secondary)
                Text(question.kind == .part ? "Partie" : question.displayLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                if !question.text.isEmpty {
                    MathText(question.text, font: .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, depth == 0 ? 0 : 22)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(question.parent.map { "\($0.displayLabel) " } ?? "")\(question.kind == .part ? "partie" : question.displayLabel) \(question.text)")
        .accessibilityValue(question.isDone ? "fait" : "à faire")
    }
}

/// Contrôle de correction : juste / moyennement juste / faux.
struct CorrectnessControl: View {
    var value: Correctness?
    var onChange: (Correctness) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Correctness.allCases) { option in
                Button {
                    Haptics.tap()
                    onChange(option)
                } label: {
                    Text(option.shortLabel)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(value == option ? option.color.opacity(0.22) : Color.secondary.opacity(0.10))
                        )
                        .foregroundStyle(value == option ? option.color.accessibleInk : Color.secondary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(value == option ? option.color.opacity(0.6) : Color.clear, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(value == option ? [.isSelected] : [])
            }
        }
    }
}

/// Détail d'un exercice : dates, sureté, correction, note.
struct ExerciseDetailSheet: View {
    @Bindable var exercise: Exercise

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var note = ""
    @State private var scoreText = ""
    @State private var maxScoreText = ""
    /// L'exercice en cours de modification (numéro, intitulé, bonus, questions).
    @State private var editing: SeriesDraft?
    @State private var confirmingDelete = false

    /// Une sous-question cochable.
    ///
    /// La ligne entière est cliquable, pas seulement la case : viser un carré de
    /// vingt points sur un écran de téléphone est le genre de détail qui fait
    /// qu'on ne coche pas.
    private func subQuestionRow(_ question: SubQuestion) -> some View {
        Button {
            question.toggle()
            Haptics.tap()
            try? context.save()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Layout.control) {
                Image(systemName: question.isDone ? "checkmark.circle.fill" : "circle")
                    .font(question.parent == nil ? .title3 : .body)
                    .foregroundStyle(question.isDone ? Color.green.accessibleMark : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.kind == .part ? "Partie" : question.displayLabel)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(question.parent.map { "\($0.displayLabel) " } ?? "")\(question.displayLabel) \(question.text)")
        .accessibilityValue(question.isDone ? "fait" : "à faire")
        .accessibilityAddTraits(question.isDone ? [.isSelected] : [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        if !exercise.title.isEmpty {
                            MathText(exercise.title, font: .headline)
                        }
                        if !exercise.statement.isEmpty {
                            MathText(exercise.statement, font: .subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text([exercise.series?.course?.displayCode, exercise.series?.title,
                              exercise.isBonus ? "bonus" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if exercise.hasSubQuestions {
                        ForEach(exercise.sortedSubQuestions) { question in
                            subQuestionRow(question)
                            ForEach(question.sortedChildren) { child in
                                subQuestionRow(child)
                            }
                        }
                    }
                    Button {
                        startEditing()
                    } label: {
                        Label(exercise.hasSubQuestions ? "Modifier les questions" : "Découper en questions",
                              systemImage: "list.bullet.indent")
                            .font(.subheadline)
                    }
                } header: {
                    if exercise.hasSubQuestions {
                        HStack {
                            Text("Questions")
                            Spacer()
                            Text(exercise.subQuestionLabel ?? "")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if exercise.hasSubQuestions {
                        Text("Coche chaque question au fur et à mesure. L'exercice est marqué fait quand elles le sont toutes — c'est le même travail, à rendre ensemble.")
                    }
                }

                Section {
                    HStack {
                        Text("Fait le")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(exercise.doneAt.map { DateUtils.shortDay.string(from: $0) } ?? "Pas encore fait")
                            .font(.subheadline.weight(.medium))
                    }
                    Button {
                        if exercise.isDone {
                            // Décocher l'exercice décoche ses questions : sinon la
                            // première case reviendrait cochée au prochain passage.
                            if exercise.hasSubQuestions {
                                exercise.setSubQuestions(done: false)
                            } else {
                                exercise.doneAt = nil
                            }
                            exercise.confidence = nil
                        } else {
                            if exercise.hasSubQuestions {
                                exercise.setSubQuestions(done: true)
                            } else {
                                exercise.doneAt = Date()
                            }
                            if exercise.confidence == nil { exercise.confidence = .medium }
                        }
                        Haptics.success()
                        try? context.save()
                    } label: {
                        Label(exercise.isDone ? "Annuler « fait »" : "Marquer comme fait",
                              systemImage: exercise.isDone ? "arrow.uturn.backward" : "checkmark.circle.fill")
                    }
                } header: {
                    Text("Réalisation")
                }

                Section {
                    ConfidenceControl(value: exercise.confidence,
                                      isEnabled: exercise.isDone) { level in
                        exercise.confidence = level
                        try? context.save()
                    }
                } header: {
                    Text("Sureté de la réponse")
                } footer: {
                    Text("Vert : sûr·e. Orange : moyennement sûr·e. Rouge : répondu au hasard ou pas sûr·e.")
                }

                Section {
                    HStack {
                        Text("Corrigé le")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(exercise.correctedAt.map { DateUtils.shortDay.string(from: $0) } ?? "Pas encore corrigé")
                            .font(.subheadline.weight(.medium))
                    }

                    CorrectnessControl(value: exercise.correctness) { option in
                        exercise.correctedAt = Date()
                        exercise.correctness = option
                        if option == .wrong { exercise.redoRequired = true }
                        try? context.save()
                    }

                    Toggle("À refaire", isOn: Binding(
                        get: { exercise.redoRequired },
                        set: { exercise.redoRequired = $0; try? context.save() }
                    ))

                    HStack {
                        TextField("Score", text: $scoreText)
                            .keyboardType(.decimalPad)
                        Text("/").foregroundStyle(.secondary)
                        TextField("Max", text: $maxScoreText)
                            .keyboardType(.decimalPad)
                    }
                } header: {
                    Text("Correction")
                } footer: {
                    Text("Un exercice corrigé « faux » est automatiquement marqué à refaire.")
                }

                Section("Remarque de correction") {
                    TextField("Ex : revoir la récurrence du cas moyen", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Label("Enregistrer", systemImage: "checkmark.circle.fill")
                    }

                    Button {
                        app.router.startFocus(courseID: exercise.series?.course?.id,
                                              courseCode: exercise.series?.course?.code ?? "",
                                              taskType: .exercise,
                                              label: "\(exercise.series?.course?.code ?? "") · \(exercise.displayNumber)")
                        dismiss()
                    } label: {
                        Label("Démarrer un chrono sur cet exercice", systemImage: "timer")
                    }

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Supprimer l'exercice", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(exercise.displayNumber)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Modifier") { startEditing() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .confirmationDialog("Supprimer l'exercice \(exercise.exerciseNumber) ?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    context.delete(exercise)
                    try? context.save()
                    Haptics.warning()
                    dismiss()
                }
            } message: {
                Text(exercise.isDone ? "Il est marqué fait : son avancement sera perdu." : "Ses questions seront supprimées avec lui.")
            }
            .onAppear {
                note = exercise.correctionNote ?? ""
                if let score = exercise.score { scoreText = String(format: "%.0f", score) }
                if let maxScore = exercise.maxScore { maxScoreText = String(format: "%.0f", maxScore) }
            }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                editor
            }
        }
    }

    /// L'exercice dans le brouillon de **sa série** : le même éditeur que la
    /// relecture d'import, et l'enregistrement vérifie qu'aucun autre exercice
    /// de la série ne porte déjà le numéro choisi.
    private func startEditing() {
        guard let series = exercise.series else { return }
        editing = SeriesDraft(series: series)
    }

    private var editedIndex: Int? {
        editing?.exercises.firstIndex { $0.existingID == exercise.id }
    }

    private var editor: some View {
        NavigationStack {
            Group {
                if let index = editedIndex, let number = editing?.number {
                    ExerciseDraftEditor(exercise: Binding(get: { editing!.exercises[index] },
                                                          set: { editing!.exercises[index] = $0 }),
                                        seriesNumber: number)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { editing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        guard let editing, let course = exercise.series?.course else { return }
                        SeriesDraftWriter.write(editing, to: course, mode: .edit, context: context)
                        try? context.save()
                        self.editing = nil
                        Haptics.success()
                    }
                    .fontWeight(.semibold)
                    .disabled(!(editing?.problems(takenNumbers: []).isEmpty ?? true))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problems = editing?.problems(takenNumbers: []), !problems.isEmpty {
                    Label(problems.joined(separator: " "), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.orange.accessibleInk)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
    }

    private func save() {
        exercise.correctionNote = note
        exercise.score = Double(scoreText.replacingOccurrences(of: ",", with: "."))
        exercise.maxScore = Double(maxScoreText.replacingOccurrences(of: ",", with: "."))
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

