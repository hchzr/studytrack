import Foundation
import Security

/// Conserve la session Supabase dans le trousseau, entre deux lancements.
///
/// Sans ça, `SupabaseClient` ne gardait le jeton qu'en mémoire : **chaque relance
/// de l'app déconnectait silencieusement**. Les groupes cessaient de se
/// synchroniser, la présence ne se publiait plus, et l'app affichait « personne ne
/// travaille » ou « connectez-vous » selon l'écran — sans qu'aucune erreur ne soit
/// visible nulle part.
///
/// Le trousseau plutôt que `UserDefaults` : un jeton d'accès est un secret, et
/// `UserDefaults` est un fichier plist lisible dans une sauvegarde.
enum SupabaseSessionStore {

    private static let service = "com.hczr.studytrack.supabase"

    /// Clé de stockage propre au projet Supabase.
    ///
    /// Changer de projet ne doit pas réutiliser la session du précédent : un jeton
    /// émis par A n'a aucun sens pour B, et le garder produirait des 401.
    private static func account(for host: String) -> String {
        "session.\(host.lowercased())"
    }

    static func load(host: String) -> StoredSession? {
        var query = baseQuery(host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let session = try? JSONDecoder().decode(StoredSession.self, from: data),
              session.isUsable else { return nil }
        migrateAccessibility(host: host)
        return session
    }

    /// Une session rangée par une version précédente (`afterFirstUnlock`, qui voyage dans les
    /// sauvegardes chiffrées) passe à `…ThisDeviceOnly` à sa première lecture.
    private static func migrateAccessibility(host: String) {
        let attributes: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemUpdate(baseQuery(host: host) as CFDictionary, attributes as CFDictionary)
    }

    @discardableResult
    static func save(_ session: StoredSession, host: String) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let query = baseQuery(host: host)
        // `afterFirstUnlock` : lisible en arrière-plan appareil verrouillé, ce qui
        // est le cas d'un rafraîchissement de jeton au réveil. `ThisDeviceOnly` : le
        // jeton ne quitte pas l'appareil (ni sauvegarde transférable, ni Trousseau iCloud).
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }

        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func clear(host: String) {
        SecItemDelete(baseQuery(host: host) as CFDictionary)
    }

    private static func baseQuery(host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: host)
        ]
    }
}
