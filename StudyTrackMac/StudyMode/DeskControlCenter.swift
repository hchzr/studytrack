import SwiftUI

/// Le centre de contrôle du bureau d'étude : ce que le Centre de contrôle de
/// macOS offrait et qu'un blocage ferme — le volume de la musique, garder le
/// Mac éveillé, l'apparence, ranger le bureau, et ce qui est bloqué.
struct DeskControlCenterButton: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "switch.2")
                .font(.callout)
                .foregroundStyle(StudyPalette.inkSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Centre de contrôle")
        .popover(isPresented: $shown, arrowEdge: .bottom) { DeskControlCenter() }
    }
}

private struct DeskControlCenter: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @State private var music = StudyMusic.shared

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 16) {
            if let volume = music.volume {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(StudyPalette.inkSecondary)
                    Slider(value: Binding(get: { volume }, set: { music.setVolume($0) }), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(StudyPalette.inkSecondary)
                }
            }
            Picker("Garder éveillé", selection: $settings.studyKeepAwake) {
                Text("Non").tag(KeepAwakePolicy.Mode.off)
                Text("Le Mac").tag(KeepAwakePolicy.Mode.system)
                Text("Le Mac et l'écran").tag(KeepAwakePolicy.Mode.display)
            }
            .onChange(of: settings.studyKeepAwake) { _, _ in StudyModeController.shared.update() }
            Toggle("Toujours sombre", isOn: $settings.studyAlwaysDark)
                .onChange(of: settings.studyAlwaysDark) { _, _ in StudyModeController.shared.update() }
            Divider()
            HStack(spacing: 10) {
                Button("Réorganiser les outils") { NotificationCenter.default.post(name: .studyTidyDesk, object: nil) }
                if !StudyMode.isOpenEnded(timer.state) {
                    Button("Encore 25 min") { timer.extendStudy(minutes: 25) }
                }
            }
            Divider()
            Label(blockedSummary, systemImage: timer.studyLocks ? "lock.fill" : "lock.open")
                .font(.caption)
                .foregroundStyle(StudyPalette.inkSecondary)
        }
        .padding(16)
        .frame(width: 300)
        .environment(\.colorScheme, .dark)
    }

    private var blockedSummary: String {
        guard timer.studyLocks else { return String(localized: "Rien n'est bloqué.") }
        let apps = settings.studyApps.filter { StudyModeController.isInstalled($0) }.count
        let system = SystemLock.processSwitchingOff ? String(localized: " Raccourcis du système éteints.") : ""
        return String(localized: "Tout est bloqué sauf \(apps) apps et \(settings.studySites.count) sites.") + system
    }
}
