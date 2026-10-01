import SwiftUI
import SwiftData

/// Tout ce que `TodayView` dérive de l'état persisté, calculé **une fois** par
/// rendu : SwiftUI réévalue une propriété calculée à chaque lecture, et l'agrégat
/// de charge reparcourt tous les cours.
private struct TodayState {
    let tracked: [Course]
    let term: AcademicTerm?
    /// La semaine en cours, du lundi au lundi suivant.
    let weekStart: Date
    /// La semaine du semestre, tous cours : théorie vue et exercices faits.
    let theory: (done: Int, total: Int)
    let series: (done: Int, total: Int)
    /// Éléments des semaines passées pas faits.
    let late: Int
    /// Temps d'étude enregistré, jour par jour, du lundi au dimanche.
    let days: [Int]
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

/// Aujourd'hui : le tableau de bord de la semaine.
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
    /// Un cours ouvert depuis « La semaine ».
    @State private var openedCourseDetail: Course?

    /// Une seule passe de dérivation, réutilisée par toutes les sections du rendu.
    private func derived() -> TodayState {
        let tracked = courses.filter(\.isTracked)
        let weekStart = DateUtils.startOfWeek(Date())
        let weekEnd = DateUtils.addDays(7, to: weekStart)
        let weeks = tracked.map { ProgressEngine.weekProgress(for: $0, week: $0.currentWeek) }
        var days = Array(repeating: 0, count: 7)
        for session in sessions {
            // Triées de la plus récente à la plus ancienne : on s'arrête au lundi.
            if session.startedAt < weekStart { break }
            guard session.startedAt < weekEnd else { continue }
            let index = DateUtils.daysBetween(weekStart, session.startedAt)
            if days.indices.contains(index) { days[index] += session.durationSeconds }
        }
        return TodayState(
            tracked: tracked,
            term: AcademicTerm.resolve(from: tracked.compactMap(\.term)),
            weekStart: weekStart,
            theory: (weeks.reduce(0) { $0 + $1.watchedCount }, weeks.reduce(0) { $0 + $1.videoCount }),
            series: (weeks.reduce(0) { $0 + $1.doneCount }, weeks.reduce(0) { $0 + $1.exerciseCount }),
            late: tracked.reduce(0) { $0 + ProgressEngine.lateCount(for: $1) },
            days: days,
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
                // Moi — le bilan et les réglages — derrière l'avatar, en haut à gauche.
                ToolbarItem(placement: .topBarLeading) {
                    ProfileButton()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        app.router.openAgenda()
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Agenda")
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

    /// L'accueil est **le tableau de bord de la semaine** : ce que la semaine a
    /// coûté en temps, ce que la journée a d'heures fixes, et où en est chaque
    /// cours dans sa semaine. Il ne propose plus « la prochaine chose à faire » :
    /// on sait sur quoi on travaille ; ce qu'on ne voit pas d'un coup d'œil,
    /// c'est la semaine entière.
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
            importNews
            WeekTimeCard(days: state.days, weekStart: state.weekStart,
                         theory: state.theory, series: state.series, late: state.late) {
                app.router.showingStats = true
            }
            todaySchedule(state)
            weekCourses(state)
        }
    }

    // MARK: La semaine, cours par cours

    /// Une ligne par cours : ce que sa semaine demande (théorie, exercices), ce
    /// qui est fait, et le retard en mots.
    @ViewBuilder
    private func weekCourses(_ state: TodayState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(state.term.map { $0.isRunning ? "Semaine \($0.currentWeek)" : "Cours" } ?? "Cours") {
                Button {
                    app.router.selectedTab = .courses
                } label: {
                    HStack(spacing: 3) {
                        Text("Tous les cours")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
            }
            CarnetSheet {
                ForEach(Array(state.tracked.enumerated()), id: \.element.id) { index, course in
                    Button {
                        openedCourseDetail = course
                    } label: {
                        WeekCourseRow(course: course)
                    }
                    .buttonStyle(PressableStyle(scale: 0.99))
                    if index < state.tracked.count - 1 { CarnetRule(inset: Carnet.rowInset) }
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
}
