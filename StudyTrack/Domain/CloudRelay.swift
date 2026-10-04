import Foundation

/// Ce que les appareils se disent **vite**, par le magasin clé-valeur d'iCloud.
///
/// La base (CloudKit) synchronise les données, en quelques secondes à quelques
/// minutes. Deux choses ne peuvent pas attendre, ni passer par elle :
///   • **le chrono** : démarré sur le Mac, il doit tourner sur l'iPhone ;
///   • **qui relit Moodle** : l'iPhone et l'iPad ne doivent pas relire (et
///     payer l'IA, et notifier) chacun de leur côté.
///
/// Les décisions sont pures (`decide`, `refreshIsDue`, `mergeKnown`) et testées ;
/// le reste lit et écrit `NSUbiquitousKeyValueStore`.
enum CloudRelay {

    // MARK: Appareil

    /// Un identifiant propre à cet appareil (pas l'utilisateur·rice).
    static var deviceID: String {
        let key = "cloudRelay.device"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Posté quand un autre appareil a écrit.
    static let changed = NSUbiquitousKeyValueStore.didChangeExternallyNotification

    private static var store: NSUbiquitousKeyValueStore { .default }

    // MARK: Chrono

    struct TimerSnapshot: Codable, Equatable {
        /// L'état du chrono ; `nil` quand la session vient d'être terminée.
        var state: FocusTimerState?
        /// La session terminée (son début), quand `state` est `nil` : les
        /// autres appareils ferment **cette** session-là, sans l'enregistrer.
        var endedSession: Date?
        var updatedAt: Date
        var device: String
    }

    enum TimerDecision: Equatable {
        case ignore
        case adopt(FocusTimerState)
        /// La session a été terminée (et enregistrée) ailleurs.
        case close
    }

    /// Que faire d'un état venu d'un autre appareil ?
    ///
    /// Une **même** session (même début) suit l'appareil qui a agi en dernier.
    /// Deux sessions **différentes** ne s'écrasent jamais : chacune sera
    /// enregistrée par son appareil.
    static func decide(local: FocusTimerState?, remote: TimerSnapshot,
                       lastApplied: Date?, device: String, now: Date = Date()) -> TimerDecision {
        guard remote.device != device, remote.updatedAt > (lastApplied ?? .distantPast) else { return .ignore }
        switch (local, remote.state) {
        case (nil, nil):
            return .ignore
        case (nil, let state?):
            return state.isRestorable(at: now) || state.isRunning ? .adopt(state) : .ignore
        case (let mine?, nil):
            return remote.endedSession.map { abs($0.timeIntervalSince(mine.sessionStartedAt)) < 1 } == true ? .close : .ignore
        case (let mine?, let state?):
            guard abs(mine.sessionStartedAt.timeIntervalSince(state.sessionStartedAt)) < 1 else { return .ignore }
            return mine == state ? .ignore : .adopt(state)
        }
    }

    private static let timerKey = "timer"
    private static let appliedKey = "cloudRelay.timerApplied"

    /// L'horodatage du dernier état publié ou adopté par cet appareil.
    static var lastAppliedTimer: Date? {
        get { UserDefaults.standard.object(forKey: appliedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: appliedKey) }
    }

    static func publishTimer(_ state: FocusTimerState?, ended: Date? = nil, now: Date = Date()) {
        let snapshot = TimerSnapshot(state: state, endedSession: ended, updatedAt: now, device: deviceID)
        guard let data = try? encoder.encode(snapshot) else { return }
        store.set(data, forKey: timerKey)
        lastAppliedTimer = now
        store.synchronize()
    }

    static func remoteTimer() -> TimerSnapshot? {
        guard let data = store.data(forKey: timerKey) else { return nil }
        return try? decoder.decode(TimerSnapshot.self, from: data)
    }

    // MARK: Moodle : un seul appareil relit

    struct RefreshClaim: Codable, Equatable {
        var at: Date
        var device: String
    }

    /// La relecture est-elle à faire **ici** ? Pas si un autre appareil l'a
    /// faite (ou commencée) il y a moins de `interval`.
    static func refreshIsDue(localLast: Date?, claim: RefreshClaim?, device: String,
                             interval: TimeInterval, now: Date = Date()) -> Bool {
        if let localLast, now.timeIntervalSince(localLast) < interval { return false }
        if let claim, claim.device != device, now.timeIntervalSince(claim.at) < interval { return false }
        return true
    }

    private static let refreshKey = "moodle.refresh"

    static func moodleRefreshClaim() -> RefreshClaim? {
        store.data(forKey: refreshKey).flatMap { try? decoder.decode(RefreshClaim.self, from: $0) }
    }

    /// « Je relis Moodle » : posé **avant** de commencer, pour que l'autre
    /// appareil qui s'ouvre au même moment ne relise pas en double.
    static func claimMoodleRefresh(now: Date = Date()) {
        guard let data = try? encoder.encode(RefreshClaim(at: now, device: deviceID)) else { return }
        store.set(data, forKey: refreshKey)
        store.synchronize()
    }

    // MARK: Moodle : ce qui a déjà été vu (et annoncé)

    private static let knownKey = "moodle.known"

    /// L'union des activités vues, cours par cours, triée : ce qu'un appareil
    /// a vu (et annoncé) ne l'est pas une seconde fois par un autre.
    static func mergeKnown(_ a: [String: [String]], _ b: [String: [String]]) -> [String: [String]] {
        var merged = a
        for (course, ids) in b {
            merged[course] = Array(Set(merged[course] ?? []).union(ids)).sorted()
        }
        return merged
    }

    static func moodleKnown() -> [String: [String]] {
        store.dictionary(forKey: knownKey) as? [String: [String]] ?? [:]
    }

    static func publishMoodleKnown(_ known: [String: [String]]) {
        store.set(mergeKnown(moodleKnown(), known), forKey: knownKey)
        store.synchronize()
    }

    // MARK: Codage

    // Dates en secondes décimales (pas ISO 8601, qui tronque à la seconde) :
    // les deux appareils comparent des instants exacts.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
