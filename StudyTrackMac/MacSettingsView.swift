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
            PersonalizeForm()
                .frame(height: 520)
                .tabItem { Label("Personnaliser", systemImage: "slider.horizontal.3") }
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
                Stepper(settings.weeklyGoalMinutes == 0
                            ? "Objectif de la semaine : charge EPFL"
                            : "Objectif de la semaine : \(DateUtils.hoursLabel(seconds: settings.weeklyGoalMinutes * 60))",
                        value: $settings.weeklyGoalMinutes, in: 0...6000, step: 60)
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
        // La session ouverte prend les nouvelles durées, et l'iPhone avec elle.
        .onChange(of: settings.pomodoro) { _, _ in MacAppDelegate.timer?.cycleDidChange() }
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
    @Environment(MacTimer.self) private var timer
    @State private var newSite = ""
    @State private var siteError = false
    @State private var editingButtons = false

    private var keepAwakeFooter: String {
        switch settings.studyKeepAwake {
        case .off:
            return String(localized: "Le Mac se met en veille comme d'habitude.")
        case .system:
            return String(localized: "Seulement pendant que le chrono tourne : la musique continue, l'écran s'éteint comme d'habitude. En pause, le Mac dort.")
        case .display:
            return String(localized: "Seulement pendant que le chrono tourne. L'écran peut s'éteindre pendant une pause Pomodoro, en mode économie d'énergie ou sous 20 % de batterie. Fermer le capot endort toujours le Mac.")
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            if timer.isLocked {
                // Sous verrou, la liste ne s'élargit pas : ajouter Safari aux
                // apps permises serait une sortie.
                Label("Verrouillé jusqu'à \(DateUtils.time.string(from: timer.state?.studyUntil ?? Date())). Les réglages du mode étude reviennent à la fin.",
                      systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            Section {
                Stepper("Durée : \(settings.studyMinutes) min", value: $settings.studyMinutes, in: 15...240, step: 5)
                Toggle("Maintenir pour finir plus tôt", isOn: $settings.studyHoldToLeave)
                Toggle("Bloquer le reste", isOn: $settings.studyBlocking)
                Toggle("Fermer les autres apps", isOn: $settings.studyCloseApps)
                    .disabled(!settings.studyBlocking)
                Picker("Musique pendant une pause", selection: $settings.studySoundtrackOnBreak) {
                    Text("Pause").tag(SessionSoundtrack.BreakPolicy.pause)
                    Text("Plus bas").tag(SessionSoundtrack.BreakPolicy.lower)
                    Text("Continue").tag(SessionSoundtrack.BreakPolicy.keep)
                }
                Toggle("Poser les apps permises dans le bureau", isOn: $settings.studyPlaceApps)
                    .disabled(!settings.studyBlocking)
                    .help("GoodNotes, Claude… s'ouvrent au centre du bureau, la barre du haut et le volet d'à côté restant visibles. Demande l'Accessibilité (écran de lancement).")
                Toggle("Barres flottantes (expérimental)", isOn: $settings.studyPanels)
                    .help("La barre du haut et la colonne d'outils deviennent des fenêtres à part, visibles par-dessus GoodNotes et les autres apps permises. Au prochain mode étude.")
                Toggle("Autres écrans au calme", isOn: $settings.studyCalmDisplays)
                    .disabled(!settings.studyBlocking)
                Toggle("Bloquer les gestes du trackpad", isOn: $settings.studyBlockGestures)
                    .disabled(!settings.studyBlocking)
                    .help("Mission Control, changer de bureau, Launchpad : les gestes à trois ou quatre doigts. Le Dock se relance au début et à la fin.")
                Toggle("Toujours sombre", isOn: $settings.studyAlwaysDark)
                    .onChange(of: settings.studyAlwaysDark) { _, _ in StudyModeController.shared.update() }
                Toggle("Cacher le Dock et la barre des menus", isOn: $settings.studyHideSystemChrome)
                    .disabled(!settings.studyBlocking)
                Button("Rétablir les raccourcis du système") { SystemLock.release() }
                    .help("Si un blocage s'est mal fini : rallume Spotlight, ⌘Tab, Mission Control, le Dock et la barre des menus.")
            } header: {
                Text("Session")
            } footer: {
                Text(settings.studyBlocking ? "Sinon, elles sont juste cachées." : "Rien n'est bloqué, ni ici ni sur l'iPhone.")
            }

            Section {
                Picker("Garder éveillé", selection: $settings.studyKeepAwake) {
                    Text("Non").tag(KeepAwakePolicy.Mode.off)
                    Text("Le Mac").tag(KeepAwakePolicy.Mode.system)
                    Text("Le Mac et l'écran").tag(KeepAwakePolicy.Mode.display)
                }
                .onChange(of: settings.studyKeepAwake) { _, _ in StudyModeController.shared.update() }
            } footer: {
                Text(keepAwakeFooter)
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
                Toggle("Mon projet Claude (dossier, compétences, connecteurs)", isOn: $settings.claudeProject)
                if settings.claudeProject {
                    LabeledContent("Dossier") {
                        HStack {
                            Text(settings.claudeProjectFolder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .foregroundStyle(.secondary)
                            Button("Choisir…", action: chooseFolder)
                        }
                    }
                    let file = ClaudeProjectSetup.file(settings: settings)
                    LabeledContent("Fichier") {
                        HStack {
                            Text(file == nil ? "aucun" : "studytrack.json").foregroundStyle(.secondary)
                            Button(file == nil ? "Créer" : "Ouvrir") { openProjectFile(exists: file != nil) }
                        }
                    }
                    LabeledContent("Boutons") {
                        HStack {
                            Text(file.map { "\($0.commands.count)" } ?? "aucun").foregroundStyle(.secondary)
                            Button("Modifier…") { editingButtons = true }
                        }
                    }
                    LabeledContent("Compétences") {
                        let skills = ClaudeProjectSetup.linkedSkills(settings: settings)
                        Text(skills.isEmpty ? "aucune" : skills.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Serveur StudyTrack (https://…)", text: $settings.claudeStudyTrackMCP)
                    LabeledContent("Permis") {
                        Text(ClaudeProject.permissionSummary(file: file ?? ClaudeProject.File(),
                                                             studyTrack: settings.claudeStudyTrackMCP.hasPrefix("https://")))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if let models = file?.models, models.tutor != nil || models.system != nil {
                        LabeledContent("Modèles") {
                            Text("indices : \(models.tutor ?? "défaut") · système : \(models.system ?? "défaut")").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Claude")
            } footer: {
                Text(settings.claudeProject ? "Ta façon de travailler est dans studytrack.json." : "Passe par ton abonnement, sans outils.")
            }

            Section {
                Toggle("Carnet d'erreurs", isOn: $settings.reviewMistakes)
                Toggle("File de reprise", isOn: $settings.reviewRedo)
                Toggle("Noter les indices de Claude", isOn: $settings.reviewHints)
                if settings.reviewRedo {
                    let ladder = ClaudeProjectSetup.file(settings: settings)?.redo ?? RedoLadder.Config()
                    LabeledContent("Paliers") {
                        Text(ladder.steps.map(\.label).joined(separator: " → ") + " · \(ladder.maxPerSeries) par série au plus")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Après une série")
            } footer: {
                Text("Quand tu clos une série, Claude compare ta copie au corrigé : les corrections, les erreurs (type, bonne démarche) et les exercices à refaire sur papier te sont proposés, rien n'est noté sans ton accord. Les paliers de la reprise se changent dans studytrack.json (« redo »).")
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
        .disabled(timer.isLocked)
        .sheet(isPresented: $editingButtons) {
            ClaudeButtonsEditor(url: ClaudeProjectSetup.fileURL(settings: settings))
        }
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

    /// Ouvre `studytrack.json` (le crée vide d'abord).
    private func openProjectFile(exists: Bool) {
        let url = ClaudeProjectSetup.fileURL(settings: settings)
        if !exists {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ClaudeProject.emptyFileTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
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
