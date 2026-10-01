import Foundation
import WebKit
import Security

/// Garde les sessions des sites de cours **d'un lancement à l'autre**.
///
/// Switch edu-ID (MediaSpace) et plusieurs sites EPFL posent des cookies « de
/// session » : sans date d'expiration, iOS les oublie quand l'app se ferme. Il
/// fallait donc se reconnecter à MediaSpace à chaque vidéo, ou presque. Ici,
/// les cookies de ces sites sont copiés dans le trousseau (sur cet appareil
/// seulement) quand l'app passe en arrière-plan ou après une connexion, et
/// remis en place au lancement. Le serveur reste maître : une session qu'il a
/// close l'est toujours ; on évite seulement de perdre celles qu'il garde.
@MainActor
enum CookieKeeper {
    /// Les sites dont on garde la session.
    private static let domains = ["epfl.ch", "eduid.ch", "switch.ch", "kaltura.com"]
    private static let service = "com.hczr.studytrack.cookies"

    private static func relevant(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Copie les cookies des sites de cours dans le trousseau.
    static func save() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter(relevant)
        let now = Date()
        let rows: [[String: Any]] = cookies.compactMap { cookie in
            if let expiry = cookie.expiresDate, expiry < now { return nil }
            var row: [String: Any] = [:]
            for (key, value) in cookie.properties ?? [:] {
                switch value {
                case let date as Date: row[key.rawValue] = date.timeIntervalSince1970
                case let string as String: row[key.rawValue] = string
                case let number as NSNumber: row[key.rawValue] = number
                default: row[key.rawValue] = "\(value)"
                }
            }
            row["__expires"] = cookie.expiresDate?.timeIntervalSince1970
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        store(data)
    }

    /// Remet en place les cookies gardés qui manquent (au lancement).
    static func restore() async {
        guard let data = load(),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let present = Set(await store.allCookies().map { "\($0.domain)|\($0.path)|\($0.name)" })
        let now = Date()
        for row in rows {
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in row where key != "__expires" {
                properties[HTTPCookiePropertyKey(key)] = value
            }
            if let expires = row["__expires"] as? Double {
                let date = Date(timeIntervalSince1970: expires)
                guard date > now else { continue }
                properties[.expires] = date
            } else {
                // Un cookie de session reste un cookie de session : il vivra
                // jusqu'à la fermeture de l'app, et sera remis au prochain lancement.
                properties[.expires] = nil
                properties[.discard] = "TRUE"
            }
            guard let cookie = HTTPCookie(properties: properties),
                  !present.contains("\(cookie.domain)|\(cookie.path)|\(cookie.name)") else { continue }
            await store.setCookie(cookie)
        }
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    // MARK: Trousseau

    private static func store(_ data: Data) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func load() -> Data? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}
