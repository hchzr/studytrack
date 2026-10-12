import Foundation
import Observation
import OSLog
#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings
import DeviceActivity
#endif

/// Le mode étude sur l'iPhone : le Temps d'écran ferme tout sauf les apps
/// choisies (GoodNotes, Claude, Safari…) et les sites de cours.
///
/// **Comment.** L'autorisation « individuelle » du Temps d'écran (FamilyControls)
/// permet à l'app de poser un bouclier (`ManagedSettingsStore`) sur toutes les
/// apps **sauf** celles qu'on a choisies une fois dans le sélecteur d'Apple —
/// l'app ne voit que des jetons opaques, jamais la liste de ce qui est installé.
/// Le web est filtré par domaine : seuls les sites permis s'ouvrent, dans Safari
/// comme dans les apps.
///
/// **Quand.** Le mode étude n'est qu'une date dans le chrono partagé
/// (`FocusTimerState.studyUntil`). `sync(_:)` est appelé à chaque changement
/// du chrono (geste ici, état adopté du Mac, réveil par push iCloud) : il pose
/// ou lève le bouclier. Et pour ne jamais laisser l'iPhone fermé si l'app ne se
/// réveille pas à temps, une activité planifiée (`DeviceActivityCenter`) court
/// jusqu'à l'échéance : l'extension `StudyTrackLock` lève le bouclier à la fin,
/// app fermée ou non.
@MainActor
@Observable
final class StudyLock {
    static let shared = StudyLock()

    /// L'autorisation du Temps d'écran a été donnée.
    private(set) var isAuthorized = false
    /// Le bouclier est posé en ce moment.
    private(set) var isShielding = false
    private(set) var lastError: String?

    private let log = Logger(subsystem: "com.hczr.studytrack", category: "studylock")
    private static let selectionKey = "studyLock.selection"
    private static let sitesKey = "studyMode.sites"

    #if canImport(FamilyControls)
    /// Les apps permises, choisies dans le sélecteur d'Apple.
    var selection = FamilyActivitySelection() {
        didSet { saveSelection() }
    }
    private let store = ManagedSettingsStore(named: .studyMode)
    #endif

    init() {
        #if canImport(FamilyControls)
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
        if let data = UserDefaults.standard.data(forKey: Self.selectionKey),
           let saved = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selection = saved
        }
        #endif
    }

    /// Le nombre d'apps permises (pour les réglages).
    var allowedAppCount: Int {
        #if canImport(FamilyControls)
        return selection.applicationTokens.count + selection.categoryTokens.count
        #else
        return 0
        #endif
    }

    /// Les sites permis : ceux du Mac (iCloud clé-valeur), sinon par défaut.
    var sites: [String] {
        get { NSUbiquitousKeyValueStore.default.array(forKey: Self.sitesKey) as? [String] ?? StudyMode.defaultSites }
        set {
            NSUbiquitousKeyValueStore.default.set(newValue, forKey: Self.sitesKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    // MARK: Autorisation

    func requestAuthorization() async {
        #if canImport(FamilyControls)
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("autorisation refusée : \(error.localizedDescription, privacy: .public)")
        }
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
        #endif
    }

    // MARK: Suivre le chrono

    /// Pose ou lève le bouclier selon l'état du chrono.
    func sync(_ state: FocusTimerState?, now: Date = Date()) {
        if StudyMode.locks(state, at: now), let until = state?.studyUntil {
            shield(until: until)
        } else {
            release()
        }
    }

    private func shield(until: Date) {
        #if canImport(FamilyControls)
        guard isAuthorized else { return }
        store.shield.applicationCategories = .all(except: selection.applicationTokens)
        store.shield.webDomainCategories = .all(except: selection.webDomainTokens)
        let domains = Set(sites.compactMap(StudyMode.normalizedDomain).map { WebDomain(domain: $0) })
        store.webContent.blockedByFilter = .all(except: domains)
        if !isShielding { log.notice("bouclier posé jusqu'à \(until, privacy: .public)") }
        isShielding = true
        scheduleRelease(at: until)
        #endif
    }

    func release() {
        #if canImport(FamilyControls)
        guard isShielding || store.shield.applicationCategories != nil else { return }
        store.clearAllSettings()
        DeviceActivityCenter().stopMonitoring([.studyMode])
        isShielding = false
        log.notice("bouclier levé")
        #endif
    }

    #if canImport(FamilyControls)
    /// La levée planifiée : l'extension lève le bouclier à l'échéance, même
    /// si l'app dort. Le système exige au moins 15 minutes : une session plus
    /// courte est levée par l'app elle-même, ou au plus tard à 15 min.
    private func scheduleRelease(at until: Date) {
        let start = Date()
        let end = max(until, start.addingTimeInterval(15 * 60 + 5))
        let calendar = Calendar.current
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(intervalStart: calendar.dateComponents(parts, from: start),
                                              intervalEnd: calendar.dateComponents(parts, from: end),
                                              repeats: false)
        let center = DeviceActivityCenter()
        center.stopMonitoring([.studyMode])
        do {
            try center.startMonitoring(.studyMode, during: schedule)
        } catch {
            log.error("levée planifiée impossible : \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveSelection() {
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
    }
    #endif
}

#if canImport(FamilyControls)
extension ManagedSettingsStore.Name {
    /// Le magasin du mode étude, partagé avec l'extension `StudyTrackLock`.
    static let studyMode = Self("studytrack.studyMode")
}

extension DeviceActivityName {
    static let studyMode = Self("studytrack.studyMode")
}
#endif
