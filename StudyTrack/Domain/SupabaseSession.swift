import Foundation

/// Session Supabase telle qu'elle survit à un lancement de l'app.
///
/// Type **valeur et pur** : la décision « ce jeton est-il encore bon ? » se teste
/// sans réseau ni trousseau, et le stockage lui-même vit ailleurs.
struct StoredSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var userID: String?
    var email: String?
    /// Instant où `accessToken` cesse d'être accepté par le serveur.
    var expiresAt: Date

    init(accessToken: String,
         refreshToken: String? = nil,
         userID: String? = nil,
         email: String? = nil,
         expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.email = email
        self.expiresAt = expiresAt
    }

    /// Marge avant l'expiration réelle.
    ///
    /// Un jeton « encore valable 3 secondes » ne l'est plus le temps que la requête
    /// parte : la marge évite un aller-retour perdu sur deux.
    static let leeway: TimeInterval = 60

    /// L'identifiant de l'utilisateur (`sub`) lu dans un jeton d'accès JWT.
    ///
    /// Le jeton porte l'identifiant : une session où il manque n'a pas à être
    /// traitée comme une absence de configuration.
    static func subject(ofJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String, !subject.isEmpty else { return nil }
        return subject
    }

    func isExpired(at now: Date = Date()) -> Bool {
        expiresAt <= now.addingTimeInterval(Self.leeway)
    }

    /// Un jeton utilisable, même expiré, tant qu'on peut le rafraîchir.
    var isUsable: Bool { !accessToken.isEmpty }
}
