import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

/// Import d'une série depuis un PDF : lecture, puis **relecture éditable**.
///
/// La détection n'est jamais parfaite — les polycopiés varient, et un PDF scanné
/// ne contient aucun texte. Tout ce qui est proposé se corrige donc ici, avant
/// que rien ne soit créé : le cours, le numéro de série, la semaine, et chaque
/// exercice (numéro, intitulé, bonus). Un numéro mal lu ne reste plus faux pour
/// toujours.
struct SeriesImportSheet: View {
    /// Cours d'où l'import est lancé. `nil` depuis l'accueil : le PDF le désigne
    /// souvent lui-même, sinon l'écran le demande — il ne choisit jamais seul.
    let course: Course?
    /// Fichier déjà fourni — par l'extension de partage, par exemple.
    var initialFileURL: URL?
    /// Texte déjà fourni (page web, mail).
    var initialText: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var selectedCourseID: UUID?
    @State private var courseWasDetected = false
    @State private var phase: Phase = .empty
    @State private var sourceName = ""
    @State private var drafts: [SeriesDraft] = []
    /// Ce que la lecture locale a trouvé, pour pouvoir y revenir.
    @State private var localResult: [DetectedSeries] = []
    @State private var aiResult: [DetectedSeries]?
    @State private var preferredSeries: Int?
    @State private var aiInput = ""
    @State private var ai: AIState = .idle
    @State private var analysisTask: Task<Void, Never>?
    /// L'étudiant·e a modifié la liste : un résultat d'IA arrivé ensuite est
    /// proposé, jamais imposé par-dessus ses corrections.
    @State private var hasEdited = false
    @State private var showingPicker = false
    @State private var showingPaste = false
    @State private var pastedText = ""

    private enum Phase: Equatable {
        case empty
        case reading
        case review
        case noText
        case failed(String)
    }

    private enum AIState: Equatable {
        case idle
        case unavailable
        case running
        case applied(String)
        /// Le modèle a répondu après une correction manuelle : on propose.
        case pending(String)
        case failed(String)
    }

    private var trackedCourses: [Course] { courses.filter(\.isTracked) }
    private var selectedCourse: Course? { courses.first { $0.id == selectedCourseID } }

    private var chosenCount: Int {
        drafts.reduce(0) { $0 + $1.exercises.filter(\.isIncluded).count }
    }

    var body: some View {
        NavigationStack {
            List {
                sourceSection
                switch phase {
                case .empty:
                    EmptyView()
                case .reading:
                    Section {
                        HStack(spacing: Layout.control) {
                            ProgressView()
                            Text("Lecture du PDF…").foregroundStyle(.secondary)
                        }
                    }
                case .noText:
                    Section {
                        Label("Aucun texte lisible", systemImage: "doc.text.magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                    } footer: {
                        Text("C'est le cas des documents scannés : ils contiennent une image, pas du texte. Ajoute les exercices à la main ci-dessous ou depuis l'onglet Exercices.")
                    }
                    addSeriesSection
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.orange.accessibleInk)
                    }
                case .review:
                    courseSection
                    analysisSection
                    ForEach($drafts) { $draft in
                        seriesSection($draft)
                    }
                    addSeriesSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Importer une série")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        analysisTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosenCount > 0 ? "Créer (\(chosenCount))" : "Créer") { create() }
                        .fontWeight(.semibold)
                        .disabled(chosenCount == 0 || selectedCourse == nil)
                }
            }
            .fileImporter(isPresented: $showingPicker,
                          allowedContentTypes: [.pdf],
                          allowsMultipleSelection: true) { result in
                handle(result)
            }
            .sheet(isPresented: $showingPaste) { pasteSheet }
            .task {
                if selectedCourseID == nil { selectedCourseID = course?.id }
                guard phase == .empty else { return }
                if let initialFileURL {
                    read([initialFileURL])
                } else if let initialText, !initialText.isEmpty {
                    analyze(text: initialText)
                }
            }
            .onDisappear { analysisTask?.cancel() }
        }
    }

    // MARK: Source

    @ViewBuilder
    private var sourceSection: some View {
        if phase == .empty || phase == .reading || !sourceName.isEmpty || phase == .noText {
            Section {
                if phase == .empty {
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Choisir un PDF", systemImage: "doc.badge.plus")
                    }
                    Button {
                        pastedText = ""
                        showingPaste = true
                    } label: {
                        Label("Coller le texte d'une série", systemImage: "doc.on.clipboard")
                    }
                } else {
                    HStack(spacing: Layout.control) {
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(Theme.accentInk)
                        Text(sourceName.isEmpty ? "Document" : sourceName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Layout.inline)
                        if phase != .reading {
                            Button("Changer") { showingPicker = true }
                                .font(.subheadline)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } footer: {
                if phase == .empty {
                    Text("Les exercices sont détectés automatiquement. Tu vérifies et corriges la liste avant que quoi que ce soit ne soit créé.")
                }
            }
        }
    }

    // MARK: Cours

    private var courseSection: some View {
        Section {
            Picker("Cours", selection: $selectedCourseID) {
                if selectedCourseID == nil {
                    Text("Choisir…").tag(UUID?.none)
                }
                ForEach(trackedCourses) { course in
                    Text("\(course.displayCode) · \(course.name)").tag(Optional(course.id))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedCourseID) { _, _ in courseWasDetected = false }
        } footer: {
            if selectedCourse == nil {
                Text("Choisis le cours auquel ajouter cette série.")
                    .foregroundStyle(Color.orange.accessibleInk)
            } else if courseWasDetected {
                Text("Cours reconnu dans le document.")
            }
        }
    }

    // MARK: Analyse

    @ViewBuilder
    private var analysisSection: some View {
        switch ai {
        case .idle:
            EmptyView()
        case .unavailable:
            Section {
                statusRow(icon: "text.magnifyingglass", tint: .secondary,
                          title: "Lecture locale",
                          detail: "L'analyse IA est désactivée (Profil › Import intelligent).")
            }
        case .running:
            Section {
                HStack(spacing: Layout.control) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text("Vérification par l'IA…").font(.subheadline.weight(.semibold))
                        Text("Tu peux déjà relire la liste.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Layout.inline)
                    Button("Arrêter", role: .destructive) { cancelAnalysis() }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                }
            }
        case .applied(let detail):
            Section {
                statusRow(icon: "checkmark.seal.fill", tint: .green, title: "Vérifié par l'IA", detail: detail)
                Button("Revenir à la lecture locale") {
                    apply(localResult)
                    ai = .idle
                    Haptics.tap()
                }
                .font(.subheadline)
            }
        case .pending(let detail):
            Section {
                statusRow(icon: "sparkles", tint: Theme.accent, title: "L'IA propose une autre lecture", detail: detail)
                Button("Utiliser la lecture de l'IA") {
                    if let aiResult { apply(aiResult) }
                    ai = .applied(detail)
                    Haptics.success()
                }
                .font(.subheadline)
            }
        case .failed(let message):
            Section {
                statusRow(icon: "exclamationmark.triangle.fill", tint: .orange,
                          title: "IA indisponible — lecture locale", detail: message)
                Button("Réessayer") { runAI() }
                    .font(.subheadline)
            }
        }
    }

    private func statusRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Layout.control) {
            Image(systemName: icon)
                .foregroundStyle(tint.accessibleMark)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(title).font(.subheadline.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Séries

    private func seriesSection(_ draft: Binding<SeriesDraft>) -> some View {
        let existing = selectedCourse?.series.first { $0.seriesNumber == draft.wrappedValue.number }
        let maxWeek = max(selectedCourse?.term?.totalWeeks ?? 14, draft.wrappedValue.plannedWeek)
        return Section {
            Stepper(value: draft.number.edited(by: markEdited), in: 1...60) {
                LabeledContent("Série", value: "\(draft.wrappedValue.number)")
            }
            TextField("Titre de la série (facultatif)", text: draft.title.edited(by: markEdited))
            Stepper(value: draft.plannedWeek.edited(by: markEdited), in: 1...maxWeek) {
                LabeledContent("Semaine prévue", value: "\(draft.wrappedValue.plannedWeek)")
            }

            ForEach(draft.exercises) { $exercise in
                ExerciseDraftRow(exercise: $exercise.edited(by: markEdited),
                                 seriesNumber: draft.wrappedValue.number,
                                 alreadyThere: existing?.exercises.contains {
                                     $0.exerciseNumber == "\(draft.wrappedValue.number).\(exercise.minor)"
                                 } ?? false)
            }
            .onDelete { offsets in
                draft.wrappedValue.exercises.remove(atOffsets: offsets)
                markEdited()
            }

            Button {
                draft.wrappedValue.addExercise()
                markEdited()
                Haptics.tap()
            } label: {
                Label("Ajouter un exercice", systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text("Série \(draft.wrappedValue.number)")
                Spacer()
                Text("\(draft.wrappedValue.exercises.filter(\.isIncluded).count) exercice\(draft.wrappedValue.exercises.filter(\.isIncluded).count > 1 ? "s" : "")")
            }
        } footer: {
            if existing != nil {
                Text("Cette série existe déjà : les exercices présents seront mis à jour, les autres ajoutés.")
            } else if draft.wrappedValue.exercises.isEmpty {
                Text("Aucun exercice reconnu. Ajoute-les à la main.")
            }
        }
    }

    @ViewBuilder
    private var addSeriesSection: some View {
        if phase == .review || phase == .noText {
            Section {
                Button {
                    let next = (drafts.map(\.number).max() ?? preferredSeries.map { $0 - 1 } ?? 0) + 1
                    var draft = SeriesDraft(number: next, title: "", plannedWeek: defaultWeek(for: next), exercises: [])
                    draft.addExercise()
                    drafts.append(draft)
                    if phase == .noText { phase = .review }
                    markEdited()
                    Haptics.tap()
                } label: {
                    Label(drafts.isEmpty ? "Ajouter une série à la main" : "Ajouter une autre série",
                          systemImage: "plus.rectangle.on.rectangle")
                }
            }
        }
    }

    // MARK: Collage

    /// Le texte d'un énoncé copié depuis Moodle ou un mail : même pipeline que le
    /// PDF, sans fichier.
    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Colle l'énoncé tel quel. Tu relis la liste avant de créer.")
                }
            }
            .navigationTitle("Coller un énoncé")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { showingPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Analyser") {
                        showingPaste = false
                        sourceName = "Texte collé"
                        analyze(text: pastedText)
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: Lecture

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            read(urls)
        }
    }

    private struct ReadResult: Sendable {
        var lines: [PDFLayoutLine]
        var unreadable: Int
    }

    /// Lit un ou plusieurs PDF **hors du fil principal**, en conservant leur mise
    /// en page. Un polycopié de trente pages figeait l'écran le temps de la lecture.
    private func read(_ urls: [URL]) {
        analysisTask?.cancel()
        phase = .reading
        ai = .idle
        sourceName = urls.count == 1
            ? urls[0].lastPathComponent
            : "\(urls.count) documents"
        let filename = urls.first?.lastPathComponent

        analysisTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ReadResult in
                var allLines: [PDFLayoutLine] = []
                var unreadable = 0
                for url in urls {
                    // Un fichier choisi hors du bac à sable doit être ouvert explicitement.
                    let needsScope = url.startAccessingSecurityScopedResource()
                    defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                    guard let document = PDFDocument(url: url) else {
                        unreadable += 1
                        continue
                    }
                    var lines = PDFLayoutExtractor.lines(from: document)
                    // Les numéros de page repartent de zéro à chaque fichier.
                    let offset = (allLines.last?.pageIndex ?? -1) + 1
                    for index in lines.indices { lines[index].pageIndex += offset }
                    allLines.append(contentsOf: lines)
                }
                return ReadResult(lines: allLines, unreadable: unreadable)
            }.value
            guard !Task.isCancelled else { return }

            if result.lines.allSatisfy(\.isEmpty) {
                if result.unreadable == urls.count {
                    phase = .failed(urls.count == 1
                                    ? "Ce fichier n'a pas pu être ouvert comme PDF."
                                    : "Aucun de ces fichiers n'a pu être ouvert comme PDF.")
                } else {
                    drafts = []
                    phase = .noText
                }
                return
            }
            analyze(lines: result.lines, filename: filename)
        }
    }

    private func analyze(text: String) {
        // Texte collé (Moodle, mail) : aucune information de police. L'analyse
        // retombe sur les motifs.
        analyze(lines: text.components(separatedBy: .newlines).map { PDFLayoutLine(text: $0) },
                filename: nil)
    }

    /// Le pipeline commun : ce que le document dit de lui, motifs tout de suite,
    /// IA ensuite, relecture toujours.
    private func analyze(lines: [PDFLayoutLine], filename: String?) {
        guard lines.contains(where: { !$0.isEmpty }) else {
            drafts = []
            phase = .noText
            return
        }

        preferredSeries = SeriesDocumentInference.seriesNumber(lines: lines, filename: filename)?.number
        if course == nil || selectedCourseID == nil,
           let detected = SeriesDocumentInference.course(
               in: lines, filename: filename,
               candidates: trackedCourses.map { .init(id: $0.id, code: $0.code, name: $0.name) }) {
            selectedCourseID = detected
            // Le `onChange` du sélecteur remet l'indicateur à faux : on le pose après.
            Task { @MainActor in courseWasDetected = true }
        }

        let parsed = SeriesLayoutParser.parse(lines, defaultSeries: preferredSeries)
        localResult = parsed
        aiResult = nil
        hasEdited = false
        apply(parsed)
        if drafts.isEmpty, let preferredSeries {
            // Rien de reconnu, mais le numéro est connu : une série vide à remplir.
            drafts = [SeriesDraft(number: preferredSeries, title: "", plannedWeek: defaultWeek(for: preferredSeries), exercises: [])]
        }
        phase = .review
        Haptics.success()

        let hasLayout = lines.contains { $0.fontSize > 0 }
        aiInput = hasLayout
            ? SeriesAIParsing.prepareLayout(lines, seriesHint: preferredSeries)
            : (preferredSeries.map { "[Indice : ce document semble être la série \($0)]\n" } ?? "")
                + SeriesAIParsing.prepare(lines.map(\.text).joined(separator: "\n"))
        if app.settings.aiExtractionEnabled, SeriesAIExtractor.plannedSource(app.settings) != nil {
            runAI()
        } else {
            ai = .unavailable
        }
    }

    /// Demande au modèle de vérifier la lecture locale. Le résultat est fusionné :
    /// les exercices sûrs restent, les repères douteux doivent être confirmés.
    private func runAI() {
        guard !aiInput.isEmpty else { return }
        analysisTask?.cancel()
        ai = .running
        let input = aiInput
        let base = localResult
        let preferred = preferredSeries
        analysisTask = Task {
            do {
                let result = try await SeriesAIExtractor.extract(prepared: input, settings: app.settings)
                guard !Task.isCancelled else { return }
                let merged = SeriesAIParsing.merge(heuristic: base, ai: result.series, preferredSeries: preferred)
                aiResult = merged
                let detail = summary(local: base, merged: merged, source: result.source)
                if hasEdited {
                    ai = merged == base ? .applied(detail) : .pending(detail)
                } else {
                    apply(merged)
                    ai = .applied(detail)
                }
                Haptics.success()
            } catch {
                guard !Task.isCancelled else { return }
                // La lecture locale reste valable : on la garde, et on dit
                // pourquoi le modèle n'a rien ajouté.
                ai = .failed(error.localizedDescription)
                AppLog.record(.warning, AppLog.Category.ai,
                              "Analyse IA sans résultat",
                              detail: error.localizedDescription)
            }
        }
    }

    private func summary(local: [DetectedSeries], merged: [DetectedSeries], source: SeriesExtractionSource) -> String {
        let before = local.reduce(0) { $0 + $1.exercises.count }
        let after = merged.reduce(0) { $0 + $1.exercises.count }
        let titled = merged.reduce(0) { $0 + $1.exercises.filter { !$0.title.isEmpty }.count }
        var parts: [String] = []
        if after > before { parts.append("\(after - before) exercice\(after - before > 1 ? "s" : "") ajouté\(after - before > 1 ? "s" : "")") }
        if after < before { parts.append("\(before - after) repère\(before - after > 1 ? "s" : "") douteux écarté\(before - after > 1 ? "s" : "")") }
        if titled > 0 { parts.append("\(titled) intitulé\(titled > 1 ? "s" : "")") }
        if parts.isEmpty { parts.append("Structure confirmée") }
        return parts.joined(separator: " · ") + " — \(source.label)"
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        ai = .failed("Analyse arrêtée.")
        Haptics.warning()
    }

    private func markEdited() { hasEdited = true }

    // MARK: Brouillons

    private func apply(_ series: [DetectedSeries]) {
        drafts = series.map { detected in
            SeriesDraft(number: detected.number,
                        title: SeriesDocumentInference.seriesTitle(detected.title,
                                                                   courseName: selectedCourse?.name ?? "",
                                                                   courseCode: selectedCourse?.code ?? ""),
                        plannedWeek: defaultWeek(for: detected.number),
                        exercises: detected.exercises.map { ExerciseDraft(detected: $0) })
        }
    }

    /// La semaine où la série est prévue : son numéro, quand il tient dans le
    /// semestre — la série 4 se fait en semaine 4 — sinon la semaine en cours.
    private func defaultWeek(for number: Int) -> Int {
        let total = selectedCourse?.term?.totalWeeks ?? 14
        if (1...total).contains(number) { return number }
        return max(selectedCourse?.currentWeek ?? 1, 1)
    }

    // MARK: Création

    /// Crée les sous-questions d'un exercice, sans jamais dupliquer.
    ///
    /// Un réimport ne doit pas doubler les cases : on complète par étiquette
    /// manquante, et on laisse l'état « fait » de celles qui existent — c'est du
    /// travail de l'étudiant·e, pas de l'import.
    private func attach(_ questions: [DetectedSubQuestion], to exercise: Exercise) {
        guard !questions.isEmpty else { return }
        for (index, question) in questions.enumerated() {
            guard !exercise.subQuestions.contains(where: { $0.label == question.label }) else { continue }
            context.insert(SubQuestion(exercise: exercise,
                                       label: question.label,
                                       text: question.text,
                                       sortOrder: index))
        }
    }

    private func create() {
        guard let course = selectedCourse else { return }
        for draft in drafts {
            let chosen = draft.exercises.filter(\.isIncluded)
            guard !chosen.isEmpty else { continue }

            let target: ExerciseSeries
            if let existing = course.series.first(where: { $0.seriesNumber == draft.number }) {
                target = existing
                let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { existing.title = title }
            } else {
                let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let new = ExerciseSeries(course: course,
                                         seriesNumber: draft.number,
                                         title: title.isEmpty ? "Série \(draft.number)" : title,
                                         plannedWeek: draft.plannedWeek)
                context.insert(new)
                target = new
            }

            var created = Set<String>()
            for exercise in chosen {
                let minor = exercise.minor.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !minor.isEmpty else { continue }
                let number = "\(draft.number).\(minor)"
                guard created.insert(number).inserted else { continue }
                let title = exercise.title.trimmingCharacters(in: .whitespacesAndNewlines)

                // Un exercice déjà présent n'est **pas** dupliqué — mais il est mis
                // à jour : c'est ainsi qu'un réimport corrige un intitulé erroné.
                if let existing = target.exercises.first(where: { $0.exerciseNumber == number }) {
                    if !title.isEmpty {
                        existing.title = title
                    } else if !existing.title.isEmpty, !SeriesPDFParser.looksLikeTitle(existing.title) {
                        existing.title = ""
                    }
                    existing.isBonus = exercise.isBonus
                    attach(exercise.subQuestions, to: existing)
                    continue
                }

                let item = Exercise(series: target,
                                    exerciseNumber: number,
                                    title: title,
                                    isBonus: exercise.isBonus,
                                    sortOrder: target.exercises.count)
                context.insert(item)
                attach(exercise.subQuestions, to: item)
            }
        }
        do {
            try context.save()
            Haptics.success()
            dismiss()
        } catch {
            AppLog.record(.error, AppLog.Category.storage, "Import de série non enregistré",
                          detail: error.localizedDescription)
            phase = .failed("L'enregistrement a échoué : \(error.localizedDescription)")
        }
    }
}

// MARK: - Brouillons éditables

/// Une série telle qu'elle sera créée — modifiable avant création.
struct SeriesDraft: Identifiable, Equatable {
    let id = UUID()
    var number: Int
    var title: String
    var plannedWeek: Int
    var exercises: [ExerciseDraft]

    /// Ajoute la ligne suivante : « 4.3 » après « 4.2 ».
    mutating func addExercise() {
        let next = (exercises.compactMap { Int($0.minor) }.max() ?? 0) + 1
        exercises.append(ExerciseDraft(minor: "\(next)", title: "", isBonus: false))
    }
}

/// Un exercice tel qu'il sera créé. Le numéro est stocké **sans** la série :
/// changer le numéro de série renumérote toute la liste d'un coup.
struct ExerciseDraft: Identifiable, Equatable {
    let id = UUID()
    var minor: String
    var title: String
    var isBonus: Bool
    var isIncluded = true
    var subQuestions: [DetectedSubQuestion] = []

    init(minor: String, title: String, isBonus: Bool) {
        self.minor = minor
        self.title = title
        self.isBonus = isBonus
    }

    init(detected: DetectedExercise) {
        minor = detected.number.split(separator: ".").last.map(String.init) ?? detected.number
        title = detected.title
        isBonus = detected.isBonus
        subQuestions = detected.subQuestions
    }
}

/// Une ligne : inclure, numéro, intitulé, bonus.
private struct ExerciseDraftRow: View {
    @Binding var exercise: ExerciseDraft
    let seriesNumber: Int
    let alreadyThere: Bool

    var body: some View {
        HStack(spacing: Layout.control) {
            Button {
                exercise.isIncluded.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: exercise.isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(exercise.isIncluded ? Theme.accent.accessibleMark : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(exercise.isIncluded ? "Exclure l'exercice" : "Inclure l'exercice")

            HStack(spacing: 0) {
                Text("\(seriesNumber).")
                    .foregroundStyle(.secondary)
                TextField("n°", text: $exercise.minor)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(width: 34)
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Numéro de l'exercice")

            VStack(alignment: .leading, spacing: Layout.micro) {
                TextField("Sans titre", text: $exercise.title)
                    .font(.subheadline)
                if alreadyThere || !exercise.subQuestions.isEmpty {
                    HStack(spacing: Layout.snug) {
                        if alreadyThere { Text("déjà présent") }
                        if !exercise.subQuestions.isEmpty {
                            Text("\(exercise.subQuestions.count) questions")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                exercise.isBonus.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: exercise.isBonus ? "star.fill" : "star")
                    .foregroundStyle(exercise.isBonus ? Color.orange.accessibleMark : Color.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Bonus")
            .accessibilityValue(exercise.isBonus ? "facultatif" : "obligatoire")
        }
        .opacity(exercise.isIncluded ? 1 : 0.45)
    }
}

private extension Binding {
    /// La même liaison, qui signale chaque écriture — pour savoir que la liste a
    /// été corrigée à la main.
    func edited(by mark: @escaping () -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; mark() })
    }
}
