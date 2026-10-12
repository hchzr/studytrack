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
    /// L'objectif d'étude du jour, en minutes (l'anneau du chrono, Aujourd'hui).
    var dailyGoalMinutes: Int { didSet { defaults.set(dailyGoalMinutes, forKey: "mac.dailyGoalMinutes") } }
    /// La petite fenêtre du chrono, au-dessus des autres, pendant une session.
    var floatingTimer: Bool { didSet { defaults.set(floatingTimer, forKey: "mac.floatingTimer") } }
    /// Un son discret à la fin d'un bloc et d'une pause.
    var sounds: Bool { didSet { defaults.set(sounds, forKey: "mac.sounds") } }
    /// L'icône reste dans le Dock fenêtre fermée (sinon : barre des menus seule).
    var keepInDock: Bool { didSet { defaults.set(keepInDock, forKey: "mac.keepInDock") } }
    /// Les secondes dans la barre des menus. Coupé par défaut : la minute suffit
    /// pour se situer, et l'étiquette ne se redessine alors qu'une fois par minute.
    var menuBarSeconds: Bool { didSet { defaults.set(menuBarSeconds, forKey: "mac.menuBarSeconds") } }

    // MARK: Mode étude

    /// Les sites ouverts pendant le mode étude (un domaine couvre ses sous-domaines).
    var studySites: [String] {
        didSet {
            defaults.set(studySites, forKey: "mac.studySites")
            // Les mêmes sites sur l'iPhone (son filtre web les lit ici).
            NSUbiquitousKeyValueStore.default.set(studySites, forKey: "studyMode.sites")
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }
    /// Les apps permises, par identifiant (GoodNotes, Claude, Aperçu…).
    var studyApps: [String] { didSet { defaults.set(studyApps, forKey: "mac.studyApps") } }
    /// La durée proposée au lancement, en minutes.
    var studyMinutes: Int { didSet { defaults.set(studyMinutes, forKey: "mac.studyMinutes") } }
    /// Sortir avant la fin demande d'appuyer longuement : une seconde de
    /// réflexion contre le réflexe.
    var studyHoldToLeave: Bool { didSet { defaults.set(studyHoldToLeave, forKey: "mac.studyHoldToLeave") } }
    /// Pomodoro pendant le mode étude.
    var studyPomodoro: Bool { didSet { defaults.set(studyPomodoro, forKey: "mac.studyPomodoro") } }

    init() {
        focusMinutes = defaults.object(forKey: "mac.focusMinutes") as? Int ?? 25
        shortBreakMinutes = defaults.object(forKey: "mac.shortBreakMinutes") as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: "mac.longBreakMinutes") as? Int ?? 15
        longBreakEvery = defaults.object(forKey: "mac.longBreakEvery") as? Int ?? 4
        autoStartFocus = defaults.bool(forKey: "mac.autoStartFocus")
        pomodoroDefault = defaults.bool(forKey: "mac.pomodoroDefault")
        showTimeInMenuBar = defaults.object(forKey: "mac.showTimeInMenuBar") as? Bool ?? true
        globalShortcut = defaults.object(forKey: "mac.globalShortcut") as? Bool ?? true
        dailyGoalMinutes = defaults.object(forKey: "mac.dailyGoalMinutes") as? Int ?? 180
        floatingTimer = defaults.object(forKey: "mac.floatingTimer") as? Bool ?? true
        sounds = defaults.object(forKey: "mac.sounds") as? Bool ?? true
        keepInDock = defaults.bool(forKey: "mac.keepInDock")
        menuBarSeconds = defaults.bool(forKey: "mac.menuBarSeconds")
        studySites = defaults.stringArray(forKey: "mac.studySites") ?? StudyMode.defaultSites
        studyApps = defaults.stringArray(forKey: "mac.studyApps") ?? StudyMode.defaultMacApps
        studyMinutes = defaults.object(forKey: "mac.studyMinutes") as? Int ?? 50
        studyHoldToLeave = defaults.object(forKey: "mac.studyHoldToLeave") as? Bool ?? true
        studyPomodoro = defaults.bool(forKey: "mac.studyPomodoro")
    }

    var dailyGoalSeconds: Int { max(15, dailyGoalMinutes) * 60 }

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
