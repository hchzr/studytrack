import Foundation
import Observation
import ServiceManagement

/// Les réglages du Mac (⌘,). Ceux de l'iPhone restent sur l'iPhone : un Mac
/// de bureau n'a pas forcément le même rythme.
@MainActor
@Observable
final class MacSettings {
    private let defaults = UserDefaults.standard

    var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "mac.focusMinutes") } }
    var shortBreakMinutes: Int { didSet { defaults.set(shortBreakMinutes, forKey: "mac.shortBreakMinutes") } }
    var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: "mac.longBreakMinutes") } }
    var longBreakEvery: Int { didSet { defaults.set(longBreakEvery, forKey: "mac.longBreakEvery") } }
    var autoStartFocus: Bool { didSet { defaults.set(autoStartFocus, forKey: "mac.autoStartFocus") } }
    var pomodoroDefault: Bool { didSet { defaults.set(pomodoroDefault, forKey: "mac.pomodoroDefault") } }
    /// Le temps à côté de l'icône, dans la barre des menus.
    var showTimeInMenuBar: Bool { didSet { defaults.set(showTimeInMenuBar, forKey: "mac.showTimeInMenuBar") } }
    /// ⌃⌥Espace démarre ou met en pause, depuis n'importe quelle app.
    var globalShortcut: Bool { didSet { defaults.set(globalShortcut, forKey: "mac.globalShortcut") } }

    init() {
        focusMinutes = defaults.object(forKey: "mac.focusMinutes") as? Int ?? 25
        shortBreakMinutes = defaults.object(forKey: "mac.shortBreakMinutes") as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: "mac.longBreakMinutes") as? Int ?? 15
        longBreakEvery = defaults.object(forKey: "mac.longBreakEvery") as? Int ?? 4
        autoStartFocus = defaults.bool(forKey: "mac.autoStartFocus")
        pomodoroDefault = defaults.bool(forKey: "mac.pomodoroDefault")
        showTimeInMenuBar = defaults.object(forKey: "mac.showTimeInMenuBar") as? Bool ?? true
        globalShortcut = defaults.object(forKey: "mac.globalShortcut") as? Bool ?? true
    }

    var pomodoro: PomodoroSettings {
        PomodoroSettings(focusMinutes: focusMinutes, shortBreakMinutes: shortBreakMinutes,
                         longBreakMinutes: longBreakMinutes, longBreakEvery: longBreakEvery,
                         autoStartFocus: autoStartFocus)
    }

    // MARK: Ouverture à la connexion

    /// Lu chez le système, pas gardé ici : l'utilisateur·rice peut le changer
    /// dans Réglages Système › Ouverture.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            launchAtLoginRevision += 1
        }
    }
    /// Force la relecture de `launchAtLogin` après un changement.
    private(set) var launchAtLoginRevision = 0
    var launchAtLoginError: String?
}
