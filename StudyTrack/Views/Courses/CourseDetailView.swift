import SwiftUI
import SwiftData

/// Un cours, **semaine par semaine**.
///
/// On ouvre un cours pour savoir quoi faire cette semaine : la théorie à voir
/// (vidéo, transparents, section du polycopié, leçon du MOOC — chacune liée),
/// la série et ses exercices jusqu'aux sous-questions, ce qui tombe cette
/// semaine. Les puces S1…S14 changent de semaine ; « Tout le cours » garde les
/// listes complètes (Séries | Théorie) et leurs outils d'édition. L'en-tête,
/// à la couleur du cours, porte un panneau de verre : fait, rythme, prochaine
/// échéance — et mène aux examens, à la progression, aux documents.
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
    @State private var showingDocuments = false
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

    /// `-scrollDown` : `simctl` ne sait pas faire défiler ; l'en-tête est
    /// masqué pour que la capture montre la liste.
    private var debugHidesHeader: Bool {
        #if DEBUG
        return PreviewLaunch.isSet(PreviewLaunch.scrollDownFlag)
        #else
        return false
        #endif
    }

    /// La semaine affichée ; `nil` = « Tout le cours ».
    @State private var shownWeek: Int?
    @State private var hasChosenWeek = false
    @State private var openedExercise: Exercise?
    @State private var openedVideo: TheoryItem?
    @State private var browsing: BrowsedLink?

    private var totalWeeks: Int {
        let planned = course.theoryItems.map(\.plannedWeek) + course.series.map(\.plannedWeek)
        return max(course.term?.totalWeeks ?? 14, planned.max() ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !debugHidesHeader {
                    hero
                }
                VStack(alignment: .leading, spacing: 22) {
                    weekPicker
                    if let week = shownWeek {
                        weekContent(week)
                    } else {
                        allContent
                    }
                }
                .padding(.horizontal, Carnet.screenPadding)
                .padding(.top, debugHidesHeader ? 8 : 18)
                .padding(.bottom, 32)
                .frame(maxWidth: Layout.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Carnet.ground.ignoresSafeArea())
        .navigationTitle(course.displayCode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showingEditor) { CourseFormView(course: course) }
        .sheet(isPresented: $showingSeriesImport) { SeriesImportSheet(course: course) }
        .sheet(isPresented: $showingAddTheory) { AddVideoSheet(course: course) }
        .sheet(isPresented: $showingAddExam) { ExamFormSheet(course: course) }
        .sheet(item: $openedExercise) { exercise in ExerciseSheet(exercise: exercise) }
        .sheet(item: $openedVideo) { video in VideoDetailSheet(video: video) }
        .sheet(item: $browsing) { InAppBrowser(link: $0) }
        .navigationDestination(isPresented: $showingProgress) {
            ScrollView {
                ProgressTabView(course: course)
                    .padding(Layout.screenPadding)
                    .adaptiveColumn()
            }
            .background(Carnet.ground.ignoresSafeArea())
            .navigationTitle("Progression · \(course.displayCode)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationDestination(isPresented: $showingExams) {
            CourseExamsView(course: course)
        }
        .navigationDestination(isPresented: $showingDocuments) {
            CourseDocumentsView(course: course)
        }
        .onAppear {
            if !hasChosenWeek {
                hasChosenWeek = true
                let empty = course.theoryItems.isEmpty && course.series.isEmpty
                shownWeek = (course.isTermRunning && !empty) ? min(max(course.currentWeek, 1), totalWeeks) : nil
            }
            if !hasAppliedInitialSection {
                hasAppliedInitialSection = true
                switch initialSection {
                case .progress: showingProgress = true
                case .exams: showingExams = true
                case .theory: shownWeek = nil; tab = .theory
                default: break
                }
            }
            #if DEBUG
            if let raw = PreviewLaunch.string(PreviewLaunch.courseTabFlag) {
                if raw == "all" { shownWeek = nil }
                if let section = Section(rawValue: raw) {
                    switch section {
                    case .progress: showingProgress = true
                    case .exams: showingExams = true
                    default: shownWeek = nil; tab = section
                    }
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

    // MARK: En-tête

    /// La couleur du cours en bandeau, son nom en serif, et le panneau de verre
    /// qui le chevauche : fait, rythme, prochaine échéance.
    private var hero: some View {
        let tint = Carnet.tint(course.colorHex)
        let progress = ProgressEngine.progress(for: course)
        let late = ProgressEngine.lateCount(for: course)
        let ahead = ProgressEngine.aheadCount(for: course)
        let next = course.nextExam
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text([course.displayCode, CarnetCourseCard.sourceLabel(course)]
                        .compactMap { $0 }.joined(separator: " · ").uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .opacity(0.85)
                Text(course.name.isEmpty ? course.displayCode : course.name)
                    .font(Carnet.serif(.title))
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine)
                    .font(.footnote)
                    .opacity(0.85)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 58)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.ignoresSafeArea(edges: .top))

            HStack(spacing: 0) {
                heroStat(label: "Fait", value: "\(Int((progress.completion * 100).rounded())) %") { showingProgress = true }
                Rectangle().fill(Carnet.rule).frame(width: 1, height: 36)
                heroStat(label: "Rythme", value: late > 0 ? "−\(late)" : (ahead > 0 ? "+\(ahead)" : "à jour"),
                         color: late > 0 ? Carnet.wrong : Carnet.ink) { showingProgress = true }
                Rectangle().fill(Carnet.rule).frame(width: 1, height: 36)
                heroStat(label: next.map { $0.kind.label } ?? "Examens",
                         value: next.map { DateUtils.shortDay.string(from: $0.date) } ?? "—") { showingExams = true }
            }
            .padding(.vertical, 12)
            .carnetGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
            .padding(.horizontal, Carnet.screenPadding)
            .padding(.top, -42)

            if course.theoryItems.isEmpty && course.series.isEmpty {
                Button {
                    app.router.openContentImport(courseID: course.id)
                } label: {
                    Label("Importer le contenu du cours", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.carnetPrimaryWide)
                .padding(.horizontal, Carnet.screenPadding)
                .padding(.top, 16)
            }
        }
    }

    private func heroStat(label: String, value: String, color: Color = Carnet.ink,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label).font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                Text(value)
                    .font(Carnet.serif(.title3))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Semaines

    private var weekPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { withAnimation(Motion.snappy) { shownWeek = nil } } label: {
                        CarnetChip(text: "Tout le cours", isSelected: shownWeek == nil)
                    }
                    .buttonStyle(.plain)
                    ForEach(1...max(totalWeeks, 1), id: \.self) { week in
                        let progress = ProgressEngine.weekProgress(for: course, week: week)
                        Button { withAnimation(Motion.snappy) { shownWeek = week } } label: {
                            weekChip(week, progress: progress)
                        }
                        .buttonStyle(.plain)
                        .id(week)
                        .accessibilityLabel("Semaine \(week)")
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear {
                if let shownWeek { proxy.scrollTo(shownWeek, anchor: .center) }
            }
        }
    }

    private func weekChip(_ week: Int, progress: WeeklyProgress) -> some View {
        let selected = shownWeek == week
        let isCurrent = course.isTermRunning && week == course.currentWeek
        return VStack(spacing: 3) {
            Text("S\(week)")
                .font(.subheadline.weight(selected || isCurrent ? .semibold : .regular))
                .foregroundStyle(selected ? Carnet.ground : (progress.hasItems ? Carnet.ink : Carnet.inkTertiary))
            Circle()
                .fill(progress.isComplete ? Carnet.correct : (progress.hasItems ? (selected ? Carnet.ground : Carnet.inkTertiary) : .clear))
                .frame(width: 4, height: 4)
        }
        .frame(minWidth: 42, minHeight: 40)
        .background(selected ? Carnet.ink : (isCurrent ? Carnet.sheetRaised : Carnet.sheet), in: Capsule())
    }

    // MARK: Une semaine

    @ViewBuilder
    private func weekContent(_ week: Int) -> some View {
        let theory = course.sortedTheoryItems.filter { $0.plannedWeek == week }
        let series = course.sortedSeries.filter { $0.plannedWeek == week }
        let deadlines = course.sortedExams.filter { exam in
            course.term.map { DateUtils.weekNumber(for: exam.date, term: $0) == week } ?? false
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Semaine \(week)")
                .font(Carnet.serif(.title2))
                .foregroundStyle(Carnet.ink)
            if let topic = weekTopic(theory: theory, series: series) {
                Text(topic).font(.subheadline).foregroundStyle(Carnet.inkSecondary)
            }
        }
        .padding(.horizontal, 6)

        if theory.isEmpty && series.isEmpty && deadlines.isEmpty {
            CarnetEmpty(icon: "calendar", title: "Rien de prévu",
                        message: "Aucune théorie ni série n'est rangée en semaine \(week).")
        }

        if !theory.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle("Théorie") {
                    Text("\(theory.filter(\.isWatched).count)/\(theory.count)")
                }
                CarnetSheet {
                    ForEach(Array(theory.enumerated()), id: \.element.id) { index, item in
                        CarnetTheoryLine(item: item,
                                         onOpen: { openedVideo = item },
                                         onBrowse: { browsing = $0 })
                        if index < theory.count - 1 { CarnetRule(inset: 54) }
                    }
                }
            }
        }

        ForEach(series) { item in
            seriesBlock(item)
        }

        if !deadlines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle("Cette semaine")
                CarnetSheet {
                    ForEach(Array(deadlines.enumerated()), id: \.element.id) { index, exam in
                        CarnetRow(icon: exam.kind.icon, tint: Carnet.tint(course.colorHex),
                                  title: exam.title.isEmpty ? exam.kind.label : exam.title,
                                  subtitle: DateUtils.fullDayLabel(exam.date) + " · " + DateUtils.time.string(from: exam.date)) {
                            Text(DateUtils.countdownLabel(to: exam.date))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                        if index < deadlines.count - 1 { CarnetRule() }
                    }
                }
            }
        }

        besideLinks
    }

    private func weekTopic(theory: [TheoryItem], series: [ExerciseSeries]) -> String? {
        if let section = theory.first?.sectionTitle, !section.isEmpty {
            let cleaned = section.replacingOccurrences(of: #"^(semaine|week)\s*\d+\s*[:·–-]?\s*"#, with: "",
                                                       options: [.regularExpression, .caseInsensitive])
            if !cleaned.isEmpty, cleaned.count < 80 { return cleaned }
        }
        if let topic = series.first?.topic, !topic.isEmpty { return topic }
        return nil
    }

    /// Une série : ses documents (énoncé, corrigé), puis chaque exercice, ses
    /// sous-questions et sa correction.
    private func seriesBlock(_ series: ExerciseSeries) -> some View {
        let links = ExerciseLinks.seriesLinks(series)
        let required = series.requiredExercises
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Série \(series.seriesNumber)" + (series.topic.isEmpty ? "" : " · \(series.topic)")) {
                Text("\(series.doneCount)/\(required.count)")
            }
            if !links.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(links, id: \.url) { link in
                            Button { browsing = link } label: {
                                Label(link.title, systemImage: link.icon)
                                    .font(.subheadline)
                                    .foregroundStyle(Carnet.ink)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 34)
                                    .background(Carnet.sheet, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            CarnetSheet {
                if series.exercises.isEmpty {
                    CarnetRow(icon: SeriesAutoReader.shared.reading.contains(series.id) ? "hourglass" : "doc.text.magnifyingglass",
                              tint: Carnet.inkSecondary,
                              title: SeriesAutoReader.shared.reading.contains(series.id) ? "Lecture de l'énoncé…" : "Exercices pas encore lus",
                              subtitle: "Ouvre l'onglet Séries pour les lire dans le PDF")
                }
                ForEach(Array(series.sortedExercises.enumerated()), id: \.element.id) { index, exercise in
                    Button { openedExercise = exercise } label: {
                        CarnetExerciseLine(exercise: exercise)
                    }
                    .buttonStyle(.plain)
                    if index < series.exercises.count - 1 { CarnetRule(inset: 54) }
                }
            }
        }
    }

    /// Ce qui accompagne le cours sans se suivre : examens, documents, progression.
    private var besideLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("À côté")
            CarnetSheet {
                Button { showingExams = true } label: {
                    CarnetRow(icon: "graduationcap", tint: Carnet.inkSecondary, title: "Examens et annales",
                              subtitle: examsDetail(course.nextExam)) { chevron }
                }
                .buttonStyle(.plain)
                if !course.documents.isEmpty {
                    CarnetRule()
                    Button { showingDocuments = true } label: {
                        CarnetRow(icon: "folder", tint: Carnet.inkSecondary, title: "Documents du cours",
                                  subtitle: course.documents.prefix(3).map(\.title).joined(separator: " · ")) { chevron }
                    }
                    .buttonStyle(.plain)
                }
                CarnetRule()
                Button { showingProgress = true } label: {
                    CarnetRow(icon: "chart.bar", tint: Carnet.inkSecondary, title: "Progression semaine par semaine") { chevron }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
    }

    // MARK: Tout le cours

    @ViewBuilder
    private var allContent: some View {
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
        besideLinks
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

/// Les documents d'un cours, rangés par leur section d'origine sur Moodle.
struct CourseDocumentsView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @State private var browsing: BrowsedLink?

    private var groups: [(title: String, documents: [CourseDocument])] {
        var order: [String] = []
        var byGroup: [String: [CourseDocument]] = [:]
        for document in course.documents {
            let key = document.group.isEmpty ? "Autres" : document.group
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(document)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.documents) { document in
                        row(document)
                    }
                }
            }
        }
        .navigationTitle("Documents · \(course.displayCode)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browsing) { InAppBrowser(link: $0) }
    }

    private func row(_ document: CourseDocument) -> some View {
        Button {
            if let url = ExerciseLinks.web(document.url) {
                browsing = BrowsedLink(title: document.title, url: url, icon: document.kind.icon)
            }
        } label: {
            Label(document.title, systemImage: document.kind.icon)
                .foregroundStyle(Color.primary)
        }
        .swipeActions {
            Button(role: .destructive) { remove(document) } label: {
                Label("Retirer", systemImage: "trash")
            }
        }
    }

    private func remove(_ document: CourseDocument) {
        course.documents.removeAll { $0 == document }
        // Retiré à la main : une mise à jour automatique ne le remettra pas.
        var ignored = course.contentIgnored
        ignored.insert(document.url)
        course.contentIgnored = ignored
        try? context.save()
    }
}
