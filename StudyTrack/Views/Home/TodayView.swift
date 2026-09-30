import SwiftUI
import SwiftData

/// Tout ce que `TodayView` dérive de l'état persisté, calculé **une fois** par rendu.
///
/// Ces valeurs étaient des propriétés calculées de la `View`. SwiftUI les réévalue
/// à chaque lecture, et `body` en faisait jusqu'à **17** pour `todos` : cinq
/// lectures directes, plus `todos.last?.id` une fois *par ligne*. Or
/// `DailyPlanner.todos` trie les vidéos et les séries de chaque cours suivi, et
/// `WorkloadEngine.aggregate` reparcourt tous les cours — l'écran payait donc une
/// quinzaine de planifications complètes par rendu, pour une liste plafonnée à 12.
private struct TodayState {
    let tracked: [Course]
    let todos: [StudyTodo]
    let term: AcademicTerm?
    let weekSeconds: Int
    let upcomingExams: [Exam]
    let dueTasks: [LinkedTask]
    /// Le planning du jour : séances, sessions planifiées, évaluations.
    let todayItems: [TodayItem]
}

/// Une ligne du planning du jour.
struct TodayItem: Identifiable {
    let id: String
    let start: Date
    let end: Date?
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
}

/// Écran principal : une action évidente, puis le reste par ordre d'utilité.
struct TodayView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @Query(sort: \Exam.date) private var exams: [Exam]
    @Query(sort: \PlannedSession.startsAt) private var plannedSessions: [PlannedSession]
    @Query(sort: \LinkedTask.dueDate) private var tasks: [LinkedTask]
    @Query(sort: \LinkedCalendarEvent.startsAt) private var events: [LinkedCalendarEvent]

    @Query private var exercises: [Exercise]
    @Query private var videos: [TheoryItem]

    /// Élément ouvert depuis la liste « À faire » : la fiche, pas le chrono.
    @State private var searchQuery = ""
    @State private var sheet: TodaySheet?
    @State private var openedExercise: Exercise?
    @State private var openedVideo: TheoryItem?
    /// Chrono laissé en route dans Focus, relu à chaque passage au premier plan.
    @State private var showAllTodos = false
    /// Un cours ouvert depuis « La semaine ».
    @State private var openedCourseDetail: Course?
    /// Les lignes cochées à l'instant : leur coche se remplit avant qu'elles
    /// ne quittent la liste, sinon la ligne disparaît sous le doigt.
    @State private var justDone: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Une seule passe de dérivation, réutilisée par toutes les sections du rendu.
    private func derived() -> TodayState {
        let tracked = courses.filter(\.isTracked)
        let todos = DailyPlanner.todos(for: tracked, limit: 12)
        let week = DateUtils.dateRange(days: 7)
        let today = DateUtils.startOfDay(Date())
        return TodayState(
            tracked: tracked,
            todos: todos,
            term: AcademicTerm.resolve(from: tracked.compactMap(\.term)),
            // Un seul parcours des sessions, au lieu d'un `filter` puis d'un `reduce`.
            weekSeconds: sessions.reduce(0) { total, session in
                session.startedAt >= week.start && session.startedAt < week.end
                    ? total + session.durationSeconds
                    : total
            },
            // Les trois `@Query` sont déjà triées : `prefix(3)` s'arrête au 3ᵉ match.
            upcomingExams: Array(exams.lazy.filter { $0.date >= today }.prefix(3)),
            dueTasks: Array(tasks.lazy
                .filter { !$0.isDone && ($0.isOverdue || $0.isDueToday) }
                .prefix(3)),
            todayItems: todayItems()
        )
    }

    /// Ce qui a une **heure** aujourd'hui, dans l'ordre : c'est la journée telle
    /// qu'elle est cadrée, avant ce qu'on choisit d'y faire.
    private func todayItems() -> [TodayItem] {
        let calendar = Calendar.current
        var items: [TodayItem] = []
        for event in events where calendar.isDateInToday(event.startsAt) {
            items.append(TodayItem(id: "event-\(event.id)",
                                   start: event.startsAt,
                                   end: event.endsAt,
                                   title: event.title,
                                   subtitle: [event.course?.displayCode, event.location.isEmpty ? nil : event.location]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   icon: event.kind.icon,
                                   color: event.course.map { Carnet.tint($0.colorHex) } ?? event.kind.color))
        }
        for session in plannedSessions where calendar.isDateInToday(session.startsAt) {
            items.append(TodayItem(id: "planned-\(session.id)",
                                   start: session.startsAt,
                                   end: session.endsAt,
                                   title: session.title,
                                   subtitle: [session.course?.displayCode, session.location.isEmpty ? nil : session.location,
                                              session.isGroupSession ? session.groupName : nil]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   icon: "timer",
                                   color: .indigo))
        }
        for exam in exams where calendar.isDateInToday(exam.date) {
            items.append(TodayItem(id: "exam-\(exam.id)",
                                   start: exam.date,
                                   end: nil,
                                   title: exam.title,
                                   subtitle: [exam.course?.displayCode, exam.location.isEmpty ? nil : exam.location]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   icon: exam.kind.icon,
                                   color: exam.kind.color))
        }
        return items.sorted { $0.start < $1.start }
    }

    /// Vrai sur iPad, et sur un iPhone Max en paysage : assez large pour deux
    /// colonnes. Décidé par la classe de taille, jamais par le modèle d'appareil,
    /// pour que Split View et Slide Over se comportent correctement.
    private var isWide: Bool { sizeClass == .regular }

    private var emptyState: some View {
        EmptyCard(icon: "books.vertical",
                  title: "Aucun cours suivi",
                  message: "Ajoute tes classes pour voir ici ce qu'il te reste à faire cette semaine.",
                  actionTitle: "Ajouter un cours") {
            app.router.selectedTab = .courses
        }
    }

    /// Les présentations de « Aujourd'hui », en une seule valeur.
    ///
    /// Les trois premières viennent d'une **demande** posée sur le routeur par un
    /// autre écran (la couverture du suivi renvoie vers le profil, par exemple) :
    /// `onChange` la consomme et la traduit en feuille.
    private enum TodaySheet: Identifiable, Hashable {
        case tasks
        case search
        case seriesImport(Course?, PendingImport?)
        case exercise(Exercise)
        case video(TheoryItem)

        var id: String {
            switch self {
            case .tasks: return "tasks"
            case .search: return "search"
            case .seriesImport(let course, let shared):
                return "seriesImport-\(course?.id.uuidString ?? "aucun")-\(shared?.receivedAt.timeIntervalSince1970 ?? 0)"
            case .exercise(let exercise): return "exercise-\(exercise.id)"
            case .video(let video): return "video-\(video.id)"
            }
        }
    }

    var body: some View {
        @Bindable var router = app.router
        let state = derived()
        return NavigationStack {
            CarnetScroll {
                content(state)
            }
            .navigationTitle("Aujourd'hui")
            .carnetSubtitle(dateLine(state))
            .navigationDestination(item: $openedCourseDetail) { course in
                CourseDetailView(course: course)
            }
            .toolbar {
                // L'action de l'onglet, puis l'avatar — la même règle partout.
                // La loupe vit dans « Cours », dont elle cherche le contenu.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Button {
                                app.router.openFocus(.timer)
                            } label: {
                                Label("Ouvrir le chrono", systemImage: "timer")
                            }
                            Button {
                                app.router.openFocus(.manual)
                            } label: {
                                Label("Saisir une session passée", systemImage: "square.and.pencil")
                            }
                        }
                        Section {
                            Button {
                                app.router.openContentImport()
                            } label: {
                                Label("Importer du contenu de cours", systemImage: "square.and.arrow.down.on.square")
                            }
                            Button {
                                sheet = .seriesImport(nil, nil)
                            } label: {
                                Label("Importer une série (PDF)", systemImage: "doc.badge.plus")
                            }
                        }
                        Button {
                            app.router.showingTasks = true
                        } label: {
                            Label("Tâches", systemImage: "checklist")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Ajouter ou démarrer")
                }
            }
            // **Une seule** feuille pour les six présentations.
            //
            // Six `.sheet` enchaînés sur la même vue ne fonctionnent pas de façon
            // fiable : SwiftUI n'en honore qu'une selon l'ordre, et les autres
            // restent silencieusement sans effet — un bouton qui « ne fait rien »,
            // impossible à reproduire pour qui ne connaît pas la cause. Une
            // présentation pilotée par une valeur supprime le problème.
            .sheet(item: $sheet, onDismiss: {
                // Sans ce retour à faux, « Tâches » ne s'ouvrait qu'une fois :
                // le drapeau restait vrai, et le toucher à nouveau ne changeait rien.
                app.router.showingTasks = false
            }) { destination in
                sheetContent(destination)
            }
            .refreshable {
                await TaskSync.sync(context: context, settings: app.settings)
            }
            .onAppear {
                // Partage reçu avant que l'accueil n'existe (lancement à froid) :
                // `onChange` ne le verra jamais passer.
                if let shared = app.router.pendingImport {
                    app.router.pendingImport = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        sheet = .seriesImport(nil, shared)
                    }
                }
                #if DEBUG
                // Les captures du simulateur ne peuvent pas taper : ces drapeaux
                // ouvrent la feuille. Le changement d'état est différé d'un tour :
                // modifié pendant la première passe de mise en page, il est absorbé
                // et la feuille ne s'ouvre jamais.
                if PreviewLaunch.isSet(PreviewLaunch.searchFlag) {
                    searchQuery = PreviewLaunch.string(PreviewLaunch.searchFlag) ?? ""
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        sheet = .search
                    }
                }
                if let path = PreviewLaunch.string(PreviewLaunch.importFileFlag) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        sheet = .seriesImport(nil, PendingImport(kind: .pdf, fileName: path, text: nil, receivedAt: Date()))
                    }
                }
                if PreviewLaunch.isSet(PreviewLaunch.profileFlag)
                    || PreviewLaunch.isSet(PreviewLaunch.statsFlag) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if PreviewLaunch.isSet(PreviewLaunch.profileFlag) { router.showingProfile = true }
                        if PreviewLaunch.isSet(PreviewLaunch.statsFlag) { router.showingStats = true }
                    }
                }
                #endif
            }
            .modifier(TodayObservers(sheet: $sheet,
                                     searchQuery: $searchQuery,
                                     requests: requests,
                                     openedExercise: openedExercise,
                                     openedVideo: openedVideo,
                                     courses: courses,
                                     app: app,
                                     applyRequests: apply))
        }
    }

    /// Le contenu de l'accueil, extrait du corps.
    ///
    /// Onze vues empilées dans une seule expression faisaient échouer le
    /// vérificateur de types (« unable to type-check this expression in reasonable
    /// time »). Les nommer une par une dans une méthode donne au compilateur des
    /// expressions courtes, et au lecteur un plan lisible de l'écran.
    /// L'accueil, dans l'ordre où l'on s'en sert : reprendre ce qu'on faisait,
    /// voir ce qui a une heure aujourd'hui, choisir la suite, ne pas rater une
    /// échéance, et voir la semaine d'un coup d'œil.
    @ViewBuilder
    private func content(_ state: TodayState) -> some View {
        if state.tracked.isEmpty {
            CarnetEmpty(icon: "books.vertical",
                        title: "Aucun cours suivi",
                        message: "Importe tes cours depuis Moodle : séries, vidéos et échéances arrivent d'un coup.",
                        actionTitle: "Importer mes cours") {
                app.router.openContentImport()
            }
        } else {
            resumeCard(state)
            importNews
            todaySchedule(state)
            weeklyList(state)
            deadlinesSection(state)
            weekCourses(state)
        }
    }

    // MARK: Reprendre

    /// La carte en verre du haut : la chose à reprendre, où on en est dedans
    /// (l'anneau compte les sous-questions), et le bouton qui y retourne.
    @ViewBuilder
    private func resumeCard(_ state: TodayState) -> some View {
        if let next = NextActionEngine.actions(for: state.tracked, limit: 1).first {
            let exercise = next.targetID.flatMap { id in exercises.first { $0.id == id } }
            let video = next.targetID.flatMap { id in videos.first { $0.id == id } }
            let tint = Carnet.tint(next.colorHex)
            let leaves = exercise?.leafSubQuestions ?? []
            let done = leaves.filter(\.isDone).count
            VStack(alignment: .leading, spacing: 12) {
                CarnetKicker("\(next.reasonLabel) · \(next.courseCode)", color: tint)
                HStack(spacing: 14) {
                    if leaves.isEmpty {
                        CarnetIconTile(systemName: next.icon, tint: tint, size: 52)
                    } else {
                        CarnetRing(value: Double(done) / Double(max(leaves.count, 1)), tint: tint,
                                   label: "\(done)/\(leaves.count)")
                    }
                    Button {
                        if let exercise { openedExercise = exercise } else if let video { openedVideo = video }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(MathMarkup.plain(next.title))
                                .font(Carnet.serif(.title3))
                                .foregroundStyle(Carnet.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(resumeDetail(next, exercise: exercise))
                                .font(.footnote)
                                .foregroundStyle(Carnet.inkSecondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        app.router.startFocus(courseID: next.courseID, courseCode: next.courseCode,
                                              taskType: next.taskType, targetID: next.targetID,
                                              label: next.focusLabel)
                        Haptics.tap()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Carnet.ground)
                            .offset(x: 1)
                            .frame(width: 50, height: 50)
                            .background(Carnet.ink, in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Démarrer le chrono : \(next.focusLabel)")
                }
            }
            .padding(16)
            .carnetGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    private func resumeDetail(_ next: NextAction, exercise: Exercise?) -> String {
        if let exercise, let current = exercise.leafSubQuestions.first(where: { !$0.isDone }) {
            return "Sous-question \(current.displayLabel) · \(next.detail)"
        }
        return next.detail
    }

    // MARK: La semaine

    /// Chaque cours en une colonne : la part faite de sa semaine.
    @ViewBuilder
    private func weekCourses(_ state: TodayState) -> some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("La semaine") {
                Button(DateUtils.hoursLabel(seconds: state.weekSeconds) + " travaillées") {
                    app.router.showingStats = true
                }
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(state.tracked) { course in
                    let week = ProgressEngine.weekProgress(for: course, week: course.currentWeek)
                    let done = week.watchedCount + week.doneCount
                    let total = week.videoCount + week.exerciseCount
                    Button {
                        openedCourseDetail = course
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(course.displayCode)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Carnet.tint(course.colorHex))
                            Text(total == 0 ? "—" : "\(done)/\(total)")
                                .font(Carnet.serif(.title2))
                                .foregroundStyle(Carnet.ink)
                            CarnetBar(value: CourseProgress.ratio(done, total), tint: Carnet.tint(course.colorHex))
                            Text(total == 0 ? "rien de prévu" : (done == total ? "semaine faite" : "reste \(total - done)"))
                                .font(.caption)
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                    .accessibilityLabel("\(course.name) : \(done) sur \(total) cette semaine")
                }
            }
        }
    }

    /// « Nouveau sur Moodle : MATH-101 : 1 série » — ce que la mise à jour
    /// automatique vient d'ajouter, jusqu'à ce qu'on le ferme.
    @ViewBuilder
    private var importNews: some View {
        let news = app.settings.contentRefreshNews
        if !news.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                CarnetIconTile(systemName: "sparkles", tint: Carnet.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nouveau dans tes cours").font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
                    Text(news).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(Motion.snappy) { app.settings.contentRefreshNews = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Carnet.inkSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Masquer")
            }
            .padding(14)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .transition(.opacity)
        }
    }

    /// Les observations de l'accueil, sorties de la chaîne de modificateurs.
    ///
    /// Huit `.onChange` à la suite d'une vingtaine d'autres modificateurs font
    /// échouer le vérificateur de types. Les isoler dans une méthode leur donne un
    /// contexte court — et le texte des fermetures reste identique.
    /// Les observations de l'accueil, sorties de la chaîne de modificateurs.
    ///
    /// Huit `.onChange` à la suite d'une vingtaine d'autres modificateurs, dans une
    /// vue qui porte une trentaine de propriétés, font échouer le vérificateur de
    /// types (« unable to type-check this expression in reasonable time »). Ce
    /// modificateur ne reçoit que ce dont il a besoin — pas la vue entière, dont
    /// le seul nom suffisait à alourdir chaque expression.
    private struct TodayObservers: ViewModifier {
        @Binding var sheet: TodaySheet?
        @Binding var searchQuery: String
        var requests: Requests
        var openedExercise: Exercise?
        var openedVideo: TheoryItem?
        var courses: [Course]
        var app: AppContainer
        var applyRequests: (Requests) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: requests) { _, state in applyRequests(state) }
                .onChange(of: app.router.shortcut) { _, shortcut in handleShortcut(shortcut) }
                .onChange(of: app.router.pendingImport) { _, shared in handleImport(shared) }
                .onChange(of: openedExercise) { _, exercise in handleExercise(exercise) }
                .onChange(of: openedVideo) { _, video in handleVideo(video) }
        }

        // Chaque fermeture appelle une méthode nommée : cinq `.onChange` dont le
        // corps est écrit sur place font échouer le vérificateur de types, et un
        // corps d'une ligne se lit mieux qu'un bloc imbriqué.

        private func handleShortcut(_ shortcut: ShortcutAction?) {
            guard let shortcut else { return }
            switch shortcut {
            case .importSeries:
                sheet = .seriesImport(nil, nil)
            case .startTimer:
                app.router.startFocus(courseID: nil, courseCode: "",
                                      taskType: .theory, label: "Session libre")
            }
            app.router.shortcut = nil
        }

        private func handleImport(_ shared: PendingImport?) {
            guard let shared else { return }
            sheet = .seriesImport(nil, shared)
            app.router.pendingImport = nil
        }

        private func handleExercise(_ exercise: Exercise?) {
            if let exercise { sheet = .exercise(exercise) }
        }

        private func handleVideo(_ video: TheoryItem?) {
            if let video { sheet = .video(video) }
        }
    }

    // MARK: Feuilles

    /// Les trois demandes du routeur, réunies pour n'être observées qu'une fois.
    /// Profil, statistiques et Focus sont présentés par `RootTabView` : ils
    /// s'ouvrent depuis n'importe quel onglet. Il ne reste ici que les tâches.
    private struct Requests: Equatable {
        var tasks = false
    }

    private var requests: Requests {
        Requests(tasks: app.router.showingTasks)
    }

    private func apply(_ state: Requests) {
        if state.tasks, sheet == nil { sheet = .tasks }
        else if !state.tasks, sheet == .tasks { sheet = nil }
    }

    @ViewBuilder
    private func sheetContent(_ destination: TodaySheet) -> some View {
        switch destination {
        case .tasks:
            TasksView()
        case .search:
            SearchView(initialQuery: searchQuery)
        case .seriesImport(let course, let shared):
            SeriesImportSheet(course: course,
                              initialFileURL: shared.flatMap(importFileURL),
                              initialText: shared?.text)
        case .exercise(let exercise):
            ExerciseSheet(exercise: exercise)
        case .video(let video):
            VideoDetailSheet(video: video)
        }
    }

    private func importFileURL(_ shared: PendingImport) -> URL? {
        if let url = PendingImportBridge.file(for: shared) { return url }
        #if DEBUG
        // `-importFile` : un chemin absolu, le simulateur non signé n'ayant pas de
        // conteneur de groupe où l'extension de partage déposerait le fichier.
        if let path = shared.fileName, path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        #endif
        return nil
    }

    // MARK: En-tête

    /// La date d'abord, en sur-titre, puis le salut : on ouvre l'app pour savoir
    /// quel jour et quelle semaine on est, avant tout le reste.
    private func greeting(_ state: TodayState) -> some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            Text(dateLine(state))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(greetingText)
                .font(.title3.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private func dateLine(_ state: TodayState) -> String {
        var parts = [DateUtils.fullDayLabel(Date()).capitalizedFirst]
        if let term = state.term {
            parts.append(term.hasEnded ? "semestre terminé" : (term.hasNotStarted ? "semestre à venir" : "semaine \(term.currentWeek) sur \(term.totalWeeks)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Horaire

    /// Ce qui a une heure aujourd'hui : cours EPFL, sessions planifiées,
    /// évaluations. Les créneaux passés restent, barrés ; toucher la feuille
    /// ouvre l'agenda.
    private func todaySchedule(_ state: TodayState) -> some View {
        let now = Date()
        let items = state.todayItems
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Horaire") {
                Button {
                    app.router.openAgenda(day: now)
                } label: {
                    HStack(spacing: 3) {
                        Text("Agenda")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
                .accessibilityLabel("Ouvrir l'agenda")
            }
            Button {
                app.router.openAgenda(day: now)
            } label: {
                CarnetSheet {
                    if items.isEmpty {
                        CarnetRow(icon: "sun.max", tint: Carnet.review,
                                  title: "Rien à l'horaire aujourd'hui",
                                  subtitle: "La journée est à toi")
                    } else {
                        ForEach(Array(items.prefix(6).enumerated()), id: \.element.id) { index, item in
                            scheduleRow(item, now: now)
                            if index < min(items.count, 6) - 1 { CarnetRule(inset: 74) }
                        }
                        if items.count > 6 {
                            Text("+ \(items.count - 6) autres")
                                .font(.footnote)
                                .foregroundStyle(Carnet.inkSecondary)
                                .padding(.leading, 74)
                                .padding(.bottom, 10)
                        }
                    }
                }
            }
            .buttonStyle(PressableStyle(scale: 0.99))
        }
    }

    private func scheduleRow(_ item: TodayItem, now: Date) -> some View {
        let isPast = (item.end ?? item.start) < now
        let isOngoing = item.start <= now && !isPast
        return HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(DateUtils.time.string(from: item.start))
                    .font(Carnet.mono(.footnote, weight: isOngoing ? .semibold : .regular))
                if let end = item.end {
                    Text(DateUtils.time.string(from: end))
                        .font(Carnet.mono(.caption2))
                        .foregroundStyle(Carnet.inkTertiary)
                }
            }
            .foregroundStyle(isPast ? Carnet.inkTertiary : Carnet.ink)
            .frame(width: 46, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(item.color)
                .opacity(isPast ? 0.35 : 1)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.body.weight(isOngoing ? .semibold : .regular))
                        .strikethrough(isPast, color: Carnet.inkTertiary)
                        .foregroundStyle(isPast ? Carnet.inkTertiary : Carnet.ink)
                        .lineLimit(1)
                    if isOngoing {
                        Text("en cours")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Carnet.ground)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Carnet.ink, in: Capsule())
                    }
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.footnote).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base: String
        switch hour {
        case 5..<12: base = "Bonjour"
        case 12..<18: base = "Bon après-midi"
        default: base = "Bonsoir"
        }
        let name = app.settings.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? base : "\(base) \(name)"
    }

    // MARK: À faire

    /// Au-delà de cinq lignes, la liste se replie : en semaine 12 elle en compte
    /// des dizaines, et l'accueil devenait un mur à faire défiler.
    private static let collapsedTodoCount = 5

    @ViewBuilder
    private func weeklyList(_ state: TodayState) -> some View {
        let rest = state.todos
        if !rest.isEmpty {
            let visible = showAllTodos ? rest : Array(rest.prefix(Self.collapsedTodoCount))
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle("À faire") { Text("\(rest.count) cette semaine") }
                CarnetSheet {
                    ForEach(visible) { todo in
                        VStack(spacing: 0) {
                            TodoRow(todo: todo,
                                    isDone: justDone.contains(todo.id),
                                    onComplete: { checkOff(todo) },
                                    onOpen: { open(todo) },
                                    onStart: {
                                        app.router.startFocus(courseID: todo.courseID,
                                                              courseCode: todo.courseCode,
                                                              taskType: todo.taskType,
                                                              targetID: todo.targetID,
                                                              label: "\(todo.courseCode) · \(todo.title)")
                                    })
                            if todo.id != visible.last?.id { CarnetRule(inset: 54) }
                        }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                    }
                    if rest.count > Self.collapsedTodoCount {
                        CarnetRule(inset: 0)
                        Button {
                            withAnimation(Motion.snappy) { showAllTodos.toggle() }
                        } label: {
                            Text(showAllTodos ? "Afficher moins" : "Tout afficher (\(rest.count))")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Carnet.ink)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Échéances

    @ViewBuilder
    private func deadlinesSection(_ state: TodayState) -> some View {
        let rows = deadlineRows(state)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle("Échéances") {
                    Button("Tâches") { app.router.showingTasks = true }
                }
                CarnetSheet {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        CarnetRow(icon: row.icon, tint: row.tint, title: row.title, subtitle: row.subtitle) {
                            if let trailing = row.trailing {
                                Text(trailing)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(row.urgent ? Carnet.wrong : Carnet.inkSecondary)
                            }
                        }
                        if index < rows.count - 1 { CarnetRule() }
                    }
                }
            }
        }
    }

    private struct DeadlineRow: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
        let trailing: String?
        var urgent = false
    }

    /// Les échéances aplaties en une liste, pour que les séparateurs tombent entre
    /// deux lignes et jamais après la dernière.
    private func deadlineRows(_ state: TodayState) -> [DeadlineRow] {
        var rows: [DeadlineRow] = []
        for exam in state.upcomingExams {
            let soon = exam.date.timeIntervalSinceNow < 3 * 86_400
            rows.append(DeadlineRow(id: "exam-\(exam.id)",
                                    icon: exam.kind.icon,
                                    tint: exam.course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkSecondary,
                                    title: exam.title,
                                    subtitle: "\(exam.course?.displayCode ?? "") · \(DateUtils.shortDay.string(from: exam.date))",
                                    trailing: DateUtils.countdownLabel(to: exam.date),
                                    urgent: soon))
        }
        for task in state.dueTasks {
            rows.append(DeadlineRow(id: "task-\(task.id)",
                                    icon: "checklist",
                                    tint: task.course.map { Carnet.tint($0.colorHex) } ?? Carnet.inkSecondary,
                                    title: task.title,
                                    subtitle: task.course?.displayCode ?? task.provider.label,
                                    trailing: task.isOverdue ? "En retard" : "Aujourd'hui",
                                    urgent: task.isOverdue))
        }
        return rows
    }

    // MARK: Actions

    /// Cocher depuis la liste : la coche se remplit, puis la ligne s'en va.
    ///
    /// La correction ne se coche pas d'un geste — elle demande un jugement — et
    /// ouvre donc la fiche tout de suite.
    private func checkOff(_ todo: StudyTodo) {
        guard todo.kind != .correction else { return complete(todo) }
        guard !justDone.contains(todo.id) else { return }
        justDone.insert(todo.id)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            withAnimation(Motion.snappy) {
                complete(todo)
            }
            justDone.remove(todo.id)
        }
    }

    private func complete(_ todo: StudyTodo) {
        switch todo.kind {
        case .video:
            if let video = videos.first(where: { $0.id == todo.targetID }) {
                video.watchedAt = video.watchedAt == nil ? Date() : nil
                if video.watchedAt == nil { video.summarizedAt = nil }
            }
        case .exercise, .redo:
            if let exercise = exercises.first(where: { $0.id == todo.targetID }) {
                exercise.setDone(!exercise.isDone)
            }
        case .correction:
            // La correction demande un jugement (juste, moyen, faux) : on ouvre la
            // fiche de l'exercice, où le contrôle de correction est à un tap.
            if let exercise = exercises.first(where: { $0.id == todo.targetID }) {
                openedExercise = exercise
            }
            return
        }
        // Pas de vibration ici : `CheckCircleButton` a déjà la sienne.
        try? context.save()
    }

    /// Ouvre la fiche de l'élément : c'est ce qu'un tap sur le texte doit faire.
    /// Démarrer le chrono est le rôle du bouton de lecture, pas de la ligne.
    private func open(_ todo: StudyTodo) {
        switch todo.kind {
        case .video:
            openedVideo = videos.first { $0.id == todo.targetID }
        case .exercise, .redo, .correction:
            openedExercise = exercises.first { $0.id == todo.targetID }
        }
    }
}
