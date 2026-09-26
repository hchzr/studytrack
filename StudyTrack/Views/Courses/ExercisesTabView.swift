import SwiftUI
import SwiftData

/// Exercices : séries, sous-exercices, bonus, sureté de réponse et correction.
struct ExercisesTabView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @State private var selectedExercise: Exercise?
    @State private var showingAddSeries = false
    @State private var showingPDFImport = false
    /// Séries terminées que l'étudiant·e a rouvertes.
    @State private var expandedSeries: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if course.series.isEmpty {
                EmptyCard(icon: "checklist",
                          title: "Aucune série",
                          message: "Importe le PDF d'une série pour que StudyTrack repère les exercices tout seul, ou ajoute-les à la main.",
                          actionTitle: "Importer un PDF") {
                    showingPDFImport = true
                }
                Button {
                    showingAddSeries = true
                } label: {
                    Label("Ajouter une série à la main", systemImage: "plus")
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
                        showingAddSeries = true
                    } label: {
                        Label("À la main", systemImage: "plus")
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
        .sheet(isPresented: $showingAddSeries) {
            AddSeriesSheet(course: course)
        }
        .sheet(isPresented: $showingPDFImport) {
            SeriesImportSheet(course: course)
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
            Text("Une pastille de sureté marque l'exercice fait en un seul geste. Les bonus sont suivis mais exclus du pourcentage.")
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
        .accessibilityLabel("\(series.title), terminée")
        .accessibilityHint("Afficher les exercices")
    }

    private func seriesCard(_ series: ExerciseSeries) -> some View {
        Card(title: series.title,
             icon: "list.bullet.rectangle",
             trailing: "\(series.doneCount)/\(series.requiredExercises.count)") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Pill(text: "Semaine \(series.plannedWeek)", color: .secondary)
                    if !series.bonusExercises.isEmpty {
                        Pill(text: "\(series.bonusExercises.count) bonus", color: .orange, icon: "star.fill")
                    }
                    if series.isComplete {
                        Pill(text: "Terminée", color: .green, icon: "checkmark.seal.fill")
                    }
                    Spacer(minLength: 0)
                    if expandedSeries.contains(series.id) {
                        Button("Replier") {
                            withAnimation(.snappy) { _ = expandedSeries.remove(series.id) }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                }

                ProgressBar(progress: series.progress, color: TaskType.exercise.tint)

                VStack(spacing: 0) {
                    ForEach(series.sortedExercises) { exercise in
                        ExerciseRow(exercise: exercise,
                                    onToggleDone: { toggleDone(exercise) },
                                    onConfidence: { level in setConfidence(level, on: exercise) },
                                    onOpen: { selectedExercise = exercise })
                        if exercise.id != series.sortedExercises.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private func toggleDone(_ exercise: Exercise) {
        if exercise.isDone {
            exercise.doneAt = nil
            exercise.confidence = nil
        } else {
            exercise.doneAt = Date()
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
                exercise.doneAt = Date()
                Haptics.success()
            }
        } else {
            exercise.confidence = nil
        }
        try? context.save()
    }
}

/// Ligne d'exercice : coche, identifiant, sureté visible, chevron.
///
/// Le code couleur n'est plus caché dans un menu : c'est un contrôle à trois
/// pastilles, toujours lisible.
struct ExerciseRow: View {
    let exercise: Exercise
    var onToggleDone: () -> Void
    var onConfidence: (ConfidenceLevel?) -> Void
    var onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
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
            .padding(.vertical, Layout.micro)
        } else {
            HStack(spacing: 0) {
                checkButton
                textButton
                confidenceControl
            }
            .padding(.vertical, Layout.micro)
        }
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
                    // L'avancement des questions se lit **sans ouvrir** : c'est ce
                    // qui distingue un exercice entamé d'un exercice intact.
                    if let label = exercise.subQuestionLabel {
                        Text(label)
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, Layout.snug)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(exercise.subQuestionDoneCount) questions sur \(exercise.subQuestions.count) faites")
                    }
                }
                if !exercise.title.isEmpty {
                    Text(exercise.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
                    .font(.title3)
                    .foregroundStyle(question.isDone ? Color.green.accessibleMark : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.displayLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !question.text.isEmpty {
                        Text(question.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(question.displayLabel) \(question.text)")
        .accessibilityValue(question.isDone ? "fait" : "à faire")
        .accessibilityAddTraits(question.isDone ? [.isSelected] : [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercice") {
                    DetailRow(icon: "number", label: "Numéro", value: exercise.exerciseNumber, tint: TaskType.exercise.tint)
                    if let series = exercise.series {
                        DetailRow(icon: "list.bullet", label: "Série", value: series.title)
                        if let course = series.course {
                            DetailRow(icon: "books.vertical", label: "Cours", value: course.code)
                        }
                    }
                    if exercise.isBonus {
                        DetailRow(icon: "star.fill", label: "Type", value: "Bonus", tint: .orange)
                    }
                }

                if exercise.hasSubQuestions {
                    Section {
                        ForEach(exercise.sortedSubQuestions) { question in
                            subQuestionRow(question)
                        }
                    } header: {
                        HStack {
                            Text("Questions")
                            Spacer()
                            Text(exercise.subQuestionLabel ?? "")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
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
                        context.delete(exercise)
                        try? context.save()
                        dismiss()
                    } label: {
                        Label("Supprimer l'exercice", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(exercise.displayNumber)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .onAppear {
                note = exercise.correctionNote ?? ""
                if let score = exercise.score { scoreText = String(format: "%.0f", score) }
                if let maxScore = exercise.maxScore { maxScoreText = String(format: "%.0f", maxScore) }
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

/// Ajout d'une série avec ses sous-exercices.
struct AddSeriesSheet: View {
    let course: Course

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var number = 1
    @State private var title = ""
    @State private var week = 1
    @State private var count = 3
    @State private var bonusCount = 0

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
                    .font(.title3)
                    .foregroundStyle(question.isDone ? Color.green.accessibleMark : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.displayLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !question.text.isEmpty {
                        Text(question.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(question.displayLabel) \(question.text)")
        .accessibilityValue(question.isDone ? "fait" : "à faire")
        .accessibilityAddTraits(question.isDone ? [.isSelected] : [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Série") {
                    Stepper("Numéro : \(number)", value: $number, in: 1...40)
                    TextField("Titre (optionnel)", text: $title)
                    Stepper("Semaine : \(week)", value: $week, in: 1...30)
                }

                Section {
                    Stepper("Sous-exercices : \(count)", value: $count, in: 0...20)
                    Stepper("Dont bonus : \(bonusCount)", value: $bonusCount, in: 0...20)
                } header: {
                    Text("Contenu")
                } footer: {
                    Text("Les sous-exercices seront nommés \(number).1, \(number).2… Les bonus sont placés en fin de série.")
                }
            }
            .navigationTitle("Nouvelle série")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { create() }
                }
            }
            .onAppear {
                number = (course.series.map(\.seriesNumber).max() ?? 0) + 1
                week = course.currentWeek
            }
        }
    }

    private func create() {
        let series = ExerciseSeries(course: course,
                                    seriesNumber: number,
                                    title: title.isEmpty ? "Série \(number)" : title,
                                    plannedWeek: week)
        context.insert(series)
        for index in 0..<count {
            let isBonus = index >= (count - bonusCount)
            let exercise = Exercise(series: series,
                                    exerciseNumber: "\(number).\(index + 1)",
                                    title: isBonus ? "Bonus" : "",
                                    isBonus: isBonus,
                                    sortOrder: index)
            context.insert(exercise)
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
