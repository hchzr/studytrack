import SwiftUI
import SwiftData

/// Le chrono : sur quoi, combien de temps, et le geste suivant.
///
/// L'écran se lit de haut en bas dans l'ordre où l'on décide : **sur quoi** je
/// travaille (cours, type, cible), **comment** (chrono libre ou Pomodoro), puis
/// le cadran et ses trois boutons. Rien d'autre n'est visible pendant une
/// session : les raccourcis de démarrage disparaissent dès que le chrono tourne,
/// parce qu'ils ne servent qu'avant.
///
/// Tout l'état vit dans `FocusController`. Cette vue ne garde que le **brouillon**
/// d'une session pas encore démarrée — le cours et le type choisis avant d'appuyer
/// sur « Démarrer ».
struct FocusTimerPanel: View {
    @Binding var isAdjusting: Bool
    @Binding var showingPomodoroSettings: Bool
    @Binding var showingShortcutEditor: Bool

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    // Brouillon d'une session pas encore démarrée.
    @State private var draftCourseID: UUID?
    @State private var draftTaskType: TaskType = .exercise
    @State private var draftTargetID: UUID?

    /// Une demande de démarrage qui remplacerait la session en cours.
    @State private var pendingStart: FocusRequest?
    @State private var confirmingDiscard = false
    /// « Session enregistrée · 42 min », affiché quelques secondes après « Terminer ».
    @State private var savedMessage: String?

    private var focus: FocusController { app.focus }
    private var pomodoroSettings: PomodoroSettings { app.settings.pomodoro }
    private var trackedCourses: [Course] { courses.filter(\.isTracked) }

    // MARK: Contexte de la session

    private var courseID: UUID? { focus.hasSession ? focus.state?.courseID : draftCourseID }
    private var taskType: TaskType { focus.hasSession ? (focus.state?.taskType ?? .other) : draftTaskType }
    private var targetID: UUID? { focus.hasSession ? focus.state?.targetID : draftTargetID }
    private var course: Course? { courses.first { $0.id == courseID } }

    private var tint: Color { course.map { Color(hex: $0.colorHex) } ?? Theme.accent }

    private var courseBinding: Binding<UUID?> {
        Binding(get: { courseID }, set: { value in
            if focus.hasSession {
                focus.updateContext(courseID: .some(value), targetID: .some(nil), label: "")
            } else {
                draftCourseID = value
                draftTargetID = nil
            }
        })
    }

    private var taskTypeBinding: Binding<TaskType> {
        Binding(get: { taskType }, set: { value in
            if focus.hasSession {
                focus.updateContext(taskType: value, targetID: .some(nil), label: "")
            } else {
                draftTaskType = value
                draftTargetID = nil
            }
        })
    }

    private var targetBinding: Binding<UUID?> {
        Binding(get: { targetID }, set: { value in
            if focus.hasSession {
                focus.updateContext(targetID: .some(value), label: "")
            } else {
                draftTargetID = value
            }
        })
    }

    private var noteBinding: Binding<String> {
        Binding(get: { focus.state?.note ?? "" }, set: { focus.updateContext(note: $0) })
    }

    private var pomodoroBinding: Binding<Bool> {
        Binding(get: { focus.isPomodoro }, set: { value in
            withAnimation(Motion.snappy) { focus.setPomodoro(value) }
            Haptics.tap()
        })
    }

    // MARK: Corps

    var body: some View {
        VStack(spacing: Layout.sectionSpacing) {
            contextSection

            // Le cadran et ses boutons se redessinent chaque seconde tant qu'il y a
            // quelque chose qui s'écoule : un travail compté ou une pause qui
            // décompte. À l'arrêt, rien ne bat.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                dialSection(now: focus.isRunning || focus.phase().isBreak ? timeline.date : Date())
            }

            if isAdjusting {
                adjustPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.green.accessibleInk)
                    .padding(.horizontal, Layout.gutter)
                    .padding(.vertical, Layout.control)
                    .background(Color.green.badgeFill, in: Capsule())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            if focus.hasSession {
                noteField
            } else {
                shortcutsSection
            }

            if let problem = StudyActivityController.lastError, focus.isRunning {
                // Le chrono fonctionne sans Live Activity, mais on dit pourquoi
                // elle n'apparaît pas : un ornement qui échoue en silence laisse
                // croire à un bug du chrono.
                Label(problem, systemImage: "platter.filled.top.and.arrow.up.iphone")
                    .font(.footnote)
                    .foregroundStyle(Color.orange.accessibleInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            todaySummary
        }
        .animation(Motion.snappy, value: focus.hasSession)
        .animation(Motion.snappy, value: savedMessage)
        .task {
            if !focus.hasSession {
                draftTaskType = .exercise
            }
            applyRequest()
            #if DEBUG
            applyDebugLaunch()
            #endif
        }
        .onChange(of: app.router.focusRequest) { _, newValue in
            guard newValue != nil else { return }
            Task { @MainActor in applyRequest() }
        }
        .onChange(of: focus.lastEvent) { _, event in
            // Une fin de bloc ou de pause pendant que l'écran est ouvert : on
            // sort de l'ajustement, qui n'a plus de sens sur une pause.
            if event != nil { isAdjusting = false }
        }
        .confirmationDialog("Remplacer la session en cours ?",
                            isPresented: Binding(get: { pendingStart != nil },
                                                 set: { if !$0 { pendingStart = nil } }),
                            titleVisibility: .visible) {
            Button("Enregistrer et démarrer") {
                if let request = pendingStart {
                    finish()
                    begin(request)
                }
                pendingStart = nil
            }
            Button("Abandonner et démarrer", role: .destructive) {
                if let request = pendingStart {
                    focus.discard()
                    begin(request)
                }
                pendingStart = nil
            }
            Button("Continuer la session actuelle", role: .cancel) { pendingStart = nil }
        } message: {
            Text("Le chrono tourne déjà sur autre chose. Que faire du temps en cours ?")
        }
        .confirmationDialog("Abandonner cette session ?",
                            isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Abandonner \(DateUtils.durationLabel(seconds: Int(focus.elapsed())))", role: .destructive) {
                focus.discard()
                isAdjusting = false
                Haptics.removed()
            }
            Button("Garder", role: .cancel) {}
        } message: {
            Text("Le temps compté ne sera pas enregistré.")
        }
    }

    // MARK: Sur quoi

    private var contextSection: some View {
        VStack(spacing: Layout.block) {
            // Cours, type et cible : trois pastilles à menu, lisibles d'un coup
            // d'œil, modifiables en deux touchers. Elles passent à la ligne au
            // lieu d'être coupées au bord de l'écran.
            FlowLayout(spacing: Layout.inline) {
                    Menu {
                        Picker("Cours", selection: courseBinding) {
                            Label("Sans cours", systemImage: "circle.dashed").tag(UUID?.none)
                            ForEach(trackedCourses) { course in
                                Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                            }
                        }
                    } label: {
                        chip(icon: "books.vertical.fill",
                             text: course?.displayCode ?? "Choisir un cours",
                             tint: course.map { Color(hex: $0.colorHex) } ?? .secondary,
                             emphasized: course == nil)
                    }
                    .accessibilityLabel("Cours")
                    .accessibilityValue(course?.displayCode ?? "aucun")

                    Menu {
                        Picker("Type de travail", selection: taskTypeBinding) {
                            ForEach(TaskType.allCases) { type in
                                Label(type.label, systemImage: type.icon).tag(type)
                            }
                        }
                    } label: {
                        chip(icon: taskType.icon, text: taskType.label, tint: taskType.tint)
                    }
                    .accessibilityLabel("Type de travail")
                    .accessibilityValue(taskType.label)

                    if let course, !targetOptions(for: course).isEmpty {
                        Menu {
                            Picker("Sur quoi ?", selection: targetBinding) {
                                Text("Tout le cours").tag(UUID?.none)
                                ForEach(targetOptions(for: course)) { option in
                                    Text(option.label).tag(UUID?.some(option.id))
                                }
                            }
                        } label: {
                            chip(icon: "scope",
                                 text: targetLabel ?? "Préciser",
                                 tint: .secondary)
                        }
                        .accessibilityLabel("Cible")
                        .accessibilityValue(targetLabel ?? "tout le cours")
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Layout.control) {
                Picker("Mode", selection: pomodoroBinding) {
                    Text("Chrono libre").tag(false)
                    Text("Pomodoro").tag(true)
                }
                .pickerStyle(.segmented)

                if focus.isPomodoro {
                    Button {
                        showingPomodoroSettings = true
                    } label: {
                        Text("\(pomodoroSettings.focusMinutes)/\(pomodoroSettings.shortBreakMinutes)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, Layout.block)
                            .frame(minHeight: 32)
                            .background(Theme.softBackground, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(Theme.accentInk)
                    .accessibilityLabel("Réglages Pomodoro : \(pomodoroSettings.focusMinutes) minutes de travail, \(pomodoroSettings.shortBreakMinutes) de pause")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
    }

    private func chip(icon: String, text: String, tint: Color, emphasized: Bool = false) -> some View {
        HStack(spacing: Layout.snug) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(text).font(.subheadline.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .padding(.horizontal, Layout.block)
        .frame(minHeight: 36)
        .background(emphasized ? Theme.softBackground : tint.badgeFill, in: Capsule())
        .overlay {
            if emphasized {
                Capsule().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .foregroundStyle(emphasized ? Color.primary : tint.badgeInk)
        .contentShape(Capsule())
    }

    // MARK: Le cadran

    /// Ce que le cadran montre, selon la phase.
    private struct DialContent {
        var time: String
        var progress: Double?
        var caption: String?
        var tint: Color
    }

    private func dialContent(now: Date) -> DialContent {
        let phase = focus.phase(at: now)
        let elapsed = focus.elapsed(at: now)
        if isAdjusting {
            return DialContent(time: TimerText.clock(elapsed),
                               progress: nil,
                               caption: "Temps compté · un tour = 1 h",
                               tint: tint)
        }
        switch phase {
        case .onBreak(let kind, let start, let end):
            let left = max(0, end.timeIntervalSince(now))
            let total = max(1, end.timeIntervalSince(start))
            return DialContent(time: TimerText.clock(left.rounded(.up)),
                               progress: left / total,
                               caption: "\(kind.label) · bloc \(nextBlockNumber) ensuite",
                               tint: .teal)
        case .readyForBlock(let block):
            return DialContent(time: TimerText.clock(pomodoroSettings.blockDuration),
                               progress: 0,
                               caption: "Pause finie · bloc \(block) prêt",
                               tint: tint)
        case .idle:
            if focus.isPomodoro {
                return DialContent(time: TimerText.clock(pomodoroSettings.blockDuration),
                                   progress: 0,
                                   caption: "Bloc 1 · \(pomodoroSettings.focusMinutes) min",
                                   tint: tint)
            }
            return DialContent(time: TimerText.clock(0), progress: nil, caption: nil, tint: tint)
        case .working, .paused:
            let paused = phase == .paused
            if focus.isPomodoro {
                let status = focus.pomodoroStatus(at: now)
                return DialContent(time: TimerText.clock(status.remaining.rounded(.up)),
                                   progress: status.progress,
                                   caption: paused
                                       ? "En pause · \(TimerText.clock(elapsed)) travaillées"
                                       : "Bloc \(status.blockNumber) · \(TimerText.clock(elapsed)) au total",
                                   tint: tint)
            }
            return DialContent(time: TimerText.clock(elapsed),
                               progress: nil,
                               caption: paused ? "En pause" : nil,
                               tint: tint)
        }
    }

    private var nextBlockNumber: Int {
        let accumulated = focus.state?.accumulated ?? 0
        return Int((accumulated / pomodoroSettings.blockDuration).rounded()) + 1
    }

    private func dialSection(now: Date) -> some View {
        let content = dialContent(now: now)
        let phase = focus.phase(at: now)
        return VStack(spacing: Layout.sectionSpacing) {
            TimerDial(time: content.time,
                      progress: content.progress,
                      tint: content.tint,
                      isRunning: focus.isRunning || phase.isBreak,
                      caption: content.caption,
                      // Le contexte est déjà dans les pastilles au-dessus : le
                      // répéter dans le cadran n'était que du bruit.
                      context: nil,
                      elapsed: focus.elapsed(at: now),
                      isAdjusting: isAdjusting,
                      onAdjust: { focus.adjust(by: $0) },
                      onSet: { total in
                          focus.setElapsed(total)
                          Haptics.success()
                      })
                .frame(maxWidth: .infinity)

            if focus.isPomodoro {
                PomodoroDots(total: max(2, pomodoroSettings.longBreakEvery),
                             completed: completedInCycle,
                             isOnBreak: phase.isBreak,
                             tint: content.tint)
            }

            controls(phase: phase)
        }
    }

    /// Blocs terminés dans le cycle en cours (jusqu'à la pause longue).
    private var completedInCycle: Int {
        let every = max(2, pomodoroSettings.longBreakEvery)
        let done = Int(((focus.state?.accumulated ?? 0) / pomodoroSettings.blockDuration).rounded(.down))
        guard done > 0 else { return 0 }
        let inCycle = done % every
        // Pile sur la pause longue : le cycle est plein, pas vide.
        return inCycle == 0 ? every : inCycle
    }

    // MARK: Boutons

    @ViewBuilder
    private func controls(phase: FocusPhase) -> some View {
        HStack(alignment: .top, spacing: Layout.sectionSpacing) {
            // À gauche : l'action rare. Abandonner, ou allonger la pause.
            if phase.isBreak {
                TimerSideButton(title: "+5 min", icon: "plus") {
                    focus.extendBreak(minutes: 5)
                    Haptics.tap()
                }
            } else {
                TimerSideButton(title: "Abandonner", icon: "xmark", role: .destructive,
                                isEnabled: focus.hasSession) {
                    confirmingDiscard = true
                }
            }

            primaryButton(phase: phase)

            // À droite : conclure.
            TimerSideButton(title: "Terminer", icon: "checkmark",
                            isEnabled: focus.hasSession && focus.elapsed() >= 1) {
                finish()
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func primaryButton(phase: FocusPhase) -> some View {
        switch phase {
        case .onBreak:
            TimerPrimaryButton(title: "Reprendre", icon: "forward.fill", tint: .teal) {
                focus.skipBreak()
            }
        case .readyForBlock(let block):
            TimerPrimaryButton(title: "Bloc \(block)", icon: "play.fill", tint: tint) {
                focus.resume()
            }
        case .working:
            TimerPrimaryButton(title: "Pause", icon: "pause.fill", tint: tint) {
                focus.pause()
            }
        case .paused:
            TimerPrimaryButton(title: "Reprendre", icon: "play.fill", tint: tint) {
                focus.resume()
            }
        case .idle:
            TimerPrimaryButton(title: "Démarrer", icon: "play.fill", tint: tint) {
                focus.start(courseID: draftCourseID,
                            taskType: draftTaskType,
                            targetID: draftTargetID,
                            pomodoro: focus.isPomodoro)
            }
        }
    }

    // MARK: Ajustement

    private var adjustPanel: some View {
        VStack(alignment: .leading, spacing: Layout.block) {
            HStack {
                Text("Corriger le temps compté")
                    .font(.headline)
                Spacer()
                Button("OK") {
                    withAnimation(Motion.snappy) { isAdjusting = false }
                    Haptics.tap()
                }
                .font(.subheadline.weight(.semibold))
            }
            // Trois façons, du plus grossier au plus fin : les boutons pour un
            // rattrapage courant, le glissement pour ajuster à la minute, le
            // champ pour une valeur exacte.
            HStack(spacing: Layout.control) {
                adjustButton("− 5 min", delta: -300)
                adjustButton("+ 5 min", delta: 300)
                adjustButton("+ 15 min", delta: 900)
            }
            Text("Fais glisser le point autour de l'anneau, ou touche le temps pour le saisir.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Layout.gutter)
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }

    private func adjustButton(_ title: String, delta: TimeInterval) -> some View {
        Button {
            focus.adjust(by: delta)
            Haptics.tap()
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.vertical, Layout.snug)
        }
        .buttonStyle(.bordered)
    }

    // MARK: Note

    private var noteField: some View {
        HStack(alignment: .top, spacing: Layout.control) {
            Image(systemName: "text.alignleft")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            TextField("Ajouter une note à la session…", text: noteBinding, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
        }
        .padding(Layout.gutter)
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }

    // MARK: Raccourcis

    private var effectiveShortcuts: [FocusShortcut] {
        let stored = FocusShortcutDefaults.sanitize(app.settings.focusShortcuts,
                                                    knownCourses: Set(courses.map(\.displayCode)))
        if !stored.isEmpty { return stored }
        return FocusShortcutDefaults.make(from: trackedCourses.map(\.displayCode))
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        let shortcuts = effectiveShortcuts
        if !shortcuts.isEmpty {
            VStack(alignment: .leading, spacing: Layout.control) {
                HStack {
                    Text("Démarrer en un toucher")
                        .font(.headline)
                    Spacer()
                    Button("Modifier") { showingShortcutEditor = true }
                        .font(.subheadline)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Layout.control)],
                          spacing: Layout.control) {
                    ForEach(shortcuts) { shortcut in
                        shortcutTile(shortcut)
                    }
                }
            }
        }
    }

    private func shortcutTile(_ shortcut: FocusShortcut) -> some View {
        let course = courses.first { $0.displayCode == shortcut.courseCode }
        let tint = course.map { Color(hex: $0.colorHex) } ?? Theme.accent
        return Button {
            Haptics.tap()
            startOrConfirm(FocusRequest(courseID: course?.id,
                                 courseCode: shortcut.courseCode,
                                 taskType: shortcut.taskType,
                                 label: ""))
        } label: {
            HStack(spacing: Layout.control) {
                Image(systemName: shortcut.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint.badgeInk)
                    .frame(width: 36, height: 36)
                    .background(tint.badgeFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(shortcut.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(tint.accessibleMark)
            }
            .padding(Layout.block)
            .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .accessibilityLabel("Démarrer \(shortcut.title), \(shortcut.subtitle)")
    }

    // MARK: Aujourd'hui

    @ViewBuilder
    private var todaySummary: some View {
        let start = DateUtils.startOfDay(Date())
        let today = sessions.filter { $0.startedAt >= start }
        let seconds = today.reduce(0) { $0 + $1.durationSeconds }
        if seconds > 0 {
            HStack(spacing: Layout.snug) {
                Image(systemName: "sum")
                    .font(.caption)
                Text("Aujourd'hui : \(DateUtils.hoursLabel(seconds: seconds)) · \(today.count) session\(today.count > 1 ? "s" : "")")
                    .font(.footnote)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Actions

    private func finish() {
        guard let seconds = focus.finish() else { return }
        isAdjusting = false
        Haptics.success()
        savedMessage = "Session enregistrée · \(DateUtils.durationLabel(seconds: seconds))"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            savedMessage = nil
        }
    }

    /// Une demande venue d'ailleurs (dock, « Démarrer » d'une tâche, Siri).
    private func applyRequest() {
        guard let pending = app.router.consumeFocusRequest() else { return }
        startOrConfirm(pending)
    }

    /// Démarre tout de suite, ou demande quoi faire de la session en cours.
    private func startOrConfirm(_ request: FocusRequest) {
        let resolved = resolve(request)
        if focus.hasSession,
           resolved.courseID != focus.state?.courseID || resolved.taskType != focus.state?.taskType {
            pendingStart = resolved
            return
        }
        begin(resolved)
    }

    private func begin(_ request: FocusRequest) {
        draftCourseID = request.courseID
        draftTaskType = request.taskType
        draftTargetID = nil
        focus.start(courseID: request.courseID,
                    taskType: request.taskType,
                    label: request.label)
    }

    /// Retrouve le cours par son code quand la demande n'a pas d'identifiant.
    private func resolve(_ request: FocusRequest) -> FocusRequest {
        guard request.courseID == nil, !request.courseCode.isEmpty else { return request }
        var resolved = request
        resolved.courseID = courses.first {
            $0.code.caseInsensitiveCompare(request.courseCode) == .orderedSame
                || $0.displayCode.caseInsensitiveCompare(request.courseCode) == .orderedSame
        }?.id
        return resolved
    }

    #if DEBUG
    /// `-course CS-250 -pomodoro -timerSeconds 600` : `xcrun simctl` ne sait pas
    /// taper, c'est le seul moyen de capturer un chrono en marche.
    private func applyDebugLaunch() {
        if let code = PreviewLaunch.string(PreviewLaunch.courseFlag),
           let match = courses.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
            draftCourseID = match.id
        }
        if PreviewLaunch.isSet(PreviewLaunch.pomodoroFlag), !focus.hasSession {
            focus.setPomodoro(true)
        }
        if let seconds = PreviewLaunch.int(PreviewLaunch.timerSecondsFlag), !focus.hasSession {
            focus.start(courseID: draftCourseID, taskType: draftTaskType,
                        pomodoro: PreviewLaunch.isSet(PreviewLaunch.pomodoroFlag))
            focus.setElapsed(TimeInterval(seconds))
        }
    }
    #endif

    // MARK: Cibles

    /// Une cible proposée au chrono : un exercice ou un élément de théorie.
    private struct TargetOption: Identifiable {
        let id: UUID
        let label: String
    }

    /// Ce qu'on peut préciser pour ce cours et ce type de travail : les
    /// exercices pour un travail d'exercice ou de correction, la théorie pour le
    /// reste — et rien pour un type qui ne s'y prête pas.
    private func targetOptions(for course: Course) -> [TargetOption] {
        switch taskType {
        case .exercise, .correction:
            return course.allExercises
                .sorted { $0.displayNumber.localizedStandardCompare($1.displayNumber) == .orderedAscending }
                .map { TargetOption(id: $0.id, label: "Exercice \($0.displayNumber)") }
        case .video, .theory, .summary:
            return course.sortedTheoryItems
                .map { TargetOption(id: $0.id, label: $0.displayNumber) }
        default:
            return []
        }
    }

    private var targetLabel: String? {
        guard let course, let targetID else { return nil }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return "Ex. \(exercise.displayNumber)"
        }
        return course.theoryItems.first { $0.id == targetID }?.displayNumber
    }
}

/// Les blocs du cycle, en pastilles : combien sont faits avant la pause longue.
///
/// Le Pomodoro ne se lisait qu'en texte (« Bloc 3 »). Des pastilles disent en
/// un regard où l'on en est du cycle, et quand viendra la vraie pause.
struct PomodoroDots: View {
    var total: Int
    var completed: Int
    var isOnBreak: Bool
    var tint: Color

    var body: some View {
        HStack(spacing: Layout.inline) {
            ForEach(0..<total, id: \.self) { index in
                let done = index < completed
                let current = index == completed && !isOnBreak
                Capsule()
                    .fill(done ? tint.accessibleMark : tint.badgeFill)
                    .frame(width: current ? 22 : 8, height: 8)
                    .overlay {
                        if current {
                            Capsule().strokeBorder(tint.accessibleMark, lineWidth: 1.5)
                        }
                    }
            }
        }
        .animation(Motion.snappy, value: completed)
        .animation(Motion.snappy, value: isOnBreak)
        .accessibilityElement()
        .accessibilityLabel("\(min(completed, total)) blocs sur \(total) avant la pause longue")
    }
}
