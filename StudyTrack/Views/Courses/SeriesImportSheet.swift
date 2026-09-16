import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

/// Import d'une série depuis un PDF : détection automatique, puis **relecture**.
///
/// La détection n'est jamais parfaite — les polycopiés varient, et un PDF scanné
/// ne contient aucun texte. L'écran de relecture n'est donc pas une précaution
/// décorative : c'est ce qui rend l'import utilisable sur des documents réels.
struct SeriesImportSheet: View {
    let course: Course

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var detected: [DetectedSeries] = []
    /// Ce que les motifs ont lu, gardé pour pouvoir y revenir.
    @State private var heuristic: [DetectedSeries] = []
    @State private var extractedText = ""
    @State private var source: SeriesExtractionSource = .heuristic
    @State private var isAnalyzing = false
    @State private var aiMessage: String?
    @State private var analysisTask: Task<Void, Never>?
    @State private var excluded: Set<String> = []
    @State private var bonusOverride: [String: Bool] = [:]
    @State private var showingPicker = false
    @State private var showingPaste = false
    @State private var pastedText = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case reading
        case noText
        case failed(String)
    }

    /// Les numéros se répètent d'une série à l'autre : la clé inclut la série.
    private func key(_ series: DetectedSeries, _ exercise: DetectedExercise) -> String {
        "\(series.number)-\(exercise.number)"
    }

    private var chosenCount: Int {
        detected.reduce(0) { total, series in
            total + series.exercises.filter { !excluded.contains(key(series, $0)) }.count
        }
    }

    /// Combien d'exercices retenus sont marqués facultatifs.
    ///
    /// Affiché dans le récapitulatif : c'est le seul moyen de s'apercevoir qu'un
    /// marquage « bonus » est là — l'inverse d'un interrupteur invisible.
    /// Combien d'exercices retenus existent déjà dans la série — ils seront mis à
    /// jour plutôt que dupliqués.
    private var existingCount: Int {
        detected.reduce(0) { total, series in
            guard let target = course.series.first(where: { $0.seriesNumber == series.number }) else {
                return total
            }
            return total + series.exercises.filter { exercise in
                !excluded.contains(key(series, exercise))
                    && target.exercises.contains { $0.exerciseNumber == exercise.number }
            }.count
        }
    }

    private var chosenBonusCount: Int {
        detected.reduce(0) { total, series in
            total + series.exercises.filter {
                !excluded.contains(key(series, $0))
                    && (bonusOverride[key(series, $0)] ?? $0.isBonus)
            }.count
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    picker
                    switch status {
                    case .idle:
                        EmptyView()
                    case .reading:
                        Card { ProgressView("Lecture du PDF…") }
                    case .noText:
                        noTextCard
                    case .failed(let message):
                        Card {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Color.orange.accessibleInk)
                        }
                    }
                    if status == .idle, !extractedText.isEmpty { analysisCard }
                    ForEach(detected) { series in
                        seriesCard(series)
                    }
                    if !detected.isEmpty { summary }
                }
                .padding(Layout.screenPadding)
                .adaptiveColumn()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Importer une série")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { create() }
                        .disabled(chosenCount == 0)
                }
            }
            .fileImporter(isPresented: $showingPicker,
                          allowedContentTypes: [.pdf],
                          allowsMultipleSelection: true) { result in
                handle(result)
            }
            .sheet(isPresented: $showingPaste) {
                pasteSheet
            }
        }
    }

    // MARK: Sections

    private var picker: some View {
        Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                Button {
                    showingPicker = true
                } label: {
                    Label("Choisir un ou plusieurs PDF", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    pastedText = ""
                    showingPaste = true
                } label: {
                    Label("Coller le texte d'une série", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("StudyTrack lit le texte et repère les numéros d'exercices ; l'IA complète automatiquement ce que les motifs ont raté. Rien n'est créé avant que tu aies validé la liste ci-dessous.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// L'état de l'analyse : quel moteur a parlé, et le moyen de changer d'avis.
    private var analysisCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(spacing: Layout.control) {
                    Image(systemName: isAnalyzing ? "sparkles" : source.icon)
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text(isAnalyzing ? "Analyse par l'IA en cours…" : "Structure lue par \(source.label)")
                            .font(.subheadline.weight(.semibold))
                        if let aiMessage {
                            Text(aiMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: Layout.inline)
                    if isAnalyzing { ProgressView() }
                }

                HStack(spacing: Layout.control) {
                    if !isAnalyzing, source == .heuristic, SeriesAIExtractor.plannedSource(app.settings) != nil {
                        Button {
                            runAI()
                        } label: {
                            Label("Analyser avec l'IA", systemImage: "sparkles")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                    }
                    if !isAnalyzing, source != .heuristic {
                        Button {
                            detected = heuristic
                            source = .heuristic
                            aiMessage = "Retour à la lecture par motifs."
                            Haptics.tap()
                        } label: {
                            Label("Revenir aux motifs", systemImage: "arrow.uturn.backward")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                    }
                    if isAnalyzing {
                        Button("Annuler") {
                            analysisTask?.cancel()
                            isAnalyzing = false
                            aiMessage = "Analyse annulée : la lecture par motifs est conservée."
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if source == .heuristic, SeriesAIExtractor.plannedSource(app.settings) == nil {
                    Text(SeriesAIExtractor.onDeviceUnavailabilityReason.map { "\($0) Un service distant se configure dans Profil › Import intelligent." }
                         ?? "Active l'analyse IA dans Profil › Import intelligent.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var noTextCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                Label("Aucun texte lisible dans ce PDF", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline)
                Text("C'est le cas des documents **scannés** : ils contiennent une image, pas du texte. Tu peux ajouter les exercices à la main depuis l'onglet Exercices — StudyTrack n'inventera jamais un numéro qu'il n'a pas lu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func seriesCard(_ series: DetectedSeries) -> some View {
        Card(title: series.title.isEmpty ? "Série \(series.number)" : "Série \(series.number) · \(series.title)",
             icon: "list.number",
             trailing: "\(series.exercises.count)") {
            VStack(alignment: .leading, spacing: 0) {
                if series.exercises.isEmpty {
                    // Mise en page non reconnue : on le dit, et on indique le
                    // recours, plutôt que d'afficher une carte vide.
                    Text("Aucun exercice reconnu dans cette série. Ajoute-les à la main depuis l'onglet Exercices : StudyTrack n'invente jamais un numéro qu'il n'a pas lu.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)
                } else {
                    // Les deux colonnes sont nommées : sans en-tête, une pastille
                    // « Bonus » à droite ne dit pas ce qu'elle fait.
                    HStack(spacing: Layout.control) {
                        Text("À créer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Layout.inline)
                        Text("Facultatif")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                }
                ForEach(series.exercises) { exercise in
                    let id = key(series, exercise)
                    let isOff = excluded.contains(id)
                    let isBonus = bonusOverride[id] ?? exercise.isBonus
                    let alreadyThere = course.series
                        .first { $0.seriesNumber == series.number }?
                        .exercises.contains { $0.exerciseNumber == exercise.number } ?? false
                    HStack(spacing: Layout.control) {
                        Button {
                            if isOff { excluded.remove(id) } else { excluded.insert(id) }
                            Haptics.tap()
                        } label: {
                            Image(systemName: isOff ? "circle" : "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(isOff ? Color.secondary : Theme.accent.accessibleMark)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(isOff ? "Inclure" : "Exclure") l'exercice \(exercise.number)")

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Layout.snug) {
                                Text("Exercice \(exercise.number)")
                                    .font(.subheadline)
                                    .foregroundStyle(isOff ? .secondary : .primary)
                                if alreadyThere {
                                    Pill(text: "déjà présent", color: .secondary)
                                }
                            }
                            if !exercise.title.isEmpty {
                                Text(exercise.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: Layout.inline)

                        // Une pastille **libellée** plutôt qu'un interrupteur sans
                        // étiquette : dans une liste dense, un `Toggle` réduit à son
                        // curseur ne dit pas ce qu'il change, et se confond avec les
                        // autres. Le mot « Bonus » reste visible dans les deux états.
                        Button {
                            bonusOverride[id] = !isBonus
                            Haptics.tap()
                        } label: {
                            HStack(spacing: Layout.tight) {
                                Image(systemName: isBonus ? "star.fill" : "star")
                                Text("Bonus")
                            }
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(isBonus ? Color.orange.badgeFill : Color.secondary.opacity(0.12),
                                        in: Capsule())
                            .foregroundStyle(isBonus ? Color.orange.badgeInk : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Exercice \(exercise.number)")
                        .accessibilityValue(isBonus ? "facultatif" : "obligatoire")
                        .accessibilityHint("Touche pour changer")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: Layout.snug) {
                Label("\(chosenCount) exercice\(chosenCount > 1 ? "s" : "") dans \(detected.count) série\(detected.count > 1 ? "s" : "")",
                      systemImage: "checkmark.seal")
                    .font(.subheadline)
                if existingCount > 0 {
                    Label("\(existingCount) déjà présent\(existingCount > 1 ? "s" : "") : intitulé et bonus seront mis à jour",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if chosenBonusCount > 0 {
                    Label("\(chosenBonusCount) marqué\(chosenBonusCount > 1 ? "s" : "") facultatif\(chosenBonusCount > 1 ? "s" : "")",
                          systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange.accessibleInk)
                }
            }
        }
    }

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
                } header: {
                    Text("Texte de la série")
                } footer: {
                    Text("Colle l'énoncé tel quel — « Série 3 », « Exercice 3.1 (bonus) »… Les motifs puis l'IA en déduisent la structure, que tu relis avant de créer.")
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
                        analyze(text: pastedText)
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: Actions

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            status = .failed(error.localizedDescription)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            read(urls)
        }
    }

    /// Lit un ou plusieurs PDF et enchaîne leurs textes : une série par fichier,
    /// ou un polycopié en plusieurs parties, dans le même écran de relecture.
    private func read(_ urls: [URL]) {
        status = .reading
        var texts: [String] = []
        var unreadable = 0
        for url in urls {
            // Un fichier choisi hors du bac à sable doit être ouvert explicitement.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            guard let document = PDFDocument(url: url) else {
                unreadable += 1
                continue
            }
            let text = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(text)
            }
        }
        if texts.isEmpty {
            if unreadable == urls.count {
                status = .failed(urls.count == 1
                                 ? "Ce fichier n'a pas pu être ouvert comme PDF."
                                 : "Aucun de ces fichiers n'a pu être ouvert comme PDF.")
            } else {
                detected = []
                status = .noText
            }
            return
        }
        analyze(text: texts.joined(separator: "\n\n"))
    }

    /// Le pipeline commun : motifs tout de suite, IA ensuite, relecture toujours.
    private func analyze(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            detected = []
            status = .noText
            return
        }

        let parsed = SeriesPDFParser.parse(text)
        heuristic = parsed
        detected = parsed
        extractedText = text
        source = .heuristic
        aiMessage = nil
        excluded = []
        bonusOverride = [:]
        // Un texte lisible mais sans structure reconnue reste analysable par l'IA :
        // c'est précisément le cas qui la justifie.
        status = .idle
        Haptics.success()
        if app.settings.aiExtractionEnabled, SeriesAIExtractor.plannedSource(app.settings) != nil {
            runAI()
        }
    }

    /// Demande au modèle de compléter la lecture par motifs. Le résultat est
    /// fusionné, jamais substitué : rien de lu par les motifs ne disparaît.
    private func runAI() {
        guard !extractedText.isEmpty else { return }
        analysisTask?.cancel()
        isAnalyzing = true
        aiMessage = nil
        let text = extractedText
        let base = heuristic
        analysisTask = Task {
            do {
                let result = try await SeriesAIExtractor.extract(from: text, settings: app.settings)
                guard !Task.isCancelled else { return }
                let merged = SeriesAIParsing.merge(heuristic: base, ai: result.series)
                let added = merged.reduce(0) { $0 + $1.exercises.count } - base.reduce(0) { $0 + $1.exercises.count }
                detected = merged
                source = result.source
                aiMessage = added > 0
                    ? "\(added) exercice\(added > 1 ? "s" : "") de plus que les motifs, et des intitulés. Vérifie avant de créer."
                    : "Rien de plus que les motifs : la structure est confirmée."
                Haptics.success()
            } catch {
                guard !Task.isCancelled else { return }
                aiMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func create() {
        for series in detected {
            let chosen = series.exercises.filter { !excluded.contains(key(series, $0)) }
            guard !chosen.isEmpty else { continue }

            let target: ExerciseSeries
            if let existing = course.series.first(where: { $0.seriesNumber == series.number }) {
                target = existing
            } else {
                let new = ExerciseSeries(course: course,
                                         seriesNumber: series.number,
                                         title: series.title.isEmpty ? "Série \(series.number)" : series.title,
                                         plannedWeek: max(course.currentWeek, 1))
                context.insert(new)
                target = new
            }

            for exercise in chosen {
                let reviewedBonus = bonusOverride[key(series, exercise)] ?? exercise.isBonus

                // Un exercice déjà présent n'est **pas** dupliqué — mais il est mis
                // à jour. Sans ça, réimporter ne corrigeait rien : les titres pris
                // à tort dans l'énoncé par les versions antérieures du parseur
                // restaient pour toujours, faute de pouvoir les réécrire.
                if let existing = target.exercises.first(where: { $0.exerciseNumber == exercise.number }) {
                    if !exercise.title.isEmpty {
                        // La relecture propose un intitulé : il fait foi, puisque
                        // l'étudiant·e vient de le valider à l'écran.
                        existing.title = exercise.title
                    } else if !existing.title.isEmpty,
                              !SeriesPDFParser.looksLikeTitle(existing.title) {
                        // Pas d'intitulé en face, et celui enregistré n'en a pas la
                        // forme : c'était un énoncé. On le retire au lieu de le
                        // laisser passer pour un titre.
                        existing.title = ""
                    }
                    existing.isBonus = reviewedBonus
                    continue
                }

                let item = Exercise(series: target,
                                    exerciseNumber: exercise.number,
                                    title: exercise.title,
                                    isBonus: reviewedBonus,
                                    sortOrder: target.exercises.count)
                context.insert(item)
            }
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
