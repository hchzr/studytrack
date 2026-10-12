import SwiftUI
import SwiftData

/// Le papier de nuit du mode étude : `Carnet` en apparence sombre, toujours.
///
/// La fenêtre du mode étude est forcée en sombre (`StudyModeView` et sa
/// fenêtre) : un écran plein qui éblouit fatigue, et le soir comme le jour le
/// travail se lit mieux crème sur encre. Les couleurs dynamiques de `Carnet`
/// prennent alors leurs valeurs de nuit ; ces noms disent l'intention.
enum StudyPalette {
    static let ground = Carnet.ground
    static let raised = Carnet.sheet
    static let raisedMore = Carnet.sheetRaised
    static let rule = Carnet.rule
    static let ink = Carnet.ink
    static let inkSecondary = Carnet.inkSecondary
    static let inkTertiary = Carnet.inkTertiary
}

/// L'écran plein du mode étude : le choix avant de commencer, la session,
/// puis « c'est fait ».
struct StudyModeView: View {
    @Bindable var screen: StudyModeController.Screen
    var browser: StudyBrowserModel
    var desk: StudyDesk

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        ZStack {
            StudyBackground(tint: tint)
            switch screen.stage {
            case .setup:
                StudySetupView(screen: screen, courses: tracked)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .session:
                if timer.studyIsOver {
                    StudyDoneView()
                        .transition(.opacity)
                } else if timer.phase == .idle {
                    // La session a été terminée ailleurs : l'écran va se fermer.
                    ProgressView().controlSize(.large)
                } else {
                    StudyWorkspace(screen: screen, browser: browser, desk: desk, courses: tracked)
                        .transition(.opacity)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .tint(StudyPalette.ink)
        .animation(.smooth(duration: 0.35), value: screen.stage)
        .animation(.smooth(duration: 0.35), value: timer.studyIsOver)
        .onAppear {
            browser.sites = { [weak settings] in settings?.studySites ?? StudyMode.defaultSites }
            browser.locks = { [weak timer] in timer?.studyLocks ?? true }
        }
    }

    private var tint: Color {
        let id = screen.stage == .setup ? screen.courseID : timer.courseID
        return MacTargets.tint(tracked.first { $0.id == id })
    }
}

/// Le fond : le papier de nuit, et une lueur de la couleur du cours.
private struct StudyBackground: View {
    var tint: Color

    var body: some View {
        ZStack {
            StudyPalette.ground
            RadialGradient(colors: [tint.opacity(0.14), .clear], center: .topLeading, startRadius: 40, endRadius: 900)
            RadialGradient(colors: [tint.opacity(0.06), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Avant de commencer

private struct StudySetupView: View {
    @Bindable var screen: StudyModeController.Screen
    let courses: [Course]

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @State private var minutes = 50
    @State private var pomodoro = false

    private var course: Course? { courses.first { $0.id == screen.courseID } }
    private var tint: Color { MacTargets.tint(course) }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 10) {
                Kicker("Mode étude", color: tint)
                Text("On s'y met ?")
                    .font(Carnet.serif(52))
                    .foregroundStyle(StudyPalette.ink)
                Text("Seulement tes outils de cours, jusqu'à la fin.")
                    .font(.title3)
                    .foregroundStyle(StudyPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Sur quoi") {
                VStack(alignment: .leading, spacing: 12) {
                    FlowChips(spacing: 7) {
                        CourseChip(title: "Libre", color: StudyPalette.inkSecondary, selected: screen.courseID == nil) {
                            screen.courseID = nil
                            screen.targetID = nil
                        }
                        ForEach(courses) { item in
                            CourseChip(title: item.displayCode, color: Carnet.tint(item.colorHex), selected: screen.courseID == item.id) {
                                screen.courseID = item.id
                                screen.targetID = nil
                            }
                            .help(item.name)
                        }
                    }
                    HStack(spacing: 10) {
                        Picker("Travail", selection: $screen.taskType) {
                            ForEach(TaskType.choices) { Label($0.label, systemImage: $0.icon).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: screen.taskType) { _, _ in screen.targetID = nil }
                        if let course {
                            TargetMenu(course: course, taskType: screen.taskType, selection: $screen.targetID)
                        }
                    }
                }
            }

            field("Durée") {
                HStack(spacing: 8) {
                    ForEach(StudyMode.durations, id: \.self) { value in
                        Button {
                            minutes = value
                        } label: {
                            Text(value < 60 ? "\(value) min" : (value % 60 == 0 ? "\(value / 60) h" : "\(value / 60) h \(value % 60)"))
                                .font(.body.weight(minutes == value ? .semibold : .regular))
                                .foregroundStyle(minutes == value ? StudyPalette.ground : StudyPalette.ink)
                                .padding(.horizontal, 16)
                                .frame(height: 36)
                                .background(minutes == value ? StudyPalette.ink : StudyPalette.raisedMore, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    // Une durée libre, en minutes, ou une heure de fin.
                    TextField("min", value: Binding(get: { minutes },
                                                    set: { minutes = min(max($0, StudyMode.minuteRange.lowerBound), StudyMode.minuteRange.upperBound) }),
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .padding(.leading, 6)
                    Stepper("", value: $minutes, in: StudyMode.minuteRange, step: 5).labelsHidden()
                    Text("min, jusqu'à").foregroundStyle(StudyPalette.inkSecondary)
                    DatePicker("Jusqu'à", selection: Binding(get: { Date().addingTimeInterval(Double(minutes) * 60) },
                                                             set: { minutes = StudyMode.minutes(until: $0) }),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
            }

            field("Rythme") {
                Toggle(isOn: $pomodoro) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pomodoro").foregroundStyle(StudyPalette.ink)
                        Text("\(settings.focusMinutes) min de travail, \(settings.shortBreakMinutes) min de pause.")
                            .font(.caption)
                            .foregroundStyle(StudyPalette.inkSecondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(Carnet.correct)
                .disabled(timer.phase != .idle)
            }

            field("Blocage") {
                Toggle(isOn: Bindable(screen).locks) {
                    Text("Bloquer le reste").foregroundStyle(StudyPalette.ink)
                }
                .toggleStyle(.switch)
                .tint(Carnet.correct)
            }

            if screen.locks {
                field("Ouverts") {
                    StudyToolStrip(course: course)
                }
            }

            HStack(spacing: 12) {
                Button("Annuler") { StudyModeController.shared.cancelSetup() }
                    .buttonStyle(PaperButtonStyle(large: true))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(endLabel)
                    .font(.callout)
                    .foregroundStyle(StudyPalette.inkSecondary)
                Button {
                    settings.studyMinutes = minutes
                    settings.studyPomodoro = pomodoro
                    StudyModeController.shared.begin(minutes: minutes, pomodoro: pomodoro)
                } label: {
                    Label(timer.phase == .idle ? "Commencer" : "Verrouiller la session", systemImage: "lock.fill")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(InkButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(48)
        .frame(width: 660)
        .background(StudyPalette.raised.opacity(0.92), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(StudyPalette.rule))
        .onAppear {
            minutes = settings.studyMinutes
            pomodoro = timer.phase == .idle ? settings.studyPomodoro : (timer.state?.pomodoro ?? false)
        }
    }

    private var endLabel: String {
        "jusqu'à " + DateUtils.time.string(from: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Carnet.serif(.title3)).foregroundStyle(StudyPalette.ink)
            content()
        }
    }
}

/// Les outils permis, en petites icônes.
private struct StudyToolStrip: View {
    let course: Course?
    @Environment(MacSettings.self) private var settings

    var body: some View {
        let tools = StudyTools.tools(for: course, settings: settings)
        HStack(spacing: 14) {
            ForEach(tools.prefix(8)) { tool in
                VStack(spacing: 5) {
                    StudyToolIcon(tool: tool, size: 34)
                    Text(tool.title).font(.caption2).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1)
                }
                .frame(width: 70)
            }
        }
    }
}

// MARK: - La session

/// Le temps du mode étude : ce qui reste (wall clock, même en pause).
struct StudyTimeline<Content: View>: View {
    @Environment(MacTimer.self) private var timer
    var interval: TimeInterval = 1
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        let anchor = (timer.state?.studyUntil ?? Date()).addingTimeInterval(0.05)
        TimelineView(TickSchedule(anchor: anchor, interval: interval, active: timer.isStudying)) { context in
            content(context.date)
        }
    }
}

/// Le grand cadran : ce qui reste du mode étude, le temps de travail dessous.
struct StudyDial: View {
    @Environment(MacTimer.self) private var timer
    var tint: Color
    var size: CGFloat

    var body: some View {
        ZStack {
            StudyTimeline { date in
                TimerRing(progress: StudyMode.progress(timer.state, at: date), tint: tint, lineWidth: 5, graduated: true)
            }
            VStack(spacing: 8) {
                TimerTimeline { date in
                    Kicker(timer.phase == .paused ? "En pause" : (timer.statusLabel(at: date) ?? "Reste"),
                           color: timer.phase == .onBreak ? MacStyle.breakTint : tint)
                }
                StudyTimeline { date in
                    Text(StudyMode.remaining(timer.state, at: date).rounded(.up).clockLabel)
                        .font(Carnet.clock(size * 0.24))
                        .foregroundStyle(StudyPalette.ink)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Image(systemName: timer.phase == .onBreak ? "cup.and.saucer" : "timer")
                    TimerClockText(font: .callout.monospacedDigit())
                    Text(timer.state?.pomodoro == true ? (timer.phase == .onBreak ? "de pause" : "du bloc") : "de travail")
                }
                .font(.callout)
                .foregroundStyle(StudyPalette.inkSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Ce qu'on travaille : la cible, ses questions, la suite.
struct StudyTargetCard: View {
    let course: Course?
    var tint: Color
    @Environment(MacTimer.self) private var timer

    var body: some View {
        let exercise = course?.allExercises.first { $0.id == timer.targetID }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let course { CourseTag(code: course.displayCode, tint: tint) }
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(Carnet.serif(26))
                    .foregroundStyle(StudyPalette.ink)
                    .lineLimit(2)
                if let exercise, !exercise.title.isEmpty, exercise.title != exercise.displayNumber {
                    Text(exercise.title).foregroundStyle(StudyPalette.inkSecondary).lineLimit(2)
                }
            }
            if let exercise, exercise.hasSubQuestions {
                SubQuestionChecklist(exercise: exercise, tint: tint, onDark: true)
            }
            if let course, timer.phase != .onBreak {
                VStack(alignment: .leading, spacing: 4) {
                    Kicker("Ensuite")
                    UpNextList(course: course, limit: 3)
                }
            }
            if let exercise {
                HStack {
                    ExerciseQuickMark(exercise: exercise)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyPalette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(StudyPalette.rule))
    }
}

/// Un bouton qu'il faut tenir : le temps d'y penser.
struct HoldButton: View {
    let title: String
    var systemImage: String
    /// Secondes à tenir ; `0` : un clic suffit.
    var hold: Double
    var action: () -> Void

    @State private var progress: Double = 0
    @State private var pressing = false

    var body: some View {
        Label(pressing ? "Maintiens…" : title, systemImage: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(StudyPalette.ink)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StudyPalette.raisedMore)
                        Capsule().fill(Carnet.correct.opacity(0.55)).frame(width: proxy.size.width * progress)
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture { if hold == 0 { action() } }
            .onLongPressGesture(minimumDuration: max(hold, 0.01), maximumDistance: 30) {
                guard hold > 0 else { return }
                progress = 0
                action()
            } onPressingChanged: { isPressing in
                guard hold > 0 else { return }
                pressing = isPressing
                withAnimation(isPressing ? .linear(duration: hold) : .easeOut(duration: 0.2)) {
                    progress = isPressing ? 1 : 0
                }
            }
    }
}

// MARK: - Outils

/// Les outils de la session : les pages du cours, puis Moodle, Claude, GoodNotes…
@MainActor
enum StudyTools {
    static func tools(for course: Course?, settings: MacSettings) -> [StudyMode.Tool] {
        var links: [String] = []
        if let course {
            links.append(course.moodleURLString)
            links.append(contentsOf: course.contentSources)
        }
        var tools = StudyMode.tools(courseName: course?.name, courseLinks: links)
        // Seulement les apps permises et installées ; seulement les sites permis.
        tools.removeAll { tool in
            switch tool.kind {
            case .app(let bundleID, _):
                return !settings.studyApps.contains(bundleID) || !StudyModeController.isInstalled(bundleID)
            case .web(let url):
                return !StudyMode.isAllowed(url: url, sites: settings.studySites)
            }
        }
        // Les autres apps permises (Aperçu, Calculette…), après.
        let listed = Set(tools.compactMap { tool -> String? in
            if case .app(let id, _) = tool.kind { return id }
            return nil
        })
        for bundleID in settings.studyApps where !listed.contains(bundleID) && bundleID != "com.apple.finder"
            && StudyModeController.isInstalled(bundleID) {
            tools.append(StudyMode.Tool(id: "app:" + bundleID, title: StudyModeController.name(for: bundleID),
                                        subtitle: "App", icon: "app", kind: .app(bundleID: bundleID, scheme: "")))
        }
        return tools
    }
}

struct StudyToolIcon: View {
    let tool: StudyMode.Tool
    var size: CGFloat = 44

    var body: some View {
        switch tool.kind {
        case .app(let bundleID, _):
            if let image = StudyModeController.icon(for: bundleID) {
                Image(nsImage: image).resizable().frame(width: size, height: size)
            } else {
                symbol
            }
        case .web:
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: tool.icon)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(StudyPalette.ink)
            .frame(width: size, height: size)
            .background(StudyPalette.raisedMore, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

// MARK: - C'est fait

private struct StudyDoneView: View {
    @Environment(MacTimer.self) private var timer

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Carnet.correct)
            Text("C'est fait.")
                .font(Carnet.serif(60))
                .foregroundStyle(StudyPalette.ink)
            TimerTimeline(interval: 60) { date in
                Text("\(DateUtils.durationLabel(seconds: Int(timer.elapsed(at: date)))) de travail.")
                    .font(.title3)
                    .foregroundStyle(StudyPalette.inkSecondary)
            }
            HStack(spacing: 12) {
                Button { timer.leaveStudy() } label: { Text("Continuer sans") }
                    .buttonStyle(PaperButtonStyle(large: true))
                Button { timer.extendStudy(minutes: 25) } label: { Label("Encore 25 min", systemImage: "plus") }
                    .buttonStyle(PaperButtonStyle(large: true))
                Button { timer.finish() } label: { Label("Terminer", systemImage: "checkmark") }
                    .buttonStyle(InkButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(60)
    }
}

// MARK: - Le voile

/// Par-dessus une app fermée pendant le mode étude.
struct StudyShieldView: View {
    var screen: StudyModeController.Screen
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]

    var body: some View {
        let course = courses.first { $0.id == timer.courseID }
        ZStack {
            StudyPalette.ground.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(StudyPalette.inkSecondary)
                Text("\(screen.blockedName ?? "Cette app") attendra")
                    .font(Carnet.serif(48))
                    .foregroundStyle(StudyPalette.ink)
                StudyTimeline(interval: 60) { date in
                    Text("Encore \(StudyMode.remaining(timer.state, at: date).minuteLabel(roundingUp: true)).")
                        .font(.title3)
                        .foregroundStyle(StudyPalette.inkSecondary)
                }
                HStack(spacing: 14) {
                    ForEach(StudyTools.tools(for: course, settings: settings).filter(\.isApp).prefix(4)) { tool in
                        Button {
                            if case .app(let id, _) = tool.kind { StudyModeController.shared.openApp(bundleID: id) }
                        } label: {
                            HStack(spacing: 8) {
                                StudyToolIcon(tool: tool, size: 22)
                                Text(tool.title)
                            }
                        }
                        .buttonStyle(PaperButtonStyle(large: true))
                    }
                    Button {
                        StudyModeController.shared.returnToStudy()
                    } label: {
                        Label("Retour", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(InkButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 8)
            }
            .padding(60)
        }
        .environment(\.colorScheme, .dark)
    }
}

extension StudyMode.Tool {
    var isApp: Bool {
        if case .app = kind { return true }
        return false
    }
}

extension Notification.Name {
    static let macOpenMainWindow = Notification.Name("mac.openMainWindow")
}
