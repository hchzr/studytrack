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

    init() {
        let settings = MacSettings()
        let store = MacStore()
        let timer = MacTimer(settings: settings)
        timer.container = store.container
        timer.applyRemote()
        // Les widgets du bureau suivent le chrono et les données.
        timer.onChange = { MacWidgetWriter.schedule(container: store.container, timer: timer) }
        store.onDataChange = { MacWidgetWriter.schedule(container: store.container, timer: timer) }
        MacWidgetWriter.schedule(container: store.container, timer: timer)
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        _timer = State(initialValue: timer)
        MacAppDelegate.timer = timer
        MacAppDelegate.settings = settings
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #if DEBUG
        // `-debugTimer start|discard` : vérifier le chrono partagé sans cliquer.
        if let index = CommandLine.arguments.firstIndex(of: "-debugTimer"), index + 1 < CommandLine.arguments.count {
            let action = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if action == "start" { timer.start(taskType: .exercise, label: "Test du chrono partagé") }
                if action == "discard" { timer.discard() }
            }
        }
        #endif
    }

    var body: some Scene {
        Window("StudyTrack", id: "main") {
            MacRootView()
                .environment(timer)
                .environment(store)
                .environment(settings)
                .frame(minWidth: 900, minHeight: 580)
        }
        .modelContainer(store.container)
        .defaultSize(width: 1180, height: 760)
        .commands { MacCommands(timer: timer) }

        MenuBarExtra {
            MenuBarTimerView()
                .environment(timer)
                .environment(settings)
                .modelContainer(store.container)
        } label: {
            MenuBarLabel()
                .environment(timer)
                .environment(settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environment(settings)
                .environment(store)
        }
    }
}

/// Le menu « Chrono » de la barre de l'app.
struct MacCommands: Commands {
    let timer: MacTimer

    var body: some Commands {
        CommandMenu("Chrono") {
            Button(timer.phase == .running ? "Pause" : (timer.phase == .idle ? "Démarrer" : "Reprendre")) {
                timer.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command])
            Button("Terminer et enregistrer") { timer.finish() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(timer.phase == .idle)
            if timer.phase == .onBreak {
                Button("Passer la pause") { timer.skipBreak() }
            }
            Divider()
            Button("Abandonner la session", role: .destructive) { timer.discard() }
                .disabled(timer.phase == .idle)
        }
        CommandGroup(after: .sidebar) {
            Button("Rechercher") {
                NotificationCenter.default.post(name: .macFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])
        }
    }
}

extension Notification.Name {
    static let macFocusSearch = Notification.Name("mac.focusSearch")
}

/// Le raccourci global et les widgets : ce qui vit hors des fenêtres.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var timer: MacTimer?
    @MainActor static var settings: MacSettings?
    @MainActor private var hotKey: GlobalHotKey?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
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

    /// Fermer la fenêtre ne quitte pas : le chrono reste dans la barre des menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
