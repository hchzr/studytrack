import SwiftUI
import SwiftData

/// Détail d'un cours : exercices, théorie, agenda — la progression en page à part.
///
/// Quatre segments se disputaient un téléphone, et on arrivait sur « Théorie »
/// alors que le suivi des exercices est la colonne vertébrale de l'app. Les
/// exercices s'ouvrent donc en premier ; la progression, qui se consulte et ne
/// se manipule pas, passe derrière un lien de l'en-tête.
struct CourseDetailView: View {
    let course: Course
    /// Onglet ouvert à l'arrivée. La recherche y mène directement : arriver sur
    /// « Théorie » après avoir cherché un exercice ferait rater ce qu'on venait
    /// chercher.
    var initialSection: Section = .exercises

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Section = .exercises
    @State private var showingProgress = false
    @State private var hasAppliedInitialSection = false
    @State private var showingEditor = false
    @State private var showingDelete = false

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case exercises, theory, agenda
        /// N'est plus un segment : ouvre la page « Progression ».
        case progress
        var id: String { rawValue }
        static var segments: [Section] { [.exercises, .theory, .agenda] }
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
                    ForEach(Section.segments) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .theory:
                    TheoryTabView(course: course)
                case .exercises, .progress:
                    ExercisesTabView(course: course)
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
        .navigationDestination(isPresented: $showingProgress) {
            ScrollView {
                ProgressTabView(course: course)
                    .padding(Layout.screenPadding)
                    .adaptiveColumn()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Progression · \(course.displayCode)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if !hasAppliedInitialSection {
                hasAppliedInitialSection = true
                if initialSection == .progress {
                    tab = .exercises
                    showingProgress = true
                } else {
                    tab = initialSection
                }
            }
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
                        // Les heures encadrées en une ligne de texte : trois
                        // pastilles se coupaient en deux lignes (« 3 h / amphi »).
                        HStack(spacing: Layout.snug) {
                            Pill(text: "\(Int(course.credits)) ECTS", color: Color(hex: course.colorHex))
                            Text(course.hasLectures
                                 ? "\(fmt(course.weeklyLectureHours)) h cours · \(fmt(course.weeklyExerciseHours)) h exos"
                                 : "\(fmt(course.weeklyExerciseHours)) h exos · sans amphi")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
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

                // Les deux gestes qu'on fait depuis un cours sans en changer
                // l'onglet : voir où on en est, et s'y mettre.
                HStack(spacing: Layout.control) {
                    Button {
                        showingProgress = true
                    } label: {
                        Label("Progression", systemImage: "chart.line.uptrend.xyaxis")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        app.router.startFocus(courseID: course.id, courseCode: course.code,
                                              taskType: tab == .theory ? .theory : .exercise,
                                              label: "\(course.displayCode) · \(tab == .theory ? "Théorie" : "Exercices")")
                    } label: {
                        Label("Chrono", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.subheadline.weight(.medium))
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
