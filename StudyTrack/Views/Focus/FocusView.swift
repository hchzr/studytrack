import SwiftUI
import SwiftData

/// Focus : un chrono évident, catégorisé, plus le journal du jour.
struct FocusView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    @State private var mode: Mode = .timer
    @State private var selectedCourseID: UUID?
    @State private var taskType: TaskType = .exercise
    @State private var startDate: Date?
    @State private var accumulated: TimeInterval = 0
    @State private var now = Date()
    @State private var pomodoro = false
    @State private var note = ""
    @State private var contextLabel = ""
    /// Cible précise de la session (un exercice, un élément de théorie).
    @State private var targetID: UUID?
    /// Premier démarrage de la session en cours — pour la présence et la
    /// restauration après une fermeture de l'app.
    @State private var sessionStartedAt: Date?
    /// Le bloc Pomodoro a-t-il déjà été annoncé pour cette session ?
    @State private var pomodoroAnnounced = false
    @State private var showingBreak = false
    @State private var showingHistory = false
    @State private var sessionToDelete: StudySession?
    @State private var restored = false

    /// Le chrono est le moment « display » de l'app : taille conservée, mais
    /// elle suit désormais la taille de texte du lecteur.
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 58

    // Saisie manuelle
    @State private var manualCourseID: UUID?
    @State private var manualTaskType: TaskType = .exercise
    @State private var manualMinutes = 45
    @State private var manualDate = Date()
    @State private var manualNote = ""

    enum Mode: String, CaseIterable, Identifiable {
        case timer, manual, journal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .timer: return "Chrono"
            case .manual: return "Manuel"
            case .journal: return "Journal"
            }
        }
    }

    private var elapsed: TimeInterval {
        accumulated + (startDate.map { now.timeIntervalSince($0) } ?? 0)
    }

    private var isRunning: Bool { startDate != nil }

    /// Le chrono ne bat que lorsque la seconde affichée peut changer : une session
    /// en cours **et** le panneau visible.
    ///
    /// Avant, un `Timer.publish(...).autoconnect()` stocké dans la `View` tirait
    /// toutes les secondes en permanence — y compris à l'arrêt, où rien ne change —
    /// et était recréé (donc ré-abonné) à chaque ré-initialisation de la structure.
    /// Chaque battement invalidait tout le corps : journal du jour refiltré et série
    /// recalculée, même sur un autre segment.
    private var tickIsActive: Bool { isRunning && mode == .timer }

    private var trackedCourses: [Course] { courses.filter(\.isTracked) }

    private var selectedCourse: Course? {
        courses.first { $0.id == selectedCourseID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .timer: timerSection
                    case .manual: manualSection
                    case .journal: journalSection
                    }
                }
                .padding(Layout.screenPadding)
                .adaptiveColumn()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Focus")
            .task {
                restoreIfNeeded()
                applyFocusRequest()
                applyFocusMode(app.router.focusMode)
                #if DEBUG
                // `-course CS-250` présélectionne un cours : `xcrun simctl` ne sait
                // pas taper, c'est le seul moyen de capturer le sélecteur « Préciser ».
                if selectedCourseID == nil,
                   let code = PreviewLaunch.string(PreviewLaunch.courseFlag),
                   let match = courses.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
                    selectedCourseID = match.id
                }
                #endif
            }
            .task(id: tickIsActive) {
                guard tickIsActive else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    now = Date()
                    checkPomodoro()
                }
            }
            .alert("Bloc terminé", isPresented: $showingBreak) {
                Button("Pause de \(app.settings.pomodoroBreakMinutes) min") { pause() }
                Button("Continuer", role: .cancel) {}
            } message: {
                Text("\(app.settings.pomodoroFocusMinutes) min de concentration. Le chrono continue tant que tu ne le mets pas en pause.")
            }
            .sheet(isPresented: $showingHistory) {
                SessionHistoryView()
            }
            .confirmationDialog("Supprimer cette session ?",
                                isPresented: Binding(get: { sessionToDelete != nil },
                                                     set: { if !$0 { sessionToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    if let session = sessionToDelete {
                        context.delete(session)
                        try? context.save()
                        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
                    }
                    sessionToDelete = nil
                }
                Button("Annuler", role: .cancel) { sessionToDelete = nil }
            }
            .onChange(of: pomodoro) { _, _ in schedulePomodoroIfNeeded() }
            // Revenir sur le chrono après un passage par le journal doit réafficher
            // la bonne durée immédiatement, sans attendre le battement suivant.
            .onChange(of: mode) { _, _ in now = Date() }
            // Changer de cours ou de type pendant une session doit se voir chez les
            // autres : ils lisent « CS-250 · Exercices », pas ce qui était vrai au
            // démarrage.
            .onChange(of: selectedCourseID) { _, _ in announcePresence(); persist() }
            .onChange(of: taskType) { _, _ in announcePresence(); persist() }
            .onChange(of: targetID) { _, _ in persist() }
            .onChange(of: note) { _, _ in persist() }
            .onChange(of: app.router.focusRequest) { _, newValue in
                guard newValue != nil else { return }
                Task { @MainActor in applyFocusRequest() }
            }
            .onChange(of: app.router.focusMode) { _, newValue in applyFocusMode(newValue) }
        }
    }

    // MARK: Chrono

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Card {
                VStack(spacing: Layout.gutter) {
                    if !contextLabel.isEmpty {
                        Text(contextLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Text(timeString(elapsed))
                        .font(.system(size: timerSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isRunning ? Theme.accentInk : .primary)
                        .frame(maxWidth: .infinity)

                    if pomodoro {
                        let target = Double(app.settings.pomodoroFocusMinutes * 60)
                        let remaining = max(0, target - elapsed)
                        LabeledProgress(title: "Pomodoro \(app.settings.pomodoroFocusMinutes) min",
                                        progress: min(1, elapsed / max(target, 1)),
                                        color: remaining == 0 ? .green : .orange,
                                        countLabel: remaining == 0
                                            ? "bloc terminé"
                                            : "reste \(DateUtils.durationLabel(seconds: Int(remaining.rounded(.up))))")
                    }

                    HStack(spacing: 12) {
                        if isRunning {
                            Button {
                                pause()
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                start()
                            } label: {
                                Label(elapsed > 0 ? "Reprendre" : "Démarrer", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button {
                            finish()
                        } label: {
                            Label("Enregistrer", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .disabled(elapsed < 1)
                    }
                }
            }

            Card(title: "Catégorisation", icon: "tag.fill") {
                VStack(alignment: .leading, spacing: 14) {
                    // Hors d'un `Form`, un `Picker` menu n'affiche que sa valeur :
                    // « Aucun cours ⌃⌄ » sans dire de quoi il s'agit. Le libellé
                    // est donc posé à la main, à gauche, comme dans un formulaire.
                    LabeledContent("Cours") {
                        Picker("Cours", selection: $selectedCourseID) {
                            Text("Aucun cours").tag(UUID?.none)
                            ForEach(trackedCourses) { course in
                                Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                            }
                        }
                        .labelsHidden()
                    }

                    LabeledContent("Type de travail") {
                        Picker("Type de travail", selection: $taskType) {
                            ForEach(TaskType.allCases) { type in
                                Label(type.label, systemImage: type.icon).tag(type)
                            }
                        }
                        .labelsHidden()
                    }

                    // « 2 h d'exercices sur CS-250 » ne dit pas si c'était la série 3
                    // ou la 5. Quand le cours et le type sont choisis, on propose
                    // donc les cibles concrètes — avec un intitulé visible, parce que
                    // « Tout le cours » seul ne dit pas de quoi il s'agit.
                    if let course = selectedCourse {
                        let options = targetOptions(for: course)
                        if !options.isEmpty {
                            LabeledContent("Sur quoi ?") {
                                Picker("Sur quoi ?", selection: $targetID) {
                                    Text("Tout le cours").tag(UUID?.none)
                                    ForEach(options) { option in
                                        Text(option.label).tag(UUID?.some(option.id))
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }

                    Toggle("Mode Pomodoro", isOn: $pomodoro)

                    TextField("Note (optionnel)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .onChange(of: selectedCourseID) { _, _ in targetID = nil }
            .onChange(of: taskType) { _, _ in targetID = nil }

            if !trackedCourses.isEmpty {
                Card(title: "Raccourcis", icon: "bolt.fill") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(trackedCourses) { course in
                            ForEach([TaskType.video, .exercise, .correction]) { type in
                                quickStartButton(course: course, type: type)
                            }
                        }
                    }
                }
            }
        }
    }

    private func quickStartButton(course: Course, type: TaskType) -> some View {
        Button {
            selectedCourseID = course.id
            taskType = type
            contextLabel = "\(course.code) · \(type.label)"
            if !isRunning { start() }
            Haptics.tap()
        } label: {
            VStack(spacing: Layout.tight) {
                Image(systemName: type.icon).font(.subheadline)
                Text(course.displayCode).font(.caption.weight(.semibold))
                Text(type.label).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(hex: course.colorHex).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Manuel

    private var manualSection: some View {
        Card(title: "Ajouter une session", icon: "square.and.pencil") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Cours", selection: $manualCourseID) {
                    Text("Aucun cours").tag(UUID?.none)
                    ForEach(trackedCourses) { course in
                        Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                    }
                }

                Picker("Type", selection: $manualTaskType) {
                    ForEach(TaskType.allCases) { type in
                        Label(type.label, systemImage: type.icon).tag(type)
                    }
                }

                Stepper("Durée : \(manualMinutes) min", value: $manualMinutes, in: 5...600, step: 5)
                DatePicker("Date", selection: $manualDate, displayedComponents: [.date, .hourAndMinute])
                TextField("Note (optionnel)", text: $manualNote, axis: .vertical)
                    .lineLimit(2...4)

                Button {
                    addManual()
                } label: {
                    Label("Enregistrer la session", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Journal

    private var journalSection: some View {
        // Une seule passe : la version précédente filtrait toutes les sessions
        // **six fois** (total, compteur, regroupement, deux tests de vide, `ForEach`)
        // et reconstruisait la série à chaque battement du chrono.
        let calendar = Calendar.current
        let today = sessions.filter { calendar.isDateInToday($0.startedAt) }
        let total = today.reduce(0) { $0 + $1.durationSeconds }
        let byType = Dictionary(grouping: today, by: \.taskType)
        let streak = GamificationEngine.currentStreak(sessions: sessions)

        return VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            HStack(spacing: 12) {
                StatCard(icon: "clock.fill",
                         value: DateUtils.hoursLabel(seconds: total),
                         title: "aujourd'hui",
                         tint: .blue)
                StatCard(icon: "list.bullet",
                         value: "\(today.count)",
                         title: "sessions",
                         tint: .purple)
                StatCard(icon: "flame.fill",
                         value: "\(streak) j",
                         title: "série",
                         tint: .orange)
            }

            Card(title: "Répartition du jour", icon: "chart.pie.fill") {
                if today.isEmpty {
                    Text("Aucune session aujourd'hui. Lance un chrono !")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(TaskType.allCases) { type in
                            if let items = byType[type], !items.isEmpty {
                                let seconds = items.reduce(0) { $0 + $1.durationSeconds }
                                LabeledProgress(title: type.label,
                                                progress: CourseProgress.ratio(seconds, max(total, 1)),
                                                color: type.tint,
                                                countLabel: DateUtils.hoursLabel(seconds: seconds))
                            }
                        }
                    }
                }
            }

            Card(title: "Sessions du jour", icon: "list.bullet.rectangle") {
                if today.isEmpty {
                    Text("Rien pour l'instant.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(today) { session in
                            HStack(spacing: 12) {
                                Image(systemName: session.taskType.icon)
                                    .foregroundStyle(session.taskType.tint.accessibleMark)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.course?.code ?? "Sans cours")
                                        .font(.subheadline.weight(.semibold))
                                    Text(sessionSubtitle(session))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(session.durationLabel)
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                                Button(role: .destructive) {
                                    sessionToDelete = session
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                // Un bouton destructeur sans libellé est le pire cas :
                                // VoiceOver n'annonçait que « trash ».
                                .accessibilityLabel("Supprimer la session de \(DateUtils.time.string(from: session.startedAt))\(session.course.map { " sur \($0.displayCode)" } ?? "")")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            Button {
                showingHistory = true
            } label: {
                Label("Tout l'historique", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Actions

    private func applyFocusMode(_ requested: AppRouter.FocusMode?) {
        guard let requested else { return }
        switch requested {
        case .timer: mode = .timer
        case .manual: mode = .manual
        case .journal: mode = .journal
        }
        app.router.focusMode = nil
    }

    private func applyFocusRequest() {
        guard let request = app.router.consumeFocusRequest() else { return }
        mode = .timer
        var resolvedID = request.courseID
        if resolvedID == nil, !request.courseCode.isEmpty {
            resolvedID = courses.first {
                $0.code.caseInsensitiveCompare(request.courseCode) == .orderedSame
            }?.id
        }
        selectedCourseID = resolvedID
        taskType = request.taskType
        contextLabel = request.label
        if !isRunning { start() }
    }

    private func start() {
        startDate = Date()
        now = Date()
        if sessionStartedAt == nil { sessionStartedAt = Date() }
        Haptics.tap()
        publishActivity()
        announcePresence()
        schedulePomodoroIfNeeded()
        persist()
    }

    private func pause() {
        guard let startDate else { return }
        accumulated += Date().timeIntervalSince(startDate)
        self.startDate = nil
        Haptics.tap()
        publishActivity()
        announcePresence()
        app.notifications.cancelPomodoro()
        persist()
    }

    // MARK: Persistance du chrono

    /// Écrit l'état du chrono pour qu'il survive à une fermeture de l'app.
    private func persist() {
        guard startDate != nil || accumulated > 0 else {
            FocusTimerStore.save(nil)
            return
        }
        FocusTimerStore.save(FocusTimerState(accumulated: accumulated,
                                             runningSince: startDate,
                                             sessionStartedAt: sessionStartedAt ?? Date(),
                                             courseID: selectedCourseID,
                                             taskTypeRaw: taskType.rawValue,
                                             targetID: targetID,
                                             note: note,
                                             contextLabel: contextLabel,
                                             pomodoro: pomodoro))
    }

    /// Reprend un chrono laissé en route par une exécution précédente.
    ///
    /// Le temps écoulé pendant l'absence est **compté** : le chrono tournait, et
    /// l'étudiant·e travaillait. Une session trop ancienne (chrono oublié la
    /// veille) n'est pas reprise : elle est enregistrée telle quelle, bornée, et
    /// le journal la montre pour correction.
    private func restoreIfNeeded() {
        guard !restored else { return }
        restored = true
        guard let saved = FocusTimerStore.load() else { return }
        guard saved.isRestorable() else {
            FocusTimerStore.save(nil)
            let seconds = min(Int(saved.elapsed()), Int(FocusTimerState.maxRestorableAge))
            if seconds >= 60 {
                let course = courses.first { $0.id == saved.courseID }
                let session = StudySession(course: course,
                                           taskType: saved.taskType,
                                           startedAt: saved.sessionStartedAt,
                                           durationSeconds: seconds,
                                           isManual: false,
                                           note: saved.note.isEmpty
                                               ? "Chrono resté ouvert — durée à vérifier"
                                               : saved.note + " · chrono resté ouvert")
                context.insert(session)
                try? context.save()
            }
            return
        }
        accumulated = saved.accumulated
        startDate = saved.runningSince
        sessionStartedAt = saved.sessionStartedAt
        selectedCourseID = saved.courseID
        taskType = saved.taskType
        note = saved.note
        contextLabel = saved.contextLabel
        pomodoro = saved.pomodoro
        // Après les `onChange` qui remettent la cible à zéro.
        let target = saved.targetID
        Task { @MainActor in targetID = target }
        now = Date()
        mode = .timer
        if saved.isRunning {
            publishActivity()
            announcePresence()
        }
    }

    // MARK: Pomodoro

    private var pomodoroTarget: TimeInterval {
        Double(app.settings.pomodoroFocusMinutes * 60)
    }

    /// Planifie la notification de fin de bloc, calée sur le temps restant.
    private func schedulePomodoroIfNeeded() {
        guard pomodoro, isRunning, elapsed < pomodoroTarget else {
            app.notifications.cancelPomodoro()
            return
        }
        pomodoroAnnounced = false
        app.notifications.schedulePomodoroEnd(at: Date().addingTimeInterval(pomodoroTarget - elapsed),
                                              breakMinutes: app.settings.pomodoroBreakMinutes)
    }

    /// Au premier battement après le terme, si l'écran est visible : une haptique
    /// et une proposition de pause. La notification couvre le cas écran éteint.
    private func checkPomodoro() {
        guard pomodoro, isRunning, !pomodoroAnnounced, elapsed >= pomodoroTarget else { return }
        pomodoroAnnounced = true
        Haptics.success()
        showingBreak = true
    }

    /// Prévient les groupes que je travaille — ou que je viens d'arrêter.
    ///
    /// Appelé aux seuls moments qui changent mon état : démarrage, pause, fin, et
    /// changement de cours ou de type. Le battement périodique est ensuite géré par
    /// `PresenceService`, qui rafraîchit `updated_at` sans que la vue s'en occupe.
    ///
    /// Une session **sans cours** est publiée elle aussi : c'est du travail, et
    /// l'absence de matière ne justifie pas de disparaître du direct.
    private func announcePresence() {
        guard isRunning else {
            app.presence.stop(context: context, social: app.social)
            return
        }
        let target = resolvedTarget()
        let entry = PresenceEntry(
            userID: app.social.userID ?? "me",
            displayName: app.settings.displayName.isEmpty ? "Moi" : app.settings.displayName,
            courseCode: selectedCourse?.code ?? "",
            taskLabel: taskType.label,
            target: target.exercise?.displayNumber ?? target.theoryItem?.displayNumber ?? "",
            startedAt: startDate ?? Date(),
            updatedAt: Date(),
            isMe: true)
        app.presence.announce(entry, context: context, social: app.social)
    }

    /// Une cible proposée au chrono : un exercice ou un élément de théorie.
    private struct TargetOption: Identifiable {
        let id: UUID
        let label: String
    }

    /// Ce qu'on peut préciser pour ce cours et ce type de travail.
    ///
    /// Les exercices pour un travail d'exercice ou de correction, la théorie pour
    /// le reste — et rien pour un type qui ne s'y prête pas (projet, autre).
    private func targetOptions(for course: Course) -> [TargetOption] {
        switch taskType {
        case .exercise, .correction:
            return course.allExercises
                .sorted { $0.displayNumber.localizedStandardCompare($1.displayNumber) == .orderedAscending }
                .map { TargetOption(id: $0.id, label: $0.displayNumber) }
        case .video, .theory, .summary:
            return course.sortedTheoryItems
                .map { TargetOption(id: $0.id, label: $0.displayNumber) }
        default:
            return []
        }
    }

    /// Résout la cible choisie en exercice ou en élément de théorie.
    private func resolvedTarget() -> (exercise: Exercise?, theoryItem: TheoryItem?) {
        guard let course = selectedCourse, let targetID else { return (nil, nil) }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return (exercise, nil)
        }
        if let item = course.theoryItems.first(where: { $0.id == targetID }) {
            return (nil, item)
        }
        return (nil, nil)
    }

    private func finish() {
        let seconds = Int(elapsed)
        guard seconds >= 1 else { return }
        let target = resolvedTarget()
        let session = StudySession(course: selectedCourse,
                                   taskType: taskType,
                                   startedAt: sessionStartedAt ?? Date().addingTimeInterval(-Double(seconds)),
                                   durationSeconds: seconds,
                                   isManual: false,
                                   note: note,
                                   exercise: target.exercise,
                                   theoryItem: target.theoryItem)
        context.insert(session)
        try? context.save()
        Haptics.success()
        startDate = nil
        accumulated = 0
        sessionStartedAt = nil
        note = ""
        contextLabel = ""
        targetID = nil
        pomodoroAnnounced = false
        StudyActivityController.end()
        app.presence.stop(context: context, social: app.social)
        app.notifications.cancelPomodoro()
        FocusTimerStore.save(nil)
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
    }

    /// Publie l'état du chrono sur l'écran verrouillé et dans l'îlot dynamique.
    ///
    /// Le compteur lui-même n'est pas envoyé chaque seconde : l'activité reçoit la
    /// date de départ et `Text(timerInterval:)` fait le reste. On ne publie donc
    /// qu'aux changements d'état — démarrage, reprise, pause.
    private func publishActivity() {
        let target = resolvedTarget()
        let label = (target.exercise?.displayNumber ?? target.theoryItem?.displayNumber)
        StudyActivityController.sync(
            attributes: StudyActivityAttributes(
                courseCode: selectedCourse?.displayCode ?? "Sans cours",
                courseName: selectedCourse?.name ?? "Session libre",
                taskLabel: taskType.label,
                taskIcon: taskType.icon,
                target: label),
            state: StudyActivityAttributes.ContentState(accumulated: accumulated,
                                                        runningSince: startDate))
    }

    private func addManual() {
        let session = StudySession(course: courses.first { $0.id == manualCourseID },
                                   taskType: manualTaskType,
                                   startedAt: manualDate,
                                   durationSeconds: manualMinutes * 60,
                                   isManual: true,
                                   note: manualNote)
        context.insert(session)
        try? context.save()
        Haptics.success()
        manualNote = ""
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
    }

    /// « 14:20 · Exercices · Exercice 3.2 » — la cible n'apparaît que si elle est connue.
    private func sessionSubtitle(_ session: StudySession) -> String {
        var parts = [DateUtils.time.string(from: session.startedAt), session.taskType.label]
        if let target = session.targetLabel { parts.append(target) }
        return parts.joined(separator: " · ")
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
