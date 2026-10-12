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

    @Environment(MacTimer.self) private var timer
    @State private var seriesID: UUID?

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
                list(series, course: course)
                    .frame(width: 250)
                Rectangle().fill(Carnet.rule).frame(width: 1)
                VStack(spacing: 0) {
                    document(series)
                    if let exercise {
                        Rectangle().fill(Carnet.rule).frame(height: 1)
                        ExerciseDrawer(exercise: exercise, desk: desk, tint: Carnet.tint(course.colorHex))
                    }
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
            case .failed(let message)?:
                VStack(spacing: 12) {
                    nativeStatement
                    HStack {
                        Text(message).font(.caption).foregroundStyle(Carnet.inkSecondary)
                        Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
                    }
                    .padding(.bottom, 12)
                }
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

/// Sous le PDF : les questions, la correction, Claude.
private struct ExerciseDrawer: View {
    @Bindable var exercise: Exercise
    var desk: StudyDesk
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            if exercise.hasSubQuestions {
                ScrollView {
                    SubQuestionChecklist(exercise: exercise, tint: tint)
                }
                .frame(maxWidth: 420, maxHeight: 150)
            }
            VStack(alignment: .leading, spacing: 10) {
                ExerciseQuickMark(exercise: exercise)
                Toggle("À refaire", isOn: $exercise.redoRequired).toggleStyle(.checkbox)
            }
            .frame(maxWidth: 300)
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    desk.ask(ClaudeTutor.QuickAction.hint.prompt)
                } label: {
                    Label("Un indice", systemImage: "lightbulb")
                }
                .buttonStyle(.ink)
                Button {
                    desk.ask(ClaudeTutor.QuickAction.check.prompt)
                } label: {
                    Label("Vérifier ma copie", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.paper)
                .help("Montre ta copie à Claude")
            }
        }
        .padding(16)
        .background(Carnet.ground)
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
