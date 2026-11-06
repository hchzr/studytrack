import AppKit
import ApplicationServices
import OSLog

/// Les apps permises (GoodNotes, Claude…) dans le bureau d'étude : leur fenêtre
/// est posée dans le **centre** du bureau, la barre du haut, la colonne d'outils
/// et le volet d'à côté restant visibles autour d'elle — écrire au centre, lire à
/// côté. Par l'Accessibilité (une permission, demandée sur l'écran de lancement).
///
/// - Posée **une fois** par fenêtre (à son apparition ou quand son app passe
///   devant), puis quand le centre change (volet ouvert ou tiré) — jamais sur un
///   déplacement : on ne se bat pas avec l'étudiant·e.
/// - Seulement les fenêtres standard ; une fenêtre de taille fixe est centrée.
/// - À la fin du blocage, chaque fenêtre reprend sa place d'origine.
/// - Sans la permission, rien ne change : les apps s'ouvrent par-dessus le bureau.
///
/// La géométrie est dans `DeskGeometry` (pure, testée).
@MainActor
final class AppPlacement {
    static let shared = AppPlacement()

    private let log = Logger(subsystem: "ch.polymestre.mac", category: "placement")
    private(set) var hole: DeskGeometry.Rect?
    private var active = false
    private var allowed: Set<String> = []
    private var observers: [pid_t: AXObserver] = [:]
    private var launchObserver: NSObjectProtocol?
    /// Les fenêtres posées : leur place d'origine, pour la rendre.
    private var placed: [Int: (window: AXUIElement, original: DeskGeometry.Rect)] = [:]
    private var pending: Task<Void, Never>?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ouvre la fenêtre de permission du système (l'écran de lancement, avant « Commencer »).
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    // MARK: Cycle de vie

    func start(allowed bundleIDs: [String]) {
        guard Self.isTrusted, !active else { return }
        allowed = Set(bundleIDs).subtracting([StudyMode.finderBundleID]).subtracting(StudyMode.backgroundApps)
        active = true
        for app in NSWorkspace.shared.runningApplications where isAllowed(app) { observe(app) }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app, self?.isAllowed(app) == true { self?.observe(app) } }
        }
        log.notice("placement : actif (\(self.allowed.count) apps)")
    }

    func stop() {
        guard active else { return }
        active = false
        pending?.cancel()
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        for (_, entry) in placed { set(entry.window, to: entry.original) }
        placed.removeAll()
        for (_, observer) in observers { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observers.removeAll()
        log.notice("placement : fenêtres rendues")
    }

    private func isAllowed(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(allowed.contains) ?? false
    }

    // MARK: Le centre du bureau

    /// Le centre change (volet d'à côté ouvert ou tiré, fenêtre redimensionnée) : les
    /// fenêtres posées le suivent, après un court délai (le geste n'est pas fini).
    func setHole(_ rect: DeskGeometry.Rect) {
        guard rect != hole else { return }
        hole = rect
        guard active, !placed.isEmpty else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let hole = self.hole else { return }
            for (_, entry) in self.placed { self.apply(entry.window, in: hole) }
        }
    }

    // MARK: Poser

    /// Une app permise passe devant : sa fenêtre principale est posée si elle ne l'a pas été.
    func appActivated(_ app: NSRunningApplication) {
        guard active, isAllowed(app) else { return }
        observe(app)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            place(focused as! AXUIElement)
        }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AppPlacement.shared.windowEvent(element) } }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let application = AXUIElementCreateApplication(pid)
        // Une fenêtre apparaît, ou l'app change de fenêtre principale ou active.
        for name in [kAXWindowCreatedNotification, kAXMainWindowChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, application, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Une notification d'une app permise : l'élément est la fenêtre, ou l'app (on prend
    /// alors sa fenêtre active).
    private func windowEvent(_ element: AXUIElement) {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == (kAXWindowRole as String) { place(element); return }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            place(focused as! AXUIElement)
        }
    }

    private func place(_ window: AXUIElement) {
        guard active, let hole else { return }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        let kind = subrole as? String
        // Une boîte de dialogue : centrée dans le trou, jamais étirée, jamais retenue.
        if kind == (kAXDialogSubrole as String) || kind == (kAXSystemDialogSubrole as String) {
            if let current = frame(of: window) {
                set(window, to: DeskGeometry.centred(width: current.width, height: current.height, in: hole))
            }
            return
        }
        // Les fenêtres standard seulement : pas les feuilles, les palettes, les menus.
        guard kind == (kAXStandardWindowSubrole as String) else { return }
        let key = Int(CFHash(window))
        guard placed[key] == nil, let original = frame(of: window) else { return }
        // Plein écran natif : on en sort d'abord (l'animation prend un instant).
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success, (fullScreen as? Bool) == true {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                self?.place(window)
            }
            return
        }
        placed[key] = (window, original)
        apply(window, in: hole)
    }

    /// Redimensionnable : le trou entier ; sinon, centrée. Taille, position, taille : la
    /// première taille peut être refusée tant que la fenêtre est trop près d'un bord.
    private func apply(_ window: AXUIElement, in hole: DeskGeometry.Rect) {
        guard let current = frame(of: window) else { return }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
        var target = DeskGeometry.placement(current: current, minimum: nil, resizable: settable.boolValue, in: hole)
        set(window, to: target)
        // L'app a un minimum plus grand que le trou : on la centre telle qu'elle est.
        if let after = frame(of: window), abs(after.width - target.width) > 2 || abs(after.height - target.height) > 2 {
            target = DeskGeometry.placement(current: after, minimum: nil, resizable: false, in: hole)
            set(window, to: target)
        }
    }

    /// « Amener ici » depuis un autre écran : la fenêtre principale de l'app prend tout
    /// cet écran. Sans l'Accessibilité, l'app est seulement ouverte.
    func bringFrontWindow(of app: NSRunningApplication, to screen: NSScreen) {
        guard Self.isTrusted, let primary = NSScreen.screens.first else { return }
        let target = DeskGeometry.Rect(x: screen.frame.minX, y: primary.frame.height - screen.frame.maxY,
                                       width: screen.frame.width, height: screen.frame.height)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        set(focused as! AXUIElement, to: target)
    }

    // MARK: Lire et écrire une fenêtre

    private func frame(of window: AXUIElement) -> DeskGeometry.Rect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return DeskGeometry.Rect(x: point.x, y: point.y, width: extent.width, height: extent.height)
    }

    private func set(_ window: AXUIElement, to rect: DeskGeometry.Rect) {
        var size = CGSize(width: rect.width, height: rect.height)
        var point = CGPoint(x: rect.x, y: rect.y)
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }
}
