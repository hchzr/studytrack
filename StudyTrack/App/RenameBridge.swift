import Foundation
import UIKit

/// Le pont vers Polymestre : ce que l'app sous son **ancienne** identité laisse
/// à la nouvelle.
///
/// Polymestre change d'identifiant d'app (`ch.polymestre.app`). Pour iOS, c'est
/// une autre app : elle ne peut pas lire les réglages privés de celle-ci
/// (`UserDefaults.standard`, dans son bac à sable). Elle est en revanche membre
/// du même groupe d'app — alors l'app en dépose une copie ici, à chaque ouverture
/// et à chaque passage en arrière-plan, et Polymestre la reprend au premier
/// lancement. Rien n'est effacé : c'est une copie.
///
/// La base (iCloud) et le trousseau ne passent pas par ici : Polymestre les relit
/// directement (voir `IdentityMigration`).
enum RenameBridge {
    /// `<groupe>/Library/Application Support/Polymestre-migration/standard-defaults.plist`
    static let folderName = "Polymestre-migration"
    static let defaultsFileName = "standard-defaults.plist"

    @MainActor private static var observer: NSObjectProtocol?

    @MainActor static func install() {
        export()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { export() }
        }
    }

    static func folder(in groupContainer: URL) -> URL {
        groupContainer.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Écrit la copie des réglages privés (format plist, écriture atomique).
    static func export() {
        guard let group = WidgetBridge.containerURL,
              let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return }
        let dir = folder(in: group)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let payload: [String: Any] = ["bundleID": bundleID, "exportedAt": Date(), "defaults": domain]
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            try data.write(to: dir.appendingPathComponent(defaultsFileName), options: .atomic)
        } catch {
            AppLog.record(.error, AppLog.Category.storage, "Copie des réglages pour Polymestre", detail: String(describing: error))
        }
    }
}
