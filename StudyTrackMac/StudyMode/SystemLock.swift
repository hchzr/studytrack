import AppKit
import OSLog

/// Éteindre les raccourcis du système pendant un blocage — et les rallumer.
///
/// Ce fichier est la seule partie qui écrit dans le système ; ce qui décide est
/// dans `StudyLockPlan` (pur, testé). Deux règles :
///
/// - **Rien ne s'éteint sans fiche.** `engage` écrit d'abord `lock-restore.json`,
///   puis éteint. Le changement vit dans le système (il survit à la mort de
///   l'app — vérifié) : sans la fiche, un plantage laisserait ⌘Espace éteint
///   jusqu'à la prochaine session.
/// - **Tout `engage` a son `release`**, appelé à la fin du blocage, au lancement
///   (une fiche restée là d'une session morte), à la sortie de l'app, par le
///   gardien (`StudyGuard`) quand l'app n'est plus là, et par le bouton des
///   réglages.
@MainActor
enum SystemLock {
    private static let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "systemlock")

    /// Les essais de débogage (`-isolatedTimer`, `-studyPreview`) ne touchent à rien.
    private static var untouched: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-isolatedTimer") || CommandLine.arguments.contains("-studyPreview")
        #else
        false
        #endif
    }

    static var hasRecord: Bool { StudyLockStore.load() != nil }

    /// ⌘Tab du système est bel et bien éteint (relu après coup) : sinon, la
    /// présentation de StudyTrack reste le seul frein quand il est devant.
    private(set) static var processSwitchingOff = false

    /// Début de blocage : raccourcis éteints, Dock et barre des menus cachés.
    static func engage(hideChrome: Bool, blockGestures: Bool = true) {
        guard !untouched else { return }
        let chrome = hideChrome && SystemChrome.permission == .granted ? SystemChrome.read() : nil
        let available = SystemHotKeys.isAvailable
        if !available { log.notice("raccourcis du système : fonctions introuvables, rien d'éteint") }
        let (disable, planned) = StudyLockPlan.plan(
            wanted: StudyLockPlan.shortcutIDs,
            enabledNow: { available && SystemHotKeys.isEnabled($0) },
            existing: StudyLockStore.load(),
            dockNow: chrome?.dock, menuBarNow: chrome?.menuBar)
        var record = planned
        if blockGestures {
            record.gestures = StudyLockPlan.mergeGestures(existing: record.gestures, current: SystemGestures.read())
        }
        // La fiche d'abord : si l'app meurt entre les deux, on saura quoi rallumer.
        StudyLockStore.save(record)
        if blockGestures { SystemGestures.block() }
        guard available else { return }
        for id in disable { SystemHotKeys.setEnabled(id, false) }
        processSwitchingOff = [1, 2].allSatisfy { !SystemHotKeys.isEnabled($0) }
        let stuck = disable.filter(SystemHotKeys.isEnabled)
        if !stuck.isEmpty { log.notice("raccourcis restés allumés : \(stuck.map(String.init).joined(separator: ","), privacy: .public)") }
        if chrome != nil, record.dockAutohide != nil {
            SystemChrome.set(dock: true, menuBar: true)
        }
        log.notice("raccourcis du système éteints : \(disable.count)")
    }

    /// Fin de blocage (ou rattrapage) : tout ce que la fiche dit est rétabli.
    static func release() {
        guard let record = StudyLockStore.load() else { return }
        if SystemHotKeys.isAvailable {
            for id in StudyLockPlan.restore(record) { SystemHotKeys.setEnabled(id, true) }
        }
        processSwitchingOff = false
        if let gestures = record.gestures { SystemGestures.restore(gestures) }
        // On essaie toujours de rétablir le Dock et la barre des menus ; la fiche ne
        // les oublie que si c'est fait. Sinon elle les garde pour la prochaine fois
        // (un Dock caché pour toujours est pire qu'une fiche qui reste).
        if record.dockAutohide != nil || record.menuBarAutohide != nil,
           !SystemChrome.set(dock: record.dockAutohide, menuBar: record.menuBarAutohide) {
            var kept = record
            kept.shortcuts = []
            kept.gestures = nil
            StudyLockStore.save(kept)
            log.notice("Dock et barre des menus : pas rétablis, la fiche les garde")
            return
        }
        StudyLockStore.clear()
        log.notice("raccourcis du système rétablis")
    }
}

// MARK: - La fiche sur disque

enum StudyLockStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/StudyTrack/lock-restore.json")
    }

    static func load() -> StudyLockPlan.Record? {
        StudyLockPlan.decode(try? Data(contentsOf: url))
    }

    static func save(_ record: StudyLockPlan.Record) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = StudyLockPlan.encode(record) { try? data.write(to: url, options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Les raccourcis (SkyLight)

/// `SLSSetSymbolicHotKeyEnabled` et ses voisines, chargées à l'exécution : des
/// fonctions privées d'Apple (présentes sur macOS 27, relevées avec `dyld_info`),
/// qui peuvent changer. Si elles manquent, `isAvailable` est faux et le blocage
/// reste celui des options de présentation.
enum SystemHotKeys {
    private typealias SetFunction = @convention(c) (Int32, Bool) -> Int32
    private typealias IsFunction = @convention(c) (Int32) -> Bool
    private typealias NameFunction = @convention(c) (Int32) -> UnsafePointer<CChar>?
    private typealias ValueFunction = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let setter: SetFunction? = symbol("SLSSetSymbolicHotKeyEnabled")
    private static let getter: IsFunction? = symbol("SLSIsSymbolicHotKeyEnabled")
    private static let namer: NameFunction? = symbol("SLSSymbolicHotKeyName")
    private static let valuer: ValueFunction? = symbol("SLSGetSymbolicHotKeyValue")

    /// Le nom d'un raccourci du système (« Spotlight », « SwitchFwd »), pour les essais.
    static func name(_ id: Int) -> String? { namer?(Int32(id)).map { String(cString: $0) } }

    /// Sa touche et ses modificateurs (code, modificateurs), pour les essais.
    static func binding(_ id: Int) -> (code: Int, modifiers: Int)? {
        var ascii: UInt16 = 0, code: UInt16 = 0, modifiers: UInt32 = 0
        guard valuer?(Int32(id), &ascii, &code, &modifiers) == 0 else { return nil }
        return (Int(code), Int(modifiers))
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let pointer = dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var isAvailable: Bool { setter != nil && getter != nil }

    static func isEnabled(_ id: Int) -> Bool { getter?(Int32(id)) ?? false }

    static func setEnabled(_ id: Int, _ enabled: Bool) { _ = setter?(Int32(id), enabled) }
}

// MARK: - Dock et barre des menus (System Events)

/// Le Dock et la barre des menus cachés pendant un blocage : sans cela, ils
/// reviennent dès qu'une app permise (GoodNotes…) est devant, puisque la
/// présentation de StudyTrack ne vaut que quand il y est lui-même. Passe par
/// System Events : une permission (« contrôler System Events »), demandée avant
/// de commencer — une fois le blocage en route, les Réglages sont fermés.
enum SystemChrome {
    enum Permission { case granted, denied, undetermined }

    private static let target = "com.apple.systemevents"

    static var permission: Permission { check(ask: false) }

    /// Demande la permission (l'écran de lancement, avant « Commencer »).
    @discardableResult
    static func request() -> Permission { check(ask: true) }

    /// System Events n'est pas toujours ouvert, et la permission ne se lit que
    /// pour une app qui tourne (sinon -600) : on le lance, masqué, et on attend.
    private static func ensureRunning() {
        func running() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: target).isEmpty }
        guard !running() else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", "-b", target]
        try? open.run()
        open.waitUntilExit()
        for _ in 0..<30 where !running() { Thread.sleep(forTimeInterval: 0.1) }
    }

    private static func check(ask: Bool) -> Permission {
        ensureRunning()
        // Le descripteur reste à `NSAppleEventDescriptor` : on n'en copie ni n'en libère rien.
        let address = NSAppleEventDescriptor(bundleIdentifier: target)
        guard let pointer = address.aeDesc else { return .undetermined }
        switch AEDeterminePermissionToAutomateTarget(pointer, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .undetermined
        }
    }

    static func read() -> (dock: Bool, menuBar: Bool)? {
        let source = """
        tell application "System Events" to tell dock preferences to return {autohide, autohide menu bar}
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil,
              result.numberOfItems == 2,
              let dock = result.atIndex(1)?.booleanValue, let menuBar = result.atIndex(2)?.booleanValue else { return nil }
        return (dock, menuBar)
    }

    /// Vrai si le Dock et la barre des menus ont bien pris la valeur demandée.
    @discardableResult
    static func set(dock: Bool?, menuBar: Bool?) -> Bool {
        var lines: [String] = []
        if let dock { lines.append("set autohide to \(dock)") }
        if let menuBar { lines.append("set autohide menu bar to \(menuBar)") }
        guard !lines.isEmpty else { return true }
        ensureRunning()
        let source = "tell application \"System Events\" to tell dock preferences\n\(lines.joined(separator: "\n"))\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}

// MARK: - Gestes du trackpad

/// Mission Control, changer de bureau, Launchpad, Centre de notifications : des
/// gestes que les raccourcis éteints n'arrêtent pas. Ils se règlent dans les
/// préférences du trackpad et du Dock ; on y écrit « bloqué » pendant le blocage
/// (les valeurs d'origine sur la fiche) et on relance le Dock pour qu'il relise.
/// Le Dock se relance tout seul (un clignotement).
enum SystemGestures {
    static func read() -> [StudyLockPlan.GestureOriginal] {
        StudyLockPlan.gestureTargets.map { target in
            let value = CFPreferencesCopyAppValue(target.key as CFString, target.domain as CFString)
            let number: Int? = (value as? NSNumber).map { $0.intValue }
            return StudyLockPlan.GestureOriginal(domain: target.domain, key: target.key, value: number)
        }
    }

    static func block() {
        for target in StudyLockPlan.gestureTargets {
            write(target.blocked, isBool: target.isBool, key: target.key, domain: target.domain)
        }
        reloadDock()
    }

    static func restore(_ originals: [StudyLockPlan.GestureOriginal]) {
        for original in originals {
            let isBool = StudyLockPlan.gestureTargets.first { $0.domain == original.domain && $0.key == original.key }?.isBool ?? false
            write(original.value, isBool: isBool, key: original.key, domain: original.domain)
        }
        reloadDock()
    }

    /// `nil` : la préférence n'existait pas, on la retire.
    private static func write(_ value: Int?, isBool: Bool, key: String, domain: String) {
        var stored: AnyObject?
        if let value { stored = isBool ? NSNumber(value: value != 0) : NSNumber(value: value) }
        CFPreferencesSetAppValue(key as CFString, stored, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    private static func reloadDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
