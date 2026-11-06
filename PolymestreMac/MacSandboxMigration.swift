import Foundation
import OSLog

/// Le Mac est sorti du bac à sable (octobre 2026) : c'est ce qui permet au mode
/// étude de **fermer** les apps non permises (une app du bac à sable ne peut ni
/// quitter ni masquer les autres). Ce qui vivait dans le conteneur du bac à
/// sable — réglages, chrono en cours, identifiant d'appareil, base locale —
/// est repris une fois, au premier lancement hors du bac à sable.
///
/// La base est de toute façon dans iCloud ; la reprendre évite seulement de
/// tout retélécharger. Les réglages, eux, n'existent que là.
enum MacSandboxMigration {
    private static let log = Logger(subsystem: "com.hczr.studytrack.mac", category: "migration")
    private static let doneKey = "mac.migratedFromSandbox"

    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// Le dossier de la base hors du bac à sable : à nous seuls, pas le
    /// `default.store` partagé de « Application Support ».
    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("StudyTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var storeURL: URL { storeDirectory.appendingPathComponent("default.store") }

    /// À appeler avant toute lecture des réglages ou de la base.
    static func run() {
        #if DEBUG
        // Les essais (`-memoryStore`) ne touchent jamais aux vraies données.
        if CommandLine.arguments.contains("-memoryStore") { return }
        #endif
        guard !isSandboxed, !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundle = Bundle.main.bundleIdentifier ?? "com.hczr.studytrack.mac"
        let container = home.appendingPathComponent("Library/Containers/\(bundle)/Data/Library", isDirectory: true)

        // Réglages : le bac à sable fait foi (identifiant d'appareil, chrono,
        // réglages) — ce qui a pu s'écrire ici avant la reprise est remplacé.
        let plist = container.appendingPathComponent("Preferences/\(bundle).plist")
        if let old = NSDictionary(contentsOf: plist) as? [String: Any] {
            var copied = 0
            for (key, value) in old where key != doneKey {
                UserDefaults.standard.set(value, forKey: key)
                copied += 1
            }
            log.notice("réglages repris du bac à sable : \(copied)")
        }

        // Base : `default.store` et ses fichiers (journal, pièces jointes).
        let oldSupport = container.appendingPathComponent("Application Support", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: storeURL.path),
              let items = try? FileManager.default.contentsOfDirectory(atPath: oldSupport.path) else { return }
        for name in items where name.hasPrefix("default") || name.hasPrefix(".default") {
            do {
                try FileManager.default.copyItem(at: oldSupport.appendingPathComponent(name),
                                                 to: storeDirectory.appendingPathComponent(name))
            } catch {
                log.error("copie de \(name, privacy: .public) impossible : \(error.localizedDescription, privacy: .public)")
            }
        }
        log.notice("base reprise du bac à sable")
    }
}
