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
    let lastTodoID: String?
    let term: AcademicTerm?
    let streak: Int
    let totalXP: Int
    let weekSeconds: Int
    let weeklyVideoMinutes: Int
    let workload: WorkloadDelta
    let upcomingExams: [Exam]
    let upcomingSessions: [PlannedSession]
    let dueTasks: [LinkedTask]
    let redoExercises: [Exercise]
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
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var openedExercise: Exercise?
    @State private var openedVideo: TheoryItem?
    /// Chrono laissé en route dans Focus, relu à chaque passage au premier plan.
    @State private var runningTimer: FocusTimerState?

    /// Une seule passe de dérivation, réutilisée par toutes les sections du rendu.
    private func derived() -> TodayState {
        let tracked = courses.filter(\.isTracked)
        let todos = DailyPlanner.todos(for: tracked, limit: 12)
        let week = DateUtils.dateRange(days: 7)
        let today = DateUtils.startOfDay(Date())
        return TodayState(
            tracked: tracked,
            todos: todos,
            lastTodoID: todos.last?.id,
            term: AcademicTerm.resolve(from: tracked.compactMap(\.term)),
            streak: GamificationEngine.currentStreak(sessions: sessions),
            totalXP: GamificationEngine.totalXP(courses: courses, sessions: sessions),
            // Un seul parcours des sessions, au lieu d'un `filter` puis d'un `reduce`.
            weekSeconds: sessions.reduce(0) { total, session in
                session.startedAt >= week.start && session.startedAt < week.end
                    ? total + session.durationSeconds
                    : total
            },
            weeklyVideoMinutes: DailyPlanner.weeklyVideoMinutes(for: tracked),
            // Hebdomadaire : l'attendu d'une semaine, comparé à cette semaine-là.
            workload: WorkloadEngine.aggregateWeekly(courses: tracked,
                                                     hoursPerCredit: app.settings.hoursPerCredit,
                                                     from: week.start,
                                                     to: week.end),
            // Les trois `@Query` sont déjà triées : `prefix(3)` s'arrête au 3ᵉ match.
            upcomingExams: Array(exams.lazy.filter { $0.date >= today }.prefix(3)),
            upcomingSessions: Array(plannedSessions.lazy.filter { !$0.isPast }.prefix(3)),
            dueTasks: Array(tasks.lazy
                .filter { !$0.isDone && ($0.isOverdue || $0.isDueToday) }
                .prefix(3)),
            redoExercises: exercises.filter(\.redoRequired),
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
                                   color: event.course.map { Color(hex: $0.colorHex) } ?? event.kind.color))
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

    /// Deux colonnes, toujours : cinq tuiles en grille adaptative laissaient une
    /// case vide et deux tailles de tuile. Trois indicateurs sur deux colonnes,
    /// puis la charge EPFL sur sa propre ligne, où elle se lit comme une phrase.
    private var statColumns: [GridItem] {
        [GridItem(.flexible(), spacing: Layout.block), GridItem(.flexible(), spacing: Layout.block)]
    }

    private var emptyState: some View {
        EmptyCard(icon: "books.vertical",
                  title: "Aucun cours suivi",
                  message: "Ajoute tes classes pour voir ici ce qu'il te reste à faire cette semaine.",
                  actionTitle: "Ajouter un cours") {
            app.router.selectedTab = .courses
        }
    }

    var body: some View {
        let state = derived()
        return NavigationStack {
            ScrollView {
                if isWide {
                    // Deux colonnes : le plan de la semaine à gauche, le travail
                    // concret à droite. Une seule colonne de 1030 pt obligeait à
                    // faire défiler pour relier « ce qui reste » à « quoi faire ».
                    HStack(alignment: .top, spacing: Layout.sectionSpacing) {
                        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                            greeting(state)
                            timerBanner
                            if state.tracked.isEmpty {
                                emptyState
                                quickActions
                            } else {
                                primaryActionCard(state)
                                quickActions
                                todaySchedule(state)
                                weekOverview(state)
                                progressSection(state)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                            if !state.tracked.isEmpty {
                                weeklyList(state)
                                redoSection(state)
                                deadlinesSection(state)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Layout.screenPadding)
                    .adaptiveColumn(maxWidth: Layout.wideWidth)
                } else {
                    LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                        greeting(state)
                        timerBanner

                        if state.tracked.isEmpty {
                            emptyState
                            quickActions
                        } else {
                            primaryActionCard(state)
                            quickActions
                            todaySchedule(state)
                            weekOverview(state)
                            weeklyList(state)
                            redoSection(state)
                            deadlinesSection(state)
                            progressSection(state)
                        }
                    }
                    .padding(Layout.screenPadding)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Aujourd'hui")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        app.router.showingProfile = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Profil et réglages")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        app.router.showingStats = true
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .accessibilityLabel("Statistiques")
                    Button {
                        app.router.showingTasks = true
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("Tâches")
                    Button {
                        app.router.selectedTab = .focus
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Nouvelle session")
                }
            }
            .sheet(isPresented: Binding(get: { app.router.showingTasks },
                                        set: { app.router.showingTasks = $0 })) {
                TasksView()
            }
            .sheet(isPresented: Binding(get: { app.router.showingProfile },
                                        set: { app.router.showingProfile = $0 })) {
                ProfileView()
            }
            .sheet(isPresented: Binding(get: { app.router.showingStats },
                                        set: { app.router.showingStats = $0 })) {
                NavigationStack {
                    StatsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fermer") { app.router.showingStats = false }
                            }
                        }
                }
            }
            .sheet(item: $openedExercise) { exercise in
                ExerciseDetailSheet(exercise: exercise)
            }
            .sheet(item: $openedVideo) { video in
                VideoDetailSheet(video: video)
            }
            .refreshable {
                await TaskSync.sync(context: context, settings: app.settings)
            }
            .onAppear { runningTimer = FocusTimerStore.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { runningTimer = FocusTimerStore.load() }
            }
            .onChange(of: app.router.selectedTab) { _, _ in runningTimer = FocusTimerStore.load() }
        }
    }

    // MARK: Chrono en cours

    /// Un chrono laissé en route dans Focus reste visible ici : sinon on l'oublie,
    /// et il compte des heures que personne n'a travaillées.
    @ViewBuilder
    private var timerBanner: some View {
        if let timer = runningTimer, timer.isRestorable() {
            Button {
                app.router.selectedTab = .focus
            } label: {
                HStack(spacing: Layout.block) {
                    Image(systemName: timer.isRunning ? "timer" : "pause.circle.fill")
                        .font(.title3)
                        .foregroundStyle(timer.isRunning ? Theme.accentInk : Color.orange.accessibleMark)
                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text(timer.isRunning ? "Chrono en cours" : "Chrono en pause")
                            .font(.subheadline.weight(.semibold))
                        Text(timerBannerDetail(timer))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Layout.inline)
                    Text(DateUtils.durationLabel(seconds: Int(timer.elapsed())))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(Layout.gutter)
                .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(timer.isRunning ? "Chrono en cours" : "Chrono en pause"), \(DateUtils.durationLabel(seconds: Int(timer.elapsed()))). Ouvrir Focus")
        }
    }

    private func timerBannerDetail(_ timer: FocusTimerState) -> String {
        let course = courses.first { $0.id == timer.courseID }
        var parts = [course?.displayCode ?? "Session libre", timer.taskType.label]
        if !timer.contextLabel.isEmpty, timer.contextLabel != parts.joined(separator: " · ") {
            parts = [timer.contextLabel]
        }
        return parts.joined(separator: " · ")
    }

    // MARK: En-tête

    private func greeting(_ state: TodayState) -> some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            // Un seul en-tête par écran : le grand titre de navigation porte le
            // nom de l'écran, le salut reste un sous-titre.
            Text(greetingText)
                .font(.title3.weight(.semibold))
            // La date et la semaine en une phrase — pas deux pastilles à décoder.
            Text(dateLine(state))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func dateLine(_ state: TodayState) -> String {
        var parts = [DateUtils.fullDayLabel(Date())]
        if let term = state.term {
            parts.append(term.hasEnded ? "semestre terminé" : (term.hasNotStarted ? "semestre à venir" : "semaine \(term.currentWeek) / \(term.totalWeeks)"))
        }
        if !app.settings.sectionCode.isEmpty { parts.append(app.settings.sectionCode) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions rapides

    /// Quatre gestes d'un tap, toujours au même endroit : chrono libre, session
    /// manuelle, planifier, tâches. Le reste de l'écran est de la lecture.
    private var quickActions: some View {
        HStack(spacing: Layout.control) {
            quickAction(icon: "play.fill", title: "Chrono", tint: Theme.accent) {
                app.router.startFocus(courseID: nil, courseCode: "", taskType: .theory, label: "Session libre")
            }
            quickAction(icon: "square.and.pencil", title: "Saisir", tint: .purple) {
                app.router.selectedTab = .focus
                app.router.focusMode = .manual
            }
            quickAction(icon: "calendar.badge.plus", title: "Planifier", tint: .indigo) {
                app.router.selectedTab = .agenda
            }
            quickAction(icon: "checklist", title: "Tâches", tint: .teal) {
                app.router.showingTasks = true
            }
        }
    }

    private func quickAction(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: Layout.snug) {
                ZStack {
                    Circle().fill(tint.badgeFill).frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint.badgeInk)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.control)
            .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: Planning du jour

    @ViewBuilder
    private func todaySchedule(_ state: TodayState) -> some View {
        if !state.todayItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Ta journée", trailing: "\(state.todayItems.count)")
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(state.todayItems.enumerated()), id: \.element.id) { index, item in
                            let isPast = (item.end ?? item.start) < Date()
                            HStack(alignment: .center, spacing: Layout.block) {
                                VStack(alignment: .trailing, spacing: Layout.micro) {
                                    Text(DateUtils.time.string(from: item.start))
                                        .font(.caption.weight(.semibold))
                                        .monospacedDigit()
                                    if let end = item.end {
                                        Text(DateUtils.time.string(from: end))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                                .frame(width: 44, alignment: .trailing)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(item.color.accessibleMark)
                                    .frame(width: 4, height: 32)
                                VStack(alignment: .leading, spacing: Layout.micro) {
                                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: Layout.inline)
                                Image(systemName: item.icon)
                                    .font(.caption)
                                    .foregroundStyle(item.color.accessibleMark)
                            }
                            .padding(.vertical, Layout.inline)
                            .opacity(isPast ? 0.55 : 1)
                            if index < state.todayItems.count - 1 {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                }
            }
        }
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

    // MARK: Action principale

    @ViewBuilder
    private func primaryActionCard(_ state: TodayState) -> some View {
        if let next = state.todos.first {
            ActionCard(icon: next.icon,
                       title: "\(next.courseCode) · \(next.title)",
                       subtitle: "\(next.kind.label) · \(next.detail)",
                       actionTitle: "Démarrer le chrono",
                       tint: next.tint) {
                app.router.startFocus(courseID: next.courseID,
                                      courseCode: next.courseCode,
                                      taskType: next.taskType,
                                      label: "\(next.courseCode) · \(next.title)")
            }
        } else {
            ActionCard(icon: "checkmark.seal.fill",
                       title: "Tout est à jour pour cette semaine",
                       subtitle: "Lance une session libre pour avancer sur ce que tu veux.",
                       actionTitle: "Démarrer une session libre",
                       tint: .green) {
                app.router.startFocus(courseID: nil,
                                      courseCode: "",
                                      taskType: .theory,
                                      label: "Session libre")
            }
        }
    }

    // MARK: Vue de la semaine

    private func weekOverview(_ state: TodayState) -> some View {
        Card(title: "Cette semaine", icon: "calendar") {
            VStack(alignment: .leading, spacing: Layout.cardGap) {
                LazyVGrid(columns: statColumns, alignment: .leading, spacing: Layout.block) {
                    StatCard(icon: "list.bullet",
                             value: "\(state.todos.count)",
                             title: "à faire",
                             tint: .blue)
                    StatCard(icon: "play.rectangle.fill",
                             value: DateUtils.durationLabel(seconds: state.weeklyVideoMinutes * 60),
                             title: "de théorie restante",
                             tint: TaskType.video.tint)
                    StatCard(icon: "clock.fill",
                             value: DateUtils.hoursLabel(seconds: state.weekSeconds),
                             title: "travaillé (7 j)",
                             tint: .purple)
                    StatCard(icon: "flame.fill",
                             value: state.streak > 0 ? "\(state.streak) j" : "—",
                             title: state.streak > 0 ? "d'affilée" : "pas de série en cours",
                             tint: .orange)
                }

                // La charge EPFL sur une ligne, en retrait : c'est un repère, pas
                // la position du produit. Elle se lit « fait / attendu », puis l'écart.
                workloadLine(state.workload)
            }
        }
    }

    private func workloadLine(_ workload: WorkloadDelta) -> some View {
        VStack(alignment: .leading, spacing: Layout.snug) {
            LabeledProgress(title: "Charge EPFL (semaine)",
                            progress: workload.completion,
                            color: workload.isBehind ? .red : (workload.isOnTrack ? .green : .orange),
                            countLabel: "\(workload.actualLabel) / \(workload.expectedLabel)")
            HStack(spacing: Layout.snug) {
                Image(systemName: workload.isBehind ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                Text(workloadSentence(workload))
                    .font(.caption)
            }
            .foregroundStyle((workload.isBehind ? Color.red : Color.green).accessibleInk)
        }
    }

    private func workloadSentence(_ workload: WorkloadDelta) -> String {
        let gap = DateUtils.hoursLabel(seconds: abs(workload.deltaSeconds))
        if workload.deltaSeconds >= 0 { return "\(gap) d'avance sur l'attendu" }
        if workload.isBehind { return "\(gap) de retard sur l'attendu" }
        return "\(gap) sous l'attendu — dans la marge"
    }

    // MARK: Liste de la semaine

    @ViewBuilder
    private func weeklyList(_ state: TodayState) -> some View {
        if !state.todos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "À faire", trailing: "\(state.todos.count) éléments")
                Card {
                    VStack(spacing: 0) {
                        ForEach(state.todos) { todo in
                            TodoRow(todo: todo,
                                    onComplete: { complete(todo) },
                                    onOpen: { open(todo) },
                                    onStart: {
                                        app.router.startFocus(courseID: todo.courseID,
                                                              courseCode: todo.courseCode,
                                                              taskType: todo.taskType,
                                                              label: "\(todo.courseCode) · \(todo.title)")
                                    })
                            if todo.id != state.lastTodoID {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func redoSection(_ state: TodayState) -> some View {
        if !state.redoExercises.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "À refaire", trailing: "\(state.redoExercises.count)")
                Card {
                    VStack(spacing: 0) {
                        ForEach(state.redoExercises.prefix(4)) { exercise in
                            Button {
                                openedExercise = exercise
                            } label: {
                            HStack(spacing: 12) {
                                ConfidenceDot(level: exercise.confidence)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(exercise.series?.course?.displayCode ?? "") · \(exercise.displayNumber)")
                                        .font(.subheadline.weight(.semibold))
                                    if let note = exercise.correctionNote, !note.isEmpty {
                                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                if let correctness = exercise.correctness {
                                    Pill(text: correctness.shortLabel, color: correctness.color)
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Ouvrir l'exercice")
                        }
                    }
                }
            }
        }
    }

    // MARK: Échéances

    @ViewBuilder
    private func deadlinesSection(_ state: TodayState) -> some View {
        if !state.upcomingExams.isEmpty || !state.upcomingSessions.isEmpty || !state.dueTasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Échéances")
                Card {
                    let rows = deadlineRows(state)
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            deadlineRow(icon: row.icon,
                                        tint: row.tint,
                                        title: row.title,
                                        subtitle: row.subtitle,
                                        trailing: row.trailing)
                            if index < rows.count - 1 {
                                Divider().padding(.leading, 36)
                            }
                        }
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
    }

    /// Les échéances aplaties en une liste, pour que les séparateurs tombent entre
    /// deux lignes et jamais après la dernière.
    private func deadlineRows(_ state: TodayState) -> [DeadlineRow] {
        var rows: [DeadlineRow] = []
        for exam in state.upcomingExams {
            rows.append(DeadlineRow(id: "exam-\(exam.id)",
                                    icon: exam.kind.icon,
                                    tint: exam.kind.color,
                                    title: exam.title,
                                    subtitle: "\(exam.course?.displayCode ?? "") · \(DateUtils.shortDay.string(from: exam.date))",
                                    trailing: DateUtils.countdownLabel(to: exam.date)))
        }
        for session in state.upcomingSessions {
            rows.append(DeadlineRow(id: "planned-\(session.id)",
                                    icon: "timer",
                                    tint: .indigo,
                                    title: session.title,
                                    subtitle: "\(DateUtils.relativeLabel(session.startsAt)) · \(DateUtils.time.string(from: session.startsAt))",
                                    trailing: session.isGroupSession ? "Groupe" : nil))
        }
        for task in state.dueTasks {
            rows.append(DeadlineRow(id: "task-\(task.id)",
                                    icon: "checklist",
                                    tint: task.isOverdue ? .red : .teal,
                                    title: task.title,
                                    subtitle: task.course?.displayCode ?? task.provider.label,
                                    trailing: task.isOverdue ? "En retard" : "Aujourd'hui"))
        }
        return rows
    }

    private func deadlineRow(icon: String, tint: Color, title: String, subtitle: String, trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint.accessibleMark)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint.accessibleInk)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: Progression

    @ViewBuilder
    private func progressSection(_ state: TodayState) -> some View {
        if !state.tracked.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Progression",
                              trailing: "Niv. \(GamificationEngine.level(forXP: state.totalXP))")
                Card {
                    VStack(spacing: 0) {
                        ForEach(state.tracked) { course in
                            NavigationLink {
                                CourseDetailView(course: course)
                            } label: {
                                CourseProgressRow(course: course)
                            }
                            .buttonStyle(.plain)
                            if course.id != state.tracked.last?.id {
                                Divider().padding(.vertical, 10)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func complete(_ todo: StudyTodo) {
        switch todo.kind {
        case .video:
            if let video = videos.first(where: { $0.id == todo.targetID }) {
                video.watchedAt = video.watchedAt == nil ? Date() : nil
                if video.watchedAt == nil { video.summarizedAt = nil }
            }
        case .exercise, .redo:
            if let exercise = exercises.first(where: { $0.id == todo.targetID }) {
                if exercise.isDone {
                    exercise.doneAt = nil
                    exercise.confidence = nil
                } else {
                    exercise.doneAt = Date()
                    if exercise.confidence == nil { exercise.confidence = .medium }
                }
            }
        case .correction:
            // La correction demande un jugement (juste, moyen, faux) : on ouvre la
            // fiche de l'exercice, où le contrôle de correction est à un tap.
            if let exercise = exercises.first(where: { $0.id == todo.targetID }) {
                openedExercise = exercise
            }
            return
        }
        Haptics.success()
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

// MARK: - Ligne « à faire »

/// Une ligne = une chose. Coche à gauche, action au centre, chrono à droite.
struct TodoRow: View {
    let todo: StudyTodo
    var onComplete: () -> Void
    var onOpen: () -> Void
    var onStart: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            CheckCircleButton(isOn: false,
                              tint: todo.tint,
                              label: "Marquer \(todo.title) terminé",
                              action: onComplete)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Layout.tight) {
                    HStack(spacing: 6) {
                        Text(todo.courseCode)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(hex: todo.colorHex).accessibleInk)
                        Text(todo.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(todo.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let duration = todo.durationLabel {
                Text(duration)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(action: onStart) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(todo.tint.accessibleMark)
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Démarrer le chrono sur \(todo.title)")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Ligne de progression d'un cours

/// Ligne compacte : code, nom, résumé des trois pourcentages, anneau.
struct CourseProgressRow: View {
    let course: Course

    var body: some View {
        let progress = ProgressEngine.progress(for: course)
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: course.colorHex))
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: Layout.tight) {
                HStack(spacing: 6) {
                    Text(course.displayCode).font(.subheadline.weight(.bold))
                    if !course.hasLectures {
                        Pill(text: "sans amphi", color: .secondary)
                    }
                }
                Text(course.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Théorie \(pct(progress.theoryPercent)) · Exos \(pct(progress.exercisePercent)) · Corr. \(pct(progress.correctionPercent))")
                    .font(.caption)      // résumé de données : un cran au-dessus du plancher
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ProgressRing(progress: progress.overallPercent,
                         color: Color(hex: course.colorHex),
                         size: 46,
                         lineWidth: 5)
        }
        .contentShape(Rectangle())
    }

    private func pct(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
