import Foundation

/// Erreurs du client Supabase.
enum SupabaseError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case server(status: Int, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Supabase n'est pas configuré (URL ou clé manquante)."
        case .invalidURL: return "URL Supabase invalide."
        case .invalidResponse: return "Réponse invalide du serveur."
        case .server(let status, let message): return "Erreur serveur (\(status)) : \(message)"
        case .decoding(let detail): return "Décodage impossible : \(detail)"
        }
    }
}

/// Session authentifiée Supabase.
struct SupabaseSession: Decodable {
    var accessToken: String
    var tokenType: String?
    var expiresIn: Int?
    var refreshToken: String?
    var user: SupabaseUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case user
    }
}

struct SupabaseUser: Decodable {
    var id: String
    var email: String?
}

/// Client REST minimal pour Supabase (Auth + PostgREST), sans dépendance externe.
final class SupabaseClient {

    let baseURL: URL
    let anonKey: String

    private let session: URLSession
    private(set) var accessToken: String?
    private(set) var userID: String?
    private(set) var userEmail: String?
    /// Jeton de rafraîchissement : sans lui, la session mourait au bout d'une heure
    /// et toutes les requêtes échouaient en 401 — en silence, puisque les appelants
    /// ignoraient l'erreur.
    private var refreshToken: String?
    private var expiresAt: Date?

    var isSignedIn: Bool { accessToken != nil }

    /// Hôte, utilisé comme clé de trousseau.
    private var host: String { baseURL.host ?? baseURL.absoluteString }

    init?(urlString: String, anonKey: String, session: URLSession = .shared) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedKey.isEmpty,
              let url = URL(string: trimmedURL) else { return nil }
        self.baseURL = url
        self.anonKey = trimmedKey
        self.session = session

        // Reprise de la session du lancement précédent.
        if let stored = SupabaseSessionStore.load(host: url.host ?? trimmedURL) {
            self.accessToken = stored.accessToken
            self.refreshToken = stored.refreshToken
            self.userID = stored.userID
            self.userEmail = stored.email
            self.expiresAt = stored.expiresAt
        }
    }

    // MARK: - Requête générique

    @discardableResult
    func request(_ path: String,
                 method: String = "GET",
                 query: [URLQueryItem] = [],
                 body: Data? = nil,
                 prefer: String? = nil,
                 useAuth: Bool = true) async throws -> Data? {
        try await perform(path, method: method, query: query, body: body,
                          prefer: prefer, useAuth: useAuth, allowsRefresh: true)
    }

    private func perform(_ path: String,
                         method: String,
                         query: [URLQueryItem],
                         body: Data?,
                         prefer: String?,
                         useAuth: Bool,
                         allowsRefresh: Bool) async throws -> Data? {
        if useAuth, allowsRefresh, needsRefresh() {
            do {
                try await refreshSession()
            } catch {
                // Jeton de rafraîchissement refusé : la session est morte pour de
                // bon. On l'efface au lieu de la garder et d'échouer en boucle.
                clearSession()
                throw error
            }
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SupabaseError.invalidURL
        }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SupabaseError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if useAuth, let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }

        // Jeton refusé alors qu'on se croyait connecté : on rafraîchit **une fois**
        // et on rejoue la requête. Sans cette seconde chance, une session expirée
        // faisait échouer chaque appel jusqu'au prochain redémarrage manuel.
        if http.statusCode == 401, useAuth, allowsRefresh, refreshToken != nil {
            do {
                try await refreshSession(force: true)
            } catch {
                clearSession()
                throw error
            }
            return try await perform(path, method: method, query: query, body: body,
                                     prefer: prefer, useAuth: useAuth, allowsRefresh: false)
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SupabaseError.server(status: http.statusCode, message: message)
        }
        return data
    }

    // MARK: - Session

    private func needsRefresh() -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(StoredSession.leeway)
    }

    /// Échange le jeton de rafraîchissement contre un jeton d'accès neuf.
    private func refreshSession(force: Bool = false) async throws {
        guard let refreshToken else { return }
        if !force, !needsRefresh() { return }

        let payload: [String: Any] = ["refresh_token": refreshToken]
        let data = try await perform("/auth/v1/token",
                                     method: "POST",
                                     query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                     body: try JSONSerialization.data(withJSONObject: payload),
                                     prefer: nil,
                                     useAuth: false,
                                     allowsRefresh: false)
        try applySession(data)
    }

    /// Efface la session partout — mémoire **et** trousseau.
    private func clearSession() {
        accessToken = nil
        refreshToken = nil
        userID = nil
        userEmail = nil
        expiresAt = nil
        SupabaseSessionStore.clear(host: host)
    }

    // MARK: - Authentification

    func signInWithApple(idToken: String, nonce: String) async throws {
        let payload: [String: Any] = [
            "provider": "apple",
            "id_token": idToken,
            "nonce": nonce
        ]
        let data = try await request("/auth/v1/token",
                                     method: "POST",
                                     query: [URLQueryItem(name: "grant_type", value: "id_token")],
                                     body: try JSONSerialization.data(withJSONObject: payload),
                                     useAuth: false)
        try applySession(data)
    }

    func signUp(email: String, password: String) async throws {
        let payload: [String: Any] = ["email": email, "password": password]
        let data = try await request("/auth/v1/signup",
                                     method: "POST",
                                     body: try JSONSerialization.data(withJSONObject: payload),
                                     useAuth: false)
        try applySession(data)
    }

    func signIn(email: String, password: String) async throws {
        let payload: [String: Any] = ["email": email, "password": password]
        let data = try await request("/auth/v1/token",
                                     method: "POST",
                                     query: [URLQueryItem(name: "grant_type", value: "password")],
                                     body: try JSONSerialization.data(withJSONObject: payload),
                                     useAuth: false)
        try applySession(data)
    }

    func signOut() async {
        if accessToken != nil {
            _ = try? await request("/auth/v1/logout", method: "POST")
        }
        clearSession()
    }

    private func applySession(_ data: Data?) throws {
        guard let data else { throw SupabaseError.invalidResponse }
        do {
            let session = try JSONDecoder().decode(SupabaseSession.self, from: data)
            self.accessToken = session.accessToken
            self.refreshToken = session.refreshToken ?? self.refreshToken
            self.userID = session.user?.id ?? self.userID
            self.userEmail = session.user?.email ?? self.userEmail
            // Sans `expires_in`, on suppose une heure : c'est la valeur par défaut
            // de Supabase, et se tromper vers le bas ne coûte qu'un rafraîchissement.
            self.expiresAt = Date().addingTimeInterval(TimeInterval(session.expiresIn ?? 3600))

            if let accessToken, let expiresAt {
                SupabaseSessionStore.save(
                    StoredSession(accessToken: accessToken,
                                  refreshToken: self.refreshToken,
                                  userID: self.userID,
                                  email: self.userEmail,
                                  expiresAt: expiresAt),
                    host: host)
            }
        } catch {
            throw SupabaseError.decoding(error.localizedDescription)
        }
    }

    // MARK: - PostgREST helpers

    @discardableResult
    func select(_ table: String, query: [URLQueryItem]) async throws -> Data? {
        try await request("/rest/v1/\(table)", query: query)
    }

    @discardableResult
    /// - Parameter returning: `false` = `return=minimal`. **Indispensable** sur une
    ///   table dont la politique de lecture dépend de la ligne qu'on insère
    ///   (`group_members` : « visible par les membres ») — avec `RETURNING`,
    ///   Postgres relit la ligne dans la même instruction, la fonction `stable`
    ///   ne la voit pas encore, et l'insertion échoue en 42501 alors qu'elle est
    ///   parfaitement autorisée.
    func insert(_ table: String, values: [String: Any], returning: Bool = true) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: values)
        return try await request("/rest/v1/\(table)",
                                 method: "POST",
                                 body: body,
                                 prefer: returning ? "return=representation" : "return=minimal")
    }

    @discardableResult
    func insert(_ table: String, rows: [[String: Any]], returning: Bool = true) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: rows)
        return try await request("/rest/v1/\(table)",
                                 method: "POST",
                                 body: body,
                                 prefer: returning ? "return=representation" : "return=minimal")
    }

    @discardableResult
    func update(_ table: String, query: [URLQueryItem], values: [String: Any]) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: values)
        return try await request("/rest/v1/\(table)",
                                 method: "PATCH",
                                 query: query,
                                 body: body,
                                 prefer: "return=representation")
    }

    @discardableResult
    func delete(_ table: String, query: [URLQueryItem]) async throws -> Data? {
        try await request("/rest/v1/\(table)", method: "DELETE", query: query)
    }

    @discardableResult
    func upsert(_ table: String, rows: [[String: Any]], onConflict: String, returning: Bool = true) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: rows)
        return try await request("/rest/v1/\(table)",
                                 method: "POST",
                                 query: [URLQueryItem(name: "on_conflict", value: onConflict)],
                                 body: body,
                                 prefer: returning
                                     ? "resolution=merge-duplicates,return=representation"
                                     : "resolution=merge-duplicates,return=minimal")
    }

    @discardableResult
    func rpc(_ function: String, params: [String: Any]) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: params)
        return try await request("/rest/v1/rpc/\(function)", method: "POST", body: body)
    }
}
