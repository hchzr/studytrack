import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Réglages (⌘,) : le chrono, la barre des menus, l'ouverture, iCloud.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Général", systemImage: "gearshape") }
            PomodoroSettingsPane()
                .tabItem { Label("Chrono", systemImage: "timer") }
            StudySettingsPane()
                .tabItem { Label("Mode étude", systemImage: "moon.stars") }
            SyncSettings()
                .tabItem { Label("iCloud", systemImage: "icloud") }
        }
        .frame(width: 520)
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
                    Text(error).font(.caption).foregroundStyle(Carnet.wrong)
                }
            } footer: {
                Text("Le chrono reste dans la barre des menus, même fenêtre fermée.")
            }
            Section {
                Toggle("Garder l'icône dans le Dock, fenêtre fermée", isOn: $settings.keepInDock)
            } footer: {
                Text("Sinon StudyTrack ne vit que dans la barre des menus quand sa fenêtre est fermée.")
            }
            Section {
                Toggle("Afficher le temps dans la barre des menus", isOn: $settings.showTimeInMenuBar)
                Toggle("Avec les secondes", isOn: $settings.menuBarSeconds)
                    .disabled(!settings.showTimeInMenuBar)
                Toggle("Raccourci global ⌃⌥Espace", isOn: $settings.globalShortcut)
            } footer: {
                Text("⌃⌥Espace démarre ou met en pause le chrono depuis n'importe quelle app. Sans les secondes, la barre des menus ne se redessine qu'une fois par minute : c'est plus doux pour la batterie.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }
}

private struct PomodoroSettingsPane: View {
    @Environment(MacSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Stepper("Objectif du jour : \(DateUtils.hoursLabel(seconds: settings.dailyGoalSeconds))",
                        value: $settings.dailyGoalMinutes, in: 30...600, step: 30)
                Toggle("Chrono flottant pendant les sessions", isOn: Binding(
                    get: { settings.floatingTimer },
                    set: { settings.floatingTimer = $0; MiniTimerPanel.shared.update() }))
                Toggle("Son à la fin d'un bloc et d'une pause", isOn: $settings.sounds)
            } header: {
                Text("Chrono")
            }
            Section {
                Toggle("Démarrer en Pomodoro", isOn: $settings.pomodoroDefault)
                Stepper("Bloc de travail : \(settings.focusMinutes) min", value: $settings.focusMinutes, in: 5...120, step: 5)
                Stepper("Pause courte : \(settings.shortBreakMinutes) min", value: $settings.shortBreakMinutes, in: 1...30)
                Stepper("Pause longue : \(settings.longBreakMinutes) min", value: $settings.longBreakMinutes, in: 5...60, step: 5)
                Stepper("Pause longue tous les \(settings.longBreakEvery) blocs", value: $settings.longBreakEvery, in: 2...8)
                Toggle("Relancer le bloc après la pause", isOn: $settings.autoStartFocus)
            } header: {
                Text("Pomodoro")
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
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
        .frame(height: 440)
    }
}

/// Le mode étude : ce qui reste ouvert, la durée, la sortie.
private struct StudySettingsPane: View {
    @Environment(MacSettings.self) private var settings
    @State private var newSite = ""
    @State private var siteError = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Stepper("Durée proposée : \(settings.studyMinutes) min", value: $settings.studyMinutes, in: 15...240, step: 5)
                Toggle("Maintenir pour terminer avant l'heure", isOn: $settings.studyHoldToLeave)
            } header: {
                Text("Session")
            } footer: {
                Text("Pendant le mode étude, les autres apps sont couvertes d'un voile et les sites non permis refusés. ⌘Q demande confirmation.")
            }

            Section {
                ForEach(settings.studyApps, id: \.self) { bundleID in
                    HStack(spacing: 10) {
                        if let icon = StudyModeController.icon(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 20, height: 20)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(StudyModeController.name(for: bundleID))
                            if !StudyModeController.isInstalled(bundleID) {
                                Text("pas installée").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { settings.studyApps.removeAll { $0 == bundleID } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Ajouter une app…", action: addApp)
            } header: {
                Text("Apps permises")
            } footer: {
                Text("Safari, Chrome et Arc restent fermés : les sites permis s'ouvrent dans le navigateur du mode étude.")
            }

            Section {
                ForEach(settings.studySites, id: \.self) { site in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(site)
                        Spacer()
                        Button { settings.studySites.removeAll { $0 == site } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Ajouter un site (ex. wolframalpha.com)", text: $newSite)
                        .onSubmit(addSite)
                    Button("Ajouter", action: addSite).disabled(newSite.isEmpty)
                }
                if siteError {
                    Text("Ce n'est pas une adresse de site.").font(.caption).foregroundStyle(Carnet.wrong)
                }
                Button("Rétablir les sites par défaut") { settings.studySites = StudyMode.defaultSites }
                    .buttonStyle(.link)
            } header: {
                Text("Sites permis")
            } footer: {
                Text("Un domaine ouvre ses sous-domaines : « epfl.ch » ouvre Moodle, Courseware, Botafogo, Mediaspace… Les mêmes sites sont permis sur l'iPhone.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }

    private func addSite() {
        guard let domain = StudyMode.normalizedDomain(newSite) else {
            siteError = true
            return
        }
        siteError = false
        if !settings.studySites.contains(domain) { settings.studySites.append(domain) }
        newSite = ""
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Permettre"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !settings.studyApps.contains(id) else { continue }
            settings.studyApps.append(id)
        }
    }
}
