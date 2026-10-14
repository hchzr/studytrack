import AppKit
import SwiftUI
import SwiftData
import OSLog

/// Le mode étude sur le Mac : un écran plein, et le reste du Mac fermé.
///
/// **Comment le Mac est « bloqué ».** L'app est dans le bac à sable : elle ne
/// peut ni quitter ni masquer de force les autres apps. Elle fait donc comme
/// le Temps d'écran de l'iPhone : quand une app non permise passe au premier
/// plan (clic dans le Dock, ⌘Tab, Spotlight), un **voile** couvre tous les
/// écrans par-dessus elle — « Safari est fermé pendant le mode étude » — avec
/// de quoi revenir à l'étude ou ouvrir un outil permis. Les apps permises
/// (GoodNotes, Claude, Aperçu…) passent au-dessus de l'écran du mode étude
/// comme d'habitude ; les sites de cours s'ouvrent dans son navigateur, qui ne
/// suit que les adresses permises.
///
/// Rien n'est retenu ici : l'état est `FocusTimerState.studyUntil`, publié par
/// le chrono partagé. Ce contrôleur ne fait que suivre (`update()`, appelé à
/// chaque changement du chrono) : l'iPhone qui lance le mode étude ouvre cet
/// écran sur le Mac, et terminer la session le ferme partout.
@MainActor
final class StudyModeController: NSObject, NSWindowDelegate {
    static let shared = StudyModeController()

    weak var timer: MacTimer?
    weak var settings: MacSettings?
    var container: ModelContainer?

    /// Ce que montre l'écran : le choix avant de commencer, ou la session.
    @MainActor
    @Observable
    final class Screen {
        enum Stage: Equatable { case setup, session }
        var stage: Stage = .setup
        /// Ce que le choix propose d'abord (depuis une ligne « À faire »).
        var courseID: UUID?
        var taskType: TaskType = .exercise
        var targetID: UUID?
        var label = ""
        /// Bloquer le reste pendant cette session (le réglage, par défaut).
        var locks = true
        /// L'app arrêtée en dernier, pour le dire.
        var blockedName: String?
        var blockedAt: Date?
    }

    let screen = Screen()
    let browser = StudyBrowserModel()
    let desk = StudyDesk()

    private var window: NSWindow?
    private var shields: [NSWindow] = []
    private var activationObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    /// Les apps à qui l'on a demandé de quitter, et quand : pendant quelques
    /// secondes, on les laisse afficher « Enregistrer les modifications ? ».
    private var quitting: [pid_t: Date] = [:]
    private var blocking = false
    private let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "study")
    #if DEBUG
    /// `-studyPreview` : l'écran dans une fenêtre ordinaire, sans rien bloquer.
    private let previewOnly = CommandLine.arguments.contains("-studyPreview")
    #else
    private let previewOnly = false
    #endif

    // MARK: Ouvrir

    /// « Mode étude… » : l'écran s'ouvre sur le choix (ou sur la session si
    /// elle est déjà verrouillée).
    func presentSetup(courseID: UUID? = nil, taskType: TaskType? = nil, targetID: UUID? = nil, label: String = "") {
        guard let timer else { return }
        if timer.isStudying || timer.studyIsOver {
            present()
            return
        }
        screen.stage = .setup
        screen.courseID = courseID ?? timer.courseID
        screen.taskType = taskType ?? timer.taskType
        screen.targetID = targetID ?? (courseID == nil ? timer.targetID : nil)
        screen.label = label
        screen.locks = settings?.studyBlocking ?? true
        showWindow()
    }

    /// Revenir à l'écran du mode étude.
    func present() {
        screen.stage = .session
        showWindow()
    }

    /// Lancer : le chrono démarre (ou se verrouille), l'iPhone suit.
    func begin(minutes: Int, pomodoro: Bool) {
        guard let timer else { return }
        // Le vrai blocage : ce qui n'est pas permis se ferme (proprement — une
        // app avec un document non enregistré le demande d'abord).
        let locks = screen.locks
        if locks, settings?.studyCloseApps ?? true {
            for app in runningBlockedApps() { ask(app, toQuit: true, force: false) }
        }
        if timer.phase == .idle { timer.pomodoro = pomodoro }
        timer.enterStudy(minutes: minutes, courseID: screen.courseID, taskType: screen.taskType,
                         targetID: screen.targetID, label: screen.label, locks: locks)
        screen.stage = .session
        log.notice("mode étude : \(minutes) min")
    }

    func cancelSetup() {
        guard screen.stage == .setup else { return }
        closeWindow()
    }

    // MARK: Suivre le chrono

    /// À chaque changement du chrono (geste ici, état adopté d'ailleurs,
    /// frontière de temps).
    func update() {
        guard let timer else { return }
        if timer.isStudying {
            if screen.stage != .session || window?.isVisible != true {
                // Lancé ailleurs (l'iPhone) : l'écran s'ouvre ici aussi.
                screen.stage = .session
                showWindow()
            }
            if timer.studyLocks { startBlocking() } else { stopBlocking() }
            applyPresentation()
        } else {
            stopBlocking()
            if timer.studyIsOver {
                // L'échéance est passée : l'écran reste, pour terminer ou prolonger.
                screen.stage = .session
            } else if screen.stage == .session {
                closeWindow()
            }
        }
    }

    // MARK: Fenêtre

    private func showWindow() {
        guard let timer, let settings else { return }
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = previewOnly ? NSRect(x: 80, y: 80, width: 1440, height: 900) : screenFrame
            let window = StudyWindow(contentRect: frame,
                                     styleMask: previewOnly ? [.titled, .closable, .resizable] : [.borderless, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            window.title = "Mode étude"
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.collectionBehavior = [.managed, .fullScreenNone]
            window.backgroundColor = NSColor(StudyPalette.ground)
            window.hasShadow = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.delegate = self
            var root = AnyView(StudyModeView(screen: screen, browser: browser, desk: desk)
                .environment(timer)
                .environment(settings))
            if let container { root = AnyView(root.modelContainer(container)) }
            window.contentView = NSHostingView(rootView: root)
            window.setFrame(frame, display: true)
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyPresentation()
    }

    private func closeWindow() {
        window?.orderOut(nil)
        NSApp.presentationOptions = []
        browser.closeAll()
        desk.closeAll()
        desk.pane = .desk
    }

    /// Dock et barre des menus cachés tant que StudyTrack est au premier plan.
    /// Sous verrou, en plus : ni ⌘Tab, ni « Forcer à quitter » (⌥⌘⎋), ni
    /// fermeture de session ou redémarrage, ni ⌘H, ni menu Pomme. Ces options
    /// ne valent que quand StudyTrack est au premier plan ; ailleurs (une app
    /// permise), le voile et le gardien (`StudyGuard`) prennent le relais.
    private func applyPresentation() {
        guard window?.isVisible == true, !previewOnly else { return }
        var options: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar]
        if timer?.isLocked == true {
            options.formUnion([.disableProcessSwitching, .disableForceQuit, .disableSessionTermination,
                               .disableHideApplication, .disableAppleMenu])
        }
        if NSApp.presentationOptions != options { NSApp.presentationOptions = options }
    }

    func windowDidBecomeKey(_ notification: Notification) { applyPresentation() }

    func windowDidResignKey(_ notification: Notification) {
        // Une autre fenêtre de StudyTrack (le cours, les réglages) : sous
        // verrou, rien ne se relâche.
        guard timer?.isLocked != true else { return }
        NSApp.presentationOptions = []
    }

    /// Sous verrou, la fenêtre ne se ferme pas (⌘W) et ne se réduit pas (⌘M).
    func windowShouldClose(_ sender: NSWindow) -> Bool { timer?.isLocked != true }

    // MARK: Blocage

    private func startBlocking() {
        guard !blocking, !previewOnly else { return }
        blocking = true
        // Tué de force depuis une app permise, StudyTrack revient (`StudyGuard`).
        StudyGuard.arm()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.check(app) }
        }
        // Une app non permise qui se lance pendant la session se ferme aussitôt :
        // elle n'a encore rien à perdre.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.launched(app) }
        }
        check(NSWorkspace.shared.frontmostApplication)
        log.notice("mode étude : blocage actif")
    }

    private func stopBlocking() {
        guard blocking else { return }
        blocking = false
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        activationObserver = nil
        launchObserver = nil
        quitting.removeAll()
        hideShields()
        log.notice("mode étude : blocage levé")
    }

    /// Les apps ouvertes qui ne sont pas permises (pour les annoncer, puis les fermer).
    func runningBlockedApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(isBlocked)
    }

    private func isBlocked(_ app: NSRunningApplication) -> Bool {
        StudyMode.shouldBlock(bundleID: app.bundleIdentifier,
                              isRegular: app.activationPolicy == .regular,
                              own: Bundle.main.bundleIdentifier ?? "",
                              allowed: settings?.studyApps ?? StudyMode.defaultMacApps)
    }

    /// Demande à une app de quitter ; `force` : la forcer si elle n'a pas
    /// quitté au bout de deux secondes (une app tout juste lancée).
    private func ask(_ app: NSRunningApplication, toQuit: Bool, force: Bool) {
        quitting[app.processIdentifier] = Date()
        app.terminate()
        guard force else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !app.isTerminated { app.forceTerminate() }
        }
    }

    private func launched(_ app: NSRunningApplication?) {
        guard blocking, let app, isBlocked(app) else { return }
        screen.blockedName = app.localizedName
        screen.blockedAt = Date()
        log.notice("mode étude : \(app.bundleIdentifier ?? "?", privacy: .public) lancée, fermée")
        if settings?.studyCloseApps ?? true {
            ask(app, toQuit: true, force: true)
        }
    }

    /// Une app vient au premier plan : permise, on la laisse ; sinon le voile.
    private func check(_ app: NSRunningApplication?) {
        guard blocking, let app else { return }
        guard isBlocked(app) else {
            hideShields()
            return
        }
        // On vient de lui demander de quitter : elle demande peut-être
        // d'enregistrer un document — on la laisse répondre.
        if let asked = quitting[app.processIdentifier], Date().timeIntervalSince(asked) < 20 { return }
        screen.blockedName = app.localizedName
        screen.blockedAt = Date()
        log.notice("mode étude : \(app.bundleIdentifier ?? "?", privacy: .public) arrêtée")
        // Le voile d'abord : rien de l'app ne se voit, même une fraction de seconde.
        showShields()
        // Puis masquer l'app, quand le système le permet (ses fenêtres partent,
        // son icône reste), et revenir à l'écran d'étude, qui le dit. Sinon le
        // voile reste, jusqu'à ce qu'on choisisse quoi faire.
        if settings?.studyCloseApps ?? true {
            ask(app, toQuit: true, force: false)
        }
        if app.hide() {
            present()
        }
    }

    private func showShields() {
        guard let timer, let settings else { return }
        if shields.isEmpty {
            for screenInfo in NSScreen.screens {
                let shield = StudyWindow(contentRect: screenInfo.frame, styleMask: [.borderless, .fullSizeContentView],
                                         backing: .buffered, defer: false)
                shield.isReleasedWhenClosed = false
                shield.level = .statusBar
                shield.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                shield.backgroundColor = .clear
                shield.isOpaque = false
                shield.hasShadow = false
                shield.appearance = NSAppearance(named: .darkAqua)
                var root = AnyView(StudyShieldView(screen: screen)
                    .environment(timer)
                    .environment(settings))
                if let container { root = AnyView(root.modelContainer(container)) }
                shield.contentView = NSHostingView(rootView: root)
                shield.setFrame(screenInfo.frame, display: true)
                shields.append(shield)
            }
        }
        for shield in shields { shield.orderFrontRegardless() }
    }

    private func hideShields() {
        for shield in shields { shield.orderOut(nil) }
    }

    /// « Revenir à l'étude » depuis le voile.
    func returnToStudy() {
        hideShields()
        present()
    }

    // MARK: Apps permises

    /// Ouvre une app permise (GoodNotes, Claude…).
    func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        hideShields()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Quitter

    /// ⌘Q pendant le mode étude : sous verrou, non — l'écran revient ; sans
    /// verrou, on demande.
    func confirmQuit() -> Bool {
        guard let timer, timer.isStudying else { return true }
        if timer.isLocked {
            present()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Quitter le mode étude ?"
        alert.informativeText = "Ta session continue."
        alert.addButton(withTitle: "Rester")
        alert.addButton(withTitle: "Quitter")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Une fenêtre sans bord qui accepte le clavier (champs, navigateur).
final class StudyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private var locked: Bool { MainActor.assumeIsolated { StudyModeController.shared.timer?.isLocked == true } }

    override func performClose(_ sender: Any?) {
        guard !locked else { NSSound.beep(); return }
        super.performClose(sender)
    }

    override func performMiniaturize(_ sender: Any?) {
        guard !locked else { NSSound.beep(); return }
        super.performMiniaturize(sender)
    }

    override func miniaturize(_ sender: Any?) {
        guard !locked else { return }
        super.miniaturize(sender)
    }
}
