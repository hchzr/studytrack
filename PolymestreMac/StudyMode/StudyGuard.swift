import AppKit
import OSLog

/// Le gardien du verrou : Polymestre ne se ferme pas pendant le mode étude.
///
/// ⌘Q, « Quitter » du Dock, la fermeture de session sont refusés par l'app
/// elle-même ; « Forcer à quitter » (⌥⌘⎋) aussi, tant qu'elle est au premier
/// plan. Reste le cas où on la force à quitter **depuis** une app permise :
/// l'app est tuée, elle ne peut rien refuser. Le gardien est là pour ça.
///
/// **Comment.** Un agent `launchd` de l'utilisateur
/// (`~/Library/LaunchAgents/ch.polymestre.guard.plist`, visible dans
/// Réglages › Ouverture), qui lance le binaire même de Polymestre avec
/// `--study-guard` : pas de fenêtre, pas d'icône, aucun service de l'app.
/// Toutes les secondes et demie, il lit le chrono partagé (`FocusTimerStore`,
/// les mêmes préférences) ; sous verrou et sans Polymestre ouvert, il le
/// relance — l'écran du mode étude revient aussitôt. Tué à son tour, `launchd`
/// le relance (`KeepAlive`) ; au démarrage du Mac, il part avec la session
/// (`RunAtLoad`). Sans verrou, il s'arrête de lui-même au bout de quinze
/// secondes, et `launchd` le laisse dormir jusqu'au prochain verrou.
///
/// Pour l'arrêter de force, il faudrait le Terminal ou le Moniteur d'activité :
/// deux apps que le mode étude ferme.
enum StudyGuard {
    static let label = "ch.polymestre.guard"
    static let flag = "--study-guard"
    fileprivate static let log = Logger(subsystem: "ch.polymestre.mac", category: "guard")

    static var isGuardProcess: Bool { CommandLine.arguments.contains(flag) }

    // MARK: Côté app

    /// L'agent posé par StudyTrack, avant le changement de nom : il relancerait le
    /// gardien de l'ancienne app. Arrêté et retiré une fois (StudyTrack le reposerait
    /// à son prochain verrou s'il servait encore).
    static func retireLegacyAgent() {
        let legacy = "com.hczr.studytrack.guard"
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(legacy).plist")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let domain = "gui/\(getuid())"
        Task.detached(priority: .utility) {
            launchctl(["bootout", "\(domain)/\(legacy)"])
            try? FileManager.default.removeItem(at: file)
            log.notice("agent de StudyTrack retiré")
        }
    }

    /// Installe l'agent (ou le réécrit si l'app a bougé) et le démarre. Appelé
    /// à chaque verrou.
    static func arm() {
        #if DEBUG
        if CommandLine.arguments.contains("-isolatedTimer") || CommandLine.arguments.contains("-studyPreview") { return }
        #endif
        guard let executable = Bundle.main.executableURL?.path else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
        let file = folder.appending(path: label + ".plist")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, flag],
            "RunAtLoad": true,
            // Une sortie propre (plus de verrou) le laisse dormir ; tué, il revient.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "ThrottleInterval": 2,
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "ch.polymestre.mac"],
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let changed = (try? Data(contentsOf: file)) != data
        let domain = "gui/\(getuid())"
        Task.detached(priority: .utility) {
            if changed {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                launchctl(["bootout", "\(domain)/\(label)"])
            }
            launchctl(["bootstrap", domain, file.path])
            launchctl(["kickstart", "\(domain)/\(label)"])
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: Côté gardien

    /// Le gardien lui-même : une boucle, pas d'interface.
    @MainActor
    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let watcher = Watcher()
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { watcher.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watcher.tick()
        log.notice("gardien : en veille")
        RunLoop.main.run()
        exit(0)
    }
}

@MainActor
private final class Watcher {
    private var calmTicks = 0
    private var relaunchedAt: Date?

    func tick() {
        // Les préférences ont pu changer dans l'autre processus.
        UserDefaults.standard.synchronize()
        let state = FocusTimerStore.load()
        let id = Bundle.main.bundleIdentifier ?? "ch.polymestre.mac"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        guard StudyMode.locks(state) else {
            if StudyMode.blocks(state) {
                // Un blocage sans verrou (session sans fin) : le gardien reste, et si
                // l'app a disparu (tuée) on ne la relance pas — on rallume ce qu'elle
                // avait éteint, pour qu'on puisse travailler.
                calmTicks = 0
                if others.isEmpty, SystemLock.hasRecord {
                    StudyGuard.log.notice("gardien : app disparue sous blocage, système rétabli")
                    SystemLock.release()
                }
                return
            }
            // Plus de verrou depuis une quinzaine de secondes : on s'arrête.
            calmTicks += 1
            if calmTicks >= 10 {
                if others.isEmpty { SystemLock.release() }
                StudyGuard.log.notice("gardien : plus de verrou, fin")
                exit(0)
            }
            return
        }
        calmTicks = 0
        guard others.isEmpty else { return }
        if let relaunchedAt, Date().timeIntervalSince(relaunchedAt) < 6 { return }
        relaunchedAt = Date()
        StudyGuard.log.notice("gardien : Polymestre fermé sous verrou, relancé")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Le gardien porte le même identifiant : sans ça, le système croirait
        // l'app déjà ouverte.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
    }
}

/// Le point d'entrée : l'app, ou son gardien.
@main
enum PolymestreMacEntry {
    static func main() {
        if StudyGuard.isGuardProcess {
            MainActor.assumeIsolated { StudyGuard.run() }
        }
        PolymestreMacApp.main()
    }
}
