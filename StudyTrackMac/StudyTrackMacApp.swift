import SwiftUI
import SwiftData
import UserNotifications

/// StudyTrack sur Mac : le chrono dans la barre des menus, et une fenêtre pour
/// voir ses cours, cocher ses exercices et relire son bilan. Les données sont
/// celles de l'iPhone, par iCloud.
@main
struct StudyTrackMacApp: App {
    @State private var store = MacStore()
    @State private var timer = MacTimer()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        Window("StudyTrack", id: "main") {
            MacRootView()
                .environment(timer)
                .environment(\.isCloudSynced, store.isCloudSynced)
                .environment(store)
                .frame(minWidth: 860, minHeight: 560)
        }
        .modelContainer(store.container)
        .commands {
            CommandMenu("Chrono") {
                Button(timer.phase == .running ? "Pause" : (timer.phase == .paused ? "Reprendre" : "Démarrer")) {
                    timer.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command])
                Button("Terminer et enregistrer") {
                    timer.stop(context: store.container.mainContext)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(timer.phase == .idle)
            }
        }

        MenuBarExtra {
            MenuBarTimerView()
                .environment(timer)
                .modelContainer(store.container)
        } label: {
            MenuBarLabel()
                .environment(timer)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct CloudSyncedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isCloudSynced: Bool {
        get { self[CloudSyncedKey.self] }
        set { self[CloudSyncedKey.self] = newValue }
    }
}
