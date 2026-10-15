import Foundation

/// Ce que le blocage du Mac change dans le système, et comment le défaire.
///
/// Tant qu'une autre app est devant, les raccourcis du système (Spotlight,
/// ⌘Tab, Mission Control, les bureaux, Launchpad…) marchent comme d'habitude :
/// la présentation de StudyTrack (`NSApp.presentationOptions`) ne vaut que
/// quand il est lui-même au premier plan. Pendant un blocage, on les éteint donc
/// un par un — et **il faut pouvoir les rallumer à coup sûr** : le changement
/// vit dans le système, pas dans l'app (il survit à sa mort, vérifié), et un
/// raccourci que l'utilisateur·rice avait lui-même éteint ne doit jamais être
/// rallumé à sa place.
///
/// Tout ce qui décide est ici, pur et testé ; l'écriture dans le système est dans
/// `StudyTrackMac/StudyMode/SystemHotKeys.swift` et `SystemChrome.swift`.
enum StudyLockPlan {

    /// Les raccourcis du système éteints pendant un blocage (numéros de
    /// `SLSSymbolicHotKeyName`, relevés sur macOS 27).
    static let shortcutIDs: [Int] = {
        var ids = [
            1, 2,                       // ⌘Tab, ⇧⌘Tab
            64, 65, 100, 101, 187,      // Spotlight, ⌥⌘Espace (recherche du Finder), la touche Spotlight
            32, 33, 34, 35, 36, 37,     // Mission Control, fenêtres de l'app, bureau
            52,                         // Dock
            79, 80, 81, 82,             // bureaux à gauche / droite
            160, 161, 173, 174,         // Launchpad / Apps
            163,                        // Centre de notifications
            190,                        // Note rapide
            192, 193, 194, 195,         // bureaux (variantes)
            222,                        // Stage Manager
        ]
        ids += Array(108...117)         // Exposé, ancien clavier
        ids += Array(118...149)         // aller au bureau N
        return ids
    }()

    /// Jamais touchés : captures d'écran, ⌘` (changer de fenêtre de l'app).
    static let neverTouched: Set<Int> = [27, 28, 29, 30, 31, 184, 185]

    /// Ce que le blocage a changé, écrit **avant** de changer quoi que ce soit.
    struct Record: Codable, Equatable {
        var version = 1
        /// Les raccourcis que nous avons éteints (ils étaient allumés).
        var shortcuts: [Int] = []
        /// Les valeurs d'origine du Dock et de la barre des menus (cachés
        /// automatiquement ou non) ; `nil` : pas touchés.
        var dockAutohide: Bool?
        var menuBarAutohide: Bool?
        var createdAt: Date
    }

    /// Les raccourcis à éteindre maintenant et la fiche à écrire d'abord.
    ///
    /// - Un raccourci déjà éteint qui n'est pas sur la fiche est celui de
    ///   l'utilisateur·rice : on n'y touche pas, et il n'ira jamais sur la fiche.
    /// - **Une fiche existante gagne** (l'app relancée en plein blocage lit « éteint »
    ///   pour ce qu'elle avait éteinte elle-même) : ses valeurs d'origine restent.
    /// - `dockNow` / `menuBarNow` ne servent que s'il n'y a pas de fiche.
    static func plan(wanted: [Int], enabledNow: (Int) -> Bool, existing: Record?,
                     dockNow: Bool?, menuBarNow: Bool?, now: Date = Date()) -> (disable: [Int], record: Record) {
        var record = existing ?? Record(dockAutohide: dockNow, menuBarAutohide: menuBarNow, createdAt: now)
        for id in wanted where !neverTouched.contains(id) && !record.shortcuts.contains(id) && enabledNow(id) {
            record.shortcuts.append(id)
        }
        return (record.shortcuts.filter { !neverTouched.contains($0) }, record)
    }

    /// Les raccourcis à rallumer : ceux de la fiche, rien d'autre. Sans effet
    /// la seconde fois (rallumer un raccourci allumé ne change rien).
    static func restore(_ record: Record) -> [Int] {
        record.shortcuts.filter { !neverTouched.contains($0) }
    }

    // MARK: Fiche sur disque

    static func encode(_ record: Record) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(record)
    }

    static func decode(_ data: Data?) -> Record? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Record.self, from: data)
    }
}
