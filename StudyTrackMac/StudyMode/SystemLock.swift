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

    /// Début de blocage : raccourcis éteints, Dock et barre des menus cachés.
    static func engage(hideChrome: Bool) {
        guard !untouched else { return }
        let chrome = hideChrome && SystemChrome.permission == .granted ? SystemChrome.read() : nil
        let available = SystemHotKeys.isAvailable
        if !available { log.notice("raccourcis du système : fonctions introuvables, rien d'éteint") }
        let (disable, record) = StudyLockPlan.plan(
            wanted: StudyLockPlan.shortcutIDs,
            enabledNow: { available && SystemHotKeys.isEnabled($0) },
            existing: StudyLockStore.load(),
            dockNow: chrome?.dock, menuBarNow: chrome?.menuBar)
        // La fiche d'abord : si l'app meurt entre les deux, on saura quoi rallumer.
        StudyLockStore.save(record)
        guard available else { return }
        for id in disable { SystemHotKeys.setEnabled(id, false) }
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
        if record.dockAutohide != nil || record.menuBarAutohide != nil {
            if SystemChrome.permission == .granted {
                SystemChrome.set(dock: record.dockAutohide, menuBar: record.menuBarAutohide)
            } else {
                log.notice("Dock et barre des menus : permission retirée, pas rétablis")
            }
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

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let setter: SetFunction? = symbol("SLSSetSymbolicHotKeyEnabled")
    private static let getter: IsFunction? = symbol("SLSIsSymbolicHotKeyEnabled")

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

    private static func check(ask: Bool) -> Permission {
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

    static func set(dock: Bool?, menuBar: Bool?) {
        var lines: [String] = []
        if let dock { lines.append("set autohide to \(dock)") }
        if let menuBar { lines.append("set autohide menu bar to \(menuBar)") }
        guard !lines.isEmpty else { return }
        let source = "tell application \"System Events\" to tell dock preferences\n\(lines.joined(separator: "\n"))\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
