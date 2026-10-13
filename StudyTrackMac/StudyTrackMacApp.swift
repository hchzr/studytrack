import SwiftUI
import SwiftData
import UserNotifications
import WidgetKit

/// StudyTrack sur Mac : le chrono dans la barre des menus, et une fenêtre pour
/// voir ses cours, cocher ses exercices et relire son bilan. Les données sont
/// celles de l'iPhone, par iCloud ; le chrono aussi.
@main
struct StudyTrackMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var store: MacStore
    @State private var settings: MacSettings
    @State private var timer: MacTimer
    @State private var menuClock: MenuBarClock

    init() {
        AppLanguage.settle(existingUser: UserDefaults.standard.object(forKey: "cloudRelay.device") != nil
                                         || UserDefaults.standard.object(forKey: "mac.epflEmail") != nil)
        #if DEBUG
        // `-cloudCheck` : iCloud marche-t-il hors du bac à sable ? Une base
        // jetable, le premier événement CloudKit, puis on quitte.
        if CommandLine.arguments.contains("-cloudCheck") { CloudCheck.run() }
        #endif
        // Avant tout : les réglages et la base du bac à sable, repris une fois.
        MacSandboxMigration.run()
        let settings = MacSettings()
        let store = MacStore(preferences: settings.shared)
        #if DEBUG
        // `-isolatedTimer` : un chrono qui ne publie rien (essais, captures) —
        // l'iPhone n'en voit rien.
        let timer = MacTimer(settings: settings, isolated: CommandLine.arguments.contains("-isolatedTimer"))
        #else
        let timer = MacTimer(settings: settings)
        #endif
        let menuClock = MenuBarClock()
        menuClock.timer = timer
        menuClock.settings = settings
        // Le mode étude suit le chrono : lancé sur l'iPhone, il s'ouvre ici.
        StudyModeController.shared.timer = timer
        StudyModeController.shared.settings = settings
        StudyModeController.shared.container = store.container
        // Les widgets du bureau, le chrono flottant, la barre des menus et le
        // mode étude suivent le chrono.
        let refreshWidgets = {
            WidgetSnapshotWriter.scheduleRefresh(context: ModelContext(store.container), settings: store.preferences)
        }
        timer.onChange = {
            refreshWidgets()
            MiniTimerPanel.shared.update()
            menuClock.update()
            StudyModeController.shared.update()
        }
        timer.attach(store.container)
        MiniTimerPanel.shared.timer = timer
        MiniTimerPanel.shared.settings = settings
        MiniTimerPanel.shared.container = store.container
        store.onDataChange = refreshWidgets
        refreshWidgets()
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        _timer = State(initialValue: timer)
        _menuClock = State(initialValue: menuClock)
        menuClock.update()
        MacAppDelegate.timer = timer
        // La voie instantanée du chrono partagé (moins d'une seconde).
        if store.isCloudSynced, !CommandLine.arguments.contains("-isolatedTimer") {
            // Chaque geste du Mac emporte l'état de l'îlot : le relais le pousse
            // à l'écran verrouillé de l'iPhone, même app fermée.
            TimerLink.shared.livePayload = { [container = store.container] snapshot in
                MacLivePayload.make(snapshot, container: container, settings: settings.pomodoro)
            }
            TimerLink.shared.startFromBundle(containerID: MacStore.cloudContainerID)
        }
        MacAppDelegate.settings = settings
        MacAppDelegate.store = store
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #if DEBUG
        MacDebugLaunch.apply(timer: timer, store: store)
        #endif
    }

    #if DEBUG
    @MainActor private static var preview: MacTimer?
    /// Un chrono à part pour regarder le panneau au repos, sans toucher au vrai.
    @MainActor static func previewTimer(_ settings: MacSettings) -> MacTimer {
        if let preview { return preview }
        let timer = MacTimer(settings: settings, isolated: true)
        preview = timer
        return timer
    }
    #endif

    var body: some Scene {
        Window("StudyTrack", id: "main") {
            MacRootView()
                .environment(timer)
                .environment(store)
                .environment(settings)
                .environment(settings.shared)
                .frame(minWidth: 900, minHeight: 580)
        }
        .modelContainer(store.container)
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            MacCommands(timer: timer, settings: settings)
            // « Importer depuis l'iPhone » (photo, numérisation) : Continuity Camera.
            ImportFromDevicesCommands()
        }

        MenuBarExtra {
            MenuBarTimerView()
                .environment(timer)
                .environment(settings)
                .modelContainer(store.container)
        } label: {
            MenuBarLabel()
                .environment(timer)
                .environment(settings)
                .environment(menuClock)
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        // Le panneau de la barre des menus dans une fenêtre, pour le regarder.
        Window("Panneau", id: "debugPanel") {
            MenuBarTimerView()
                .environment(Self.previewTimer(settings))
                .environment(settings)
                .modelContainer(store.container)
        }
        .windowResizability(.contentSize)
        #endif

        Settings {
            MacSettingsView()
                .environment(settings)
                .environment(settings.shared)
                .environment(store)
                .modelContainer(store.container)
        }
    }
}

/// La barre des menus de l'app : Chrono, Aller, la palette, l'aide.
struct MacCommands: Commands {
    let timer: MacTimer
    let settings: MacSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("À propos de StudyTrack") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .credits: NSAttributedString(
                        string: "Tes cours, tes séries, ton temps.",
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                ])
            }
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Chrono") {
            Button(timer.phase == .running ? "Pause" : (timer.phase == .idle ? "Démarrer" : "Reprendre")) {
                if timer.phase == .onBreak { timer.skipBreak() } else { timer.toggle() }
            }
            .keyboardShortcut("t", modifiers: [.command])
            Button("Terminer") { timer.finish() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(timer.phase == .idle)
            Button("Écourter la pause") { timer.skipBreak() }
                .disabled(timer.phase != .onBreak)
            Divider()
            Toggle("Chrono flottant", isOn: Binding(get: { settings.floatingTimer }, set: {
                settings.floatingTimer = $0
                MiniTimerPanel.shared.update()
            }))
            .keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
            Button(timer.isStudying ? "Revenir au mode étude" : "Mode étude…") {
                StudyModeController.shared.presentSetup()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Abandonner", role: .destructive) { timer.discard() }
                .disabled(timer.phase == .idle)
        }
        CommandGroup(after: .newItem) {
            Button("Note rapide…") { NotificationCenter.default.post(name: .macQuickNote, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Aller") {
            Button("Aujourd'hui") { go("today") }.keyboardShortcut("1", modifiers: [.command])
            Button("Chrono") { go("focus") }.keyboardShortcut("2", modifiers: [.command])
            Button("Agenda") { go("agenda") }.keyboardShortcut("3", modifiers: [.command])
            Button("Bilan") { go("stats") }.keyboardShortcut("4", modifiers: [.command])
            Divider()
            Button("Rechercher…") {
                NotificationCenter.default.post(name: .macFocusSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command])
        }
        CommandGroup(replacing: .textEditing) {
            Button("Rechercher…") {
                NotificationCenter.default.post(name: .macFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])
        }
        CommandGroup(replacing: .help) {
            Button("Raccourcis") {
                let alert = NSAlert()
                alert.messageText = "Raccourcis"
                alert.informativeText = """
                ⌃⌥Espace — démarrer ou mettre en pause, depuis n'importe quelle app
                ⌘T — démarrer / pause · ⇧⌘T — terminer
                ⌘K ou ⌘F — chercher, ouvrir, chronométrer (⌘↩)
                ⌘1 ⌘2 ⌘3 ⌘4 — Aujourd'hui, Chrono, Agenda, Bilan
                ⇧⌘E — mode étude (plein écran, Mac et iPhone fermés au reste)
                ⌥⌘M — chrono flottant
                Dans un cours : Espace coche, ↩ chronomètre l'exercice choisi
                """
                alert.runModal()
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }

    private func go(_ page: String) {
        NotificationCenter.default.post(name: .macGoTo, object: page)
    }
}

extension Notification.Name {
    static let macFocusSearch = Notification.Name("mac.focusSearch")
    static let macGoTo = Notification.Name("mac.goTo")
    /// La note rapide (⇧⌘N, barre des menus) : la fenêtre l'ouvre.
    static let macQuickNote = Notification.Name("mac.quickNote")
}

/// Le raccourci global et les widgets : ce qui vit hors des fenêtres.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var timer: MacTimer?
    @MainActor static var settings: MacSettings?
    @MainActor private var hotKey: GlobalHotKey?

    @MainActor static var store: MacStore?

    /// Relit les cours (Moodle, Botafogo) s'il est temps : la même chaîne que
    /// l'iPhone (`ContentRefresher`), sur l'appareil qui la réclame le premier.
    @MainActor static func refreshContent(force: Bool = false) {
        guard let store else { return }
        Task { @MainActor in
            await ContentRefresher.refreshIfDue(context: store.container.mainContext, settings: store.preferences, force: force)
        }
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Les sites de l'EPFL, sans rien afficher : la session Microsoft garde
        // la connexion, mais celle de chaque site s'efface à la fermeture.
        if !CommandLine.arguments.contains("-epflConnect") {
            Task { @MainActor in
                await SchoolConnect.shared.connectAll()
                // Une série publiée sur Moodle depuis la dernière fois.
                Self.refreshContent(force: CommandLine.arguments.contains("-refreshContent"))
            }
        }
        MiniTimerPanel.shared.update()
        // Au réveil du Mac, la socket du chrono partagé est morte : on la relance.
        // À l'endormissement, on la ferme : pas de tentatives de reconnexion
        // pendant la veille.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                TimerLink.shared.resume()
                StudyModeController.shared.update()
                Self.refreshContent()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TimerLink.shared.suspend() }
        }
        StudyModeController.shared.update()
        hotKey = GlobalHotKey { Self.timer?.toggle() }
        updateHotKey()
        withObservationTracking({ _ = Self.settings?.globalShortcut }, onChange: { [weak self] in
            Task { @MainActor in self?.observeHotKey() }
        })
    }

    @MainActor
    private func observeHotKey() {
        updateHotKey()
        withObservationTracking({ _ = Self.settings?.globalShortcut }, onChange: { [weak self] in
            Task { @MainActor in self?.observeHotKey() }
        })
    }

    @MainActor
    private func updateHotKey() {
        if Self.settings?.globalShortcut ?? true { hotKey?.register() } else { hotKey?.unregister() }
    }

    /// Clic droit sur l'icône du Dock : le chrono.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let timer = Self.timer else { return nil }
        let menu = NSMenu()
        let title: String
        switch timer.phase {
        case .idle: title = "Démarrer le chrono"
        case .running: title = "Pause"
        case .paused: title = "Reprendre"
        case .onBreak: title = "Écourter la pause"
        }
        menu.addItem(DockItem(title: title) { timer.phase == .onBreak ? timer.skipBreak() : timer.toggle() })
        if timer.phase != .idle {
            menu.addItem(DockItem(title: "Terminer et enregistrer") { timer.finish() })
        }
        return menu
    }

    /// Fermer la fenêtre ne quitte pas : le chrono reste dans la barre des menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q pendant le mode étude : on demande d'abord.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        StudyModeController.shared.confirmQuit() ? .terminateNow : .terminateCancel
    }
}

/// Un élément de menu qui exécute une fermeture.
private final class DockItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @MainActor @objc private func fire() { handler() }
}

/// L'état de l'îlot de l'iPhone, construit par le Mac à chaque geste.
enum MacLivePayload {
    @MainActor
    static func make(_ snapshot: CloudRelay.TimerSnapshot, container: ModelContainer, settings: PomodoroSettings) -> Data? {
        guard let state = snapshot.state else {
            return LiveActivityBuilder.push(event: "end", state: ActivityTimerState(countingSince: nil, frozenTotal: 0),
                                            attributes: nil)
        }
        let course = TimerEngine.course(state.courseID, in: ModelContext(container))
        let exercise = LiveActivityBuilder.exercise(for: state, course: course)
        let content = LiveActivityBuilder.state(timer: state, settings: settings, exercise: exercise, course: course)
        return LiveActivityBuilder.push(event: "update", state: content,
                                        attributes: LiveActivityBuilder.attributes(for: state, course: course))
    }
}

#if DEBUG
import CoreData

enum CloudCheck {
    static func run() -> Never {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudcheck-\(UUID().uuidString).store")
        let schema = StudyTrackSchema.current
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .private(MacStore.cloudContainerID))
        var container: ModelContainer?
        do {
            container = try ModelContainer(for: schema, migrationPlan: StudyTrackMigrationPlan.self, configurations: [configuration])
            FileHandle.standardError.write(Data("CLOUD container ok (sandbox: \(MacSandboxMigration.isSandboxed))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("CLOUD container FAILED: \(error)\n".utf8))
            exit(1)
        }
        let observer = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil else { return }
            FileHandle.standardError.write(Data("CLOUD event \(event.type.rawValue) succeeded=\(event.succeeded) error=\(String(describing: event.error))\n".utf8))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(40))
        let courses = container.map { (try? ModelContext($0).fetchCount(FetchDescriptor<Course>())) ?? -1 } ?? -1
        FileHandle.standardError.write(Data("CLOUD courses imported: \(courses)\n".utf8))
        NotificationCenter.default.removeObserver(observer)
        container = nil
        for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        exit(0)
    }
}
#endif
