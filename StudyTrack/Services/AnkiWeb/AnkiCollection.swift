import Foundation
import SQLite3

/// La copie locale de la collection AnkiWeb : le fichier SQLite téléchargé
/// (schéma 11 — paquets, types de notes et réglages en JSON dans la table `col`).
///
/// Elle sert à **lire** — paquets, types de notes, cartes dues, historique de
/// révision — et à préparer les notes envoyées : identifiants libres, position
/// des nouvelles cartes, comptes exacts pour le contrôle de cohérence du serveur.
final class AnkiCollection {
    private var db: OpaquePointer?
    let url: URL

    static var defaultURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnkiWeb", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("collection.anki2")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: defaultURL.path) }

    init?(url: URL = AnkiCollection.defaultURL, writable: Bool = false) {
        self.url = url
        let flags = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    /// Remplace la copie par une collection fraîchement téléchargée.
    static func install(_ data: Data) throws {
        let target = defaultURL
        let temp = target.deletingLastPathComponent().appendingPathComponent("collection.download")
        try data.write(to: temp, options: .atomic)
        guard AnkiCollection(url: temp) != nil else { throw AnkiWebClient.Failure.decoding("collection") }
        _ = try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: defaultURL)
    }

    // MARK: SQL

    private func rows(_ sql: String, _ bind: [Any] = [], _ read: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        bindAll(statement, bind)
        while sqlite3_step(statement) == SQLITE_ROW { read(statement) }
    }

    private func scalar(_ sql: String, _ bind: [Any] = []) -> Int64 {
        var value: Int64 = 0
        rows(sql, bind) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    @discardableResult
    private func execute(_ sql: String, _ bind: [Any] = []) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bindAll(statement, bind)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func bindAll(_ statement: OpaquePointer, _ values: [Any]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, position, number)
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            default: sqlite3_bind_null(statement, position)
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func colJSON(_ column: String) -> [String: Any] {
        var json: [String: Any] = [:]
        rows("SELECT \(column) FROM col LIMIT 1") { statement in
            let raw = self.text(statement, 0)
            json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
        }
        return json
    }

    // MARK: Métadonnées

    var creation: Date {
        Date(timeIntervalSince1970: TimeInterval(scalar("SELECT crt FROM col")))
    }

    var schema: Int64 { scalar("SELECT scm FROM col") }

    // MARK: Paquets et types de notes

    struct Deck: Identifiable, Hashable {
        let id: Int64
        let name: String
        let isFiltered: Bool
        /// « EPFL::Analyse » → « Analyse ».
        var leaf: String { name.components(separatedBy: "::").last ?? name }
    }

    var decks: [Deck] {
        colJSON("decks").values.compactMap { value in
            guard let deck = value as? [String: Any],
                  let id = (deck["id"] as? NSNumber)?.int64Value,
                  let name = deck["name"] as? String else { return nil }
            return Deck(id: id, name: name, isFiltered: (deck["dyn"] as? NSNumber)?.intValue == 1)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct Notetype: Identifiable, Hashable {
        let id: Int64
        let name: String
        let isCloze: Bool
        let fields: [String]
        let templateCount: Int
    }

    var notetypes: [Notetype] {
        colJSON("models").values.compactMap { value in
            guard let model = value as? [String: Any],
                  let id = (model["id"] as? NSNumber)?.int64Value,
                  let name = model["name"] as? String else { return nil }
            let fields = ((model["flds"] as? [[String: Any]]) ?? [])
                .sorted { (($0["ord"] as? NSNumber)?.intValue ?? 0) < (($1["ord"] as? NSNumber)?.intValue ?? 0) }
                .compactMap { $0["name"] as? String }
            return Notetype(id: id, name: name,
                            isCloze: (model["type"] as? NSNumber)?.intValue == 1,
                            fields: fields,
                            templateCount: (model["tmpls"] as? [Any])?.count ?? 1)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Cohérence

    /// `[[0,0,0], cartes, notes, révisions, tombes, types, paquets, options]` —
    /// ce que le serveur compare avant d'accepter un envoi.
    func sanityCounts(addingNotes notes: Int = 0, cards: Int = 0) -> [Any] {
        [[0, 0, 0],
         Int(scalar("SELECT count() FROM cards")) + cards,
         Int(scalar("SELECT count() FROM notes")) + notes,
         Int(scalar("SELECT count() FROM revlog")),
         Int(scalar("SELECT count() FROM graves")),
         colJSON("models").count,
         colJSON("decks").count,
         colJSON("dconf").count]
    }

    var nextNewPosition: Int { Int(scalar("SELECT coalesce(max(due), 0) FROM cards WHERE type = 0")) + 1 }
    var maxNoteID: Int64 { scalar("SELECT coalesce(max(id), 0) FROM notes") }
    var maxCardID: Int64 { scalar("SELECT coalesce(max(id), 0) FROM cards") }

    /// Les notes et cartes envoyées, recopiées ici : la copie reste identique au
    /// serveur, et le prochain envoi n'a pas besoin de tout retélécharger.
    func record(notes: [[Any]], cards: [[Any]]) -> Bool {
        execute("BEGIN")
        for note in notes {
            // [id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data]
            let fields = note[6] as? String ?? ""
            let sort = fields.components(separatedBy: "\u{1f}").first ?? ""
            guard execute("INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                          [note[0], note[1], note[2], note[3], note[4], note[5], fields, sort, 0, 0, ""]) else {
                execute("ROLLBACK")
                return false
            }
        }
        for card in cards {
            guard execute("INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                          Array(card.prefix(18))) else {
                execute("ROLLBACK")
                return false
            }
        }
        return execute("COMMIT")
    }

    // MARK: Statistiques

    /// Le jour d'Anki : les jours écoulés depuis la création, bascule à 4 h.
    private var today: Int {
        let rollover: TimeInterval = 4 * 3600
        return Int((Date().timeIntervalSince1970 - creation.timeIntervalSince1970 - rollover) / 86_400)
    }

    struct DeckStats: Hashable {
        var due = 0
        var new = 0
        var learning = 0
        var total = 0
        var reviewedToday = 0
        var retention: Double?
    }

    /// Les cartes d'un paquet et de ses sous-paquets.
    func stats(deck: Deck) -> DeckStats {
        let ids = decks.filter { $0.id == deck.id || $0.name.hasPrefix(deck.name + "::") }.map(\.id)
        guard !ids.isEmpty else { return DeckStats() }
        let list = ids.map(String.init).joined(separator: ",")
        var stats = DeckStats()
        let now = Int64(Date().timeIntervalSince1970)
        stats.due = Int(scalar("SELECT count() FROM cards WHERE did IN (\(list)) AND ((queue = 2 AND due <= ?) OR (queue = 3 AND due <= ?))",
                               [today, today]))
        stats.learning = Int(scalar("SELECT count() FROM cards WHERE did IN (\(list)) AND queue = 1 AND due <= ?", [now + 1200]))
        stats.new = Int(scalar("SELECT count() FROM cards WHERE did IN (\(list)) AND queue = 0"))
        stats.total = Int(scalar("SELECT count() FROM cards WHERE did IN (\(list))"))
        let dayStart = (Int64(creation.timeIntervalSince1970) + Int64(today) * 86_400 + 4 * 3600) * 1000
        stats.reviewedToday = Int(scalar("SELECT count() FROM revlog r JOIN cards c ON c.id = r.cid WHERE c.did IN (\(list)) AND r.id >= ?", [dayStart]))
        let since = (now - 30 * 86_400) * 1000
        let reviewed = scalar("SELECT count() FROM revlog r JOIN cards c ON c.id = r.cid WHERE c.did IN (\(list)) AND r.type = 1 AND r.id >= ?", [since])
        let passed = scalar("SELECT count() FROM revlog r JOIN cards c ON c.id = r.cid WHERE c.did IN (\(list)) AND r.type = 1 AND r.ease > 1 AND r.id >= ?", [since])
        stats.retention = reviewed >= 10 ? Double(passed) / Double(reviewed) : nil
        return stats
    }

    /// L'historique de révision depuis `after` (ms), avec le paquet de chaque carte.
    func reviews(after: Int64) -> [AnkiReview] {
        let names = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0.name) })
        var result: [AnkiReview] = []
        rows("SELECT r.id, r.time, c.did FROM revlog r JOIN cards c ON c.id = r.cid WHERE r.id > ? ORDER BY r.id", [after]) { statement in
            let deck = names[sqlite3_column_int64(statement, 2)] ?? "Anki"
            result.append(AnkiReview(id: sqlite3_column_int64(statement, 0),
                                     durationMs: Int(sqlite3_column_int64(statement, 1)),
                                     deck: deck))
        }
        return result
    }
}
