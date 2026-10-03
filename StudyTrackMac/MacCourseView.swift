import SwiftUI
import SwiftData

/// Un cours : ses séries et sa théorie, semaine par semaine. Cocher ici,
/// c'est cocher sur l'iPhone.
struct MacCourseView: View {
    @Bindable var course: Course

    enum Tab: String, CaseIterable, Identifiable {
        case series = "Séries", theory = "Théorie"
        var id: String { rawValue }
    }

    @Environment(MacTimer.self) private var timer
    @Environment(\.modelContext) private var context
    @State private var tab: Tab = .series
    @State private var onlyCurrentWeek = false

    private var tint: Color { Color(hex: course.colorHex) }

    var body: some View {
        List {
            Section {
                header
            }
            switch tab {
            case .series: seriesSections
            case .theory: theorySections
            }
        }
        .listStyle(.inset)
        .navigationTitle(course.displayCode)
        .navigationSubtitle(course.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Affichage", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItem {
                Toggle(isOn: $onlyCurrentWeek) {
                    Label("Semaine \(course.currentWeek)", systemImage: "calendar")
                }
                .help("Seulement la semaine en cours")
            }
            ToolbarItem {
                Button {
                    timer.courseID = course.id
                    timer.taskType = tab == .series ? .exercise : .theory
                    if timer.phase == .idle { timer.start() }
                } label: {
                    Label("Chrono", systemImage: timer.phase == .idle ? "play.circle" : "timer")
                }
                .help("Démarrer le chrono sur ce cours")
                .disabled(timer.phase != .idle && timer.courseID == course.id)
            }
        }
        .onChange(of: tab) { _, _ in try? context.save() }
    }

    private var header: some View {
        let progress = ProgressEngine.progress(for: course)
        let late = ProgressEngine.lateCount(for: course)
        return HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name).font(.system(size: 26, weight: .regular, design: .serif))
                Text([course.credits > 0 ? "\(course.credits.formatted()) ECTS" : nil,
                      course.currentWeek > 0 ? "semaine \(course.currentWeek)" : nil,
                      late > 0 ? "\(late) en retard" : "à jour"].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(late > 0 ? .red : .secondary)
            }
            Spacer()
            stat("Théorie", progress.watchedCount, progress.videoCount)
            stat("Exercices", progress.doneCount, progress.exerciseCount)
            Text("\(Int((progress.completion * 100).rounded())) %")
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 8)
    }

    private func stat(_ title: String, _ done: Int, _ total: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(done)/\(total)").font(.title3.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Séries

    @ViewBuilder
    private var seriesSections: some View {
        let series = course.sortedSeries.filter { !onlyCurrentWeek || $0.plannedWeek == course.currentWeek }
        if series.isEmpty {
            Text(onlyCurrentWeek ? "Pas de série cette semaine." : "Aucune série.").foregroundStyle(.secondary)
        }
        ForEach(series) { item in
            Section {
                ForEach(item.sortedExercises) { exercise in
                    ExerciseMacRow(exercise: exercise, tint: tint)
                }
            } header: {
                HStack(spacing: 10) {
                    Text(item.title.isEmpty ? "Série \(item.seriesNumber)" : item.title)
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(.primary)
                    if item.plannedWeek > 0 {
                        Text("S\(item.plannedWeek)").foregroundStyle(.secondary)
                    }
                    if let due = item.dueDate {
                        Text("à rendre le \(DateUtils.shortDay.string(from: due))").foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("\(item.doneCount)/\(item.requiredExercises.count)").monospacedDigit().foregroundStyle(.secondary)
                    if let url = web(item.urlString) {
                        Link(destination: url) { Label("Énoncé", systemImage: "doc.richtext") }
                    }
                    if let url = web(item.solutionURLString) {
                        if let date = item.solutionsAt, date > Date() {
                            Label("Corrigé le \(DateUtils.shortDay.string(from: date))", systemImage: "lock")
                                .foregroundStyle(.secondary)
                        } else {
                            Link(destination: url) { Label("Corrigé", systemImage: "checkmark.seal") }
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 10)
            }
        }
    }

    // MARK: Théorie

    @ViewBuilder
    private var theorySections: some View {
        let items = course.sortedTheoryItems.filter { !onlyCurrentWeek || $0.plannedWeek == course.currentWeek }
        let weeks = Dictionary(grouping: items, by: \.plannedWeek)
        if items.isEmpty {
            Text(onlyCurrentWeek ? "Pas de théorie cette semaine." : "Aucune théorie.").foregroundStyle(.secondary)
        }
        ForEach(weeks.keys.sorted { lhs, rhs in
            // Les éléments sans semaine (documents) en dernier.
            (lhs == 0 ? Int.max : lhs) < (rhs == 0 ? Int.max : rhs)
        }, id: \.self) { week in
            Section {
                ForEach(weeks[week] ?? []) { item in
                    TheoryMacRow(item: item, tint: tint)
                }
            } header: {
                Text(week > 0 ? "Semaine \(week)" : "Documents")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.primary)
                    .padding(.top, 10)
            }
        }
    }

    private func web(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
}

private struct ExerciseMacRow: View {
    @Bindable var exercise: Exercise
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { exercise.isDone }, set: { exercise.setDone($0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            Text(exercise.exerciseNumber).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 36, alignment: .leading)
            Text(exercise.title.isEmpty ? exercise.displayNumber : exercise.title)
                .strikethrough(exercise.isDone && exercise.correctness == .correct, color: .secondary)
            if exercise.isBonus {
                Text("bonus").font(.caption).foregroundStyle(.secondary)
            }
            if exercise.redoRequired {
                Text("à refaire").font(.caption.weight(.semibold)).foregroundStyle(.red)
            }
            Spacer()
            Menu {
                ForEach(Correctness.allCases) { result in
                    Button(result.label) { exercise.correct(result) }
                }
                if exercise.correctness != nil {
                    Divider()
                    Button("Retirer la correction") { exercise.clearCorrection() }
                }
            } label: {
                if let correctness = exercise.correctness {
                    Label(correctness.shortLabel, systemImage: "circle.fill")
                        .foregroundStyle(correctness.color)
                } else {
                    Text(exercise.isDone ? "À corriger" : "Correction")
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.callout)
        }
        .padding(.vertical, 2)
    }
}

private struct TheoryMacRow: View {
    @Bindable var item: TheoryItem
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { item.isWatched },
                                 set: { item.watchedAt = $0 ? (item.watchedAt ?? Date()) : nil })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            Image(systemName: item.kind.icon).foregroundStyle(tint).frame(width: 18)
            if !item.number.isEmpty {
                Text(item.number).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(item.title.isEmpty ? item.kind.label : item.title).lineLimit(2)
            Spacer()
            if item.durationSeconds > 0 {
                Text(item.durationLabel).foregroundStyle(.secondary).monospacedDigit()
            }
            if let url = URL(string: item.urlString), url.scheme?.hasPrefix("http") == true {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .help("Ouvrir")
            }
        }
        .padding(.vertical, 2)
    }
}
