import SwiftUI

/// Réglages (⌘,) : le chrono, la barre des menus, l'ouverture, iCloud.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Général", systemImage: "gearshape") }
            PomodoroSettingsPane()
                .tabItem { Label("Pomodoro", systemImage: "timer") }
            SyncSettings()
                .tabItem { Label("iCloud", systemImage: "icloud") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @Environment(MacSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Ouvrir StudyTrack à la connexion", isOn: Binding(
                    get: { _ = settings.launchAtLoginRevision; return settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Le chrono reste dans la barre des menus, même fenêtre fermée.")
            }
            Section {
                Toggle("Afficher le temps dans la barre des menus", isOn: $settings.showTimeInMenuBar)
                Toggle("Raccourci global ⌃⌥Espace", isOn: $settings.globalShortcut)
            } footer: {
                Text("⌃⌥Espace démarre ou met en pause le chrono depuis n'importe quelle app.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}

private struct PomodoroSettingsPane: View {
    @Environment(MacSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Démarrer en Pomodoro", isOn: $settings.pomodoroDefault)
                Stepper("Bloc de travail : \(settings.focusMinutes) min", value: $settings.focusMinutes, in: 5...120, step: 5)
                Stepper("Pause courte : \(settings.shortBreakMinutes) min", value: $settings.shortBreakMinutes, in: 1...30)
                Stepper("Pause longue : \(settings.longBreakMinutes) min", value: $settings.longBreakMinutes, in: 5...60, step: 5)
                Stepper("Pause longue tous les \(settings.longBreakEvery) blocs", value: $settings.longBreakEvery, in: 2...8)
                Toggle("Relancer le bloc après la pause", isOn: $settings.autoStartFocus)
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}

private struct SyncSettings: View {
    @Environment(MacStore.self) private var store

    var body: some View {
        Form {
            Section {
                LabeledContent("Base") {
                    Text(store.isCloudSynced ? "iCloud (privé)" : "locale")
                }
                LabeledContent("État") {
                    Text(SyncFooter.describe(store.syncState, synced: store.isCloudSynced, now: Date()))
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Cours, séries, coches et sessions sont ceux de l'iPhone. Moodle est relu par l'iPhone (un seul appareil à la fois) ; ce qu'il ajoute arrive ici tout seul.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}
