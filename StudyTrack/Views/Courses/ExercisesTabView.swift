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
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    /// La série ouverte dans l'espace de travail, et l'exercice où l'ouvrir.
    @State private var workspace: WorkspaceTarget?
    @State private var editingSeries: SeriesEditTarget?
    @State private var showingPDFImport = false
    /// PDF d'une série importée de Moodle, téléchargé dans la session : il
    /// ouvre l'import avec le fichier déjà choisi.
    @State private var downloadedPDF: DownloadedPDF?
    @State private var downloadingSeries: UUID?
    @State private var downloadError: String?
    @Environment(AppContainer.self) private var app

    struct DownloadedPDF: Identifiable {
        let id = UUID()
        var url: URL
    }
    @State private var deletingSeries: ExerciseSeries?
    @State private var deletingExercise: Exercise?
    /// Séries dont l'étudiant·e a inversé le pliage par défaut (une série
    /// terminée rouverte, une série en cours repliée).
    @State private var toggledSeries: Set<UUID> = []
    /// Exercices qu'on vient de cocher : la ligne demande la sureté, au lieu
    /// d'en inventer une.
    @State private var askingConfidence: Set<UUID> = []

    struct WorkspaceTarget: Identifiable {
        let id = UUID()
        var series: ExerciseSeries
        var start: Exercise?
    }

    /// Une série à modifier, ou une nouvelle (`series == nil`).
    struct SeriesEditTarget: Identifiable {
        let id = UUID()
        var series: ExerciseSeries?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if course.series.isEmpty {
                EmptyCard(icon: TaskType.exercise.icon,
                          title: "Aucune série",
                          message: "Importe les séries depuis Moodle (elles arrivent rangées par semaine), ou le PDF d'une série : exercices et questions (a)(b)(c) sont repérés tout seuls.",
                          actionTitle: "Importer depuis Moodle") {
                    app.router.openContentImport(courseID: course.id)
                }
                HStack(spacing: Layout.control) {
                    Button {
                        showingPDFImport = true
                    } label: {
                        Label("Un PDF", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        editingSeries = SeriesEditTarget(series: nil)
                    } label: {
                        Label("À la main", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            } else {
                // L'ajout **en haut**, mais discret : en semaine 12, importer la
                // série 12 obligeait à faire défiler onze séries terminées. Deux
                // gros boutons pleins, eux, faisaient concurrence au chrono de
                // la fiche — un menu suffit à un geste hebdomadaire.
                HStack(alignment: .firstTextBaseline) {
                    Text("Séries")
                        .font(.headline)
                    Text("\(course.series.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button { showingPDFImport = true } label: {
                            Label("Importer le PDF d'une série", systemImage: "doc.badge.plus")
                        }
                        Button { editingSeries = SeriesEditTarget(series: nil) } label: {
                            Label("Créer une série à la main", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Label("Ajouter", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Ajouter une série")
                }
                .padding(.horizontal, Layout.micro)

                VStack(spacing: Layout.control) {
                    ForEach(course.sortedSeries) { series in
                        seriesCard(series)
                    }
                }

                legend
            }
        }
        .sheet(item: $workspace) { target in
            ExerciseWorkspace(series: target.series, start: target.start)
        }
        #if DEBUG
        .onAppear {
            // Le simulateur ne sait pas taper : ce drapeau ouvre le détail d'un
            // exercice pour pouvoir le photographier.
            guard workspace == nil,
                  let wanted = PreviewLaunch.string(PreviewLaunch.exerciseDetailFlag) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if let exercise = course.sortedSeries
                    .flatMap(\.sortedExercises)
                    .first(where: { $0.exerciseNumber == wanted }),
                   let series = exercise.series {
                    workspace = WorkspaceTarget(series: series, start: exercise)
                }
            }
        }
        #endif
        .sheet(item: $editingSeries) { target in
            SeriesEditorSheet(course: course, series: target.series)
        }
        .sheet(isPresented: $showingPDFImport) {
            SeriesImportSheet(course: course)
        }
        .sheet(item: $downloadedPDF) { pdf in
            SeriesImportSheet(course: course, initialFileURL: pdf.url)
        }
        .alert("PDF inaccessible", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("Choisir le fichier") { showingPDFImport = true }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
        .confirmationDialog("Supprimer « \(deletingSeries?.title ?? "") » ?",
                            isPresented: Binding(get: { deletingSeries != nil }, set: { if !$0 { deletingSeries = nil } }),
                            titleVisibility: .visible,
                            presenting: deletingSeries) { series in
            Button("Supprimer la série et ses \(series.exercises.count) exercices", role: .destructive) {
                context.delete(series)
                try? context.save()
                Haptics.removed()
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
                Haptics.removed()
            }
        } message: { exercise in
            Text(exercise.isDone ? "Il est marqué fait : son avancement sera perdu." : "Ses questions seront supprimées avec lui.")
        }
    }

    /// La légende des glyphes d'étape, en une ligne discrète sous la liste.
    private var legend: some View {
        HStack(spacing: Layout.block) {
            legendItem(.toDo, "à faire")
            legendItem(.toCorrect(.high), "fait")
            legendItem(.corrected(.correct), "corrigé")
            legendItem(.redo, "à refaire")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.micro)
        .accessibilityHidden(true)
    }

    private func legendItem(_ stage: ExerciseStage, _ label: String) -> some View {
        HStack(spacing: Layout.snug) {
            ExerciseStageMark(stage: stage, size: 14)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Une série terminée — sans rien « à refaire » — se replie en une ligne :
    /// ce qui reste à faire remonte, ce qui est fait ne disparaît pas.
    private func isCollapsed(_ series: ExerciseSeries) -> Bool {
        let collapsedByDefault = series.isComplete && !series.exercises.contains(where: \.redoRequired)
        return collapsedByDefault != toggledSeries.contains(series.id)
    }

    private func toggleCollapsed(_ series: ExerciseSeries) {
        withAnimation(Motion.snappy) {
            if toggledSeries.contains(series.id) {
                toggledSeries.remove(series.id)
            } else {
                toggledSeries.insert(series.id)
            }
        }
        Haptics.soft()
    }

    /// Une série, repliée ou dépliée : **le même en-tête** dans les deux cas.
    ///
    /// La série repliée était une ligne à part, avec son propre dessin, et la
    /// dépliée une carte à barre de progression : deux objets pour une seule
    /// chose. L'en-tête porte maintenant l'avancement (un anneau, ou le sceau
    /// d'une série finie), et toucher l'en-tête plie ou déplie.
    private func seriesCard(_ series: ExerciseSeries) -> some View {
        let collapsed = isCollapsed(series)
        return VStack(alignment: .leading, spacing: 0) {
            seriesHeader(series, collapsed: collapsed)

            if !collapsed {
                seriesBody(series)
                    .padding(.horizontal, Layout.gutter)
                    .padding(.bottom, Layout.block)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }

    private func seriesHeader(_ series: ExerciseSeries, collapsed: Bool) -> some View {
        HStack(spacing: Layout.block) {
            Button {
                toggleCollapsed(series)
            } label: {
                HStack(spacing: Layout.block) {
                    Group {
                        if series.isComplete {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title3)
                                .foregroundStyle(Color.green.accessibleMark)
                        } else {
                            ProgressRing(progress: series.progress,
                                         color: TaskType.exercise.tint,
                                         size: 28,
                                         lineWidth: 4,
                                         showsLabel: false)
                        }
                    }
                    .frame(width: 30)

                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text(series.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(seriesSubtitle(series))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Layout.inline)
                    Text("\(series.doneCount)/\(series.requiredExercises.count)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 180))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(series.title), \(series.doneCount) sur \(series.requiredExercises.count)")
            .accessibilityHint(collapsed ? "Afficher les exercices" : "Replier la série")

            Menu {
                seriesMenuItems(series)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions sur \(series.title)")
        }
        .padding(.leading, Layout.gutter)
        .padding(.trailing, Layout.control)
        .padding(.vertical, Layout.tight)
        .contextMenu { seriesMenuItems(series) }
    }

    @ViewBuilder
    private func seriesBody(_ series: ExerciseSeries) -> some View {
        VStack(alignment: .leading, spacing: Layout.block) {
                Divider()

                if series.exercises.isEmpty {
                    // Une série venue de Moodle connaît son PDF : un tap le lit.
                    if let url = URL(string: series.urlString), !series.urlString.isEmpty {
                        Button {
                            Task { await readPDF(of: series, at: url) }
                        } label: {
                            HStack(spacing: Layout.inline) {
                                if downloadingSeries == series.id { ProgressView() }
                                Label("Lire les exercices dans le PDF", systemImage: "doc.text.magnifyingglass")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(downloadingSeries != nil)
                    }
                    Button {
                        editingSeries = SeriesEditTarget(series: series)
                    } label: {
                        Label("Saisir les exercices à la main", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }

                // Reprendre là où on s'est arrêté : le premier exercice pas
                // fait, sinon le premier à refaire ou à corriger.
                if let resume = ExerciseFlow.resumePoint(in: series.exercises) {
                    Button {
                        workspace = WorkspaceTarget(series: series, start: resume)
                    } label: {
                        HStack(spacing: Layout.control) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(series.exercises.contains(where: \.isDone) ? "Reprendre à \(resume.exerciseNumber)" : "Commencer à \(resume.exerciseNumber)")
                                    .font(.subheadline.weight(.semibold))
                                Text(ExerciseStage(resume).isDone || resume.redoRequired
                                     ? "\(ExerciseStage(resume).label) · exercice par exercice, chrono compris"
                                     : "Exercice par exercice, chrono compris")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Theme.accentInk)
                        .padding(Layout.control)
                        .background(Theme.accent.badgeFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                }

                VStack(spacing: 0) {
                    ForEach(series.sortedExercises) { exercise in
                        ExerciseRow(exercise: exercise,
                                    seconds: ExerciseFlow.seconds(on: exercise.id, sessions: sessions),
                                    isAskingConfidence: askingConfidence.contains(exercise.id),
                                    onToggleDone: { toggleDone(exercise) },
                                    onConfidence: { level in setConfidence(level, on: exercise) },
                                    onOpen: { workspace = WorkspaceTarget(series: series, start: exercise) })
                        .contextMenu {
                            Button { workspace = WorkspaceTarget(series: series, start: exercise) } label: {
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
                            Divider().padding(.leading, Layout.minTouch)
                        }
                    }
                }
        }
    }

    @MainActor
    private func readPDF(of series: ExerciseSeries, at url: URL) async {
        downloadingSeries = series.id
        defer { downloadingSeries = nil }
        do {
            downloadedPDF = DownloadedPDF(url: try await AuthenticatedDownloader.download(url))
        } catch {
            downloadError = "\(error.localizedDescription) Reconnecte-toi à Moodle depuis « Importer du contenu », ou choisis le fichier toi-même."
        }
    }

    private func seriesSubtitle(_ series: ExerciseSeries) -> String {
        var parts = [series.plannedWeek > 0 ? "Semaine \(series.plannedWeek)" : "Sans semaine"]
        if series.exercises.isEmpty { parts.append("exercices à importer") }
        if let due = series.dueDate { parts.append("à rendre le \(DateUtils.shortDay.string(from: due))") }
        if !series.bonusExercises.isEmpty { parts.append("\(series.bonusExercises.count) bonus") }
        let spent = ExerciseFlow.seconds(on: series, sessions: sessions)
        if spent >= 60 { parts.append(DateUtils.hoursLabel(seconds: spent)) }
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
        Divider()
        Button(role: .destructive) { deletingSeries = series } label: {
            Label("Supprimer la série…", systemImage: "trash")
        }
    }

    private func setAll(_ series: ExerciseSeries, done: Bool) {
        for exercise in series.exercises {
            exercise.setDone(done)
        }
        Haptics.success()
        try? context.save()
    }

    /// Cocher demande la sureté sur la ligne ; décocher l'efface. Aucune
    /// sureté n'est posée d'office.
    private func toggleDone(_ exercise: Exercise) {
        let done = !exercise.isDone
        exercise.setDone(done)
        withAnimation(Motion.snappy) {
            if done { askingConfidence.insert(exercise.id) } else { askingConfidence.remove(exercise.id) }
        }
        // Pas de vibration ici : le glyphe d'étape a déjà la sienne.
        try? context.save()
    }

    private func setConfidence(_ level: ConfidenceLevel, on exercise: Exercise) {
        exercise.confidence = level
        if !exercise.isDone {
            exercise.setDone(true)
            exercise.confidence = level
        }
        withAnimation(Motion.snappy) { _ = askingConfidence.remove(exercise.id) }
        Haptics.success()
        try? context.save()
    }
}

/// Ligne d'exercice : son étape, son numéro, ce qu'il demande, et le temps
/// déjà passé dessus.
///
/// L'ancienne ligne montrait trois pastilles de sureté **sur chaque exercice**,
/// fait ou non, plus un compteur de questions dépliable : une liste de douze
/// exercices devenait un mur de trente-six ronds. Il reste un seul glyphe
/// d'étape (`ExerciseStageMark`) qu'un toucher coche, et une ligne qui ouvre
/// l'espace de travail. La sureté est **demandée** juste après avoir coché —
/// jamais inventée.
struct ExerciseRow: View {
    let exercise: Exercise
    var seconds: Int = 0
    var isAskingConfidence = false
    var onToggleDone: () -> Void
    var onConfidence: (ConfidenceLevel) -> Void
    var onOpen: () -> Void

    private var stage: ExerciseStage { ExerciseStage(exercise) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onToggleDone) {
                    ExerciseStageMark(stage: stage)
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(exercise.isDone ? "Marquer \(exercise.displayNumber) à faire" : "Marquer \(exercise.displayNumber) fait")
                .accessibilityValue(stage.label)

                Button(action: onOpen) {
                    HStack(spacing: Layout.control) {
                        VStack(alignment: .leading, spacing: Layout.micro) {
                            HStack(spacing: Layout.snug) {
                                Text(exercise.exerciseNumber)
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .accessibilityLabel(exercise.displayNumber)
                                if exercise.isBonus {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.orange.accessibleMark)
                                        .accessibilityLabel("bonus")
                                }
                            }
                            if let line = summary {
                                MathText(line, font: .caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: Layout.inline)
                        VStack(alignment: .trailing, spacing: Layout.micro) {
                            Text(stage.label)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(stage.tint.accessibleInk)
                            if seconds >= 60 {
                                Text(DateUtils.durationLabel(seconds: seconds))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: Layout.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Ouvre l'exercice : questions, sureté, correction et chrono")
            }

            if isAskingConfidence {
                VStack(alignment: .leading, spacing: Layout.snug) {
                    Text("Sûr·e de ta réponse ?")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ConfidenceChoice(value: exercise.confidence, onChoose: onConfidence)
                }
                .padding(.leading, Layout.minTouch)
                .padding(.bottom, Layout.control)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Le titre, sinon l'énoncé : une ligne qui dit de quoi parle l'exercice.
    private var summary: String? {
        if !exercise.title.isEmpty { return exercise.title }
        if !exercise.statement.isEmpty { return exercise.statement }
        return nil
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

