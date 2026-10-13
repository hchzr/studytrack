import Foundation
import WebKit
import Security

/// Garde les sessions des sites de cours **d'un lancement à l'autre**.
///
/// Switch edu-ID (MediaSpace) et plusieurs sites EPFL posent des cookies « de
/// session » : sans date d'expiration, WebKit les oublie quand l'app se ferme
/// (sur l'iPhone comme sur le Mac). Il
/// fallait donc se reconnecter à MediaSpace à chaque vidéo, ou presque. Ici,
/// les cookies de ces sites sont copiés dans le trousseau (sur cet appareil
/// seulement) quand l'app passe en arrière-plan ou après une connexion, et
/// remis en place au lancement. Le serveur reste maître : une session qu'il a
/// close l'est toujours ; on évite seulement de perdre celles qu'il garde.
@MainActor
enum CookieKeeper {
    /// Les sites dont on garde la session.
    nonisolated private static var domains: [String] {
        Institution.current.rootDomains + ["eduid.ch", "switch.ch", "kaltura.com"] + [Institution.current.video?.passwordIdPHost].compactMap { $0 }
    }
    nonisolated private static let service = "com.hczr.studytrack.cookies"

    nonisolated private static func relevant(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Copie les cookies des sites de cours dans le trousseau.
    static func save() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter(relevant)
        store(cookies)
    }

    /// Remet en place les cookies gardés qui manquent (au lancement).
    static func restore() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let present = Set(await store.allCookies().map(key))
        for cookie in stored() where !present.contains(key(cookie)) {
            await store.setCookie(cookie)
        }
    }

    /// Les cookies gardés, sans passer par WebKit : la surveillance de Moodle
    /// tourne en arrière-plan, où le magasin de WebKit n'est pas sûr.
    nonisolated static func stored(now: Date = Date()) -> [HTTPCookie] {
        guard let data = load(),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in row where key != "__expires" {
                properties[HTTPCookiePropertyKey(key)] = value
            }
            if let expires = row["__expires"] as? Double {
                let date = Date(timeIntervalSince1970: expires)
                guard date > now else { return nil }
                properties[.expires] = date
            } else {
                // Un cookie de session reste un cookie de session : il vivra
                // jusqu'à la fermeture de l'app, et sera remis au prochain lancement.
                properties[.expires] = nil
                properties[.discard] = "TRUE"
            }
            return HTTPCookie(properties: properties)
        }
    }

    /// Garde les cookies renouvelés par un serveur (Moodle prolonge sa session
    /// à chaque requête) à la place des anciens.
    nonisolated static func merge(_ fresh: [HTTPCookie]) {
        let updates = fresh.filter(relevant)
        guard !updates.isEmpty else { return }
        let replaced = Set(updates.map(key))
        store(stored().filter { !replaced.contains(key($0)) } + updates)
    }

    nonisolated private static func key(_ cookie: HTTPCookie) -> String {
        "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
    }

    nonisolated private static func store(_ cookies: [HTTPCookie]) {
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

    nonisolated static func clear() {
        #if os(macOS)
        try? FileManager.default.removeItem(at: file)
        #endif
        SecItemDelete(base as CFDictionary)
    }

    // MARK: Trousseau

    nonisolated private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    #if os(macOS)
    /// Sur le Mac, un fichier lisible par toi seul, à côté de la base de l'app
    /// (comme les cookies d'un navigateur) : le trousseau demandait un droit que
    /// l'app de développement n'a pas, ou une autorisation à chaque version.
    nonisolated private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyTrack/session-cookies.json")
    }
    #endif

    nonisolated private static func store(_ data: Data) {
        #if os(macOS)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: file, options: [.atomic])) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        #else
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
        #endif
    }

    nonisolated private static func load() -> Data? {
        #if os(macOS)
        return try? Data(contentsOf: file)
        #else
        var item: CFTypeRef?
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
        #endif
    }
}
