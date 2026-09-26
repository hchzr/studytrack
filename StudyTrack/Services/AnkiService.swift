import Foundation

/// Parle à **AnkiConnect** — l'extension d'Anki Desktop qui expose son API locale.
///
/// Pourquoi AnkiConnect plutôt qu'un export de fichier : c'est ce qui fait qu'une
/// carte arrive dans le paquet **tout de suite**, révisable le soir même, sans
/// manipulation de fichier. La contrepartie est honnête et affichée dans l'app :
/// Anki doit être ouvert, sur le même réseau, et l'extension installée.
///
/// Aucune erreur n'est avalée : « Anki ne répond pas » et « le paquet n'existe
/// pas » demandent deux gestes différents.
enum AnkiService {

    enum AnkiError: LocalizedError {
        case notConfigured
        case unreachable(String)
        case http(Int)
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Adresse d'AnkiConnect vide (Profil › Anki)."
            case .unreachable(let detail):
                return "Anki est injoignable — \(detail)"
            case .http(let code):
                return "AnkiConnect a répondu \(code)."
            case .rejected(let message):
                return AnkiConnect.explain(message)
            }
        }
    }

    struct Connection {
        var version: Int
        var decks: [String]
    }

    // MARK: Appel

    /// Envoie une action et rend son résultat, ou une erreur expliquée.
    static func call(_ action: String,
                     params: [String: Any] = [:],
                     endpoint: String,
                     session: URLSession = .shared) async throws -> AnkiOutcome {
        guard let base = AnkiConnect.normalizeEndpoint(endpoint),
              let url = URL(string: base) else { throw AnkiError.notConfigured }
        guard let body = AnkiConnect.requestData(action: action, params: params) else {
            throw AnkiError.rejected("requête illisible")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnkiError.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnkiError.http(http.statusCode)
        }

        let outcome = AnkiConnect.outcome(from: data)
        if let message = outcome.errorMessage { throw AnkiError.rejected(message) }
        return outcome
    }

    // MARK: Actions

    /// Vérifie que l'extension répond, et récupère les paquets.
    ///
    /// Deux appels en un : se contenter de la version laisserait croire que tout
    /// va bien alors que la liste des paquets est le vrai préalable à l'envoi.
    static func test(endpoint: String, session: URLSession = .shared) async throws -> Connection {
        let versionOutcome = try await call("version", endpoint: endpoint, session: session)
        var version = 0
        if case .value(.number(let value)) = versionOutcome { version = Int(value) }

        let decksOutcome = try await call("deckNames", endpoint: endpoint, session: session)
        return Connection(version: version, decks: decksOutcome.stringList.sorted())
    }

    static func deckNames(endpoint: String, session: URLSession = .shared) async throws -> [String] {
        try await call("deckNames", endpoint: endpoint, session: session).stringList.sorted()
    }

    /// Crée la carte. Renvoie l'identifiant Anki, ou `nil` si l'ajout a été refusé
    /// en silence (doublon, par exemple).
    @discardableResult
    static func add(_ note: AnkiNote,
                    endpoint: String,
                    session: URLSession = .shared) async throws -> Double? {
        // Le paquet doit exister : AnkiConnect refuse sinon, et le message brut
        // n'aide pas. On le crée au passage, c'est ce que veut l'utilisateur.
        _ = try? await call("createDeck",
                            params: ["deck": note.deckName],
                            endpoint: endpoint,
                            session: session)

        let outcome = try await call("addNote", params: note.payload, endpoint: endpoint, session: session)
        if case .value(.number(let id)) = outcome { return id }
        return nil
    }

    /// Envoie plusieurs cartes, en comptant celles qui passent.
    ///
    /// Séquentiel et tolérant : une carte en doublon ne doit pas faire échouer les
    /// suivantes, sinon un envoi de vingt cartes s'arrête à la première déjà vue.
    static func add(_ notes: [AnkiNote],
                    endpoint: String,
                    session: URLSession = .shared) async -> (added: Int, skipped: Int, firstError: String?) {
        var added = 0
        var skipped = 0
        var firstError: String?
        for note in notes {
            do {
                if try await add(note, endpoint: endpoint, session: session) != nil {
                    added += 1
                } else {
                    skipped += 1
                }
            } catch {
                skipped += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return (added, skipped, firstError)
    }

    /// Le nombre de cartes dues aujourd'hui, pour situer la charge de révision.
    static func dueCount(endpoint: String, session: URLSession = .shared) async -> Int? {
        guard let outcome = try? await call("findCards",
                                            params: ["query": "is:due"],
                                            endpoint: endpoint,
                                            session: session),
              case .value(.array(let cards)) = outcome else { return nil }
        return cards.count
    }
}
