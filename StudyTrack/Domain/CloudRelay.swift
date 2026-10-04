import Foundation
import SwiftData

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
    ///
    /// Une **nouvelle** session venue d'ailleurs remplace pourtant la mienne
    /// quand l'autre appareil l'a fermée : terminer puis relancer aussitôt
    /// écrase la balise « terminée » avant qu'elle n'arrive — seule la
    /// nouvelle session parvient. On le sait par `endedSession` (que chaque
    /// publication porte désormais), ou parce que ma session était **partagée**
    /// (`shared` : vue chez l'autre appareil) et que la sienne est plus récente.
    static func decide(local: FocusTimerState?, remote: TimerSnapshot,
                       lastApplied: Date?, device: String, shared: Date? = nil,
                       now: Date = Date()) -> TimerDecision {
        guard remote.device != device, remote.updatedAt > (lastApplied ?? .distantPast) else { return .ignore }
        switch (local, remote.state) {
        case (nil, nil):
            return .ignore
        case (nil, let state?):
            return state.isRestorable(at: now) || state.isRunning ? .adopt(state) : .ignore
        case (let mine?, nil):
            return same(remote.endedSession, mine.sessionStartedAt) ? .close : .ignore
        case (let mine?, let state?):
            if same(mine.sessionStartedAt, state.sessionStartedAt) {
                return mine == state ? .ignore : .adopt(state)
            }
            let closedThere = same(remote.endedSession, mine.sessionStartedAt)
                || (same(shared, mine.sessionStartedAt) && state.sessionStartedAt > mine.sessionStartedAt)
            guard closedThere, state.isRestorable(at: now) || state.isRunning else { return .ignore }
            return .adopt(state)
        }
    }

    private static func same(_ a: Date?, _ b: Date) -> Bool {
        a.map { abs($0.timeIntervalSince(b)) < 1 } ?? false
    }

    private static let sharedKey = "cloudRelay.sharedSession"
    private static let endedKey = "cloudRelay.lastEnded"

    /// La session que l'autre appareil connaît (dont il a publié un état).
    static var sharedSession: Date? {
        get { UserDefaults.standard.object(forKey: sharedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: sharedKey) }
    }

    /// Retient qu'une session est partagée : à appeler avec chaque état distant.
    static func noteShared(local: FocusTimerState?, remote: TimerSnapshot) {
        guard let mine = local, remote.device != deviceID,
              let theirs = remote.state, same(theirs.sessionStartedAt, mine.sessionStartedAt) else { return }
        sharedSession = mine.sessionStartedAt
    }

    private static let timerKey = "timer"
    private static let appliedKey = "cloudRelay.timerApplied"

    /// L'horodatage du dernier état publié ou adopté par cet appareil.
    static var lastAppliedTimer: Date? {
        get { UserDefaults.standard.object(forKey: appliedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: appliedKey) }
    }

    /// Publie par les deux voies : le magasin clé-valeur, et la balise de cet
    /// appareil dans la base (`context`), bien plus rapide.
    @discardableResult @MainActor
    static func publishTimer(_ state: FocusTimerState?, ended: Date? = nil, now: Date = Date(),
                             context: ModelContext? = nil) -> TimerSnapshot {
        // La dernière session fermée ici voyage avec chaque publication : si
        // une nouvelle session la suit de près, l'autre appareil saura quand
        // même que l'ancienne est finie.
        if let ended { UserDefaults.standard.set(ended, forKey: endedKey) }
        let lastEnded = ended ?? UserDefaults.standard.object(forKey: endedKey) as? Date
        let snapshot = TimerSnapshot(state: state, endedSession: lastEnded, updatedAt: now, device: deviceID)
        guard let data = try? encoder.encode(snapshot) else { return snapshot }
        store.set(data, forKey: timerKey)
        lastAppliedTimer = now
        store.synchronize()
        onPublish?(snapshot)
        if let context {
            let device = deviceID
            let mine = (try? context.fetch(FetchDescriptor<RelayBeacon>(predicate: #Predicate { $0.device == device }))) ?? []
            let beacon = mine.first ?? RelayBeacon(device: device)
            if mine.isEmpty { context.insert(beacon) }
            for extra in mine.dropFirst() { context.delete(extra) }
            beacon.updatedAt = now
            beacon.payload = data
            try? context.save()
        }
        return snapshot
    }

    // MARK: Voie instantanée (`TimerLink`)

    /// Appelé à chaque publication : la voie instantanée l'envoie.
    @MainActor static var onPublish: ((TimerSnapshot) -> Void)?
    /// Le dernier état reçu par la voie instantanée (en mémoire).
    @MainActor private(set) static var linked: TimerSnapshot?

    /// Un état arrive par la voie instantanée : retenu, puis les chronos
    /// relisent (même notification que le magasin clé-valeur).
    @MainActor static func receivedFromLink(_ snapshot: TimerSnapshot) {
        guard snapshot.device != deviceID else { return }
        if let linked, linked.updatedAt >= snapshot.updatedAt { return }
        linked = snapshot
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// L'état le plus récent publié par un **autre** appareil, quelle que soit
    /// la voie par laquelle il est arrivé.
    @MainActor
    static func remoteTimer(context: ModelContext? = nil) -> TimerSnapshot? {
        var candidates: [TimerSnapshot] = linked.map { [$0] } ?? []
        if let data = store.data(forKey: timerKey), let snapshot = try? decoder.decode(TimerSnapshot.self, from: data) {
            candidates.append(snapshot)
        }
        if let context {
            let beacons = (try? context.fetch(FetchDescriptor<RelayBeacon>())) ?? []
            candidates += beacons.compactMap { $0.payload.flatMap { try? decoder.decode(TimerSnapshot.self, from: $0) } }
        }
        return newest(candidates, excluding: deviceID)
    }

    /// Le plus récent des autres appareils (pur, testé).
    static func newest(_ snapshots: [TimerSnapshot], excluding device: String) -> TimerSnapshot? {
        snapshots.filter { $0.device != device }.max { $0.updatedAt < $1.updatedAt }
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
