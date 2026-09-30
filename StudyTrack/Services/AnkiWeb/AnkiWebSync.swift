import Foundation
import Observation
import Security
import SwiftData

/// Une carte à ajouter dans Anki : le paquet, le type de note, ses champs.
struct AnkiDraftNote: Codable, Hashable, Identifiable {
    var id = UUID()
    var deckID: Int64
    var notetypeID: Int64
    var fields: [String]
    var tags: [String]
    /// D'où elle vient (« Exercice 3.2 · CS-250 ») : affiché dans la file d'attente.
    var origin: String
}

/// AnkiWeb, sans ordinateur : se connecter, garder une copie de la collection,
/// y ajouter des notes, et lire les statistiques de révision.
///
/// **Sûreté.** L'app n'envoie jamais la collection entière. Un ajout est une
/// synchronisation normale où l'app déclare n'avoir rien reçu depuis la copie
/// qu'elle tient (qui doit être identique au serveur — sinon elle la
/// retélécharge d'abord). Le serveur applique les notes dans une transaction,
/// vérifie les comptes, et **annule tout** si quoi que ce soit diffère.
@MainActor
@Observable
final class AnkiWebSync {
    static let shared = AnkiWebSync()

    private(set) var isWorking = false
    private(set) var status = ""
    private(set) var lastError: String?
    /// Les notes pas encore envoyées (hors ligne, ou envoi refusé).
    private(set) var pending: [AnkiDraftNote] = []

    private let defaults = UserDefaults.standard
    private enum Key {
        static let username = "ankiweb.username"
        static let endpoint = "ankiweb.endpoint"
        static let serverMod = "ankiweb.mirror.mod"
        static let serverUsn = "ankiweb.mirror.usn"
        static let lastRefresh = "ankiweb.mirror.refreshedAt"
        static let pending = "ankiweb.pending"
        static let lastReviewID = "ankiweb.lastReviewID"
        static let deckMap = "ankiweb.deckMap"
        static let notetype = "ankiweb.notetype"
        static let autoRedo = "ankiweb.autoRedo"
    }

    // MARK: Préférences

    /// Le paquet de chaque cours (code du cours → identifiant du paquet).
    var deckMap: [String: Int64] {
        get { (defaults.dictionary(forKey: Key.deckMap) as? [String: NSNumber])?.mapValues(\.int64Value) ?? [:] }
        set { defaults.set(newValue.mapValues { NSNumber(value: $0) }, forKey: Key.deckMap) }
    }

    /// Le type de note des cartes créées (question / réponse).
    var notetypeID: Int64? {
        get { (defaults.object(forKey: Key.notetype) as? NSNumber)?.int64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Key.notetype) }
    }

    /// Un exercice corrigé « faux » devient une carte, tout seul.
    var autoRedo: Bool {
        get { defaults.bool(forKey: Key.autoRedo) }
        set { defaults.set(newValue, forKey: Key.autoRedo) }
    }

    /// Le paquet d'un cours : choisi, sinon deviné (code ou nom dans le paquet).
    func deck(for course: Course?, in collection: AnkiCollection) -> AnkiCollection.Deck? {
        let decks = collection.decks.filter { !$0.isFiltered }
        guard let course else { return decks.first { $0.name == "Default" } ?? decks.first }
        if let id = deckMap[course.code], let deck = decks.first(where: { $0.id == id }) { return deck }
        let code = course.code.uppercased()
        let name = course.name.lowercased()
        return decks.first { $0.name.uppercased().contains(code) }
            ?? decks.first { !name.isEmpty && $0.leaf.lowercased().contains(name) }
            ?? decks.first { !name.isEmpty && name.contains($0.leaf.lowercased()) && $0.leaf.count >= 4 }
    }

    /// Le type question / réponse : choisi, sinon « Basic » / « Basique ».
    func basicNotetype(in collection: AnkiCollection) -> AnkiCollection.Notetype? {
        let types = collection.notetypes.filter { !$0.isCloze && $0.fields.count >= 2 }
        if let id = notetypeID, let type = types.first(where: { $0.id == id }) { return type }
        return types.first { ["basic", "basique", "einfach"].contains($0.name.lowercased()) }
            ?? types.first { $0.templateCount == 1 }
    }

    private init() {
        if let data = defaults.data(forKey: Key.pending),
           let saved = try? JSONDecoder().decode([AnkiDraftNote].self, from: data) {
            pending = saved
        }
    }

    var username: String { defaults.string(forKey: Key.username) ?? "" }
    var isSignedIn: Bool { AnkiKeychain.hostKey != nil }
    var hasCollection: Bool { AnkiCollection.exists }
    var lastRefresh: Date? { defaults.object(forKey: Key.lastRefresh) as? Date }

    private func client() -> AnkiWebClient {
        AnkiWebClient(hostKey: AnkiKeychain.hostKey ?? "",
                      endpoint: defaults.string(forKey: Key.endpoint).flatMap(URL.init(string:)))
    }

    private func remember(_ client: AnkiWebClient) {
        defaults.set(client.endpoint.absoluteString, forKey: Key.endpoint)
    }

    // MARK: Compte

    /// Le mot de passe ne sert qu'à obtenir la clé d'hôte ; seule la clé est
    /// gardée (trousseau).
    func signIn(username: String, password: String) async -> Bool {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let client = AnkiWebClient(endpoint: defaults.string(forKey: Key.endpoint).flatMap(URL.init(string:)))
            status = "Connexion à AnkiWeb…"
            let key = try await client.login(username: username, password: password)
            AnkiKeychain.hostKey = key
            defaults.set(username, forKey: Key.username)
            remember(client)
            try await refreshMirror(force: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func signOut() {
        AnkiKeychain.hostKey = nil
        for key in [Key.username, Key.endpoint, Key.serverMod, Key.serverUsn, Key.lastRefresh] {
            defaults.removeObject(forKey: key)
        }
        AnkiCollection.remove()
        status = ""
    }

    // MARK: Copie de la collection

    /// Retélécharge la collection si le serveur a changé depuis la copie.
    func refreshMirror(force: Bool = false) async throws {
        let client = client()
        status = "Lecture d'AnkiWeb…"
        let meta = try await client.meta()
        remember(client)
        let upToDate = AnkiCollection.exists
            && defaults.object(forKey: Key.serverMod) as? Int64 == meta.modified
            && AnkiCollection()?.schema == meta.schema
        if upToDate && !force {
            status = "À jour"
            defaults.set(Date(), forKey: Key.lastRefresh)
            return
        }
        status = "Téléchargement de la collection…"
        let data = try await client.download()
        try AnkiCollection.install(data)
        // Le téléchargement incrémente le numéro de synchronisation du serveur :
        // on relit l'état pour que la copie corresponde exactement.
        let after = try await client.meta()
        defaults.set(after.modified, forKey: Key.serverMod)
        defaults.set(after.usn, forKey: Key.serverUsn)
        defaults.set(Date(), forKey: Key.lastRefresh)
        status = "Collection à jour"
    }

    // MARK: Ajouter des notes

    func enqueue(_ note: AnkiDraftNote) {
        pending.append(note)
        savePending()
    }

    func discard(_ note: AnkiDraftNote) {
        pending.removeAll { $0.id == note.id }
        savePending()
    }

    private func savePending() {
        defaults.set(try? JSONEncoder().encode(pending), forKey: Key.pending)
    }

    /// Envoie la file d'attente. Rien n'est retiré de la file tant qu'AnkiWeb
    /// n'a pas confirmé.
    @discardableResult
    func pushPending() async -> Int {
        guard isSignedIn, !pending.isEmpty, !isWorking else { return 0 }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        let batch = pending
        do {
            try await push(batch)
            pending.removeAll { note in batch.contains { $0.id == note.id } }
            savePending()
            status = batch.count == 1 ? "1 carte ajoutée à Anki" : "\(batch.count) cartes ajoutées à Anki"
            return batch.count
        } catch {
            lastError = error.localizedDescription
            status = ""
            return 0
        }
    }

    private func push(_ drafts: [AnkiDraftNote]) async throws {
        let client = client()
        var meta = try await client.meta()
        if meta.modified != defaults.object(forKey: Key.serverMod) as? Int64 || AnkiCollection()?.schema != meta.schema {
            try await refreshMirror(force: true)
            meta = try await client.meta()
        }
        guard let collection = AnkiCollection(writable: true) else { throw AnkiWebClient.Failure.decoding("collection") }
        let serverUsn = meta.usn
        let (notes, cards) = try build(drafts, collection: collection, usn: serverUsn)

        status = "Envoi à AnkiWeb…"
        do {
            // « Rien reçu depuis `serverUsn` » : la copie est le serveur.
            let graves = try await client.start(minUsn: serverUsn, localIsNewer: false)
            let removed = ["cards", "notes", "decks"].reduce(0) { $0 + ((graves[$1] as? [Any])?.count ?? 0) }
            guard removed == 0 else { throw AnkiWebClient.Failure.fullSyncRequired }

            let tags = Array(Set(drafts.flatMap(\.tags)))
            let changes = try await client.applyChanges(tags: tags)
            let changed = ((changes["models"] as? [Any])?.count ?? 0)
                + (((changes["decks"] as? [Any])?.first as? [Any])?.count ?? 0)
            guard changed == 0 else { throw AnkiWebClient.Failure.fullSyncRequired }

            while true {
                let chunk = try await client.chunk()
                let rows = ["notes", "cards", "revlog"].reduce(0) { $0 + ((chunk[$1] as? [Any])?.count ?? 0) }
                guard rows == 0 else { throw AnkiWebClient.Failure.fullSyncRequired }
                if chunk["done"] as? Bool ?? true { break }
            }

            try await client.applyChunk(notes: notes, cards: cards, done: true)
            let check = try await client.sanityCheck(collection.sanityCounts(addingNotes: notes.count, cards: cards.count))
            guard (check["status"] as? String) == "ok" else {
                throw AnkiWebClient.Failure.sanity("")
            }
            let modified = try await client.finish()
            _ = collection.record(notes: notes, cards: cards)
            defaults.set(modified, forKey: Key.serverMod)
            defaults.set(serverUsn + 1, forKey: Key.serverUsn)
        } catch {
            // Le serveur annule la transaction : sa collection reste intacte.
            await client.abort()
            throw error
        }
    }

    /// Les lignes `notes` et `cards` au format du protocole.
    private func build(_ drafts: [AnkiDraftNote], collection: AnkiCollection, usn: Int) throws -> ([[Any]], [[Any]]) {
        let types = Dictionary(uniqueKeysWithValues: collection.notetypes.map { ($0.id, $0) })
        let decks = Set(collection.decks.map(\.id))
        let now = Int64(Date().timeIntervalSince1970)
        var noteID = max(collection.maxNoteID + 1, Int64(Date().timeIntervalSince1970 * 1000))
        var cardID = max(collection.maxCardID + 1, noteID)
        var position = collection.nextNewPosition
        var notes: [[Any]] = []
        var cards: [[Any]] = []
        for draft in drafts {
            guard let type = types[draft.notetypeID], decks.contains(draft.deckID) else {
                throw AnkiWebClient.Failure.unsupported("Le paquet ou le type de note de « \(draft.origin) » n'existe plus dans Anki.")
            }
            var fields = Array(draft.fields.prefix(type.fields.count))
            while fields.count < type.fields.count { fields.append("") }
            let joined = fields.joined(separator: "\u{1f}")
            let tags = draft.tags.isEmpty ? "" : " " + draft.tags.map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: " ") + " "
            notes.append([noteID, Self.guid(), type.id, now, usn, tags, joined, "", "", 0, ""])

            let ords: [Int]
            if type.isCloze {
                ords = Self.clozeNumbers(in: joined).map { $0 - 1 }
                guard !ords.isEmpty else {
                    throw AnkiWebClient.Failure.unsupported("« \(draft.origin) » : une note à trous doit contenir {{c1::…}}.")
                }
            } else {
                ords = Array(0..<max(1, min(type.templateCount, 1)))
            }
            for ord in ords {
                // [id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data]
                cards.append([cardID, noteID, draft.deckID, ord, now, usn, 0, 0, position, 0, 0, 0, 0, 0, 0, 0, 0, ""])
                cardID += 1
            }
            position += 1
            noteID += 1
            cardID = max(cardID, noteID)
        }
        return (notes, cards)
    }

    static func clozeNumbers(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{c(\d+)::"#) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let numbers = matches.compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
        return Array(Set(numbers)).filter { $0 > 0 }.sorted()
    }

    /// Un identifiant global de note, comme Anki (base 91, dix caractères).
    static func guid() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")
        var value = UInt64.random(in: 1...UInt64.max)
        var result = ""
        while value > 0 {
            result.append(alphabet[Int(value % UInt64(alphabet.count))])
            value /= UInt64(alphabet.count)
        }
        return result
    }

    // MARK: Révisions

    /// Les révisions faites depuis le dernier relevé (tous appareils confondus,
    /// puisqu'elles arrivent par AnkiWeb).
    func newReviews() -> [AnkiReview] {
        guard let collection = AnkiCollection() else { return [] }
        let floor = Int64((Date().timeIntervalSince1970 - 30 * 86_400) * 1000)
        let after = max(defaults.object(forKey: Key.lastReviewID) as? Int64 ?? 0, floor)
        let reviews = collection.reviews(after: after)
        if let last = reviews.map(\.id).max() { defaults.set(last, forKey: Key.lastReviewID) }
        return reviews
    }
}

extension AnkiWebSync {
    /// Un exercice corrigé « faux » devient une carte (si l'option est active) :
    /// l'énoncé au recto, la note de correction et la solution au verso.
    func enqueueRedo(_ exercise: Exercise) {
        guard autoRedo, isSignedIn, let collection = AnkiCollection() else { return }
        let course = exercise.series?.course
        guard let deck = deck(for: course, in: collection), let type = basicNotetype(in: collection) else { return }
        let origin = "\(exercise.displayNumber) · \(course?.displayCode ?? "")"
        guard !pending.contains(where: { $0.origin == origin }) else { return }
        let statement = exercise.statement.isEmpty ? exercise.title : exercise.statement
        let front = ([course?.displayCode, exercise.displayNumber].compactMap { $0 }.joined(separator: " · ")
                     + (statement.isEmpty ? "" : "<br><br>" + statement))
            .replacingOccurrences(of: "\n", with: "<br>")
        let back = [exercise.correctionNote ?? "", exercise.solution].filter { !$0.isEmpty }
            .joined(separator: "<br><br>").replacingOccurrences(of: "\n", with: "<br>")
        enqueue(AnkiDraftNote(deckID: deck.id, notetypeID: type.id, fields: [front, back],
                              tags: ["studytrack", "à_refaire"], origin: origin))
        Task { await pushPending() }
    }
}

/// La clé d'hôte AnkiWeb, dans le trousseau.
enum AnkiKeychain {
    private static let service = "com.hczr.studytrack.ankiweb"

    static var hostKey: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let newValue else { return }
            var insert = base
            insert[kSecValueData as String] = Data(newValue.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
