import SwiftUI
import SwiftData

/// Focus : un chrono évident, catégorisé, plus le journal du jour.
struct FocusView: View {
    /// Présenté en feuille par le dock : le bouton qui la ferme.
    var onClose: (() -> Void)? = nil

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
    @State private var showingShortcutEditor = false
    /// Mode ajustement : le point de l'anneau se fait glisser.
    @State private var isAdjusting = false
    /// Raccourci en attente de confirmation, quand il remplacerait la session.
    @State private var pendingShortcut: FocusShortcut?

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

    /// Teinte du cadran : celle du cours, pour que le chrono se reconnaisse d'un
    /// coup d'œil sans lire le code.
    private var dialTint: Color {
        selectedCourse.map { Color(hex: $0.colorHex) } ?? Theme.accent
    }

    private var dialContext: String? {
        guard let course = selectedCourse else { return contextLabel.isEmpty ? nil : contextLabel }
        var parts = [course.displayCode, taskType.label]
        if let target = resolvedTarget().exercise?.displayNumber
            ?? resolvedTarget().theoryItem?.displayNumber {
            parts.append(target)
        }
        return parts.joined(separator: " · ")
    }

    /// Sous le temps : l'état Pomodoro, ou l'explication du geste.
    private var dialCaption: String? {
        if isAdjusting {
            return "+ / − 1 min par petit pas · un tour = 1 h"
        }
        return pomodoro ? pomodoroStatus.remainingLabel : nil
    }

    private var pomodoroStatus: PomodoroStatus {
        PomodoroEngine.status(elapsed: elapsed, focusMinutes: app.settings.pomodoroFocusMinutes)
    }

    /// Temps déjà travaillé aujourd'hui, toutes sessions confondues.
    private var todaySessions: [StudySession] {
        let start = DateUtils.startOfDay(Date())
        return sessions.filter { $0.startedAt >= start }
    }

    private var todaySeconds: Int {
        todaySessions.reduce(0) { $0 + $1.durationSeconds }
    }

    private var sessionCount: Int { todaySessions.count }

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
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fermer", action: onClose)
                    }
                }
            }
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
                    contextLabel = "\(match.code) · \(taskType.label)"
                }
                // `-pomodoro -timerSeconds 600` : montre un chrono en marche dans
                // son bloc, ce que `simctl` ne peut pas provoquer sans taper.
                if PreviewLaunch.isSet(PreviewLaunch.pomodoroFlag) { pomodoro = true }
                if PreviewLaunch.isSet(PreviewLaunch.shortcutsFlag) { showingShortcutEditor = true }
                if let seconds = PreviewLaunch.int(PreviewLaunch.timerSecondsFlag) {
                    accumulated = TimeInterval(seconds)
                    startDate = Date()
                    sessionStartedAt = Date().addingTimeInterval(-TimeInterval(seconds))
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
            .sheet(isPresented: $showingShortcutEditor) {
                FocusShortcutsEditor()
            }

            .confirmationDialog("Remplacer la session en cours ?",
                                isPresented: Binding(get: { pendingShortcut != nil },
                                                     set: { if !$0 { pendingShortcut = nil } }),
                                titleVisibility: .visible) {
                Button("Enregistrer et changer", role: .destructive) {
                    if let shortcut = pendingShortcut {
                        let course = courses.first { $0.displayCode == shortcut.courseCode }
                        finish()
                        apply(shortcut, course: course)
                    }
                    pendingShortcut = nil
                }
                Button("Abandonner et changer", role: .destructive) {
                    if let shortcut = pendingShortcut {
                        let course = courses.first { $0.displayCode == shortcut.courseCode }
                        discard()
                        apply(shortcut, course: course)
                    }
                    pendingShortcut = nil
                }
                Button("Annuler", role: .cancel) { pendingShortcut = nil }
            } message: {
                Text("Le chrono tourne déjà. Que faire du temps en cours ?")
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
            // L'anneau de l'îlot apparaît et disparaît avec le mode : sans cette
            // republication, activer le Pomodoro en pleine session ne se voyait
            // que sur l'écran Focus.
            .onChange(of: pomodoro) { _, _ in
                schedulePomodoroIfNeeded()
                if isRunning { publishActivity() }
            }
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
            // Une commande venue de l'écran verrouillé a modifié l'état persisté :
            // l'écran doit le refléter sans qu'on le rouvre.
            .onReceive(NotificationCenter.default.publisher(for: FocusTimerCommandHandler.didChange)) { _ in
                restoreIfNeeded(force: true)
            }
        }
    }

    // MARK: Chrono

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Card {
                VStack(spacing: Layout.cardGap) {
                    // **Sur quoi** on travaille, avant de démarrer : le choix vivait
                    // sous le cadran, hors de l'écran, et la plupart des sessions
                    // partaient « sans cours ».
                    contextPickers

                    TimerDial(time: timeString(elapsed),
                              progress: pomodoro ? pomodoroStatus.progress : nil,
                              tint: dialTint,
                              isRunning: isRunning,
                              caption: dialCaption,
                              context: dialContext,
                              elapsed: elapsed,
                              isAdjusting: isAdjusting,
                              onAdjust: { applyAdjustment($0) },
                              onSet: { applyExact($0) })

                    if pomodoro {
                        pomodoroStrip
                    }

                    controls

                    if let problem = StudyActivityController.lastError, isRunning {
                        // Le chrono fonctionne sans Live Activity, mais on dit
                        // pourquoi elle n'apparaît pas : un ornement qui échoue en
                        // silence laisse croire à un bug du chrono.
                        Label(problem, systemImage: "platter.filled.top.and.arrow.up.iphone")
                            .font(.caption2)
                            .foregroundStyle(Color.orange.accessibleInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if todaySeconds > 0 {
                        Divider()
                        HStack(spacing: Layout.snug) {
                            Image(systemName: "sum")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Aujourd'hui : \(DateUtils.hoursLabel(seconds: todaySeconds))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: Layout.inline)
                            if sessionCount > 0 {
                                Text("\(sessionCount) session\(sessionCount > 1 ? "s" : "")")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Le cours et le type sont au-dessus du cadran ; ici, les précisions.
            Card(title: "Détails", icon: "text.alignleft") {
                VStack(alignment: .leading, spacing: 14) {
                    // « 2 h d'exercices sur CS-250 » ne dit pas si c'était la série 3
                    // ou la 5. Quand le cours et le type sont choisis, on propose
                    // donc les cibles concrètes.
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

                    TextField("Note (optionnel)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .onChange(of: selectedCourseID) { _, _ in targetID = nil }
            .onChange(of: taskType) { _, _ in targetID = nil }

            shortcutsCard
        }
    }

    // MARK: Chrono — fragments

    /// Cours et type de travail, en deux pastilles au-dessus du cadran.
    private var contextPickers: some View {
        HStack(spacing: Layout.inline) {
            Menu {
                Picker("Cours", selection: $selectedCourseID) {
                    Text("Sans cours").tag(UUID?.none)
                    ForEach(trackedCourses) { course in
                        Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                    }
                }
            } label: {
                contextChip(icon: "books.vertical.fill",
                            text: selectedCourse?.displayCode ?? "Choisir un cours",
                            tint: selectedCourse.map { Color(hex: $0.colorHex) } ?? .secondary)
            }
            .accessibilityLabel("Cours")
            .accessibilityValue(selectedCourse?.displayCode ?? "aucun")

            Menu {
                Picker("Type de travail", selection: $taskType) {
                    ForEach(TaskType.allCases) { type in
                        Label(type.label, systemImage: type.icon).tag(type)
                    }
                }
            } label: {
                contextChip(icon: taskType.icon, text: taskType.label, tint: taskType.tint)
            }
            .accessibilityLabel("Type de travail")
            .accessibilityValue(taskType.label)
        }
        .frame(maxWidth: .infinity)
    }

    private func contextChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: Layout.snug) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(text).font(.subheadline.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, Layout.block)
        .padding(.vertical, Layout.inline)
        .background(tint.badgeFill, in: Capsule())
        .foregroundStyle(tint.badgeInk)
    }

    /// Le pomodoro en une ligne : le bloc, les blocs terminés, ce qu'il reste.
    ///
    /// Le bloc était annoncé par une notification et rien d'autre : en regardant
    /// l'écran, on ne savait pas si on était au deuxième ou au cinquième.
    private var pomodoroStrip: some View {
        let status = pomodoroStatus
        return HStack(spacing: Layout.control) {
            Label(status.label, systemImage: "circle.hexagongrid.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.isBlockComplete ? Color.green.accessibleInk : Theme.accentInk)

            if status.completedBlocks > 0 {
                Text("\(status.completedBlocks) terminé\(status.completedBlocks > 1 ? "s" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Layout.inline)

            if status.isBlockComplete {
                Text("pause conseillée")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.green.accessibleInk)
            }
        }
        .padding(.horizontal, Layout.block)
        .padding(.vertical, Layout.snug)
        .background(Theme.softBackground, in: Capsule())
    }

    /// Deux actions, deux poids : celle qu'on fait dix fois est un disque, celle
    /// qu'on fait une fois est un bouton discret.
    private var controls: some View {
        VStack(spacing: Layout.block) {
            TimerPrimaryButton(isRunning: isRunning,
                               hasElapsed: elapsed > 0,
                               tint: dialTint) {
                isRunning ? pause() : start()
            }

            // Enregistrer et abandonner n'existent qu'une fois du temps compté :
            // deux boutons grisés au repos n'étaient que du bruit.
            if elapsed >= 1 {
                HStack(spacing: Layout.control) {
                    Button {
                        finish()
                    } label: {
                        Label("Enregistrer", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        discard()
                    } label: {
                        Label("Abandonner", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
                .transition(.opacity)
            }

            // Deux réglages vivants, à portée de pouce pendant la session.
            //
            // Le Pomodoro était un interrupteur enterré dans « Catégorisation » :
            // il fallait descendre pour le voir, et rien n'indiquait l'état quand il
            // était actif. Il est maintenant **sur** la carte du chrono.
            HStack(spacing: Layout.control) {
                Button {
                    pomodoro.toggle()
                    Haptics.tap()
                } label: {
                    HStack(spacing: Layout.snug) {
                        Image(systemName: pomodoro ? "circle.hexagongrid.fill" : "circle.hexagongrid")
                        Text(pomodoro
                             ? "Pomodoro \(app.settings.pomodoroFocusMinutes)/\(app.settings.pomodoroBreakMinutes)"
                             : "Pomodoro")
                            .font(.subheadline.weight(pomodoro ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(pomodoro ? dialTint.badgeFill : Color.secondary.opacity(0.12),
                                in: Capsule())
                    .foregroundStyle(pomodoro ? dialTint.badgeInk : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mode Pomodoro")
                .accessibilityValue(pomodoro ? "activé" : "désactivé")

                Button {
                    withAnimation(Motion.snappy) { isAdjusting.toggle() }
                    Haptics.tap()
                } label: {
                    HStack(spacing: Layout.snug) {
                        Image(systemName: isAdjusting
                              ? "checkmark.circle.fill" : "slider.horizontal.below.rectangle")
                        Text(isAdjusting ? "Terminé" : "Ajuster").font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isAdjusting ? Theme.accent.badgeFill : Color.secondary.opacity(0.12),
                                in: Capsule())
                    .foregroundStyle(isAdjusting ? Theme.accent.badgeInk : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isAdjusting ? "Terminer l'ajustement" : "Ajuster le temps compté")
            }

            if isAdjusting {
                VStack(alignment: .leading, spacing: Layout.control) {
                    // Trois façons, du plus grossier au plus fin : les boutons pour
                    // un rattrapage courant, le glissement pour ajuster à la minute,
                    // le champ pour une valeur exacte. Chacune est plus rapide que
                    // les autres selon ce qu'on veut faire.
                    HStack(spacing: Layout.control) {
                        adjustButton("− 5 min", delta: -300)
                        adjustButton("+ 5 min", delta: 300)
                        adjustButton("+ 15 min", delta: 900)
                    }

                    HStack(spacing: Layout.control) {
                        Button(role: .destructive) {
                            applyAdjustment(-elapsed)
                            Haptics.removed()
                        } label: {
                            Label("Zéro", systemImage: "arrow.counterclockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(elapsed < 1)

                        Text("Touche le temps pour le saisir, ou fais glisser le point.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Raccourcis

    /// Les raccourcis composés par l'étudiant·e, ou une proposition par défaut.
    private var effectiveShortcuts: [FocusShortcut] {
        let stored = FocusShortcutDefaults.sanitize(
            app.settings.focusShortcuts,
            knownCourses: Set(courses.map(\.displayCode)))
        if !stored.isEmpty { return stored }
        return FocusShortcutDefaults.make(from: trackedCourses.map(\.displayCode))
    }

    private var shortcutsCard: some View {
        Card(title: "Raccourcis", icon: "bolt.fill") {
            VStack(alignment: .leading, spacing: Layout.block) {
                if effectiveShortcuts.isEmpty {
                    Text("Ajoute un cours pour obtenir des raccourcis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Layout.control)],
                              spacing: Layout.control) {
                        ForEach(effectiveShortcuts) { shortcut in
                            shortcutTile(shortcut)
                        }
                    }
                }

                Button {
                    showingShortcutEditor = true
                } label: {
                    Label("Modifier les raccourcis", systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func shortcutTile(_ shortcut: FocusShortcut) -> some View {
        let course = courses.first { $0.displayCode == shortcut.courseCode }
        let tint = course.map { Color(hex: $0.colorHex) } ?? Theme.accent
        let isCurrent = isRunning
            && selectedCourseID == course?.id
            && taskType == shortcut.taskType

        Button {
            start(shortcut, course: course)
        } label: {
            VStack(alignment: .leading, spacing: Layout.snug) {
                HStack(spacing: Layout.snug) {
                    Image(systemName: shortcut.icon)
                        .font(.subheadline)
                        .foregroundStyle(tint.accessibleInk)
                    Spacer(minLength: 0)
                    if isCurrent {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(tint.accessibleInk)
                    }
                }
                Text(shortcut.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(shortcut.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.block)
            .background(tint.opacity(isCurrent ? 0.26 : 0.13),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isCurrent ? tint.accessibleMark : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(shortcut.title), \(shortcut.subtitle)\(isCurrent ? ", en cours" : "")")
    }

    /// Un raccourci lance le chrono **tout de suite**, ou demande confirmation
    /// s'il remplacerait une session en cours.
    private func start(_ shortcut: FocusShortcut, course: Course?) {
        Haptics.tap()
        if isRunning, selectedCourseID != course?.id || taskType != shortcut.taskType {
            pendingShortcut = shortcut
            return
        }
        apply(shortcut, course: course)
    }

    private func apply(_ shortcut: FocusShortcut, course: Course?) {
        selectedCourseID = course?.id
        taskType = shortcut.taskType
        targetID = nil
        contextLabel = "\(shortcut.courseCode) · \(shortcut.taskType.label)"
        if !isRunning { start() }
    }

    /// Un pas de temps, d'un tap.
    private func adjustButton(_ title: String, delta: TimeInterval) -> some View {
        Button {
            applyAdjustment(delta)
            Haptics.tap()
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    /// Fixe le temps **absolu** — ce que le champ éditable envoie.
    private func applyExact(_ total: TimeInterval) {
        let bounded = max(0, total)
        guard abs(bounded - elapsed) >= 0.5 else { return }
        accumulated = bounded
        startDate = isRunning ? Date() : nil
        now = Date()
        persist()
        publishActivity()
        Haptics.success()
    }

    /// Applique une **variation** au temps compté.
    ///
    /// Relative, et non absolue : viser une position sur l'anneau obligerait à
    /// savoir où l'on se trouve sur le tour, et un temps de plus d'une heure
    /// retomberait au même point. Un tour complet vaut une heure, dans un sens
    /// comme dans l'autre, quel que soit le total.
    private func applyAdjustment(_ delta: TimeInterval) {
        let total = max(0, elapsed + delta)
        guard abs(total - elapsed) >= 0.5 else { return }
        accumulated = total
        // La période en cours repart de maintenant : le chrono continue de tourner
        // à partir du nouveau total.
        startDate = isRunning ? Date() : nil
        now = Date()
        persist()
        publishActivity()
    }

    /// Abandonne la session en cours sans l'enregistrer.
    ///
    /// Il n'existait aucun moyen de renoncer : une session lancée par erreur
    /// devait être enregistrée pour libérer le chrono, et polluait les statistiques.
    private func discard() {
        startDate = nil
        accumulated = 0
        sessionStartedAt = nil
        note = ""
        contextLabel = ""
        targetID = nil
        pomodoroAnnounced = false
        FocusTimerStore.save(nil)
        StudyActivityController.end()
        app.presence.stop(context: context, social: app.social)
        Haptics.removed()
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
    private func restoreIfNeeded(force: Bool = false) {
        // `force` : une commande venue de l'écran verrouillé a changé l'état
        // persisté. Le garde une-fois-par-vie ne doit pas empêcher de le relire —
        // sinon mettre en pause depuis la Live Activity laisserait l'écran afficher
        // un chrono qui tourne.
        guard force || !restored else { return }
        restored = true
        guard let saved = FocusTimerStore.load() else {
            // Plus rien à restaurer : la session a été enregistrée ailleurs.
            startDate = nil
            accumulated = 0
            sessionStartedAt = nil
            return
        }
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
        // L'anneau de l'îlot se remplit tout seul pendant le bloc, mais le passage
        // au bloc suivant est un **changement d'état** : sans republication, il
        // resterait plein jusqu'à la prochaine pause.
        publishActivity()
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
        // Le widget ne se rafraîchissait qu'au changement d'onglet : une session
        // terminée n'y apparaissait qu'après être allé voir ailleurs.
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
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
            // Le compte de sous-questions et l'anneau Pomodoro sont composés par
            // le contrôleur, pas ici : c'est la même fonction que pour les
            // commandes venues de l'écran verrouillé, donc les deux chemins
            // publient exactement la même chose.
            state: StudyActivityController.makeState(
                elapsed: elapsed,
                running: startDate != nil,
                pomodoro: pomodoro,
                focusMinutes: app.settings.pomodoroFocusMinutes,
                exercise: target.exercise))
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
        WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
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
