import Foundation
import CryptoKit
import Security

/// Les secrets du chiffrement de groupe, dans le trousseau : l'identité de ce
/// compte (clé privée Curve25519) et la clé de chaque groupe.
///
/// **Synchronisés** par le Trousseau iCloud (`kSecAttrSynchronizable`) : l'iPad
/// et l'iPhone d'une même personne partagent ainsi identité et clés, et un
/// téléphone restauré relit l'entraide sans attendre qu'un membre lui renvoie
/// la clé. Sans Trousseau iCloud, chaque appareil a sa propre identité et
/// reçoit la clé comme un nouveau membre — c'est prévu par la distribution.
///
/// Rien ici ne part sur le réseau : seule la clé **publique** est publiée.
enum GroupKeyStore {

    private static let service = "ch.polymestre.e2ee"

    // MARK: Identité

    /// L'identité de ce compte, créée au premier besoin.
    ///
    /// Une par compte Supabase : se connecter avec un autre compte sur le même
    /// téléphone ne doit pas lui donner les clés du précédent.
    static func identity(for userID: String) -> Curve25519.KeyAgreement.PrivateKey {
        let account = "identity.\(userID.lowercased())"
        if let data = read(account), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        write(key.rawRepresentation, account: account)
        return key
    }

    // MARK: Clés de groupe

    static func groupKey(groupID: String, keyID: String) -> SymmetricKey? {
        guard let data = read("group.\(groupID.lowercased()).\(keyID)"), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func saveGroupKey(_ key: SymmetricKey, groupID: String) {
        let keyID = GroupCrypto.keyID(of: key)
        write(key.withUnsafeBytes { Data($0) }, account: "group.\(groupID.lowercased()).\(keyID)")
    }

    // MARK: Trousseau

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
    }

    private static func read(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, account: String) {
        let query = baseQuery(account)
        // `afterFirstUnlock` : lisible quand une notification ou un
        // rafraîchissement réveille l'app, téléphone verrouillé.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
