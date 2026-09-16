import SwiftUI
import SwiftData

/// Détail d'un cours : théorie, exercices, progression, agenda.
struct CourseDetailView: View {
    let course: Course

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Section = .theory
    @State private var showingEditor = false
    @State private var showingDelete = false

    enum Section: String, CaseIterable, Identifiable {
        case theory, exercises, progress, agenda
        var id: String { rawValue }
        var title: String {
            switch self {
            case .theory: return "Théorie"
            case .exercises: return "Exercices"
            case .progress: return "Progression"
            case .agenda: return "Agenda"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                header

                Picker("Section", selection: $tab) {
                    ForEach(Section.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .theory:
                    TheoryTabView(course: course)
                case .exercises:
                    ExercisesTabView(course: course)
                case .progress:
                    ProgressTabView(course: course)
                case .agenda:
                    CourseAgendaTabView(course: course)
                }
            }
            .padding(Layout.screenPadding)
            .adaptiveColumn()
        }
        .background(Color(.systemGroupedBackground))
        // Le titre porte le **nom** du cours. Le code est un identifiant
        // administratif, pas ce que l'étudiant·e a sous les yeux dans son horaire.
        .navigationTitle(course.name.isEmpty ? course.displayCode : course.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Modifier le cours", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        app.router.startFocus(courseID: course.id,
                                              courseCode: course.code,
                                              taskType: .exercise,
                                              label: "\(course.displayCode) · Exercices")
                    } label: {
                        Label("Démarrer un chrono", systemImage: "timer")
                    }
                    if let url = URL(string: course.moodleURLString), !course.moodleURLString.isEmpty {
                        Link(destination: url) {
                            Label("Ouvrir la page du cours", systemImage: "safari")
                        }
                    }
                    Divider()
                    Button {
                        course.isTracked.toggle()
                        try? context.save()
                        Haptics.tap()
                    } label: {
                        Label(course.isTracked ? "Archiver" : "Réactiver",
                              systemImage: course.isTracked ? "archivebox" : "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        showingDelete = true
                    } label: {
                        Label("Supprimer le cours…", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Actions sur le cours")
            }
        }
        .sheet(isPresented: $showingEditor) {
            CourseFormView(course: course)
        }
        .onAppear {
            #if DEBUG
            // `-courseTab agenda` : le segment est à un tap, que `simctl` ne sait pas faire.
            if let raw = PreviewLaunch.string(PreviewLaunch.courseTabFlag),
               let section = Section(rawValue: raw) {
                tab = section
            }
            #endif
        }
        .confirmationDialog("Supprimer « \(course.displayCode) » ?",
                            isPresented: $showingDelete,
                            titleVisibility: .visible) {
            Button("Supprimer le cours et son historique", role: .destructive) { deleteCourse() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Théorie, séries, évaluations et \(DateUtils.hoursLabel(seconds: WorkloadEngine.studySeconds(for: course))) de sessions seront effacées. « Archiver » garde tout, hors de la vue.")
        }
    }

    private func deleteCourse() {
        for exam in course.exams { app.notifications.cancelExam(id: exam.id) }
        context.delete(course)
        try? context.save()
        Haptics.warning()
        dismiss()
    }

    private var header: some View {
        let progress = ProgressEngine.progress(for: course)
        let week = course.currentWeek
        let theory = ProgressEngine.remainingVideos(for: course, week: week)
        let exercises = ProgressEngine.remainingExercises(for: course, week: week)
        return Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(alignment: .center, spacing: Layout.block) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: course.colorHex))
                        .frame(width: 6, height: 52)

                    VStack(alignment: .leading, spacing: Layout.tight) {
                        HStack(spacing: Layout.snug) {
                            Text(course.displayCode).font(.headline)
                            if course.displayCode != course.code {
                                Text(course.code).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: Layout.snug) {
                            Pill(text: "\(Int(course.credits)) ECTS", color: Color(hex: course.colorHex))
                            if course.hasLectures {
                                Pill(text: "\(fmt(course.weeklyLectureHours)) h amphi", color: .blue, icon: "building.columns.fill")
                            } else {
                                Pill(text: "sans amphi", color: .secondary)
                            }
                            Pill(text: "\(fmt(course.weeklyExerciseHours)) h exos", color: .green, icon: "checklist")
                        }
                        if let term = course.term {
                            Text(term.statusLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: Layout.inline)

                    ProgressRing(progress: progress.overallPercent,
                                 color: Color(hex: course.colorHex),
                                 size: 60,
                                 lineWidth: 7)
                }

                // Une ligne qui répond à « qu'est-ce qu'il me reste cette semaine ? »,
                // avant tout tableau. La charge EPFL est dans l'onglet Progression.
                if course.isTermRunning {
                    HStack(spacing: Layout.snug) {
                        Image(systemName: theory.isEmpty && exercises.isEmpty ? "checkmark.circle.fill" : "list.bullet")
                            .font(.caption)
                            .foregroundStyle((theory.isEmpty && exercises.isEmpty ? Color.green : Color.secondary).accessibleMark)
                        Text(weekSentence(theory: theory, exercises: exercises))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func weekSentence(theory: [TheoryItem], exercises: [Exercise]) -> String {
        var parts: [String] = []
        if !theory.isEmpty {
            let minutes = theory.reduce(0) { $0 + $1.durationMinutes }
            parts.append("\(theory.count) élément\(theory.count > 1 ? "s" : "") de théorie" + (minutes > 0 ? " (\(DateUtils.durationLabel(seconds: minutes * 60)))" : ""))
        }
        if !exercises.isEmpty { parts.append("\(exercises.count) exercice\(exercises.count > 1 ? "s" : "")") }
        if parts.isEmpty { return "Tout est fait pour la semaine \(course.currentWeek)." }
        return "Reste cette semaine : " + parts.joined(separator: " et ") + "."
    }

    private func workloadStat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(tint.accessibleInk).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
