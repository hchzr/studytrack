import Foundation
import Observation
import SwiftData
import ServiceManagement

/// Les réglages du Mac (⌘,).
///
/// Ce qui touche à l'étude — cycle Pomodoro, objectif de la semaine, nom,
/// section — vit dans `shared` (`SettingsStore`), partagé avec l'iPhone par
/// iCloud : régler 50/10 sur le Mac le règle sur l'iPhone. Le reste (barre des
/// menus, Dock, raccourci, mode étude du Mac) est propre au Mac.
@MainActor
@Observable
final class MacSettings {
    private let defaults = UserDefaults.standard
    /// Les réglages d'étude communs à l'iPhone et au Mac.
    let shared = SettingsStore()

    var focusMinutes: Int {
        get { shared.pomodoroFocusMinutes }
        set { shared.pomodoroFocusMinutes = newValue }
    }
    var shortBreakMinutes: Int {
        get { shared.pomodoroBreakMinutes }
        set { shared.pomodoroBreakMinutes = newValue }
    }
    var longBreakMinutes: Int {
        get { shared.pomodoroLongBreakMinutes }
        set { shared.pomodoroLongBreakMinutes = newValue }
    }
    var longBreakEvery: Int {
        get { shared.pomodoroLongBreakEvery }
        set { shared.pomodoroLongBreakEvery = newValue }
    }
    var autoStartFocus: Bool {
        get { shared.pomodoroAutoStartFocus }
        set { shared.pomodoroAutoStartFocus = newValue }
    }
    var pomodoroDefault: Bool {
        get { shared.pomodoroDefault }
        set { shared.pomodoroDefault = newValue }
    }
    /// Le temps à côté de l'icône, dans la barre des menus.
    var showTimeInMenuBar: Bool { didSet { defaults.set(showTimeInMenuBar, forKey: "mac.showTimeInMenuBar") } }
    /// ⌃⌥Espace démarre ou met en pause, depuis n'importe quelle app.
    var globalShortcut: Bool { didSet { defaults.set(globalShortcut, forKey: "mac.globalShortcut") } }
    /// L'objectif de la semaine, en minutes, commun à l'iPhone (0 : celui de
    /// la charge EPFL). Le jour en vise le septième.
    var weeklyGoalMinutes: Int {
        get { shared.weeklyGoalMinutes }
        set { shared.weeklyGoalMinutes = newValue }
    }
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
    /// Fermer les apps non permises (sinon : seulement les couvrir d'un voile).
    var studyCloseApps: Bool { didSet { defaults.set(studyCloseApps, forKey: "mac.studyCloseApps2") } }
    /// Cacher le Dock et la barre des menus pendant un blocage (System Events).
    /// La bande-son des sessions (jamais pendant un cours) et ce qu'elle fait pendant une pause.
    var studySoundtrack: SessionSoundtrack.Choice? {
        didSet { defaults.set(SessionSoundtrack.encode(studySoundtrack), forKey: "mac.studySoundtrack") }
    }
    var studySoundtrackOnBreak: SessionSoundtrack.BreakPolicy {
        didSet { defaults.set(studySoundtrackOnBreak.rawValue, forKey: "mac.studySoundtrackOnBreak") }
    }
    /// Le mode étude reste sombre (défaut) ou suit l'apparence du Mac.
    var studyAlwaysDark: Bool { didSet { defaults.set(studyAlwaysDark, forKey: "mac.studyAlwaysDark") } }
    /// Bloquer aussi les gestes du trackpad (Mission Control, changer de bureau…).
    var studyBlockGestures: Bool { didSet { defaults.set(studyBlockGestures, forKey: "mac.studyBlockGestures") } }
    var studyHideSystemChrome: Bool { didSet { defaults.set(studyHideSystemChrome, forKey: "mac.studyHideSystemChrome") } }
    /// Le mode étude bloque le reste (apps, sites, iPhone). Coupé : un écran
    /// de travail, sans rien fermer.
    var studyBlocking: Bool { didSet { defaults.set(studyBlocking, forKey: "mac.studyBlocking") } }
    /// Garder le Mac éveillé pendant que le chrono du mode étude tourne.
    var studyKeepAwake: KeepAwakePolicy.Mode { didSet { defaults.set(studyKeepAwake.rawValue, forKey: "mac.studyKeepAwake") } }
    /// Pomodoro pendant le mode étude.
    var studyPomodoro: Bool { didSet { defaults.set(studyPomodoro, forKey: "mac.studyPomodoro") } }
    /// Le dernier mode étude était sans fin : le choix le repropose.
    var studyOpenEnded: Bool { didSet { defaults.set(studyOpenEnded, forKey: "mac.studyOpenEnded") } }

    // MARK: Claude

    /// Le « projet EPFL » : Claude tourne dans un dossier à soi, avec les
    /// compétences de l'étudiant·e et les serveurs MCP qu'elles utilisent.
    /// Coupé par défaut : le mode isolé coûte ~600 jetons par message.
    var claudeProject: Bool { didSet { defaults.set(claudeProject, forKey: "mac.claudeProject") } }
    /// Le dossier du projet (`~/EPFL` par défaut).
    var claudeProjectFolder: String { didSet { defaults.set(claudeProjectFolder, forKey: "mac.claudeProjectFolder") } }
    /// L'adresse du serveur MCP de StudyTrack (iPhone › Réglages › Assistant IA).
    var claudeStudyTrackMCP: String { didSet { defaults.set(claudeStudyTrackMCP, forKey: "mac.claudeStudyTrackMCP") } }

    // MARK: Après une série (chacun s'éteint : l'app reste simple pour qui n'en veut pas)

    /// Le carnet d'erreurs : chaque écart d'un post-mortem devient une ligne.
    var reviewMistakes: Bool { didSet { defaults.set(reviewMistakes, forKey: "mac.reviewMistakes") } }
    /// La file de reprise : refaire sur papier les exercices qui ont coincé.
    var reviewRedo: Bool { didSet { defaults.set(reviewRedo, forKey: "mac.reviewRedo") } }
    /// Les indices de Claude notés exercice par exercice.
    var reviewHints: Bool { didSet { defaults.set(reviewHints, forKey: "mac.reviewHints") } }

    /// Ce qui est allumé, tel que Claude le reçoit (plafond du projet compris).
    func reviewFeatures(_ file: ClaudeProject.File?) -> SeriesReview.Features {
        SeriesReview.Features(mistakes: reviewMistakes, redo: reviewRedo, hints: reviewHints,
                              redoPerSeries: file?.redo?.maxPerSeries ?? RedoLadder.Config().maxPerSeries)
    }

    init() {
        showTimeInMenuBar = defaults.object(forKey: "mac.showTimeInMenuBar") as? Bool ?? true
        globalShortcut = defaults.object(forKey: "mac.globalShortcut") as? Bool ?? true
        floatingTimer = defaults.object(forKey: "mac.floatingTimer") as? Bool ?? true
        sounds = defaults.object(forKey: "mac.sounds") as? Bool ?? true
        keepInDock = defaults.bool(forKey: "mac.keepInDock")
        menuBarSeconds = defaults.bool(forKey: "mac.menuBarSeconds")
        // Les sites ajoutés depuis (GeoGebra, Desmos…) rejoignent une liste déjà enregistrée.
        let savedSites = defaults.stringArray(forKey: "mac.studySites") ?? StudyMode.defaultSites
        studySites = savedSites + StudyMode.defaultSites.filter { !savedSites.contains($0) && StudyMode.addedLater.contains($0) }
        // Le Finder n'est plus permis d'office (⌥⌘Espace y ouvrait tout le disque) :
        // retiré des listes déjà enregistrées, une seule fois.
        var savedApps = defaults.stringArray(forKey: "mac.studyApps") ?? StudyMode.defaultMacApps
        if !defaults.bool(forKey: "mac.studyApps.v2") {
            savedApps = StudyMode.removingFinder(from: savedApps)
            defaults.set(savedApps, forKey: "mac.studyApps")
            defaults.set(true, forKey: "mac.studyApps.v2")
        }
        studyApps = savedApps
        studyMinutes = defaults.object(forKey: "mac.studyMinutes") as? Int ?? 50
        studyHoldToLeave = defaults.object(forKey: "mac.studyHoldToLeave") as? Bool ?? true
        studyPomodoro = defaults.bool(forKey: "mac.studyPomodoro")
        studyOpenEnded = defaults.bool(forKey: "mac.studyOpenEnded")
        // Fermer les autres apps n'est plus le défaut : une app peut refuser (le
        // Terminal demande), alors que la masquer et la couvrir marche toujours.
        studyCloseApps = defaults.object(forKey: "mac.studyCloseApps2") as? Bool ?? false
        studySoundtrack = SessionSoundtrack.decode(defaults.data(forKey: "mac.studySoundtrack"))
        studySoundtrackOnBreak = defaults.string(forKey: "mac.studySoundtrackOnBreak")
            .flatMap(SessionSoundtrack.BreakPolicy.init(rawValue:)) ?? .pause
        studyAlwaysDark = defaults.object(forKey: "mac.studyAlwaysDark") as? Bool ?? true
        studyBlockGestures = defaults.object(forKey: "mac.studyBlockGestures") as? Bool ?? true
        studyHideSystemChrome = defaults.object(forKey: "mac.studyHideSystemChrome") as? Bool ?? true
        studyBlocking = defaults.object(forKey: "mac.studyBlocking") as? Bool ?? true
        studyKeepAwake = defaults.string(forKey: "mac.studyKeepAwake").flatMap(KeepAwakePolicy.Mode.init(rawValue:)) ?? .off
        claudeProject = defaults.bool(forKey: "mac.claudeProject")
        claudeProjectFolder = defaults.string(forKey: "mac.claudeProjectFolder")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("EPFL").path
        claudeStudyTrackMCP = defaults.string(forKey: "mac.claudeStudyTrackMCP") ?? ""
        reviewMistakes = defaults.object(forKey: "mac.reviewMistakes") as? Bool ?? true
        reviewRedo = defaults.object(forKey: "mac.reviewRedo") as? Bool ?? true
        reviewHints = defaults.object(forKey: "mac.reviewHints") as? Bool ?? true
        migrateLegacyPreferences()
    }

    /// Les réglages Pomodoro et l'objectif du jour du Mac (clés `mac.*`) passent,
    /// une fois, dans les réglages partagés — sauf si l'iPhone les a déjà réglés.
    private func migrateLegacyPreferences() {
        guard !defaults.bool(forKey: "mac.prefsShared") else { return }
        defaults.set(true, forKey: "mac.prefsShared")
        let iCloud = NSUbiquitousKeyValueStore.default
        func carry(_ legacy: String, _ key: String, _ apply: (Any) -> Void) {
            guard let value = defaults.object(forKey: legacy), iCloud.object(forKey: "pref." + key) == nil else { return }
            apply(value)
        }
        carry("mac.focusMinutes", "settings.pomodoroFocusMinutes") { self.focusMinutes = $0 as? Int ?? 25 }
        carry("mac.shortBreakMinutes", "settings.pomodoroBreakMinutes") { self.shortBreakMinutes = $0 as? Int ?? 5 }
        carry("mac.longBreakMinutes", "settings.pomodoroLongBreakMinutes") { self.longBreakMinutes = $0 as? Int ?? 15 }
        carry("mac.longBreakEvery", "settings.pomodoroLongBreakEvery") { self.longBreakEvery = $0 as? Int ?? 4 }
        carry("mac.autoStartFocus", "settings.pomodoroAutoStartFocus") { self.autoStartFocus = $0 as? Bool ?? false }
        carry("mac.pomodoroDefault", "settings.pomodoroDefault") { self.pomodoroDefault = $0 as? Bool ?? false }
        carry("mac.dailyGoalMinutes", "settings.weeklyGoalMinutes") { self.weeklyGoalMinutes = ($0 as? Int ?? 0) * 7 }
    }

    /// L'objectif de la semaine (réglé, sinon la charge EPFL des cours suivis).
    func weeklyGoalSeconds(in context: ModelContext) -> Int {
        StudyGoal.weeklySeconds(in: context, goalMinutes: weeklyGoalMinutes, hoursPerCredit: shared.hoursPerCredit)
    }

    /// Le septième de l'objectif de la semaine : l'anneau du jour.
    func dailyGoalSeconds(in context: ModelContext) -> Int {
        StudyGoal.dailySeconds(weekly: weeklyGoalSeconds(in: context))
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
