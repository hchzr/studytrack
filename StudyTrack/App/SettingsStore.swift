import Foundation
import Observation

/// Réglages persistés dans `UserDefaults`. Observables par SwiftUI.
@Observable
final class SettingsStore {
    private enum Key {
        static let hoursPerCredit = "settings.hoursPerCredit"
        static let pomodoroFocusMinutes = "settings.pomodoroFocusMinutes"
        static let pomodoroBreakMinutes = "settings.pomodoroBreakMinutes"
        static let pomodoroLongBreakMinutes = "settings.pomodoroLongBreakMinutes"
        static let pomodoroLongBreakEvery = "settings.pomodoroLongBreakEvery"
        static let pomodoroAutoStartFocus = "settings.pomodoroAutoStartFocus"
        static let pomodoroDefault = "settings.pomodoroDefault"
        static let displayName = "settings.displayName"
        static let sectionCode = "settings.sectionCode"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        static let anonymousInLeaderboards = "settings.anonymousInLeaderboards"
        static let dailyReminderEnabled = "settings.dailyReminderEnabled"
        static let dailyReminderHour = "settings.dailyReminderHour"
        static let weeklyRecapEnabled = "settings.weeklyRecapEnabled"
        static let todoistToken = "settings.todoistToken"
        static let googleClientID = "settings.googleClientID"
        static let googleClientSecret = "settings.googleClientSecret"
        static let googleRefreshToken = "settings.googleRefreshToken"
        static let tickTickToken = "settings.tickTickToken"
        static let notionToken = "settings.notionToken"
        static let notionDatabaseID = "settings.notionDatabaseID"
        static let webhookURL = "settings.webhookURL"
        static let thingsEnabled = "settings.thingsEnabled"
        static let timetableURLString = "settings.timetableURLString"
        static let shareProgressWithGroups = "settings.shareProgressWithGroups"
        static let trackAttendance = "settings.trackAttendance"
        static let hasSeededSampleData = "settings.hasSeededSampleData"
        static let focusShortcuts = "settings.focusShortcuts"
        static let ankiEndpoint = "settings.ankiEndpoint"
        static let ankiDeck = "settings.ankiDeck"
        static let ankiModel = "settings.ankiModel"
        static let ankiLastReviewID = "settings.ankiLastReviewID"
        static let ankiLastSync = "settings.ankiLastSync"
        static let aiExtractionEnabled = "settings.aiExtractionEnabled"
        /// Anciennes clés du « service perso » (clé d'API saisie), retiré :
        /// effacées au lancement pour ne pas garder une clé en clair.
        static let legacyAI = ["settings.aiEndpoint", "settings.aiAPIKey", "settings.aiModel"]
        static let contentAutoRefresh = "settings.contentAutoRefresh"
        static let contentLastRefresh = "settings.contentLastRefresh"
        static let contentRefreshNews = "settings.contentRefreshNews"
        static let assistantToken = "settings.assistantToken"
        static let assistantLastSync = "settings.assistantLastSync"
    }

    private let defaults: UserDefaults

    // MARK: Charge EPFL
    /// Heures de travail attendues par crédit ECTS (EPFL : ~25–30 h).
    var hoursPerCredit: Double { didSet { defaults.set(hoursPerCredit, forKey: Key.hoursPerCredit) } }

    // MARK: Identité académique
    var displayName: String { didSet { defaults.set(displayName, forKey: Key.displayName) } }
    /// Section EPFL choisie (code, ex : « IN »).
    var sectionCode: String { didSet { defaults.set(sectionCode, forKey: Key.sectionCode) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }

    var section: EPFLSection? { EPFLCatalog.section(code: sectionCode) }

    // MARK: Pomodoro
    var pomodoroFocusMinutes: Int { didSet { defaults.set(pomodoroFocusMinutes, forKey: Key.pomodoroFocusMinutes) } }
    /// La pause courte. La clé historique est conservée : les réglages déjà
    /// faits ne sont pas perdus.
    var pomodoroBreakMinutes: Int { didSet { defaults.set(pomodoroBreakMinutes, forKey: Key.pomodoroBreakMinutes) } }
    var pomodoroLongBreakMinutes: Int { didSet { defaults.set(pomodoroLongBreakMinutes, forKey: Key.pomodoroLongBreakMinutes) } }
    var pomodoroLongBreakEvery: Int { didSet { defaults.set(pomodoroLongBreakEvery, forKey: Key.pomodoroLongBreakEvery) } }
    var pomodoroAutoStartFocus: Bool { didSet { defaults.set(pomodoroAutoStartFocus, forKey: Key.pomodoroAutoStartFocus) } }
    /// Une nouvelle session démarre-t-elle en Pomodoro ?
    var pomodoroDefault: Bool { didSet { defaults.set(pomodoroDefault, forKey: Key.pomodoroDefault) } }

    /// Le cycle tel que la logique pure l'attend.
    var pomodoro: PomodoroSettings {
        PomodoroSettings(focusMinutes: pomodoroFocusMinutes,
                         shortBreakMinutes: pomodoroBreakMinutes,
                         longBreakMinutes: pomodoroLongBreakMinutes,
                         longBreakEvery: pomodoroLongBreakEvery,
                         autoStartFocus: pomodoroAutoStartFocus)
    }

    // MARK: Suivi
    /// Suivre la présence en amphi (heures de cours réelles).
    var trackAttendance: Bool { didSet { defaults.set(trackAttendance, forKey: Key.trackAttendance) } }

    // MARK: Vie privée
    var anonymousInLeaderboards: Bool { didSet { defaults.set(anonymousInLeaderboards, forKey: Key.anonymousInLeaderboards) } }
    var shareProgressWithGroups: Bool { didSet { defaults.set(shareProgressWithGroups, forKey: Key.shareProgressWithGroups) } }

    // MARK: Notifications
    var dailyReminderEnabled: Bool { didSet { defaults.set(dailyReminderEnabled, forKey: Key.dailyReminderEnabled) } }
    var dailyReminderHour: Int { didSet { defaults.set(dailyReminderHour, forKey: Key.dailyReminderHour) } }
    var weeklyRecapEnabled: Bool { didSet { defaults.set(weeklyRecapEnabled, forKey: Key.weeklyRecapEnabled) } }

    // MARK: Intégrations — tâches
    var todoistToken: String { didSet { defaults.set(todoistToken, forKey: Key.todoistToken) } }
    var googleClientID: String { didSet { defaults.set(googleClientID, forKey: Key.googleClientID) } }
    var googleClientSecret: String { didSet { defaults.set(googleClientSecret, forKey: Key.googleClientSecret) } }
    var googleRefreshToken: String { didSet { defaults.set(googleRefreshToken, forKey: Key.googleRefreshToken) } }
    var tickTickToken: String { didSet { defaults.set(tickTickToken, forKey: Key.tickTickToken) } }
    var notionToken: String { didSet { defaults.set(notionToken, forKey: Key.notionToken) } }
    var notionDatabaseID: String { didSet { defaults.set(notionDatabaseID, forKey: Key.notionDatabaseID) } }
    var webhookURL: String { didSet { defaults.set(webhookURL, forKey: Key.webhookURL) } }
    var thingsEnabled: Bool { didSet { defaults.set(thingsEnabled, forKey: Key.thingsEnabled) } }

    // MARK: Intégrations — calendrier & social
    /// URL du flux iCalendar « Mon horaire » (EPFL) ou de tout autre calendrier.
    var timetableURLString: String { didSet { defaults.set(timetableURLString, forKey: Key.timetableURLString) } }

    // MARK: Import intelligent (analyse des PDF)
    /// Proposer l'analyse par modèle de langage à l'import d'un PDF.
    var aiExtractionEnabled: Bool { didSet { defaults.set(aiExtractionEnabled, forKey: Key.aiExtractionEnabled) } }

    // MARK: Anki
    /// Adresse d'AnkiConnect. Vide = fonctionnalité éteinte.
    ///
    /// Ce n'est pas `127.0.0.1` par défaut : sur un iPhone, cette adresse désigne
    /// le téléphone lui-même, pas le Mac où tourne Anki. On laisse le champ vide
    /// et l'écran explique quoi y mettre, plutôt que de proposer une valeur qui ne
    /// peut pas marcher.
    var ankiEndpoint: String { didSet { defaults.set(ankiEndpoint, forKey: Key.ankiEndpoint) } }
    var ankiDeck: String { didSet { defaults.set(ankiDeck, forKey: Key.ankiDeck) } }
    /// Modèle de note Anki. « Basic » est le nom par défaut d'Anki.
    var ankiModel: String { didSet { defaults.set(ankiModel, forKey: Key.ankiModel) } }

    var isAnkiConfigured: Bool { AnkiConnect.normalizeEndpoint(ankiEndpoint) != nil }

    /// Dernière révision Anki déjà relevée (ms depuis 1970) : l'import suivant
    /// ne demande que les révisions plus récentes.
    var ankiLastReviewID: Double { didSet { defaults.set(ankiLastReviewID, forKey: Key.ankiLastReviewID) } }
    /// Dernier relevé réussi du temps Anki.
    var ankiLastSync: Date? { didSet { defaults.set(ankiLastSync, forKey: Key.ankiLastSync) } }

    // MARK: Contenu des cours
    /// Relire Moodle et Botafogo tout seul (au plus deux fois par jour) pour
    /// ajouter la série de la semaine dès qu'elle est publiée.
    var contentAutoRefresh: Bool { didSet { defaults.set(contentAutoRefresh, forKey: Key.contentAutoRefresh) } }
    var contentLastRefresh: Date? { didSet { defaults.set(contentLastRefresh, forKey: Key.contentLastRefresh) } }
    /// « Moodle : Série 4 ajoutée en MATH-101 » — affiché sur l'accueil
    /// jusqu'à ce qu'on le ferme ; vide quand il n'y a rien de neuf.
    var contentRefreshNews: String { didSet { defaults.set(contentRefreshNews, forKey: Key.contentRefreshNews) } }

    // MARK: Assistant IA (MCP)
    /// Jeton secret qui relie l'app à son serveur MCP. Vide = pas relié.
    var assistantToken: String { didSet { defaults.set(assistantToken, forKey: Key.assistantToken) } }
    var assistantLastSync: Date? { didSet { defaults.set(assistantLastSync, forKey: Key.assistantLastSync) } }

    // MARK: Chrono
    /// Raccourcis du chrono, composés par l'étudiant·e.
    ///
    /// Stockés en JSON plutôt qu'en liste de clés : l'ordre compte, et un tableau
    /// se relit d'un coup.
    var focusShortcutsRaw: String { didSet { defaults.set(focusShortcutsRaw, forKey: Key.focusShortcuts) } }

    var focusShortcuts: [FocusShortcut] {
        get { FocusShortcut.decode(focusShortcutsRaw) }
        set { focusShortcutsRaw = FocusShortcut.encode(newValue) }
    }

    // MARK: État interne
    var hasSeededSampleData: Bool { didSet { defaults.set(hasSeededSampleData, forKey: Key.hasSeededSampleData) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hoursPerCredit = defaults.object(forKey: Key.hoursPerCredit) as? Double ?? 30
        self.pomodoroFocusMinutes = defaults.object(forKey: Key.pomodoroFocusMinutes) as? Int ?? 25
        self.pomodoroBreakMinutes = defaults.object(forKey: Key.pomodoroBreakMinutes) as? Int ?? 5
        self.pomodoroLongBreakMinutes = defaults.object(forKey: Key.pomodoroLongBreakMinutes) as? Int ?? 15
        self.pomodoroLongBreakEvery = defaults.object(forKey: Key.pomodoroLongBreakEvery) as? Int ?? 4
        self.pomodoroAutoStartFocus = defaults.object(forKey: Key.pomodoroAutoStartFocus) as? Bool ?? false
        self.pomodoroDefault = defaults.object(forKey: Key.pomodoroDefault) as? Bool ?? false
        self.displayName = defaults.string(forKey: Key.displayName) ?? ""
        self.sectionCode = defaults.string(forKey: Key.sectionCode) ?? ""
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.trackAttendance = defaults.object(forKey: Key.trackAttendance) as? Bool ?? true
        self.anonymousInLeaderboards = defaults.bool(forKey: Key.anonymousInLeaderboards)
        self.shareProgressWithGroups = defaults.object(forKey: Key.shareProgressWithGroups) as? Bool ?? true
        self.dailyReminderEnabled = defaults.object(forKey: Key.dailyReminderEnabled) as? Bool ?? true
        self.dailyReminderHour = defaults.object(forKey: Key.dailyReminderHour) as? Int ?? 19
        self.weeklyRecapEnabled = defaults.object(forKey: Key.weeklyRecapEnabled) as? Bool ?? true
        self.todoistToken = defaults.string(forKey: Key.todoistToken) ?? ""
        self.googleClientID = defaults.string(forKey: Key.googleClientID) ?? ""
        self.googleClientSecret = defaults.string(forKey: Key.googleClientSecret) ?? ""
        self.googleRefreshToken = defaults.string(forKey: Key.googleRefreshToken) ?? ""
        self.tickTickToken = defaults.string(forKey: Key.tickTickToken) ?? ""
        self.notionToken = defaults.string(forKey: Key.notionToken) ?? ""
        self.notionDatabaseID = defaults.string(forKey: Key.notionDatabaseID) ?? ""
        self.webhookURL = defaults.string(forKey: Key.webhookURL) ?? ""
        self.thingsEnabled = defaults.bool(forKey: Key.thingsEnabled)
        self.timetableURLString = defaults.string(forKey: Key.timetableURLString) ?? ""
        self.hasSeededSampleData = defaults.bool(forKey: Key.hasSeededSampleData)
        self.focusShortcutsRaw = defaults.string(forKey: Key.focusShortcuts) ?? ""
        self.ankiEndpoint = defaults.string(forKey: Key.ankiEndpoint) ?? ""
        self.ankiDeck = defaults.string(forKey: Key.ankiDeck) ?? "StudyTrack"
        self.ankiModel = defaults.string(forKey: Key.ankiModel) ?? "Basic"
        self.ankiLastReviewID = defaults.double(forKey: Key.ankiLastReviewID)
        self.ankiLastSync = defaults.object(forKey: Key.ankiLastSync) as? Date
        self.contentAutoRefresh = defaults.object(forKey: Key.contentAutoRefresh) as? Bool ?? true
        self.contentLastRefresh = defaults.object(forKey: Key.contentLastRefresh) as? Date
        self.contentRefreshNews = defaults.string(forKey: Key.contentRefreshNews) ?? ""
        self.assistantToken = defaults.string(forKey: Key.assistantToken) ?? ""
        self.assistantLastSync = defaults.object(forKey: Key.assistantLastSync) as? Date
        self.aiExtractionEnabled = defaults.object(forKey: Key.aiExtractionEnabled) as? Bool ?? true
        for key in Key.legacyAI { defaults.removeObject(forKey: key) }
    }

    /// Vrai quand la **build** porte une configuration Supabase — ce n'est plus un
    /// réglage d'utilisateur (voir `SupabaseConfig`).
    var isSupabaseConfigured: Bool {
        SupabaseConfig.isConfigured
    }

    var hasTimetableURL: Bool {
        !timetableURLString.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
