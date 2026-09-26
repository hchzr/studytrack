import SwiftUI
import SwiftData

/// « Mes cours » : le plan du semestre, une carte par cours.
struct CoursesView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var showingForm = false
    @State private var showingSearch = false
    @State private var showingImport = false
    /// Cours sélectionné dans la barre latérale (iPad).
    @State private var selectedCourseID: UUID?
    /// Cours dont la suppression attend confirmation.
    ///
    /// Supprimer un cours emporte ses vidéos, ses séries, ses évaluations **et ses
    /// sessions de travail** : un semestre de temps enregistré. Un menu contextuel
    /// sans confirmation était une perte de données à un doigt près.
    @State private var courseToDelete: Course?
    /// Cours poussé dans la pile iPhone (capture `-course`, lien profond).
    @State private var pushedCourse: Course?
    /// Import de série lancé depuis l'appui long sur un cours.
    @State private var seriesImportCourse: Course?
    /// Segment à ouvrir sur le cours poussé par un autre onglet.
    @State private var pushedSection: CourseDetailView.Section = .exercises

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var archived: [Course] { courses.sorted { $0.code < $1.code }.filter { !$0.isTracked } }
    private var selectedCourse: Course? { courses.first { $0.id == selectedCourseID } }

    /// Deux volets sur iPad, une colonne ailleurs.
    ///
    /// Décidé par la classe de taille : en Split View ou en Slide Over la fenêtre
    /// redevient compacte et l'écran retombe sur la mise en page iPhone, au lieu
    /// d'écraser deux volets dans une largeur de téléphone.
    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isWide { split } else { column }
        }
        .sheet(isPresented: $showingSearch) { SearchView() }
        .sheet(isPresented: $showingForm) {
            CourseFormView(course: nil, defaultSectionCode: app.settings.sectionCode)
        }
        .sheet(isPresented: $showingImport) {
            ImportSheet(defaultSectionCode: app.settings.sectionCode)
        }
        .confirmationDialog("Supprimer « \(courseToDelete?.displayCode ?? "") » ?",
                            isPresented: Binding(get: { courseToDelete != nil },
                                                 set: { if !$0 { courseToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer le cours et son historique", role: .destructive) {
                if let course = courseToDelete { delete(course) }
                courseToDelete = nil
            }
            Button("Archiver plutôt") {
                courseToDelete?.isTracked = false
                try? context.save()
                courseToDelete = nil
            }
            Button("Annuler", role: .cancel) { courseToDelete = nil }
        } message: {
            Text(deleteMessage)
        }
        .sheet(item: $seriesImportCourse) { course in
            SeriesImportSheet(course: course)
        }
        .task { applyPreviewCourse(); applyRoute() }
        .onChange(of: app.router.courseRoute) { _, _ in applyRoute() }
        // Les cours arrivent parfois après la première passe : `@Query` rend une
        // liste vide, puis la remplit. Sans ce second essai, le drapeau de
        // prévisualisation ne trouvait rien et la capture montrait la liste.
        .onChange(of: courses.count) { _, _ in applyPreviewCourse() }
    }

    /// Un cours demandé par un autre onglet : sélectionné (iPad) ou poussé (iPhone).
    private func applyRoute() {
        guard let route = app.router.courseRoute,
              let match = courses.first(where: { $0.id == route.id }) else { return }
        app.router.courseRoute = nil
        pushedSection = route.section
        selectedCourseID = match.id
        if !isWide {
            pushedCourse = nil
            Task { @MainActor in pushedCourse = match }
        }
    }

    /// `-course CS-250` présélectionne un cours : `xcrun simctl` ne sait pas taper
    /// dans la liste, c'est le seul moyen de capturer le volet de détail.
    private func applyPreviewCourse() {
        #if DEBUG
        guard selectedCourseID == nil,
              let code = PreviewLaunch.string(PreviewLaunch.courseFlag),
              let match = courses.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame })
        else { return }
        selectedCourseID = match.id
        if !isWide { pushedCourse = match }
        #endif
    }

    private var deleteMessage: String {
        guard let course = courseToDelete else { return "" }
        let hours = DateUtils.hoursLabel(seconds: WorkloadEngine.studySeconds(for: course))
        return "Théorie, séries, évaluations et \(hours) de sessions enregistrées seront effacées. Archiver garde tout, hors de la vue."
    }

    private func delete(_ course: Course) {
        for exam in course.exams { app.notifications.cancelExam(id: exam.id) }
        if selectedCourseID == course.id { selectedCourseID = nil }
        context.delete(course)
        try? context.save()
        Haptics.warning()
    }

    // MARK: iPad — maître / détail

    /// La liste des cours à gauche, le cours choisi à droite.
    ///
    /// « Mes cours » est le seul écran à deux niveaux de l'app : en colonne unique,
    /// passer d'un cours à l'autre obligeait à revenir en arrière à chaque fois.
    private var split: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                if let course = selectedCourse {
                    CourseDetailView(course: course, initialSection: pushedSection)
                        .id("\(course.id)-\(pushedSection.rawValue)")
                } else {
                    semesterOverview
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedCourseID) {
            if courses.isEmpty {
                Text("Aucun cours. Importe ton horaire ou ajoute un cours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !tracked.isEmpty {
                Section("Cours suivis") {
                    ForEach(tracked) { course in
                        CourseSidebarRow(course: course)
                            .tag(course.id)
                            .contextMenu {
                                Button {
                                    course.isTracked = false
                                    try? context.save()
                                } label: {
                                    Label("Archiver", systemImage: "archivebox")
                                }
                                Button(role: .destructive) {
                                    courseToDelete = course
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            if !archived.isEmpty {
                Section("Archivés") {
                    ForEach(archived) { course in
                        CourseSidebarRow(course: course)
                            .tag(course.id)
                            .swipeActions {
                                Button("Réactiver") {
                                    course.isTracked = true
                                    try? context.save()
                                    Haptics.tap()
                                }
                                .tint(Theme.accent)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Mes cours")
        .toolbar { toolbarItems }
    }

    /// Le volet de droite au repos : le récapitulatif du semestre, qui n'a plus sa
    /// place en pleine largeur une fois la liste détachée.
    private var semesterOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                summary
                Text("Choisis un cours dans la liste pour voir sa théorie, ses exercices, sa progression et son agenda.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Layout.screenPadding)
            .adaptiveColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Mes cours")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: iPhone — une colonne

    private var column: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    if courses.isEmpty {
                        EmptyCard(icon: "books.vertical",
                                  title: "Aucun cours",
                                  message: "Importe ton horaire EPFL (.ics) pour créer tes cours automatiquement, ou ajoute-les un par un.",
                                  actionTitle: "Importer mon horaire") {
                            showingImport = true
                        }
                        Button {
                            showingForm = true
                        } label: {
                            Label("Ajouter un cours à la main", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        summary
                        trackedSection
                        if !archived.isEmpty { archivedSection }
                    }
                }
                .padding(Layout.screenPadding)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mes cours")
            .toolbar { toolbarItems }
            .navigationDestination(item: $pushedCourse) { course in
                CourseDetailView(course: course, initialSection: pushedSection)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { ProfileButton() }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingImport = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Importer")
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: Layout.block) {
                Button {
                    showingSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Rechercher")
                Button {
                    showingForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Ajouter un cours")
            }
        }
    }

    /// Le semestre affiché : celui des cours suivis, ou le plus proche.
    private var term: AcademicTerm? {
        AcademicTerm.resolve(from: courses.compactMap(\.term))
    }

    private var summary: some View {
        // Le coin de la carte disait « Non renseignée » — la **section**, alors
        // que le titre annonce le semestre. On y met ce que le titre promet.
        Card(title: term?.displayName ?? "Semestre", icon: "graduationcap.fill",
             trailing: term?.statusLabel) {
            VStack(alignment: .leading, spacing: Layout.block) {
                if let term {
                    LabeledProgress(title: "Avancement du semestre",
                                    progress: term.timeProgress,
                                    color: Theme.accent,
                                    countLabel: term.hasEnded ? "terminé" : "\(term.weeksRemaining) sem. restantes")
                }
                // Trois chiffres en une ligne : trois tuiles occupaient la moitié
                // de l'écran avant le premier cours.
                Text(summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var summaryLine: String {
        let credits = tracked.reduce(0) { $0 + Int($1.credits) }
        let framed = DateUtils.hoursLabel(hours: tracked.reduce(0) { $0 + WorkloadEngine.framedWeeklyHours(for: $1) })
        return "\(tracked.count) cours · \(credits) ECTS · \(framed) encadrées par semaine"
    }

    private var trackedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Cours suivis", trailing: "\(tracked.count)")
            ForEach(tracked) { course in
                NavigationLink {
                    CourseDetailView(course: course)
                } label: {
                    CourseCardRow(course: course)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    // Les gestes fréquents d'abord : s'y mettre, ajouter la série
                    // de la semaine. Archiver et supprimer ensuite.
                    Button {
                        app.router.startFocus(courseID: course.id, courseCode: course.code,
                                              taskType: .exercise, label: "\(course.displayCode) · Exercices")
                    } label: {
                        Label("Démarrer un chrono", systemImage: "play.fill")
                    }
                    Button {
                        seriesImportCourse = course
                    } label: {
                        Label("Importer une série (PDF)", systemImage: "doc.badge.plus")
                    }
                    Divider()
                    Button {
                        course.isTracked = false
                        try? context.save()
                    } label: {
                        Label("Archiver", systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        courseToDelete = course
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Archivés", trailing: "\(archived.count)")
            ForEach(archived) { course in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: course.colorHex).opacity(0.5))
                        .frame(width: 4, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(course.displayCode).font(.subheadline.weight(.medium))
                        Text(course.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Réactiver") {
                        course.isTracked = true
                        try? context.save()
                        Haptics.tap()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

/// Ligne de la barre latérale iPad : code, nom, anneau de progression.
///
/// Volontairement plus dense que `CourseCardRow` : dans un volet permanent, une
/// liste qu'on balaie des yeux bat une pile de cartes.
struct CourseSidebarRow: View {
    let course: Course

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        return HStack(spacing: Layout.block) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: course.colorHex))
                .frame(width: 4, height: 34)

            VStack(alignment: .leading, spacing: Layout.micro) {
                Text(course.displayCode).font(.subheadline.weight(.semibold))
                Text(course.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Layout.inline)

            ProgressRing(progress: progress.overallPercent,
                         color: Color(hex: course.colorHex),
                         size: 38,
                         lineWidth: 4)
        }
        .padding(.vertical, 2)
    }
}

/// Carte d'un cours : identité, avancement global, et **ce qu'il reste cette
/// semaine** — la seule information qui appelle une action depuis la liste.
///
/// Les trois pourcentages (théorie / exos / corrections) ont quitté la carte :
/// trois chiffres colorés par cours, c'est douze chiffres à balayer pour choisir
/// où aller. Ils vivent dans la fiche, onglet Progression.
struct CourseCardRow: View {
    let course: Course

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        let week = course.currentWeek
        let remainingTheory = ProgressEngine.remainingVideos(for: course, week: week)
        let remainingExercises = ProgressEngine.remainingExercises(for: course, week: week)
        let redo = course.allExercises.filter(\.redoRequired).count
        return Card {
            VStack(alignment: .leading, spacing: Layout.block) {
                HStack(alignment: .center, spacing: Layout.block) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: course.colorHex))
                        .frame(width: 5, height: 44)

                    VStack(alignment: .leading, spacing: Layout.tight) {
                        HStack(spacing: Layout.snug) {
                            Text(course.displayCode).font(.subheadline.weight(.bold))
                            if course.displayCode != course.code {
                                Text(course.code).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(course.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: Layout.snug) {
                            Pill(text: "\(Int(course.credits)) ECTS", color: Color(hex: course.colorHex))
                            if let exam = course.nextExam, exam.daysUntil <= 21 {
                                Pill(text: "\(exam.kind.label) \(DateUtils.countdownLabel(to: exam.date))",
                                     color: exam.kind.color, icon: exam.kind.icon)
                            }
                        }
                    }

                    Spacer(minLength: Layout.inline)

                    ProgressRing(progress: progress.overallPercent,
                                 color: Color(hex: course.colorHex),
                                 size: 52,
                                 lineWidth: 6)
                }

                Divider()

                // Une phrase, pas un tableau : « cette semaine, il reste… ».
                HStack(spacing: Layout.snug) {
                    Image(systemName: weekIcon(theory: remainingTheory.count, exercises: remainingExercises.count, redo: redo))
                        .font(.caption)
                        .foregroundStyle(weekTint(theory: remainingTheory.count, exercises: remainingExercises.count, redo: redo).accessibleMark)
                    Text(weekSentence(theory: remainingTheory, exercises: remainingExercises.count, redo: redo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func weekSentence(theory: [TheoryItem], exercises: Int, redo: Int) -> String {
        guard course.isTermRunning else { return "Semestre en pause" }
        var parts: [String] = []
        if !theory.isEmpty {
            let minutes = theory.reduce(0) { $0 + $1.durationMinutes }
            parts.append("\(theory.count) théorie" + (minutes > 0 ? " (\(DateUtils.durationLabel(seconds: minutes * 60)))" : ""))
        }
        if exercises > 0 { parts.append("\(exercises) exo\(exercises > 1 ? "s" : "")") }
        if redo > 0 { parts.append("\(redo) à refaire") }
        if parts.isEmpty { return "À jour pour la semaine \(course.currentWeek)" }
        return "Reste cette semaine : " + parts.joined(separator: " · ")
    }

    private func weekIcon(theory: Int, exercises: Int, redo: Int) -> String {
        if redo > 0 { return "arrow.counterclockwise" }
        if theory + exercises == 0 { return "checkmark.circle.fill" }
        return "list.bullet"
    }

    private func weekTint(theory: Int, exercises: Int, redo: Int) -> Color {
        if redo > 0 { return .red }
        if theory + exercises == 0 { return .green }
        return .secondary
    }
}
