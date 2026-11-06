import Foundation
import Security

/// La clé du compte de la synchronisation chiffrée (`AK`), dans le trousseau de CET appareil.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` et non synchronisable : la clé ne
/// part ni dans une sauvegarde transférable ni dans le Trousseau iCloud — c'est
/// l'appairage ou la clé de secours qui donnent la clé à un autre appareil. Lisible
/// après le premier déverrouillage, pour qu'une passe en arrière-plan puisse déchiffrer.
/// Une clé par compte Supabase : se connecter avec un autre compte n'ouvre pas celle du précédent.
enum SyncKeyStore {
    private static let service = "com.hczr.studytrack.syncvault"

    private static func baseQuery(_ userID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ak.\(userID.lowercased())",
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    static func load(userID: String) -> Data? {
        var query = baseQuery(userID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
        return data
    }

    @discardableResult
    static func save(_ key: Data, userID: String) -> Bool {
        let query = baseQuery(userID)
        let attributes: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func clear(userID: String) {
        SecItemDelete(baseQuery(userID) as CFDictionary)
    }
}

/// La WebSocket de l'appairage vers le relais (`wss://<hôte>/v1/pair-…`). N'existe que le
/// temps de l'écran « Ajouter un appareil » ou « Entrer un code » : fermée, plus rien ne tourne.
final class RelayPairSocket: NSObject, SyncPairSocket, @unchecked Sendable {
    /// Le relais ne dit rien à l'ouverture : la socket est tenue pour ouverte dès qu'elle est lancée
    /// (les envois attendent la connexion). Posé après la création, `onOpen` part tout de suite.
    var onOpen: (() -> Void)? {
        didSet {
            lock.lock(); let fire = onOpen != nil && !opened; if fire { opened = true }; lock.unlock()
            if fire, let handler = onOpen { DispatchQueue.global().async(execute: handler) }
        }
    }
    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var closed = false
    private var opened = false

    /// L'hôte du relais du build (`TimerRelayHost` de l'Info.plist), sans « https:// » ; `nil` s'il n'est pas configuré.
    static var configuredHost: String? {
        let host = Bundle.main.object(forInfoDictionaryKey: "TimerRelayHost") as? String ?? ""
        return host.isEmpty || host.hasPrefix("$(") ? nil : host
    }

    static func factory(host: String) -> SyncPairSocketFactory {
        { channel in RelayPairSocket(host: host, channel: channel) }
    }

    init(host: String, channel: String) {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/v1/" + channel
        components.queryItems = [URLQueryItem(name: "device", value: UUID().uuidString)]
        task = URLSession.shared.webSocketTask(with: components.url!)
        super.init()
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.onMessage?(text)
                self.receive()
            case .success:
                self.receive()
            case .failure:
                self.finish()
            }
        }
    }

    func send(_ text: String) {
        task.send(.string(text)) { [weak self] error in if error != nil { self?.finish() } }
    }

    func close() {
        lock.lock(); let already = closed; closed = true; lock.unlock()
        if !already { task.cancel(with: .normalClosure, reason: nil) }
    }

    private func finish() {
        lock.lock(); let already = closed; closed = true; lock.unlock()
        if !already { onClose?() }
    }
}
