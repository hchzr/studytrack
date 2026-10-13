import SwiftUI
import SwiftData

/// Le bureau du mode étude : une barre en haut (ce qui reste, sur quoi, les
/// gestes), une colonne d'outils à gauche, l'outil choisi au centre. Tout est
/// natif — la série en PDF, le cours (StudyTrack, Moodle, Botafogo), Claude
/// par l'abonnement, la calculatrice ; le navigateur reste pour le reste.
struct StudyWorkspace: View {
    @Bindable var screen: StudyModeController.Screen
    @Bindable var browser: StudyBrowserModel
    @Bindable var desk: StudyDesk
    let courses: [Course]

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings

    private var course: Course? { courses.first { $0.id == timer.courseID } }
    private var tint: Color { MacTargets.tint(course) }

    var body: some View {
        VStack(spacing: 0) {
            StudyTopBar(course: course, tint: tint)
            Rectangle().fill(Carnet.rule).frame(height: 1)
            HStack(spacing: 0) {
                StudyRail(desk: desk, browser: browser, course: course)
                Rectangle().fill(Carnet.rule).frame(width: 1)
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Carnet.ground.opacity(desk.pane == .desk ? 0 : 1))
            }
        }
        .overlay(alignment: .top) { blockedToast }
        .background(paneShortcuts)
        .sheet(item: $desk.signIn) { site in
            SignInSheet(site: site) { desk.signedIn(site) }
        }
        // En entrant dans le bureau : chaque site, sans rien afficher, avec la
        // session Microsoft déjà là (rien ne se passe si elle n'y est pas).
        .task {
            if !EPFLConnect.shared.allConnected { await EPFLConnect.shared.connectAll() }
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch desk.pane {
        case .desk:
            StudyDeskHome(course: course, tint: tint, desk: desk, open: open)
        case .exercise, .course:
            if desk.sideBySide {
                HSplitView {
                    CoursePane(course: course, desk: desk, openWeb: openWeb)
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    ExercisePane(course: course, desk: desk, openWeb: openWeb, compact: true)
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if desk.pane == .exercise {
                ExercisePane(course: course, desk: desk, openWeb: openWeb)
            } else {
                CoursePane(course: course, desk: desk, openWeb: openWeb)
            }
        case .claude:
            ClaudePane(course: course, courses: courses, desk: desk)
        case .calc:
            CalcPane(desk: desk, openWeb: openWeb)
        case .web:
            if browser.tabs.isEmpty {
                StudyWebHome(course: course, open: open)
            } else {
                StudyBrowserPane(browser: browser, tint: tint) { desk.pane = .desk }
                    .padding(14)
            }
        }
    }

    private func toggleSideBySide() {
        desk.sideBySide.toggle()
        if desk.sideBySide, desk.pane != .course, desk.pane != .exercise { desk.pane = .exercise }
    }

    private func openWeb(_ url: URL, _ title: String) {
        browser.open(url, title: title)
        desk.pane = .web
    }

    /// Un outil : un site → l'onglet Web, une app → l'app, sinon le bon onglet.
    private func open(_ tool: StudyMode.Tool) {
        switch tool.kind {
        case .web(let url):
            openWeb(url, tool.title)
        case .app(let bundleID, _):
            StudyModeController.shared.openApp(bundleID: bundleID)
        }
    }

    /// ⌘1 à ⌘6 : les outils ; ⌘\\ : le cours et la série côte à côte.
    private var paneShortcuts: some View {
        ZStack {
            ForEach(StudyDesk.Pane.allCases) { pane in
                Button("") { desk.pane = pane }
                    .keyboardShortcut(pane.shortcut, modifiers: [.command])
            }
            Button("") { toggleSideBySide() }
                .keyboardShortcut("\\", modifiers: [.command])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var blockedToast: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let name = screen.blockedName, let at = screen.blockedAt, context.date.timeIntervalSince(at) < 4 {
                Label("\(name) est fermé", systemImage: "hand.raised.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(StudyPalette.ground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(StudyPalette.ink, in: Capsule())
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Barre du haut

private struct StudyTopBar: View {
    let course: Course?
    var tint: Color
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                StudyTimeline { date in
                    TimerRing(progress: StudyMode.progress(timer.state, at: date), tint: tint, lineWidth: 3)
                        .frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    StudyTimeline { date in
                        Text(StudyMode.remaining(timer.state, at: date).rounded(.up).clockLabel)
                            .font(Carnet.clock(22))
                            .foregroundStyle(StudyPalette.ink)
                    }
                    Text("jusqu'à \(DateUtils.time.string(from: timer.state?.studyUntil ?? Date()))")
                        .font(.caption2).foregroundStyle(StudyPalette.inkTertiary)
                }
            }
            Rectangle().fill(StudyPalette.rule).frame(width: 1, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                if let course { CourseTag(code: course.displayCode, tint: tint) }
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(Carnet.serif(.headline))
                    .foregroundStyle(StudyPalette.ink)
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                Image(systemName: timer.phase == .onBreak ? "cup.and.saucer" : "timer")
                TimerClockText(font: .callout.monospacedDigit())
            }
            .font(.callout)
            .foregroundStyle(StudyPalette.inkSecondary)
            Spacer()
            Button {
                if timer.phase == .onBreak { timer.skipBreak() } else { timer.toggle() }
            } label: {
                Image(systemName: timer.phase == .running ? "pause.fill" : (timer.phase == .onBreak ? "forward.fill" : "play.fill"))
            }
            .buttonStyle(RoundButtonStyle(size: 34, prominent: true, tint: StudyPalette.ink))
            .help(timer.phase == .running ? "Pause" : "Reprendre")
            Button { timer.extendStudy(minutes: 25) } label: { Label("25 min", systemImage: "plus") }
                .buttonStyle(.paper)
            HoldButton(title: "Terminer", systemImage: "checkmark", hold: settings.studyHoldToLeave ? 1.5 : 0) {
                timer.finish()
            }
            Menu {
                Button("Mes cours") {
                    NSApp.setActivationPolicy(.regular)
                    NotificationCenter.default.post(name: .macOpenMainWindow, object: nil)
                }
                Divider()
                Button("Sortir, garder la session") { timer.leaveStudy() }
                Button("Abandonner", role: .destructive) { timer.discard() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(StudyPalette.inkSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(StudyPalette.raised.opacity(0.6))
    }
}

// MARK: - Colonne d'outils

private struct StudyRail: View {
    var desk: StudyDesk
    var browser: StudyBrowserModel
    let course: Course?
    @Environment(MacSettings.self) private var settings

    var body: some View {
        VStack(spacing: 6) {
            ForEach(StudyDesk.Pane.allCases) { pane in
                RailButton(title: pane.title, icon: pane.icon, selected: desk.pane == pane,
                           badge: pane == .web && !browser.tabs.isEmpty ? "\(browser.tabs.count)" : nil) {
                    desk.pane = pane
                }
                .help("\(pane.title) (⌘\(String(pane.shortcut.character)))")
            }
            RailButton(title: "Côte à côte", icon: "rectangle.split.2x1", selected: desk.sideBySide) {
                desk.sideBySide.toggle()
                if desk.sideBySide, desk.pane != .course, desk.pane != .exercise { desk.pane = .exercise }
            }
            .help("Cours et série côte à côte (⌘\\)")
            Spacer()
            Rectangle().fill(StudyPalette.rule).frame(width: 34, height: 1)
            ForEach(apps, id: \.self) { bundleID in
                Button {
                    StudyModeController.shared.openApp(bundleID: bundleID)
                } label: {
                    VStack(spacing: 3) {
                        if let icon = StudyModeController.icon(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                        }
                        Text(StudyModeController.name(for: bundleID)).font(.system(size: 9)).foregroundStyle(StudyPalette.inkTertiary)
                            .lineLimit(1)
                    }
                    .frame(width: 64)
                }
                .buttonStyle(.plain)
                .help(StudyModeController.name(for: bundleID))
            }
        }
        .padding(.vertical, 14)
        .frame(width: 76)
        .background(StudyPalette.raised.opacity(0.4))
    }

    /// Les apps permises et installées (sauf le Finder et la Calculette : le
    /// bureau a les siennes).
    private var apps: [String] {
        settings.studyApps.filter {
            $0 != "com.apple.finder" && $0 != "com.apple.calculator" && StudyModeController.isInstalled($0)
        }
    }
}

private struct RailButton: View {
    let title: String
    let icon: String
    let selected: Bool
    var badge: String?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                    .frame(width: 44, height: 34)
                    .background(selected ? StudyPalette.ink : (hovering ? StudyPalette.raisedMore : .clear),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(selected ? StudyPalette.ground : StudyPalette.ink)
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge).font(.system(size: 9, weight: .bold)).padding(3)
                                .background(Carnet.wrong, in: Circle()).foregroundStyle(.white).offset(x: 4, y: -4)
                        }
                    }
                Text(title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? StudyPalette.ink : StudyPalette.inkSecondary)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Bureau

/// L'accueil du bureau : le grand cadran, l'exercice, la suite — et les
/// raccourcis vers chaque outil.
private struct StudyDeskHome: View {
    let course: Course?
    var tint: Color
    var desk: StudyDesk
    var open: (StudyMode.Tool) -> Void
    @Environment(MacTimer.self) private var timer

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 40) {
                VStack(spacing: 26) {
                    StudyDial(tint: tint, size: 360)
                    StudyTargetCard(course: course, tint: tint)
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Ta session").font(Carnet.serif(.title2)).foregroundStyle(StudyPalette.ink)
                    step(1, "Revoir le cours", detail: theoryDetail, icon: "books.vertical", done: theoryLeft == 0) { desk.pane = .course }
                    step(2, "Faire la série", detail: seriesDetail, icon: "doc.text", done: series?.isComplete == true) {
                        if let next = nextExercise, let course { timer.retarget(courseID: course.id, taskType: .exercise, targetID: next.id) }
                        desk.pane = .exercise
                    }
                    step(3, "Bloqué ?", detail: "Un indice, ou fais vérifier ta copie", icon: "sparkle", done: false) { desk.pane = .claude }
                    step(4, "Débriefer", detail: "Post-mortem quand la série est corrigée", icon: "checklist", done: false) { desk.pane = .claude }
                    HStack(spacing: 8) {
                        mini(.calc)
                        mini(.web)
                        Button { desk.sideBySide = true; desk.pane = .exercise } label: {
                            Label("Côte à côte", systemImage: "rectangle.split.2x1")
                        }
                        .buttonStyle(.paper)
                    }
                    .padding(.top, 4)
                    accounts
                }
                .frame(width: 420)
            }
            .padding(40)
        }
    }

    // MARK: Le fil de la session

    private var series: ExerciseSeries? {
        if let current = course?.allExercises.first(where: { $0.id == timer.targetID })?.series { return current }
        let all = course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? []
        return all.first { $0.plannedWeek >= (course?.currentWeek ?? 0) && !$0.isComplete } ?? all.last
    }

    private var nextExercise: Exercise? { series.flatMap { ExerciseFlow.resumePoint(in: $0.sortedExercises) } }

    private var theoryLeft: Int {
        guard let course else { return 0 }
        return course.sortedTheoryItems.filter { $0.plannedWeek == course.currentWeek && !$0.isWatched }.count
    }

    private var theoryDetail: String {
        theoryLeft == 0 ? "À jour pour cette semaine" : "\(theoryLeft) à voir cette semaine"
    }

    private var seriesDetail: String {
        guard let series else { return "Pas de série" }
        let name = series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title
        return "\(name) · \(series.doneCount)/\(series.requiredExercises.count)" + (nextExercise.map { " · ensuite \($0.displayNumber)" } ?? "")
    }

    private func step(_ number: Int, _ title: String, detail: String, icon: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(done ? Carnet.correct.opacity(0.25) : StudyPalette.raisedMore)
                    if done { Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(Carnet.correct) }
                    else { Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(StudyPalette.ink) }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(StudyPalette.ink)
                    Text(detail).font(.caption).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: icon).foregroundStyle(StudyPalette.inkTertiary)
            }
            .padding(12)
            .background(StudyPalette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudyPalette.rule))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mini(_ pane: StudyDesk.Pane) -> some View {
        Button { desk.pane = pane } label: { Label(pane.title, systemImage: pane.icon) }
            .buttonStyle(.paper)
    }

    /// Les comptes EPFL : connectés sans rien demander, ou un bouton.
    private var accounts: some View {
        let connect = EPFLConnect.shared
        return HStack(spacing: 10) {
            ForEach(EPFLConnect.Site.allCases) { site in
                let state = connect.state(site)
                HStack(spacing: 4) {
                    Circle().fill(state == .connected ? Carnet.correct : (state == .failed ? Carnet.wrong : StudyPalette.inkTertiary))
                        .frame(width: 6, height: 6)
                    Text(site.title).font(.caption2).foregroundStyle(StudyPalette.inkSecondary)
                }
            }
            Spacer()
            if connect.isRunning {
                ProgressView().controlSize(.mini)
            } else if EPFLConnect.Site.allCases.contains(where: { connect.state($0) == .failed }) {
                Button("Se connecter") { desk.signIn = connect.state(.moodle) == .failed ? .moodle : .mediaspace }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(StudyPalette.ink)
            }
        }
        .padding(.top, 6)
    }

    private func shortcut(_ pane: StudyDesk.Pane, _ detail: String) -> some View {
        Button { desk.pane = pane } label: {
            HStack(spacing: 14) {
                Image(systemName: pane.icon)
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(StudyPalette.raisedMore, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundStyle(StudyPalette.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).font(.body.weight(.medium)).foregroundStyle(StudyPalette.ink)
                    Text(detail).font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                }
                Spacer()
                Text("⌘\(String(pane.shortcut.character))").font(.caption.monospacedDigit()).foregroundStyle(StudyPalette.inkTertiary)
            }
            .padding(12)
            .background(StudyPalette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudyPalette.rule))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// L'onglet Web vide : les sites permis du cours, à ouvrir.
private struct StudyWebHome: View {
    let course: Course?
    var open: (StudyMode.Tool) -> Void
    @Environment(MacSettings.self) private var settings

    var body: some View {
        let tools = StudyTools.tools(for: course, settings: settings).filter { !$0.isApp }
            + [StudyMode.Tool(id: "geogebra", title: "GeoGebra", subtitle: "Géométrie", icon: "compass.drawing",
                              kind: .web(URL(string: "https://www.geogebra.org/calculator")!))]
        VStack(alignment: .leading, spacing: 14) {
            Text("Sites permis").font(Carnet.serif(.title2)).foregroundStyle(StudyPalette.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(tools.filter(isAllowed)) { tool in
                    Button { open(tool) } label: {
                        HStack(spacing: 12) {
                            StudyToolIcon(tool: tool, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.title).foregroundStyle(StudyPalette.ink)
                                Text(tool.subtitle).font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(StudyPalette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudyPalette.rule))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Pour en ajouter : Réglages › Mode étude.")
                .font(.caption).foregroundStyle(StudyPalette.inkTertiary)
            Spacer()
        }
        .padding(32)
    }

    private func isAllowed(_ tool: StudyMode.Tool) -> Bool {
        guard case .web(let url) = tool.kind else { return false }
        return StudyMode.isAllowed(url: url, sites: settings.studySites)
    }
}
