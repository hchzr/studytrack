import SwiftUI
import SwiftData
import PDFKit

/// La série, dans le bureau : la liste des exercices (choisir l'un, c'est y
/// passer le chrono), le PDF de l'énoncé ouvert à l'exercice, et sous la main
/// les questions à cocher, la correction, « Demander à Claude ».
struct ExercisePane: View {
    let course: Course?
    var desk: StudyDesk
    var openWeb: (URL, String) -> Void
    /// Côte à côte avec le cours : sans la liste des exercices (le menu du
    /// titre suffit), et une colonne plus étroite.
    var compact = false

    @Environment(MacTimer.self) private var timer
    @Query private var allCourses: [Course]
    @State private var seriesID: UUID?

    /// Ta copie de la série, dans tes notes (GoodNotes → Google Drive…).
    private func copy(_ series: ExerciseSeries) -> NotesLibrary.Document? {
        guard let course else { return nil }
        return NotesStore.shared.copy(for: series, course: course, among: allCourses)
    }

    private var allSeries: [ExerciseSeries] { course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? [] }

    private var series: ExerciseSeries? {
        if let seriesID, let found = allSeries.first(where: { $0.id == seriesID }) { return found }
        if let current = course?.allExercises.first(where: { $0.id == timer.targetID })?.series { return current }
        let week = course?.currentWeek ?? 0
        return allSeries.first { $0.plannedWeek >= week && !$0.isComplete } ?? allSeries.last
    }

    private var exercise: Exercise? {
        series?.exercises.first { $0.id == timer.targetID }
    }

    var body: some View {
        if let course, let series {
            HStack(spacing: 0) {
                if !compact {
                    list(series, course: course)
                        .frame(width: 230)
                    Rectangle().fill(Carnet.rule).frame(width: 1)
                }
                if hasDocument(series) {
                    // L'énoncé en PDF au centre, l'exercice toujours à côté : ses
                    // questions, où on en est, les gestes.
                    VStack(spacing: 0) {
                        if copy(series) != nil {
                            Picker("Afficher", selection: Binding(get: { desk.showingCopy }, set: { desk.showingCopy = $0 })) {
                                Text("Énoncé").tag(false)
                                Text("Ma copie").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .padding(8)
                        }
                        document(series)
                    }
                    .task { await NotesStore.shared.refresh() }
                    if let exercise {
                        Rectangle().fill(Carnet.rule).frame(width: 1)
                        ScrollView {
                            ExerciseSheet(exercise: exercise, series: series, desk: desk, tint: Carnet.tint(course.colorHex),
                                          showStatement: false, copy: copy(series), next: { next in select(next, in: course) })
                                .padding(18)
                        }
                        .frame(width: compact ? 300 : 360)
                        .background(Carnet.ground)
                    }
                } else if let exercise {
                    ScrollView {
                        ExerciseSheet(exercise: exercise, series: series, desk: desk, tint: Carnet.tint(course.colorHex),
                                      showStatement: true, copy: copy(series), next: { next in select(next, in: course) })
                            .padding(32)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView("Choisis un exercice", systemImage: "list.number")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Pas de série", systemImage: "doc.text")
            } description: {
                Text(course == nil ? "Choisis un cours." : "Rien d'importé pour ce cours.")
            }
        }
    }

    // MARK: Liste

    private func list(_ series: ExerciseSeries, course: Course) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(course.displayCode, color: Carnet.tint(course.colorHex))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 2)
            Menu {
                ForEach(allSeries) { item in
                    Button(name(item)) { seriesID = item.id }
                }
            } label: {
                Text(name(series)).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .help("Série")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(series.sortedExercises) { item in
                        ExerciseListRow(exercise: item, isCurrent: item.id == timer.targetID, tint: Carnet.tint(course.colorHex)) {
                            select(item, in: course)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            HStack {
                Text("\(series.doneCount)/\(series.requiredExercises.count) faits")
                Spacer()
                if let due = series.dueDate {
                    Text("à rendre \(DateUtils.countdownLabel(to: due))").foregroundStyle(due < Date() ? Carnet.wrong : Carnet.inkSecondary)
                }
            }
            .font(.caption)
            .foregroundStyle(Carnet.inkSecondary)
            .padding(14)
        }
    }

    private func name(_ series: ExerciseSeries) -> String {
        series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title
    }

    /// Choisir un exercice, c'est y passer le chrono : le temps est compté à
    /// l'exercice, sans rien couper.
    private func select(_ exercise: Exercise, in course: Course) {
        seriesID = exercise.series?.id
        timer.retarget(courseID: course.id, taskType: .exercise, targetID: exercise.id)
    }

    // MARK: Document

    private func address(_ series: ExerciseSeries) -> String {
        if desk.showingCopy, let copy = copy(series), let url = NotesStore.shared.url(copy) { return url.absoluteString }
        return exercise?.statementURLString.isEmpty == false ? exercise!.statementURLString : series.urlString
    }

    private func hasDocument(_ series: ExerciseSeries) -> Bool {
        let address = address(series)
        guard !address.isEmpty else { return false }
        if case .failed? = desk.document(address) { return exercise?.statement.isEmpty != false }
        return true
    }

    @ViewBuilder
    private func document(_ series: ExerciseSeries) -> some View {
        let address = exercise?.statementURLString.isEmpty == false ? exercise!.statementURLString : series.urlString
        if address.isEmpty {
            nativeStatement
        } else {
            switch desk.document(address) {
            case .ready(let file)?:
                PDFPane(url: file, search: searchTerms)
            case .needsLogin?:
                loginPrompt(address)
            case .failed?:
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark").font(.largeTitle).foregroundStyle(Carnet.inkTertiary)
                    Text("Énoncé introuvable").foregroundStyle(Carnet.inkSecondary)
                    Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading?, nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { desk.loadPDF(address) }
            }
        }
    }

    /// Les mots qui retrouvent l'exercice dans le PDF : « Exercice 2 »,
    /// « Ex-03-02 »…
    private var searchTerms: [String] {
        guard let exercise else { return [] }
        let number = exercise.exerciseNumber
        let last = number.split(separator: ".").last.map(String.init) ?? number
        var terms = ["Exercice \(number)", "Exercice \(last)", "Exercise \(last)", "Ex. \(last)"]
        if let series = exercise.series, let n = Int(last) {
            terms.insert(String(format: "Ex-%02d-%02d", series.seriesNumber, n), at: 0)
            terms.append(String(format: "Exercice %d.%d", series.seriesNumber, n))
        }
        return terms
    }

    /// L'énoncé lu par l'import (Botafogo, ou extrait du PDF), quand il n'y a
    /// pas de PDF à montrer.
    @ViewBuilder
    private var nativeStatement: some View {
        if let exercise, !exercise.statement.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(exercise.displayNumber).font(Carnet.serif(26)).foregroundStyle(Carnet.ink)
                    MacMathText(exercise.statement, size: 15).foregroundStyle(Carnet.ink).textSelection(.enabled)
                    if !exercise.hint.isEmpty {
                        DisclosureGroup("Indication") {
                            MacMathText(exercise.hint, size: 14).foregroundStyle(Carnet.ink).textSelection(.enabled)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Choisis un exercice", systemImage: "list.number")
        }
    }

    private func loginPrompt(_ address: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key").font(.largeTitle).foregroundStyle(Carnet.inkSecondary)
            Text("Connecte-toi à Moodle").font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
            HStack {
                Button("Se connecter") { desk.signIn = .moodle }.buttonStyle(.ink)
                Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExerciseListRow: View {
    @Bindable var exercise: Exercise
    let isCurrent: Bool
    let tint: Color
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: exercise.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(exercise.isDone ? tint : Carnet.inkTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(exercise.displayNumber).foregroundStyle(Carnet.ink)
                    if let label = exercise.subQuestionLabel {
                        Text(label).font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
                if exercise.redoRequired {
                    Text("à refaire").font(.caption2.weight(.semibold)).foregroundStyle(Carnet.wrong)
                } else if let correctness = exercise.correctness {
                    VerdictTag(correctness: correctness)
                }
                if isCurrent { Image(systemName: "timer").font(.caption).foregroundStyle(tint) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isCurrent ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(exercise.isDone ? "Marquer à faire" : "Marquer comme fait") { exercise.setDone(!exercise.isDone) }
            Toggle("À refaire", isOn: $exercise.redoRequired)
        }
    }
}

/// L'exercice, en feuille : l'énoncé (quand il n'y a pas de PDF), les
/// questions à cocher juste dessous, où on en est (fait, juste / moyen / faux,
/// à refaire), le corrigé quand il est publié, et les gestes (indice, faire
/// vérifier sa copie, exercice suivant).
struct ExerciseSheet: View {
    @Bindable var exercise: Exercise
    let series: ExerciseSeries
    var desk: StudyDesk
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
                Toggle("À refaire", isOn: $exercise.redoRequired).toggleStyle(.checkbox)
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
                    Button { desk.ask(ClaudeTutor.QuickAction.hint.prompt) } label: { Label("Un indice", systemImage: "lightbulb") }
                        .buttonStyle(.ink)
                    Button {
                        if let copy, let data = NotesStore.shared.attachmentData(copy) {
                            desk.pendingAttachment = .init(kind: .pdf, data: data, name: copy.title)
                        }
                        desk.ask(ClaudeTutor.QuickAction.check.prompt, attachSeries: false)
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

/// Un PDF natif (PDFKit), ouvert à l'exercice cherché.
struct PDFPane: NSViewRepresentable {
    let url: URL
    var search: [String] = []

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(Carnet.ground)
        view.document = PDFDocument(url: url)
        context.coordinator.url = url
        jump(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.url != url {
            view.document = PDFDocument(url: url)
            context.coordinator.url = url
            context.coordinator.searched = []
        }
        jump(view, coordinator: context.coordinator)
    }

    private func jump(_ view: PDFView, coordinator: Coordinator) {
        guard search != coordinator.searched, let document = view.document else { return }
        coordinator.searched = search
        for term in search {
            if let found = document.findString(term, withOptions: [.caseInsensitive]).first {
                view.go(to: found)
                view.setCurrentSelection(found, animate: true)
                return
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
        var searched: [String] = []
    }
}
