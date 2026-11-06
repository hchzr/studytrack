import Foundation

/// Les identifiants de l'app : ceux de Polymestre, et ceux de StudyTrack (l'ancienne
/// identité), que `IdentityMigration` relit une fois pour reprendre les données.
///
/// Un seul endroit : un identifiant écrit en dur ailleurs serait celui qu'on oublie.
enum AppIdentity {
    /// Le conteneur iCloud de la base (CloudKit, base privée de l'étudiant·e).
    static let cloudContainer = "iCloud.ch.polymestre.app"

    /// Les services du trousseau (un par usage).
    enum Keychain {
        static let supabase = "ch.polymestre.supabase"
        static let groupKeys = "ch.polymestre.e2ee"
        static let syncVault = "ch.polymestre.syncvault"
        static let cookies = "ch.polymestre.cookies"
        static let ankiWeb = "ch.polymestre.ankiweb"
    }

    /// Le dossier de l'app dans « Application Support » (Mac) et dans les caches.
    static let folderName = "Polymestre"

    /// StudyTrack, avant le changement de nom (novembre 2026).
    enum Legacy {
        static let cloudContainer = "iCloud.com.hczr.studytrack.app"
        #if os(macOS)
        static let bundleID = "com.hczr.studytrack.mac"
        static let appGroup = "5GGDH5F3NG.com.hczr.studytrack"
        #else
        static let bundleID = "com.hczr.studytrack.app"
        static let appGroup = "group.com.studytracker.app"
        #endif
        static let folderName = "StudyTrack"

        /// Ancien service → nouveau.
        static let keychainServices: [(old: String, new: String)] = [
            ("com.hczr.studytrack.supabase", Keychain.supabase),
            ("com.hczr.studytrack.e2ee", Keychain.groupKeys),
            ("com.hczr.studytrack.syncvault", Keychain.syncVault),
            ("com.hczr.studytrack.cookies", Keychain.cookies),
            ("com.hczr.studytrack.ankiweb", Keychain.ankiWeb),
        ]
    }

    /// Vrai quand ce binaire porte l'ancienne identité (la build « pont ») : rien à reprendre.
    static var isLegacyBuild: Bool { Bundle.main.bundleIdentifier == Legacy.bundleID }
}
