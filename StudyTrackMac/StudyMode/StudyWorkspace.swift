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
    @Environment(\.modelContext) private var context
    /// L'horaire du jour, relu chaque minute (le cours en cours, la suite).
    @State private var classes: [ScheduledClass] = []
    @State private var toastVisible = false
    /// Relu toutes les 30 s : le bilan des cinq dernières minutes en dépend.
    @State private var now = Date()
    /// Le voile de pause / bilan qu'on a écarté (jusqu'au prochain changement).
    @State private var dismissedTakeover: DeskArrangement.Takeover?

    private var course: Course? { courses.first { $0.id == timer.courseID } }
    private var tint: Color { MacTargets.tint(course) }
    private var moment: DeskMoment {
        DeskSchedule.moment(taskType: timer.taskType, inGroup: timer.state?.groupSession != nil, course: course)
    }

    var body: some View {
        VStack(spacing: 0) {
            StudyTopBar(course: course, tint: tint, moment: moment, openMusic: { desk.pane = .music }, openResource: openResource)
            Rectangle().fill(Carnet.rule).frame(height: 1)
            HStack(spacing: 0) {
                StudyRail(desk: desk, browser: browser, course: course)
                Rectangle().fill(Carnet.rule).frame(width: 1)
                ZStack(alignment: .topLeading) {
                    DeskSplit(desk: desk) {
                        center
                    } side: {
                        side
                    }
                    ClaudeLayer(desk: desk) {
                        Frozen(key: course?.id) {
                            ClaudePane(course: course, courses: courses, desk: desk, accessory: AnyView(floatingClaudeButtons))
                        }
                        .equatable()
                    }
                }
            }
        }
        .overlay(alignment: .top) { blockedToast }
        .overlay { takeoverView }
        .animation(.smooth(duration: 0.3), value: layout.takeover)
        .onChange(of: layout.takeover) { _, _ in dismissedTakeover = nil }
        .onChange(of: arrangementKey) { _, _ in arrange(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: .studyTidyDesk)) { _ in arrange(force: true) }
        .task {
            arrange(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
        .overlay(alignment: .top) {
            if let notice = desk.dropNotice {
                Label(notice, systemImage: "iphone.and.arrow.forward")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: desk.dropNotice)
        .background(paneShortcuts)
        // Music suivi pendant toute la session (le petit lecteur de la barre du haut).
        .musicAttached()
        .sheet(item: $desk.signIn) { site in
            SignInSheet(site: site) { desk.signedIn(site) }
        }
        // En entrant dans le bureau : chaque site, sans rien afficher, avec la
        // session Microsoft déjà là (rien ne se passe si elle n'y est pas).
        .task {
            if !SchoolConnect.shared.allConnected { await SchoolConnect.shared.connectAll(prompting: true) }
        }
        // Claude prêt avant qu'on l'ouvre.
        .task { await desk.prepareClaude(settings: settings, courses: courses) }
        .task {
            while !Task.isCancelled {
                classes = DeskSchedule.today(context: context)
                let wake = DeskSchedule.nextChange(in: classes)
                try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow + 0.5)))
            }
        }
    }

    // MARK: Le bureau s'arrange

    /// Ce que le bureau sait du moment (voir `DeskArrangement`).
    private var arrangementContext: DeskArrangement.Context {
        var context = DeskArrangement.Context(moment: moment)
        context.isTheory = timer.taskType.canonical == .theory
        context.phase = !timer.isStudying ? .ended : (timer.phase == .onBreak ? .onBreak : (timer.phase == .paused ? .paused : .running))
        let exercise = course?.allExercises.first { $0.id == timer.targetID }
        context.hasTarget = exercise != nil
        context.targetDone = exercise?.isDone ?? false
        let series = exercise?.series
        context.seriesComplete = exercise != nil && (series?.isComplete ?? false)
        context.solutionAvailable = series.map { solutionAddress($0) != nil } ?? false
        if let series, let course { context.hasCopy = NotesStore.shared.copy(for: series, course: course, among: courses) != nil }
        context.hasCourseNotes = course != nil
        if !StudyMode.isOpenEnded(timer.state) { context.minutesLeft = Int(StudyMode.remaining(timer.state, at: now) / 60) }
        if moment == .lecture, let klass = DeskSchedule.latest(of: course?.id, in: classes),
           case .pause = LectureClock.phase(of: klass.slot, at: now) {
            context.classBreak = true
        }
        return context
    }

    private var layout: DeskArrangement.Layout { DeskArrangement.layout(for: arrangementContext) }
    private var arrangementKey: String { DeskArrangement.signature(arrangementContext) }

    /// À un changement de moment (ou « Ranger le bureau ») : le centre, le côté
    /// et Claude se mettent en place, sauf ce que l'étudiant·e a déplacé.
    private func arrange(force: Bool) {
        let key = arrangementKey
        desk.pins = DeskArrangement.pins(desk.pins, previous: desk.lastSignature, current: key)
        guard force || key != desk.lastSignature else { return }
        desk.lastSignature = key
        if force { desk.pins = DeskArrangement.Pins() }
        let wanted = layout
        let apply = DeskArrangement.applicable(wanted, pins: desk.pins)
        desk.applying = true
        defer { desk.applying = false }
        if let center = apply.center, let pane = StudyDesk.Pane(rawValue: center.rawValue) { desk.pane = pane }
        if let sides = apply.side {
            if let first = sides.compactMap(sideItem).first { desk.openSide(first) }
            desk.sideOpen = wanted.sideOpen
        }
        if apply.claude { desk.showClaude() }
    }

    /// Ce que `DeskArrangement.Side` ouvre : une entrée de ce que le volet propose déjà.
    private func sideItem(for side: DeskArrangement.Side) -> StudyDesk.SideItem? {
        let entries = sideSuggestions.flatMap(\.entries).map(\.item)
        switch side {
        case .series: return entries.first { $0.kind == .series }
        case .copy: return entries.first { if case .notebook = $0.kind { return true } else { return false } }
        case .solution: return entries.first { if case .reading(.pdf) = $0.kind { return $0.title == String(localized: "Corrigé") } else { return false } }
        case .courseNotes: return entries.first { $0.kind == .courseNotes }
        case .sheet: return entries.first { $0.kind == .sheet }
        }
    }

    // MARK: Ce qui prend l'écran

    @ViewBuilder
    private var takeoverView: some View {
        let kind = layout.takeover
        if kind != .none, dismissedTakeover != kind {
            ZStack {
                if kind != .wrapUp {
                    Color.black.opacity(0.4).ignoresSafeArea()
                        .onTapGesture { dismissedTakeover = kind }
                }
                VStack {
                    if kind == .wrapUp { Spacer() }
                    takeoverCard(kind)
                        .padding(kind == .wrapUp ? 24 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.opacity)
        }
    }

    private func takeoverCard(_ kind: DeskArrangement.Takeover) -> some View {
        let minutes = arrangementContext.minutesLeft ?? 0
        let title: String, detail: String, icon: String
        switch kind {
        case .onBreak:
            title = String(localized: "Pause"); detail = String(localized: "Lève les yeux. Le bloc suivant t'attend."); icon = "cup.and.saucer"
        case .paused:
            title = String(localized: "En pause"); detail = String(localized: "Le temps ne compte plus."); icon = "pause.circle"
        case .classBreak:
            title = String(localized: "Pause du cours"); detail = String(localized: "Le cours reprend dans quelques minutes."); icon = "person.wave.2"
        default:
            title = String(localized: "Plus que \(minutes) min"); detail = String(localized: "Note où tu t'arrêtes, ou prolonge."); icon = "hourglass"
        }
        return VStack(spacing: 14) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(StudyPalette.inkSecondary)
            Text(title).font(Carnet.serif(.title)).foregroundStyle(StudyPalette.ink)
            Text(detail).font(.callout).foregroundStyle(StudyPalette.inkSecondary)
            HStack(spacing: 10) {
                switch kind {
                case .onBreak:
                    Button("Écourter la pause") { timer.skipBreak() }.buttonStyle(.ink)
                    Button("Rester ici") { dismissedTakeover = kind }.buttonStyle(.paper)
                case .paused:
                    Button("Reprendre") { timer.resume() }.buttonStyle(.ink)
                    Button("Plus tard") { dismissedTakeover = kind }.buttonStyle(.paper)
                case .wrapUp:
                    if !StudyMode.isOpenEnded(timer.state) {
                        Button("Encore 25 min") { timer.extendStudy(minutes: 25) }.buttonStyle(.paper)
                    }
                    Button("D'accord") { dismissedTakeover = kind }.buttonStyle(.ink)
                default:
                    Button("D'accord") { dismissedTakeover = kind }.buttonStyle(.ink)
                }
            }
        }
        .padding(28)
        .frame(width: 380)
        .deskGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: Le centre

    /// Un outil à la fois ; ceux déjà ouverts restent vivants, cachés, et
    /// reviennent tels qu'on les a laissés.
    private var center: some View {
        // Chaque outil à une taille exacte : ce qui bouge dedans (une horloge,
        // l'avancée d'un morceau) n'oblige plus à recalculer la mise en page des
        // outils cachés à côté, ni celle du bureau.
        GeometryReader { geometry in
        ZStack {
            ForEach(StudyDesk.Pane.allCases.filter { desk.opened.contains($0) }) { which in
                let shown = desk.pane == which
                Group {
                    if which == .desk {
                        home
                    } else {
                        // Rendu une fois : changer d'outil, ouvrir le volet ou le
                        // redimensionner ne recalcule pas les outils cachés.
                        Frozen(key: [which.rawValue, course?.id.uuidString ?? ""]) { tool(which) }
                            .equatable()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .disabled(!shown)
                    .accessibilityHidden(!shown)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Carnet.ground.opacity(desk.pane == .desk ? 0 : 1))
    }

    @ViewBuilder
    private func tool(_ which: StudyDesk.Pane) -> some View {
        switch which {
        case .desk:
            home
        case .exercise:
            ExercisePane(course: course, desk: desk, openWeb: openWeb)
        case .course:
            CoursePane(course: course, desk: desk.sites, openWeb: openWeb, ask: { desk.ask($0, attachSeries: false) },
                       sendBeside: { reading, title in openBeside(reading, title: title) })
        case .notes:
            NotesPane(course: course, sendBeside: { path, title in
                desk.openSide(.init(kind: .notebook(path: path), title: title, icon: "pencil.and.scribble", courseID: course?.id))
            })
        case .calc:
            CalcPane(desk: desk.calc, openWeb: openWeb)
        case .music:
            MusicPane()
        case .web:
            if browser.tabs.isEmpty {
                StudyWebHome(course: course, open: open)
            } else {
                StudyBrowserPane(browser: browser, tint: tint) { desk.pane = .desk }
                    .padding(14)
            }
        }
    }

    /// Le Bureau : l'accueil selon le moment (en cours, révision, séance).
    @ViewBuilder
    private var home: some View {
        switch moment {
        case .lecture where course != nil:
            LectureDeskView(course: course!,
                            klass: DeskSchedule.latest(of: course?.id, in: classes),
                            next: DeskSchedule.next(in: classes),
                            hub: desk.sites, openCourse: openCourse,
                            openApp: { bundleID, _ in StudyModeController.shared.openApp(bundleID: bundleID) },
                            openWeb: openWeb)
        case .revision where course != nil:
            RevisionDeskView(course: course!, openCourse: openCourse) { exercise in
                timer.retarget(courseID: course?.id, taskType: .exercise, targetID: exercise.id)
                desk.pane = .exercise
            }
        default:
            StudyDeskHome(course: course, tint: tint, desk: desk, open: open)
        }
    }

    // MARK: À côté

    /// Les onglets d'à côté de ce cours (et Claude, de tous les cours).
    private var sideItems: [StudyDesk.SideItem] {
        desk.sideItems.filter { $0.courseID == nil || $0.courseID == course?.id }
    }

    private var side: some View {
        VStack(spacing: 0) {
            SideTabBar(desk: desk, items: sideItems, tint: tint)
            Rectangle().fill(Carnet.rule).frame(height: 1)
            GeometryReader { geometry in
            ZStack {
                if !sideItems.contains(where: { $0.id == desk.sideSelection }) {
                    SidePicker(groups: sideSuggestions, openIDs: sideItems, tint: tint) { item in
                        if item.kind == .claude { desk.dockClaude() } else { desk.openSide(item) }
                    }
                }
                ForEach(sideItems) { item in
                    let shown = item.id == desk.sideSelection
                    Frozen(key: [item.id.uuidString, course?.id.uuidString ?? ""]) { sideContent(item) }
                        .equatable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .disabled(!shown)
                        .accessibilityHidden(!shown)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background(Carnet.ground)
    }

    @ViewBuilder
    private func sideContent(_ item: StudyDesk.SideItem) -> some View {
        switch item.kind {
        case .series:
            if desk.pane == .exercise {
                SidePlaceholder(icon: "doc.text", text: "La série est au centre.",
                                action: ("Mettre le cours au centre", { desk.pane = .course }))
            } else {
                ExercisePane(course: course, desk: desk, openWeb: openWeb, compact: true)
            }
        case .claude:
            ClaudePane(course: course, courses: courses, desk: desk, accessory: AnyView(
                DeskIconButton(icon: "macwindow", help: "Détacher : Claude flotte par-dessus") { desk.floatClaude() }
            ))
        case .calc:
            CalcPane(desk: desk.calc, openWeb: openWeb)
        case .courseNotes:
            if let course {
                ScrollView { CourseNotesView(course: course).padding(18) }
            }
        case .sheet:
            if let course {
                RevisionSheetView(course: course, desk: desk.sites, openPoly: { path in openBeside(.botafogo(title: path, url: path), title: polyTitle(path)) },
                                  compact: true)
            }
        case .poly:
            if let course, let site = botafogoSite {
                BotafogoPairedPoly(book: desk.sites.botafogo(site), site: site, focus: focusSeries, desk: desk.sites, openWeb: openWeb,
                                   ask: { desk.ask($0, attachSeries: false) }, tint: Carnet.tint(course.colorHex))
            }
        case .notebook(let path):
            NotebookReader(path: path)
        case .reading(let reading):
            CoursePane(course: course, desk: desk.sites, openWeb: openWeb, ask: { desk.ask($0, attachSeries: false) }, document: reading)
        }
    }

    /// Ce qu'on peut ouvrir à côté, rangé : l'exercice, tes notes, le cours, les outils.
    private var sideSuggestions: [SidePicker.Group] {
        guard let course else { return [] }
        let id = course.id
        var groups: [SidePicker.Group] = []
        let series = currentSeries
        var work: [SidePicker.Entry] = []
        if let series {
            let name = series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title
            work.append(.init(item: .init(kind: .series, title: name, icon: "doc.text", courseID: id), detail: String(localized: "L'énoncé, les exercices, j'ai fini")))
            if let copy = NotesStore.shared.copy(for: series, course: course, among: courses) {
                work.append(.init(item: .init(kind: .notebook(path: copy.path), title: String(localized: "Ma copie"), icon: "pencil.and.scribble", courseID: id),
                                  detail: copy.title))
            }
            if let address = solutionAddress(series) {
                work.append(.init(item: .init(kind: .reading(.pdf(title: "Corrigé", address: address)), title: String(localized: "Corrigé"), icon: "checkmark.seal", courseID: id),
                                  detail: name))
            }
        }
        if botafogoSite != nil {
            work.append(.init(item: .init(kind: .poly, title: String(localized: "Polycopié"), icon: "book.closed", courseID: id),
                              detail: String(localized: "Ouvert sur la matière de la série")))
        }
        if !work.isEmpty { groups.append(.init(title: String(localized: "Pour l'exercice"), entries: work)) }

        var notes: [SidePicker.Entry] = [
            .init(item: .init(kind: .courseNotes, title: String(localized: "Notes du cours"), icon: "text.alignleft", courseID: id), detail: String(localized: "Markdown"))
        ]
        let copyPath = series.flatMap { NotesStore.shared.copy(for: $0, course: course, among: courses)?.path }
        for document in NotesStore.shared.documents(for: course, among: courses).filter({ $0.path != copyPath }).sorted(by: { $0.modified > $1.modified }).prefix(6) {
            notes.append(.init(item: .init(kind: .notebook(path: document.path), title: document.title, icon: "pencil.and.scribble", courseID: id),
                               detail: document.modified.formatted(.relative(presentation: .named))))
        }
        groups.append(.init(title: String(localized: "Tes notes"), entries: notes))

        var material: [SidePicker.Entry] = [
            .init(item: .init(kind: .sheet, title: String(localized: "Fiche"), icon: "list.bullet.rectangle", courseID: id), detail: String(localized: "Ta fiche de révision"))
        ]
        for resource in course.sortedResources.prefix(6) {
            let reading: CoursePane.Reading? = resource.kind == .poly ? .botafogo(title: resource.title, url: resource.address) : ResourceLibrary.reading(for: resource)
            guard let reading else { continue }
            material.append(.init(item: .init(kind: .reading(reading), title: resource.title, icon: resource.kind.icon, courseID: id),
                                  detail: String(localized: "Gardé")))
        }
        groups.append(.init(title: String(localized: "Le cours"), entries: material))

        var tools: [SidePicker.Entry] = [
            .init(item: .init(kind: .calc, title: String(localized: "Calcul"), icon: "function", courseID: nil), detail: String(localized: "La calculatrice"))
        ]
        if desk.claudePlacement == .floating {
            tools.append(.init(item: .init(kind: .claude, title: "Claude", icon: "sparkle", courseID: nil), detail: String(localized: "Ancré ici au lieu de flotter")))
        }
        groups.append(.init(title: String(localized: "Outils"), entries: tools))
        return groups
    }

    private var floatingClaudeButtons: some View {
        HStack(spacing: 0) {
            DeskIconButton(icon: "sidebar.right", help: "Ancrer à droite, dans le volet d'à côté") { desk.dockClaude() }
            DeskIconButton(icon: "minus", help: "Ranger Claude (⌘J)") { desk.claudeShown = false }
        }
    }

    // MARK: Ouvrir

    /// La série du moment : celle de l'exercice suivi, sinon celle de la semaine.
    private var currentSeries: ExerciseSeries? {
        if let current = course?.allExercises.first(where: { $0.id == timer.targetID })?.series { return current }
        let all = course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? []
        return all.first { $0.plannedWeek >= (course?.currentWeek ?? 0) && !$0.isComplete } ?? all.last
    }

    /// Le PDF du corrigé, une fois publié.
    private func solutionAddress(_ series: ExerciseSeries) -> String? {
        guard !series.solutionURLString.isEmpty, !BotafogoLinks.isPage(series.solutionURLString),
              series.solutionURLString != series.urlString,
              series.solutionsAt.map({ $0 <= Date() }) ?? true else { return nil }
        return series.solutionURLString
    }

    private var botafogoSite: URL? {
        course?.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }

    private func polyTitle(_ path: String) -> String {
        botafogoSite.flatMap { desk.sites.botafogo($0).section(path)?.title } ?? String(localized: "Polycopié")
    }

    /// La page Botafogo de la série de l'exercice en cours (le polycopié ouvert sur sa matière).
    private var focusSeries: String? {
        (currentSeries?.urlString).flatMap(BotafogoLinks.coursPath)
    }

    /// Un document du cours, gardé à côté.
    private func openBeside(_ reading: CoursePane.Reading, title: String) {
        let icon: String
        switch reading {
        case .pdf: icon = "doc.richtext"
        case .botafogo: icon = "book.closed"
        case .video, .edx, .edxMoment, .edxPlaylist: icon = "play.rectangle"
        case .edThread, .edLesson: icon = "bubble.left.and.bubble.right"
        default: icon = "doc"
        }
        desk.openSide(.init(kind: .reading(reading), title: title, icon: icon, courseID: course?.id))
    }

    /// Ouvre l'onglet Cours sur ce que l'accueil demande (diapositives, Ed…).
    private func openCourse(_ request: SiteHub.Request) {
        desk.sites.request = request
        desk.pane = .course
    }

    /// Une ressource gardée, ouverte **à côté** de ce qu'on fait : la fiche-
    /// résumé à côté de l'énoncé, sans quitter l'exercice.
    private func openResource(_ resource: SavedResource) {
        if resource.kind == .web, !resource.isFile, let url = URL(string: resource.address) {
            openWeb(url, resource.title)
            return
        }
        let reading: CoursePane.Reading? = resource.kind == .poly
            ? .botafogo(title: resource.title, url: resource.address)
            : ResourceLibrary.reading(for: resource)
        if let reading { openBeside(reading, title: resource.title) }
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

    /// ⌘1…⌘7 : l'outil du centre ; ⌘J : Claude ; ⌘\ : le volet d'à côté ;
    /// ⌃⇥ : l'onglet d'à côté suivant.
    private var paneShortcuts: some View {
        ZStack {
            ForEach(StudyDesk.Pane.allCases) { pane in
                Button("") { desk.pane = pane }
                    .keyboardShortcut(pane.shortcut, modifiers: [.command])
            }
            Button("") { desk.toggleClaude() }
                .keyboardShortcut("j", modifiers: [.command])
            Button("") { desk.sideOpen.toggle() }
                .keyboardShortcut("\\", modifiers: [.command])
            Button("") { desk.cycleSide(by: 1, among: sideItems) }
                .keyboardShortcut(.tab, modifiers: [.control])
            Button("") { desk.cycleSide(by: -1, among: sideItems) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Quatre secondes, puis plus rien : un minuteur unique, et non une
    /// horloge qui redessinait l'écran chaque seconde de toute la session.
    private var blockedToast: some View {
        ZStack {
            if toastVisible, let name = screen.blockedName {
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
        .animation(.smooth(duration: 0.3), value: toastVisible)
        .task(id: screen.blockedAt) {
            guard let at = screen.blockedAt else { return }
            let remaining = 4 - Date().timeIntervalSince(at)
            guard remaining > 0 else { return }
            toastVisible = true
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled { toastVisible = false }
        }
    }
}

// MARK: - Barre du haut

private struct StudyTopBar: View {
    let course: Course?
    var tint: Color
    var moment: DeskMoment
    var openMusic: () -> Void
    var openResource: (SavedResource) -> Void
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @State private var music = StudyMusic.shared

    /// Une seule horloge : à gauche la session (avec **son** bouton pause,
    /// dans la même pastille) puis sur quoi on travaille, à droite la musique
    /// et les sorties. Rien au milieu : en plein écran, l'encoche des MacBook
    /// y cache ce qu'on pose.
    var body: some View {
        HStack(spacing: 16) {
            sessionClock
            subject
                .frame(maxWidth: 360, alignment: .leading)
            Spacer(minLength: 24)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(StudyPalette.raised.opacity(0.6))
        // Suivie toute la session : la musique lancée dans Music apparaît
        // ici sans passer d'abord par l'onglet Musique.
        .musicAttached()
        .animation(.smooth(duration: 0.25), value: music.nowPlaying.hasTrack)
    }

    /// Le cours et la forme du bureau sur une ligne, la cible dessous.
    private var subject: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let course { CourseTag(code: course.displayCode, tint: tint) }
                momentMenu
                if let group = timer.state?.groupSession {
                    Label(group.groupName, systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(StudyPalette.inkSecondary)
                        .help("Chrono commun avec le groupe")
                }
            }
            Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                .font(Carnet.serif(19))
                .foregroundStyle(StudyPalette.ink)
                .lineLimit(1)
        }
    }

    /// La session : l'anneau, ce qui reste (ou depuis quand), et la pause.
    private var sessionClock: some View {
        let paused = timer.phase == .paused
        return HStack(spacing: 12) {
            StudyTimeline { date in
                TimerRing(progress: StudyMode.progress(timer.state, at: date), tint: tint, lineWidth: 3)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                StudyTimeline { date in
                    Text(StudyMode.clock(timer.state, at: date).clockLabel)
                        .font(Carnet.clock(20))
                        .foregroundStyle(paused ? StudyPalette.inkSecondary : StudyPalette.ink)
                }
                HStack(spacing: 4) {
                    Text(clockCaption)
                    // Le chrono de travail n'apparaît que quand il dit autre
                    // chose que la session : un bloc Pomodoro, une pause.
                    if timer.state?.pomodoro == true {
                        Text("·")
                        Image(systemName: timer.phase == .onBreak ? "cup.and.saucer" : "timer")
                        TimerClockText(font: .caption2.monospacedDigit())
                    }
                }
                .font(.caption2)
                .foregroundStyle(paused ? Carnet.review : StudyPalette.inkTertiary)
            }
            Button {
                if timer.phase == .onBreak { timer.skipBreak() } else { timer.toggle() }
            } label: {
                Image(systemName: timer.phase == .running ? "pause.fill" : (timer.phase == .onBreak ? "forward.fill" : "play.fill"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(StudyPalette.ground)
                    .frame(width: 30, height: 30)
                    .background(paused ? tint : StudyPalette.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(timer.phase == .running ? "Mettre la session en pause" : (timer.phase == .onBreak ? "Écourter la pause" : "Reprendre la session"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(StudyPalette.raisedMore, in: Capsule())
        .overlay(Capsule().strokeBorder(paused ? tint.opacity(0.6) : StudyPalette.rule))
        .fixedSize()
    }

    private var clockCaption: String {
        if timer.phase == .paused { return String(localized: "En pause") }
        if StudyMode.isOpenEnded(timer.state) {
            return "depuis \(DateUtils.time.string(from: timer.state?.studySince ?? Date()))"
        }
        return "jusqu'à \(DateUtils.time.string(from: timer.state?.studyUntil ?? Date()))"
    }

    private var trailing: some View {
        HStack(spacing: 12) {
            resourcesMenu
            // Ce qui joue dans Music : à part, séparé des gestes de la session.
            // Toujours là : au repos, il ouvre le choix de la musique.
            MusicMiniPlayer(open: openMusic)
            Rectangle().fill(StudyPalette.rule).frame(width: 1, height: 26)
            if timer.isLocked {
                // Sous verrou : une seule sortie, qu'on ne prend pas par réflexe.
                Image(systemName: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(StudyPalette.inkTertiary)
                    .help("Session verrouillée")
                HoldButton(title: "Sortie d'urgence", systemImage: "exclamationmark.triangle", hold: StudyMode.emergencyHold) {
                    timer.finish(emergency: true)
                }
                .help("Maintiens \(Int(StudyMode.emergencyHold)) secondes : la session s'enregistre, notée « sortie d'urgence ».")
            } else {
                HoldButton(title: "Terminer", systemImage: "checkmark", hold: settings.studyHoldToLeave ? 1.5 : 0) {
                    timer.finish()
                }
            }
            Menu {
                if !StudyMode.isOpenEnded(timer.state) {
                    Button { timer.extendStudy(minutes: 25) } label: { Label("Encore 25 min", systemImage: "plus") }
                    Divider()
                }
                Button("Ranger le bureau") { NotificationCenter.default.post(name: .studyTidyDesk, object: nil) }
                Button("Mes cours") {
                    NSApp.setActivationPolicy(.regular)
                    NotificationCenter.default.post(name: .macOpenMainWindow, object: nil)
                }
                if !timer.isLocked {
                    Divider()
                    Button("Sortir, garder la session") { timer.leaveStudy() }
                    Button("Abandonner", role: .destructive) { timer.discard() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(StudyPalette.inkSecondary)
        }
    }

    /// Les ressources gardées du cours, à un clic : elles s'ouvrent à côté.
    @ViewBuilder
    private var resourcesMenu: some View {
        if let course {
            Menu {
                if course.savedResources.isEmpty {
                    Text("Rien de gardé pour l'instant")
                    Text("Le signet en haut d'un document, ou Cours › Gardés")
                } else {
                    ForEach(course.sortedResources) { resource in
                        Button { openResource(resource) } label: {
                            Label(resource.title, systemImage: resource.isPinned ? "pin" : resource.kind.icon)
                        }
                    }
                }
            } label: {
                Image(systemName: course.savedResources.isEmpty ? "bookmark" : "bookmark.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(StudyPalette.inkSecondary)
            .help("Tes ressources gardées (elles s'ouvrent à côté)")
        }
    }

    /// La forme du bureau, à changer à la main : suivre le cours, faire la
    /// série, réviser. Le chrono continue ; le temps déjà compté reste.
    private var momentMenu: some View {
        Menu {
            Button { timer.retarget(courseID: timer.courseID, taskType: .lecture) } label: {
                Label(DeskMoment.lecture.title, systemImage: DeskMoment.lecture.icon)
            }
            Button { timer.retarget(courseID: timer.courseID, taskType: .exercise) } label: {
                Label(DeskMoment.series.title, systemImage: DeskMoment.series.icon)
            }
            Button { timer.retarget(courseID: timer.courseID, taskType: .theory) } label: {
                Label(course?.nextExam != nil ? DeskMoment.revision.title : TaskType.theory.label, systemImage: DeskMoment.revision.icon)
            }
        } label: {
            HStack(spacing: 4) {
                Text("·").foregroundStyle(StudyPalette.inkTertiary)
                Image(systemName: moment.icon)
                Text(moment.title)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(StudyPalette.inkSecondary)
            .contentShape(Rectangle())
        }
        .pillMenu()
        .disabled(course == nil)
        .help("La forme du bureau")
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
            Rectangle().fill(StudyPalette.rule).frame(width: 34, height: 1).padding(.vertical, 4)
            // Par-dessus ou à côté de l'outil du centre, sans le remplacer.
            RailButton(title: "Claude", icon: "sparkle", selected: desk.claudeVisible) { desk.toggleClaude() }
                .help(desk.claudePlacement == .floating ? "Claude, par-dessus (⌘J)" : "Claude, à droite (⌘J)")
                .contextMenu {
                    Button { desk.floatClaude() } label: { Label("Flottant", systemImage: "macwindow") }
                    Button { desk.dockClaude() } label: { Label("Ancré à droite", systemImage: "sidebar.right") }
                }
            RailButton(title: "À côté", icon: "sidebar.right", selected: desk.sideOpen) { desk.sideOpen.toggle() }
                .help("Le volet d'à côté : un cahier, l'énoncé, un PDF… (⌘\\)")
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
    /// Ouvert à côté (côte à côte) : marqué, sans être l'onglet principal.
    var beside = false
    var badge: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RailButtonLabel(title: title, icon: icon, selected: selected, beside: beside, badge: badge)
        }
        .buttonStyle(.plain)
    }
}

private struct RailButtonLabel: View {
    let title: String
    let icon: String
    let selected: Bool
    var beside = false
    var badge: String?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: selected ? .semibold : .regular))
                .frame(width: 44, height: 34)
                .background(selected ? StudyPalette.ink : (hovering ? StudyPalette.raisedMore : .clear),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if beside {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudyPalette.ink.opacity(0.7), lineWidth: 1.5)
                    }
                }
                .foregroundStyle(selected ? StudyPalette.ground : StudyPalette.ink)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 9, weight: .bold)).padding(3)
                            .background(Carnet.wrong, in: Circle()).foregroundStyle(.white).offset(x: 4, y: -4)
                    }
                }
            Text(title).font(.system(size: 10, weight: selected || beside ? .semibold : .regular))
                .foregroundStyle(selected || beside ? StudyPalette.ink : StudyPalette.inkSecondary)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - À côté

/// Une vue calculée une seule fois tant que sa clé ne change pas : ce qu'elle
/// montre se met à jour par ses propres données (le modèle observé), pas à
/// chaque rendu du bureau autour d'elle.
struct Frozen<Content: View>: View, Equatable {
    let key: AnyHashable
    @ViewBuilder let content: () -> Content

    init(key: some Hashable, @ViewBuilder content: @escaping () -> Content) {
        self.key = AnyHashable(key)
        self.content = content
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View { content() }
}

/// Le centre et le volet d'à côté. La largeur suit la souris pendant qu'on
/// tire la poignée (un état local : rien d'autre ne se recalcule), et n'est
/// gardée qu'au lâcher.
private struct DeskSplit<Center: View, Side: View>: View {
    var desk: StudyDesk
    @ViewBuilder var center: Center
    @ViewBuilder var side: Side
    @State private var liveWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let handle: CGFloat = desk.sideOpen ? 9 : 0
            let maximum = max(StudyDesk.sideMinimum, geometry.size.width - StudyDesk.centerMinimum - 9)
            let width = min(max(StudyDesk.sideMinimum, liveWidth ?? desk.sideWidth), maximum)
            let centerWidth = max(0, geometry.size.width - handle - (desk.sideOpen ? width : 0))
            // Des largeurs exactes : un outil qui ne veut pas rétrécir (la barre
            // de la série) ne pousse plus le volet hors de la fenêtre.
            HStack(spacing: 0) {
                // Un outil plus large que la place est coupé à droite, jamais
                // centré et coupé des deux côtés.
                center
                    .frame(width: centerWidth, height: geometry.size.height, alignment: .leading)
                    .clipped()
                if desk.sideOpen {
                    SplitHandle(width: width, minimum: StudyDesk.sideMinimum, maximum: maximum,
                                change: { liveWidth = $0 },
                                end: { desk.sideWidth = $0; liveWidth = nil },
                                reset: { desk.sideWidth = 460 })
                        .frame(width: 9)
                        .overlay { Rectangle().fill(Carnet.rule).frame(width: 1).allowsHitTesting(false) }
                }
                // Toujours là, à sa largeur, simplement masqué quand le volet est
                // fermé : ses onglets restent tels quels (la page du PDF, le cahier).
                side
                    .frame(width: width, height: geometry.size.height, alignment: .leading)
                    .frame(width: desk.sideOpen ? width : 0, alignment: .leading)
                    .clipped()
                    .opacity(desk.sideOpen ? 1 : 0)
                    .allowsHitTesting(desk.sideOpen)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
    }
}

/// La poignée du volet, en AppKit : une vraie zone de 9 points, le curseur
/// de redimensionnement, le suivi natif de la souris. Double-clic : la largeur
/// d'origine.
private struct SplitHandle: NSViewRepresentable {
    let width: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    var change: (CGFloat) -> Void
    var end: (CGFloat) -> Void
    var reset: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.width = width
        view.minimum = minimum
        view.maximum = maximum
        view.change = change
        view.end = end
        view.reset = reset
    }

    final class HandleView: NSView {
        var width: CGFloat = 0
        var minimum: CGFloat = 0
        var maximum: CGFloat = 0
        var change: ((CGFloat) -> Void)?
        var end: ((CGFloat) -> Void)?
        var reset: (() -> Void)?
        private var startX: CGFloat?
        private var startWidth: CGFloat = 0
        private var last: CGFloat = 0

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { reset?(); return }
            startX = event.locationInWindow.x
            startWidth = width
            last = width
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            NSCursor.resizeLeftRight.set()
            last = min(max(minimum, startWidth - (event.locationInWindow.x - startX)), maximum)
            change?(last)
        }

        override func mouseUp(with event: NSEvent) {
            guard startX != nil else { return }
            startX = nil
            end?(last)
        }
    }
}

/// Les onglets d'à côté, comme ceux d'un navigateur ; « + » ouvre la page
/// de choix (ce qu'on peut mettre à côté).
private struct SideTabBar: View {
    var desk: StudyDesk
    let items: [StudyDesk.SideItem]
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        SideTab(item: item, selected: item.id == desk.sideSelection, tint: tint,
                                select: { desk.sideSelection = item.id }, close: { desk.closeSide(item.id) })
                    }
                    let choosing = !items.contains { $0.id == desk.sideSelection }
                    Button { desk.sideSelection = nil } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 26)
                            .background(choosing ? Carnet.ground : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(choosing ? StudyPalette.ink : StudyPalette.inkSecondary)
                    .help("Ouvrir autre chose à côté")
                }
                .padding(.horizontal, 8)
            }
            DeskIconButton(icon: "sidebar.right", help: "Fermer le volet (⌘\\) — les onglets restent") { desk.sideOpen = false }
                .padding(.trailing, 6)
        }
        .frame(height: 40)
        .background(StudyPalette.raised.opacity(0.5))
    }
}

private struct SideTab: View {
    let item: StudyDesk.SideItem
    let selected: Bool
    let tint: Color
    var select: () -> Void
    var close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? tint : StudyPalette.inkTertiary)
            Text(item.title)
                .font(.callout.weight(selected ? .medium : .regular))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyPalette.inkSecondary)
            .opacity(selected || hovering ? 1 : 0)
            .help("Fermer l'onglet")
        }
        .foregroundStyle(selected ? StudyPalette.ink : StudyPalette.inkSecondary)
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 28)
        .background(selected ? Carnet.ground : (hovering ? StudyPalette.raisedMore : .clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(StudyPalette.rule)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .contextMenu { Button("Fermer l'onglet", action: close) }
    }
}

/// La page « nouvel onglet » d'à côté : ce qu'on peut y mettre, rangé.
private struct SidePicker: View {
    struct Entry: Identifiable {
        let item: StudyDesk.SideItem
        let detail: String
        var id: UUID { item.id }
    }

    struct Group: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    let groups: [Group]
    let openIDs: [StudyDesk.SideItem]
    let tint: Color
    var open: (StudyDesk.SideItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("À côté").font(Carnet.serif(26)).foregroundStyle(StudyPalette.ink)
                    Text("Ce que tu veux garder sous les yeux pendant que tu travailles au centre.")
                        .font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title.uppercased())
                            .font(.caption2.weight(.semibold)).tracking(1)
                            .foregroundStyle(StudyPalette.inkTertiary)
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                    }
                }
                Text("Dans le cours ou tes notes, « À côté » en haut d'un document l'ajoute ici.")
                    .font(.caption).foregroundStyle(StudyPalette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ entry: Entry) -> some View {
        let isOpen = openIDs.contains { $0.same(entry.item) }
        return Button { open(entry.item) } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(StudyPalette.raisedMore, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.item.title).foregroundStyle(StudyPalette.ink).lineLimit(1)
                    Text(entry.detail).font(.caption).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if isOpen {
                    Text("Ouvert").font(.caption2).foregroundStyle(StudyPalette.inkTertiary)
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskRowStyle())
    }
}

private struct DeskRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? StudyPalette.raisedMore : (hovering ? StudyPalette.raised : .clear),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

private struct SidePlaceholder: View {
    let icon: String
    let text: LocalizedStringKey
    var action: (LocalizedStringKey, () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.title).foregroundStyle(StudyPalette.inkTertiary)
            Text(text).foregroundStyle(StudyPalette.inkSecondary)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.paper)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Un cahier de tes notes, à côté ; relu quand GoodNotes le resauvegarde.
private struct NotebookReader: View {
    let path: String
    private var store: NotesStore { .shared }

    var body: some View {
        if let document = store.documents.first(where: { $0.path == path }), let url = store.url(document) {
            PDFPane(url: url, memory: url.absoluteString)
                .id("\(path)#\(document.modified.timeIntervalSince1970)")
                .overlay(alignment: .topTrailing) {
                    Button { Task { await store.refresh(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .help("Relire le cahier (sauvegardé \(document.modified.formatted(.relative(presentation: .named))))")
                }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await store.refresh() }
        }
    }
}

/// Un petit bouton d'icône, pour les en-têtes.
struct DeskIconButton: View {
    let icon: String
    let help: LocalizedStringKey
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudyPalette.inkSecondary)
        .help(help)
    }
}

// MARK: - Claude flottant

/// Claude par-dessus le bureau : on le déplace par sa poignée, on le
/// redimensionne par ses coins bas ; il garde sa place d'une session à l'autre.
/// Pendant le geste, la place est un état local (rien d'autre ne se
/// recalcule) ; elle n'est gardée qu'au lâcher.
private struct ClaudeLayer<Content: View>: View {
    var desk: StudyDesk
    @ViewBuilder var content: Content
    @State private var live: CGRect?
    @State private var gestureStart: CGRect?

    private static var minimum: CGSize { CGSize(width: 360, height: 380) }

    var body: some View {
        if desk.claudePlacement == .floating, desk.claudeOpened {
            GeometryReader { geometry in
                card(clamp(live ?? desk.claudeFrame, in: geometry.size))
            }
        }
    }

    /// Sa place, ramenée dans le bureau si la fenêtre a rétréci.
    private func clamp(_ stored: CGRect?, in bounds: CGSize) -> CGRect {
        let height = min(640, bounds.height - 40)
        var rect = stored ?? CGRect(x: bounds.width - 440 - 20, y: bounds.height - height - 20, width: 440, height: height)
        rect.size.width = min(max(rect.width, Self.minimum.width), max(Self.minimum.width, bounds.width - 16))
        rect.size.height = min(max(rect.height, Self.minimum.height), max(Self.minimum.height, bounds.height - 16))
        rect.origin.x = min(max(rect.minX, 8), max(8, bounds.width - rect.width - 8))
        rect.origin.y = min(max(rect.minY, 8), max(8, bounds.height - rect.height - 8))
        return rect
    }

    private func card(_ rect: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 0) {
            grabber(rect)
            content
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(shape)
        // L'ombre sur une simple forme, sous la conversation : la dessiner
        // d'après tout le contenu coûtait cher à chaque image.
        .background(shape.fill(Carnet.ground).shadow(color: .black.opacity(0.45), radius: 24, y: 10))
        .overlay(shape.strokeBorder(StudyPalette.rule).allowsHitTesting(false))
        .overlay(alignment: .bottomLeading) { corner(rect, leading: true) }
        .overlay(alignment: .bottomTrailing) { corner(rect, leading: false) }
        .scaleEffect(desk.claudeShown ? 1 : 0.96, anchor: .bottomTrailing)
        .opacity(desk.claudeShown ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: desk.claudeShown)
        .offset(x: rect.minX, y: rect.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(desk.claudeShown)
        .accessibilityHidden(!desk.claudeShown)
    }

    private func commit() {
        if let live { desk.claudeFrame = live }
        live = nil
        gestureStart = nil
    }

    /// La poignée : glisser pour déplacer.
    private func grabber(_ rect: CGRect) -> some View {
        Capsule()
            .fill(StudyPalette.inkTertiary.opacity(0.7))
            .frame(width: 40, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 16)
            .background(StudyPalette.raised.opacity(0.7))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = gestureStart ?? rect
                    if gestureStart == nil { gestureStart = rect }
                    live = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                }
                .onEnded { _ in commit() })
            .help("Glisser pour déplacer Claude")
    }

    /// Un coin bas : glisser pour redimensionner.
    private func corner(_ rect: CGRect, leading: Bool) -> some View {
        Color.clear
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = gestureStart ?? rect
                    if gestureStart == nil { gestureStart = rect }
                    let dx = value.translation.width, dy = value.translation.height
                    var next = start
                    next.size.height = max(Self.minimum.height, start.height + dy)
                    if leading {
                        let width = max(Self.minimum.width, start.width - dx)
                        next.origin.x = start.maxX - width
                        next.size.width = width
                    } else {
                        next.size.width = max(Self.minimum.width, start.width + dx)
                    }
                    live = next
                }
                .onEnded { _ in commit() })
            .help("Glisser pour redimensionner")
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
                    // La file de reprise passe avant le reste quand quelque chose est dû.
                    let due = course.map { SeriesReview.redoQueue([$0]).filter { ($0.redoDueAt ?? .distantFuture) <= Date() } } ?? []
                    if let first = due.first {
                        Button {
                            if let course { timer.retarget(courseID: course.id, taskType: .exercise, targetID: first.id) }
                            desk.pane = .exercise
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.counterclockwise.circle.fill").font(.title2).foregroundStyle(Carnet.review)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(due.count == 1 ? "Une reprise due : \(first.displayNumber)" : "\(due.count) reprises dues")
                                        .font(.callout.weight(.semibold)).foregroundStyle(StudyPalette.ink)
                                    Text("Sur papier, l'énoncé seul, sans tes notes — 15 min chacune").font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(StudyPalette.inkTertiary)
                            }
                            .padding(14)
                            .background(Carnet.review.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Carnet.review.opacity(0.35)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // Les étapes et leur ordre : Personnaliser › Ta session (les mêmes sur l'iPhone).
                    ForEach(Array(SessionFlow.load().steps.enumerated()), id: \.element) { index, item in
                        switch item {
                        case .course:
                            step(index + 1, item.title, detail: theoryDetail, icon: "books.vertical", done: theoryLeft == 0) { desk.pane = .course }
                        case .series:
                            step(index + 1, item.title, detail: seriesDetail, icon: "doc.text", done: series?.isComplete == true) {
                                if let next = nextExercise, let course { timer.retarget(courseID: course.id, taskType: .exercise, targetID: next.id) }
                                desk.pane = .exercise
                            }
                        case .help:
                            step(index + 1, item.title, detail: "Un indice, ou fais vérifier ta copie", icon: "sparkle", done: false) { desk.showClaude() }
                        case .debrief:
                            step(index + 1, item.title, detail: debriefDetail, icon: "checklist", done: false) { desk.showClaude() }
                        }
                    }
                    HStack(spacing: 8) {
                        mini(.calc)
                        mini(.web)
                        Button { desk.showClaude() } label: { Label("Claude", systemImage: "sparkle") }
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

    /// Clore la série : quand elle est finie, c'est le moment.
    private var debriefDetail: String {
        guard let series else { return String(localized: "Clore la série avec Claude quand elle est finie") }
        if series.requiredExercises.allSatisfy({ ExerciseStage($0).isDone }), series.exercises.contains(where: { $0.isDone && !$0.isCorrected }) {
            return String(localized: "La série est finie : clos-la avec Claude (corrections, erreurs, à refaire)")
        }
        return String(localized: "Quand la série est finie : corrections, erreurs, à refaire")
    }

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
        let connect = SchoolConnect.shared
        return HStack(spacing: 10) {
            ForEach(SchoolConnect.Site.allCases) { site in
                let state = connect.state(site)
                HStack(spacing: 4) {
                    Circle().fill(state == .connected ? Carnet.correct
                                  : state == .failed ? Carnet.wrong
                                  : state == .needsYou ? Carnet.review : StudyPalette.inkTertiary)
                        .frame(width: 6, height: 6)
                    Text(site.title).font(.caption2).foregroundStyle(StudyPalette.inkSecondary)
                }
            }
            Spacer()
            if connect.isRunning {
                ProgressView().controlSize(.mini)
            } else if let site = connect.signInSite {
                Button(site == .mediaspace ? "Mot de passe edu-ID" : "Confirmer que c'est toi") { desk.signIn = site }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(StudyPalette.ink)
            } else if SchoolConnect.Site.allCases.contains(where: { connect.state($0) == .failed }) {
                Button("Réessayer") { Task { await connect.connectAll(prompting: true) } }
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
