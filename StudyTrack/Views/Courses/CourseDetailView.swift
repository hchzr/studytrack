import SwiftUI
import SwiftData

/// Détail d'un cours : la semaine en cours, les examens, puis Séries | Théorie.
///
/// Deux segments, pas quatre. L'ancien onglet « Agenda » mêlait évaluations,
/// annales, sessions, séances et tâches : les examens ont leur page (le bloc
/// « Examens » de l'en-tête), les séances et sessions sont dans l'Agenda,
/// filtrables par cours. La progression se lit dans l'en-tête — la semaine en
/// cours, Théorie et Séries — et s'ouvre en détail d'un tap.
struct CourseDetailView: View {
    let course: Course
    /// Section ouverte à l'arrivée. La recherche y mène directement.
    var initialSection: Section = .exercises

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Section = .exercises
    @State private var showingProgress = false
    @State private var showingExams = false
    @State private var hasAppliedInitialSection = false
    @State private var showingEditor = false
    @State private var showingDelete = false
    @State private var showingSeriesImport = false
    @State private var showingAddTheory = false
    @State private var showingAddExam = false

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case exercises, theory
        /// Pages poussées, pas des segments.
        case exams, progress
        var id: String { rawValue }
        static var segments: [Section] { [.exercises, .theory] }
        var title: String {
            switch self {
            case .theory: return "Théorie"
            case .exercises: return "Séries"
            case .progress: return "Progression"
            case .exams: return "Examens"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                header
                examsRow

                Picker("Section", selection: $tab) {
                    ForEach(Section.segments) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .theory:
                    TheoryTabView(course: course)
                default:
                    ExercisesTabView(course: course)
                }
            }
            .padding(Layout.screenPadding)
            .adaptiveColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(course.name.isEmpty ? course.displayCode : course.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showingEditor) { CourseFormView(course: course) }
        .sheet(isPresented: $showingSeriesImport) { SeriesImportSheet(course: course) }
        .sheet(isPresented: $showingAddTheory) { AddVideoSheet(course: course) }
        .sheet(isPresented: $showingAddExam) { ExamFormSheet(course: course) }
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
        .navigationDestination(isPresented: $showingExams) {
            CourseExamsView(course: course)
        }
        .onAppear {
            if !hasAppliedInitialSection {
                hasAppliedInitialSection = true
                switch initialSection {
                case .progress: showingProgress = true
                case .exams: showingExams = true
                default: tab = initialSection
                }
            }
            #if DEBUG
            if let raw = PreviewLaunch.string(PreviewLaunch.courseTabFlag),
               let section = Section(rawValue: raw) {
                switch section {
                case .progress: showingProgress = true
                case .exams: showingExams = true
                default: tab = section
                }
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

    // MARK: Barre du haut

    /// Deux boutons, deux rôles : « + » ajoute **du contenu** au cours, « ⋯ »
    /// agit **sur le cours** lui-même. Tout était auparavant dans un seul menu,
    /// et importer une série se cherchait dans l'onglet Séries.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    app.router.openContentImport(courseID: course.id)
                } label: {
                    Label("Importer depuis Moodle, Courseware…", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    showingSeriesImport = true
                } label: {
                    Label("Importer une série (PDF)", systemImage: "doc.badge.plus")
                }
                Divider()
                Button {
                    showingAddTheory = true
                } label: {
                    Label("Ajouter de la théorie", systemImage: TaskType.theory.icon)
                }
                Button {
                    showingAddExam = true
                } label: {
                    Label("Ajouter une évaluation", systemImage: "graduationcap")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Ajouter au cours")

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
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Actions sur le cours")
        }
    }

    private func deleteCourse() {
        for exam in course.exams { app.notifications.cancelExam(id: exam.id) }
        context.delete(course)
        try? context.save()
        Haptics.removed()
        dismiss()
    }

    // MARK: En-tête

    private var header: some View {
        let tint = Color(hex: course.colorHex)
        let week = ProgressEngine.weekProgress(for: course, week: course.currentWeek)
        return VStack(alignment: .leading, spacing: Layout.cardGap) {
            HStack(alignment: .top, spacing: Layout.block) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: 6, height: 44)
                VStack(alignment: .leading, spacing: Layout.tight) {
                    HStack(spacing: Layout.snug) {
                        Text(course.displayCode).font(.headline)
                        if course.displayCode != course.code {
                            Text(course.code).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Layout.inline)
                Button {
                    app.router.startFocus(courseID: course.id, courseCode: course.code,
                                          taskType: tab == .theory ? .theory : .exercise,
                                          label: "\(course.displayCode) · \(tab == .theory ? "Théorie" : "Séries")")
                } label: {
                    Label("Chrono", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Démarrer un chrono sur \(course.displayCode)")
            }

            Divider()

            // La semaine en cours, sur les deux axes qui comptent. Toucher ouvre
            // la progression semaine par semaine.
            Button {
                showingProgress = true
            } label: {
                VStack(alignment: .leading, spacing: Layout.block) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(course.isTermRunning ? "Semaine \(course.currentWeek)" : "Hors semestre")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if week.isComplete {
                            Label("à jour", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.green.accessibleInk)
                        }
                        Spacer()
                        Text("Progression")
                            .font(.subheadline)
                            .foregroundStyle(Theme.accentInk)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    if week.hasItems {
                        WeekAxisRow(title: "Théorie", done: week.watchedCount, total: week.videoCount,
                                    tint: TaskType.theory.tint)
                        WeekAxisRow(title: seriesTitle(week), done: week.doneCount, total: week.exerciseCount,
                                    tint: TaskType.exercise.tint,
                                    trailing: week.doneCount > 0 ? "\(week.correctedCount) corrigé\(week.correctedCount > 1 ? "s" : "")" : nil)
                    } else {
                        Text(course.theoryItems.isEmpty && course.series.isEmpty
                             ? "Aucun contenu : importe la théorie et les séries depuis Moodle, Courseware ou Botafogo."
                             : "Rien de planifié cette semaine.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if course.theoryItems.isEmpty && course.series.isEmpty {
                Button {
                    app.router.openContentImport(courseID: course.id)
                } label: {
                    Label("Importer le contenu du cours", systemImage: "square.and.arrow.down.on.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Layout.gutter)
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }

    private func seriesTitle(_ week: WeeklyProgress) -> String {
        switch week.seriesNumbers.count {
        case 0: return "Séries"
        case 1: return "Série \(week.seriesNumbers[0])"
        default: return "Séries " + week.seriesNumbers.map(String.init).joined(separator: ", ")
        }
    }

    private var metaLine: String {
        // Espaces insécables : « 2 h » ne se coupe pas en fin de ligne.
        var parts = ["\(fmt(course.credits))\u{00A0}ECTS"]
        parts.append(course.hasLectures
                     ? "\(fmt(course.weeklyLectureHours))\u{00A0}h de cours · \(fmt(course.weeklyExerciseHours))\u{00A0}h d'exercices"
                     : "\(fmt(course.weeklyExerciseHours))\u{00A0}h d'exercices, sans amphi")
        return parts.joined(separator: " · ")
    }

    // MARK: Examens

    /// Une ligne : la prochaine évaluation et son compte à rebours, ou une
    /// invitation à les saisir. Ouvre la page Examens (évaluations, annales, plan).
    private var examsRow: some View {
        let next = course.nextExam
        return Button {
            showingExams = true
        } label: {
            HStack(spacing: Layout.block) {
                Image(systemName: next?.kind.icon ?? "graduationcap")
                    .font(.subheadline)
                    .foregroundStyle((next?.kind.color ?? Theme.accent).accessibleMark)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Layout.micro) {
                    Text(next.map { $0.title.isEmpty ? $0.kind.label : $0.title } ?? "Examens")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(examsDetail(next))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Layout.inline)
                if let next {
                    Text(DateUtils.countdownLabel(to: next.date))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(next.kind.color.accessibleInk)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Layout.gutter)
            .padding(.vertical, Layout.block)
            .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func examsDetail(_ next: Exam?) -> String {
        guard let next else {
            return course.exams.isEmpty ? "Ajoute le midterm et l'examen final" : "Évaluations passées et annales"
        }
        var parts = [DateUtils.fullDayLabel(next.date)]
        if !course.pastExams.isEmpty { parts.append("\(course.pastExams.count) annale\(course.pastExams.count > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// « Théorie  3/5  ▬▬▬▬░░ », une ligne par axe de la semaine.
struct WeekAxisRow: View {
    var title: String
    var done: Int
    var total: Int
    var tint: Color
    var trailing: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.inline) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Layout.inline)
                Text(total == 0 ? "—" : "\(done)/\(total)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(total > 0 && done == total ? Color.green.accessibleInk : .primary)
                    .contentTransition(.numericText())
            }
            ProgressBar(progress: CourseProgress.ratio(done, total), color: tint, height: 6)
                .opacity(total == 0 ? 0.35 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(done) sur \(total)")
    }
}
