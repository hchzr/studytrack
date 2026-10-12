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
            }
            Section {
                Toggle("Garder l'icône dans le Dock", isOn: $settings.keepInDock)
            }
            Section {
                Toggle("Temps dans la barre des menus", isOn: $settings.showTimeInMenuBar)
                Toggle("Avec les secondes", isOn: $settings.menuBarSeconds)
                    .disabled(!settings.showTimeInMenuBar)
                Toggle("Raccourci global ⌃⌥Espace", isOn: $settings.globalShortcut)
            } footer: {
                Text("Sans les secondes, ça use moins la batterie.")
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
                Toggle("Chrono flottant", isOn: Binding(
                    get: { settings.floatingTimer },
                    set: { settings.floatingTimer = $0; MiniTimerPanel.shared.update() }))
                Toggle("Sons", isOn: $settings.sounds)
            } header: {
                Text("Chrono")
            }
            Section {
                Toggle("Démarrer en Pomodoro", isOn: $settings.pomodoroDefault)
                Stepper("Bloc de travail : \(settings.focusMinutes) min", value: $settings.focusMinutes, in: 5...120, step: 5)
                Stepper("Pause courte : \(settings.shortBreakMinutes) min", value: $settings.shortBreakMinutes, in: 1...30)
                Stepper("Pause longue : \(settings.longBreakMinutes) min", value: $settings.longBreakMinutes, in: 5...60, step: 5)
                Stepper("Pause longue tous les \(settings.longBreakEvery) blocs", value: $settings.longBreakEvery, in: 2...8)
                Toggle("Relancer après la pause", isOn: $settings.autoStartFocus)
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
                Text("Les mêmes données que sur ton iPhone.")
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
                Stepper("Durée : \(settings.studyMinutes) min", value: $settings.studyMinutes, in: 15...240, step: 5)
                Toggle("Maintenir pour finir plus tôt", isOn: $settings.studyHoldToLeave)
                Toggle("Fermer les autres apps", isOn: $settings.studyCloseApps)
            } header: {
                Text("Session")
            } footer: {
                Text("Sinon, elles sont juste cachées.")
            }

            Section {
                LabeledContent("Claude Code") {
                    if let path = ClaudeChat.executable?.path {
                        Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("introuvable").foregroundStyle(Carnet.wrong)
                    }
                }
                Toggle("Projet EPFL", isOn: $settings.claudeProject)
                if settings.claudeProject {
                    LabeledContent("Dossier") {
                        HStack {
                            Text(settings.claudeProjectFolder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .foregroundStyle(.secondary)
                            Button("Choisir…", action: chooseFolder)
                        }
                    }
                    LabeledContent("Compétences") {
                        let skills = ClaudeProjectSetup.linkedSkills(settings: settings)
                        Text(skills.isEmpty ? "aucune" : skills.joined(separator: ", "))
                            .foregroundStyle(skills.isEmpty ? Carnet.wrong : .secondary)
                    }
                    Toggle("Notion (carnet d'erreurs)", isOn: $settings.claudeNotion)
                    TextField("Serveur StudyTrack (https://…)", text: $settings.claudeStudyTrackMCP)
                    LabeledContent("Permis") {
                        Text(ClaudeProject.permissionSummary(notion: settings.claudeNotion,
                                                             studyTrack: settings.claudeStudyTrackMCP.hasPrefix("https://")))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Claude")
            } footer: {
                Text(settings.claudeProject ? "Tes compétences EPFL, dans ce dossier. Rien d'autre." : "Passe par ton abonnement, sans outils.")
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
                    TextField("wolframalpha.com", text: $newSite)
                        .onSubmit(addSite)
                    Button("Ajouter", action: addSite).disabled(newSite.isEmpty)
                }
                if siteError {
                    Text("Adresse invalide").font(.caption).foregroundStyle(Carnet.wrong)
                }
                Button("Rétablir") { settings.studySites = StudyMode.defaultSites }
                    .buttonStyle(.link)
            } header: {
                Text("Sites permis")
            } footer: {
                Text("« epfl.ch » ouvre aussi Moodle, Botafogo…")
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.claudeProjectFolder = url.path
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
