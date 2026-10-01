import Foundation
import SQLite3
import CryptoKit

/// Réviser, créer et modifier dans la copie de la collection — et ce que la
/// synchronisation en a besoin.
///
/// Toute modification faite ici porte `usn = -1` : c'est la convention d'Anki
/// pour « pas encore envoyé ». La synchronisation (`AnkiWebSync`) envoie ces
/// lignes, puis leur donne le numéro du serveur. Rien n'est jamais perdu entre
/// deux synchronisations : une révision faite hors ligne part à la suivante.
extension AnkiCollection {

    // MARK: Collection

    var usn: Int { Int(scalar("SELECT usn FROM col")) }
    var modified: Int64 { scalar("SELECT mod FROM col") }
    var configuration: [String: Any] { colJSON("conf") }

    /// FSRS activé dans la collection (réglage global d'Anki).
    var usesFSRS: Bool { (configuration["fsrs"] as? Bool) ?? ((configuration["fsrs"] as? NSNumber)?.boolValue ?? false) }

    func clock(now: Date = Date()) -> AnkiClock {
        let rollover = (configuration["rollover"] as? NSNumber)?.intValue ?? 4
        return AnkiClock(now: now, creation: creation, rolloverHour: rollover)
    }

    /// Les options du paquet (son préréglage `dconf`).
    func options(forDeck deckID: Int64) -> AnkiDeckOptions {
        let decks = colJSON("decks")
        let deck = decks[String(deckID)] as? [String: Any]
        let confID = (deck?["conf"] as? NSNumber).map { String($0.int64Value) } ?? "1"
        let dconf = colJSON("dconf")
        return AnkiDeckOptions(json: (dconf[confID] as? [String: Any]) ?? (dconf["1"] as? [String: Any]) ?? [:])
    }

    /// Le paquet et tous ses sous-paquets.
    func deckTree(_ deck: Deck) -> [Int64] {
        decks.filter { $0.id == deck.id || $0.name.hasPrefix(deck.name + "::") }.map(\.id)
    }

    func model(_ id: Int64) -> [String: Any] {
        (colJSON("models")[String(id)] as? [String: Any]) ?? [:]
    }

    // MARK: Cartes et notes

    struct StudyCard: Identifiable, Equatable {
        let id: Int64
        let noteID: Int64
        let deckID: Int64
        let ordinal: Int
        var state: AnkiCardState
    }

    struct StudyNote: Identifiable, Equatable {
        let id: Int64
        let notetypeID: Int64
        var fields: [String]
        var tags: [String]
        var modified: Int64
    }

    func card(_ id: Int64) -> StudyCard? {
        var card: StudyCard?
        rows("SELECT id, nid, did, ord, type, queue, due, ivl, factor, reps, lapses, left, data FROM cards WHERE id = ?", [id]) { s in
            card = StudyCard(id: sqlite3_column_int64(s, 0), noteID: sqlite3_column_int64(s, 1),
                             deckID: sqlite3_column_int64(s, 2), ordinal: Int(sqlite3_column_int64(s, 3)),
                             state: AnkiCardState(type: Int(sqlite3_column_int64(s, 4)), queue: Int(sqlite3_column_int64(s, 5)),
                                                  due: sqlite3_column_int64(s, 6), ivl: Int(sqlite3_column_int64(s, 7)),
                                                  factor: Int(sqlite3_column_int64(s, 8)), reps: Int(sqlite3_column_int64(s, 9)),
                                                  lapses: Int(sqlite3_column_int64(s, 10)), left: Int(sqlite3_column_int64(s, 11)),
                                                  data: self.text(s, 12)))
        }
        return card
    }

    func note(_ id: Int64) -> StudyNote? {
        var note: StudyNote?
        rows("SELECT id, mid, flds, tags, mod FROM notes WHERE id = ?", [id]) { s in
            note = StudyNote(id: sqlite3_column_int64(s, 0), notetypeID: sqlite3_column_int64(s, 1),
                             fields: self.text(s, 2).components(separatedBy: "\u{1f}"),
                             tags: self.text(s, 3).split(separator: " ").map(String.init),
                             modified: sqlite3_column_int64(s, 4))
        }
        return note
    }

    /// Les notes d'un paquet, les plus récentes d'abord ; filtrées par texte.
    func notes(inDecks deckIDs: [Int64], matching search: String = "", limit: Int = 300) -> [StudyNote] {
        guard !deckIDs.isEmpty else { return [] }
        let list = deckIDs.map(String.init).joined(separator: ",")
        var result: [StudyNote] = []
        let query = search.trimmingCharacters(in: .whitespaces)
        let filter = query.isEmpty ? "" : "AND n.flds LIKE ?"
        let bind: [Any] = query.isEmpty ? [] : ["%\(query)%"]
        rows("SELECT DISTINCT n.id, n.mid, n.flds, n.tags, n.mod FROM notes n JOIN cards c ON c.nid = n.id WHERE c.did IN (\(list)) \(filter) ORDER BY n.id DESC LIMIT \(limit)", bind) { s in
            result.append(StudyNote(id: sqlite3_column_int64(s, 0), notetypeID: sqlite3_column_int64(s, 1),
                                    fields: self.text(s, 2).components(separatedBy: "\u{1f}"),
                                    tags: self.text(s, 3).split(separator: " ").map(String.init),
                                    modified: sqlite3_column_int64(s, 4)))
        }
        return result
    }

    // MARK: File de révision

    struct DueCounts: Equatable {
        var learning = 0
        var review = 0
        var new = 0
        var total: Int { learning + review + new }
    }

    /// Ce qui reste à faire aujourd'hui, limites quotidiennes du paquet comprises.
    func dueCounts(deck: Deck, clock: AnkiClock) -> DueCounts {
        let queue = studyQueue(deck: deck, clock: clock)
        return DueCounts(learning: queue.learning.count, review: queue.review.count, new: queue.new.count)
    }

    struct StudyQueue {
        var learning: [Int64] = []
        var review: [Int64] = []
        var new: [Int64] = []
        /// L'apprentissage d'abord (il a une heure), puis les révisions, puis les nouvelles.
        var next: Int64? { learning.first ?? review.first ?? new.first }
    }

    /// La file d'Anki pour un paquet : apprentissage dû (20 min d'avance
    /// permises, comme Anki), révisions dues jusqu'à la limite du jour, puis
    /// nouvelles cartes jusqu'à la leur — moins ce qui a déjà été fait aujourd'hui.
    func studyQueue(deck: Deck, clock: AnkiClock) -> StudyQueue {
        let ids = deckTree(deck)
        guard !ids.isEmpty else { return StudyQueue() }
        let list = ids.map(String.init).joined(separator: ",")
        let options = self.options(forDeck: deck.id)
        let today = clock.today
        let dayStart = clock.todayStartMillis
        var queue = StudyQueue()
        rows("SELECT id FROM cards WHERE did IN (\(list)) AND ((queue = 1 AND due <= ?) OR (queue = 3 AND due <= ?)) ORDER BY due",
             [clock.seconds + 1200, today]) { queue.learning.append(sqlite3_column_int64($0, 0)) }
        let reviewedToday = Int(scalar("SELECT count() FROM revlog r JOIN cards c ON c.id = r.cid WHERE c.did IN (\(list)) AND r.id >= ? AND r.type = 1", [dayStart]))
        let reviewLimit = max(0, options.reviewsPerDay - reviewedToday)
        rows("SELECT id FROM cards WHERE did IN (\(list)) AND queue = 2 AND due <= ? ORDER BY due, id LIMIT \(reviewLimit)", [today]) {
            queue.review.append(sqlite3_column_int64($0, 0))
        }
        // Nouvelles introduites aujourd'hui : leur première ligne d'historique date d'aujourd'hui.
        let introduced = Int(scalar("SELECT count() FROM (SELECT r.cid FROM revlog r JOIN cards c ON c.id = r.cid WHERE c.did IN (\(list)) GROUP BY r.cid HAVING min(r.id) >= ? AND min(r.type) = 0)", [dayStart]))
        let newLimit = max(0, options.newPerDay - introduced)
        rows("SELECT id FROM cards WHERE did IN (\(list)) AND queue = 0 ORDER BY due, ord LIMIT \(newLimit)") {
            queue.new.append(sqlite3_column_int64($0, 0))
        }
        return queue
    }

    /// La prochaine carte en apprentissage plus tard aujourd'hui, s'il y en a une.
    func nextLearningDue(deck: Deck) -> Date? {
        let list = deckTree(deck).map(String.init).joined(separator: ",")
        guard !list.isEmpty,
              let due = scalarOptional("SELECT min(due) FROM cards WHERE did IN (\(list)) AND queue = 1"), due > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(due))
    }

    // MARK: Rendu

    struct RenderedCard {
        var question: String
        var answer: String
        var css: String
    }

    func render(_ card: StudyCard) -> RenderedCard? {
        guard let note = note(card.noteID) else { return nil }
        let model = self.model(note.notetypeID)
        let names = ((model["flds"] as? [[String: Any]]) ?? [])
            .sorted { (($0["ord"] as? NSNumber)?.intValue ?? 0) < (($1["ord"] as? NSNumber)?.intValue ?? 0) }
            .compactMap { $0["name"] as? String }
        var fields: [String: String] = [:]
        for (index, name) in names.enumerated() where index < note.fields.count { fields[name] = note.fields[index] }
        let isCloze = (model["type"] as? NSNumber)?.intValue == 1
        let templates = (model["tmpls"] as? [[String: Any]]) ?? []
        let template = isCloze ? templates.first : templates.first { ($0["ord"] as? NSNumber)?.intValue == card.ordinal } ?? templates.first
        let deckName = decks.first { $0.id == card.deckID }?.name ?? ""
        let context = AnkiTemplate.Context(fields: fields, ordinal: card.ordinal, isCloze: isCloze,
                                           tags: note.tags.joined(separator: " "), deck: deckName,
                                           cardName: template?["name"] as? String ?? "")
        let front = AnkiTemplate.question(template?["qfmt"] as? String ?? "{{Front}}", context)
        let back = AnkiTemplate.answer(template?["afmt"] as? String ?? "{{FrontSide}}<hr id=answer>{{Back}}", front: front, context)
        return RenderedCard(question: front, answer: back, css: model["css"] as? String ?? "")
    }

    func fieldNames(ofNotetype id: Int64) -> [String] {
        ((model(id)["flds"] as? [[String: Any]]) ?? [])
            .sorted { (($0["ord"] as? NSNumber)?.intValue ?? 0) < (($1["ord"] as? NSNumber)?.intValue ?? 0) }
            .compactMap { $0["name"] as? String }
    }

    // MARK: Écritures (copie ouverte en écriture)

    private var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func touchCollection() {
        execute("UPDATE col SET mod = ?", [nowMillis])
    }

    /// Enregistre une réponse : la carte replanifiée et sa ligne d'historique.
    @discardableResult
    func record(_ answer: AnkiAnswer, for card: StudyCard, millisecondsTaken: Int) -> Bool {
        let s = answer.card
        execute("BEGIN")
        guard execute("UPDATE cards SET type = ?, queue = ?, due = ?, ivl = ?, factor = ?, reps = ?, lapses = ?, left = ?, data = ?, mod = ?, usn = -1 WHERE id = ?",
                      [s.type, s.queue, s.due, s.ivl, s.factor, s.reps, s.lapses, s.left, s.data, Int64(Date().timeIntervalSince1970), card.id]) else {
            execute("ROLLBACK"); return false
        }
        var id = nowMillis
        while scalar("SELECT count() FROM revlog WHERE id = ?", [id]) > 0 { id += 1 }
        guard execute("INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) VALUES (?,?,-1,?,?,?,?,?,?)",
                      [id, card.id, answer.ease, answer.interval, answer.lastInterval, answer.factor,
                       min(max(millisecondsTaken, 0), 60_000), answer.reviewType]) else {
            execute("ROLLBACK"); return false
        }
        touchCollection()
        return execute("COMMIT")
    }

    /// Le champ de tri et la somme de contrôle d'Anki pour une note.
    private func sortFieldAndChecksum(fields: [String], notetype: [String: Any]) -> (String, Int64) {
        let sortIndex = (notetype["sortf"] as? NSNumber)?.intValue ?? 0
        let sort = AnkiTemplate.stripHTML(fields.indices.contains(sortIndex) ? fields[sortIndex] : (fields.first ?? ""))
        let first = AnkiTemplate.stripHTML(fields.first ?? "")
        let digest = Insecure.SHA1.hash(data: Data(first.utf8)).map { String(format: "%02x", $0) }.joined()
        return (sort, AnkiTemplate.checksum(sha1Hex: digest))
    }

    private static func tagString(_ tags: [String]) -> String {
        let cleaned = tags.map { $0.replacingOccurrences(of: " ", with: "_") }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? "" : " " + cleaned.joined(separator: " ") + " "
    }

    /// Les étiquettes nouvelles, connues de la collection (à envoyer).
    private func register(tags: [String]) {
        var known = colJSON("tags")
        var changed = false
        for tag in tags where known[tag] == nil {
            known[tag] = -1
            changed = true
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: known) else { return }
        execute("UPDATE col SET tags = ?", [String(decoding: data, as: UTF8.self)])
    }

    /// Modifie les champs (et étiquettes) d'une note.
    @discardableResult
    func update(note id: Int64, fields: [String], tags: [String]) -> Bool {
        guard let existing = note(id) else { return false }
        let notetype = model(existing.notetypeID)
        var values = Array(fields.prefix(fieldNames(ofNotetype: existing.notetypeID).count))
        while values.count < fieldNames(ofNotetype: existing.notetypeID).count { values.append("") }
        let (sort, checksum) = sortFieldAndChecksum(fields: values, notetype: notetype)
        register(tags: tags)
        let ok = execute("UPDATE notes SET flds = ?, sfld = ?, csum = ?, tags = ?, mod = ?, usn = -1 WHERE id = ?",
                         [values.joined(separator: "\u{1f}"), sort, checksum, Self.tagString(tags), Int64(Date().timeIntervalSince1970), id])
        // Une note à trous gagne une carte pour chaque nouveau trou.
        if ok, (notetype["type"] as? NSNumber)?.intValue == 1,
           let deck = scalarOptional("SELECT did FROM cards WHERE nid = ? LIMIT 1", [id]) {
            let existingOrds = Set(intColumn("SELECT ord FROM cards WHERE nid = ?", [id]))
            let wanted = AnkiNoteTools.clozeNumbers(in: values.joined(separator: " ")).map { $0 - 1 }
            insertCards(noteID: id, deckID: deck, ordinals: wanted.filter { !existingOrds.contains($0) })
        }
        touchCollection()
        return ok
    }

    /// Ajoute une note et ses cartes ; rend l'identifiant de la note.
    @discardableResult
    func addNote(deckID: Int64, notetypeID: Int64, fields: [String], tags: [String]) throws -> Int64 {
        let notetype = model(notetypeID)
        let names = fieldNames(ofNotetype: notetypeID)
        guard !names.isEmpty, decks.contains(where: { $0.id == deckID }) else {
            throw AnkiWebClient.Failure.unsupported("Le paquet ou le type de note n'existe plus dans Anki.")
        }
        var values = Array(fields.prefix(names.count))
        while values.count < names.count { values.append("") }
        let isCloze = (notetype["type"] as? NSNumber)?.intValue == 1
        let ordinals: [Int]
        if isCloze {
            ordinals = AnkiNoteTools.clozeNumbers(in: values.joined(separator: " ")).map { $0 - 1 }
            guard !ordinals.isEmpty else {
                throw AnkiWebClient.Failure.unsupported("Une note à trous doit contenir {{c1::…}}.")
            }
        } else {
            // Une carte par modèle dont le recto n'est pas vide (« Basique et
            // inversée » en donne deux).
            var fieldMap: [String: String] = [:]
            for (index, name) in names.enumerated() { fieldMap[name] = values[index] }
            let templates = (notetype["tmpls"] as? [[String: Any]]) ?? []
            let filled = templates.compactMap { template -> Int? in
                let ord = (template["ord"] as? NSNumber)?.intValue ?? 0
                let front = AnkiTemplate.question(template["qfmt"] as? String ?? "",
                                                  .init(fields: fieldMap, ordinal: ord, isCloze: false))
                return AnkiTemplate.stripHTML(front).isEmpty && !front.contains("<img") ? nil : ord
            }
            ordinals = filled.isEmpty ? [0] : filled
        }
        let (sort, checksum) = sortFieldAndChecksum(fields: values, notetype: notetype)
        var noteID = max(maxNoteID + 1, nowMillis)
        while scalar("SELECT count() FROM notes WHERE id = ?", [noteID]) > 0 { noteID += 1 }
        execute("BEGIN")
        guard execute("INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) VALUES (?,?,?,?,-1,?,?,?,?,0,'')",
                      [noteID, AnkiNoteTools.guid(), notetypeID, Int64(Date().timeIntervalSince1970), Self.tagString(tags),
                       values.joined(separator: "\u{1f}"), sort, checksum]) else {
            execute("ROLLBACK")
            throw AnkiWebClient.Failure.decoding("note")
        }
        insertCards(noteID: noteID, deckID: deckID, ordinals: ordinals)
        register(tags: tags)
        touchCollection()
        execute("COMMIT")
        return noteID
    }

    private func insertCards(noteID: Int64, deckID: Int64, ordinals: [Int]) {
        var cardID = max(maxCardID + 1, nowMillis)
        let position = nextNewPosition
        for ord in ordinals {
            while scalar("SELECT count() FROM cards WHERE id = ?", [cardID]) > 0 { cardID += 1 }
            execute("INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data) VALUES (?,?,?,?,?,-1,0,0,?,0,0,0,0,0,0,0,0,'')",
                    [cardID, noteID, deckID, ord, Int64(Date().timeIntervalSince1970), position])
            cardID += 1
        }
    }

    /// Supprime une note et ses cartes ; les « tombes » le diront au serveur.
    func delete(note id: Int64) {
        execute("BEGIN")
        let cards = intColumn64("SELECT id FROM cards WHERE nid = ?", [id])
        for card in cards { execute("INSERT INTO graves (usn, oid, type) VALUES (-1, ?, 0)", [card]) }
        execute("INSERT INTO graves (usn, oid, type) VALUES (-1, ?, 1)", [id])
        execute("DELETE FROM cards WHERE nid = ?", [id])
        execute("DELETE FROM notes WHERE id = ?", [id])
        touchCollection()
        execute("COMMIT")
    }

    // MARK: Ce qui attend d'être envoyé

    var pendingChanges: Int {
        Int(scalar("SELECT (SELECT count() FROM cards WHERE usn = -1) + (SELECT count() FROM notes WHERE usn = -1) + (SELECT count() FROM revlog WHERE usn = -1) + (SELECT count() FROM graves WHERE usn = -1)"))
    }

    /// Les lignes non envoyées d'une table, au format du protocole, avec le
    /// numéro du serveur à la place de −1 (comme le client d'Anki).
    func pendingRows(_ table: String, usn serverUsn: Int) -> [[Any]] {
        let columns: String
        switch table {
        case "revlog": columns = "id, cid, ?, ease, ivl, lastIvl, factor, time, type"
        case "cards": columns = "id, nid, did, ord, mod, ?, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data"
        default: columns = "id, guid, mid, mod, ?, tags, flds, sfld, csum, flags, data"
        }
        var result: [[Any]] = []
        rows("SELECT \(columns) FROM \(table) WHERE usn = -1", [serverUsn]) { statement in
            var row: [Any] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(statement, index))
                case SQLITE_NULL: row.append(NSNull())
                default: row.append(self.text(statement, index))
                }
            }
            result.append(row)
        }
        return result
    }

    func pendingGraves() -> (cards: [Int64], notes: [Int64], decks: [Int64]) {
        (intColumn64("SELECT oid FROM graves WHERE usn = -1 AND type = 0", []),
         intColumn64("SELECT oid FROM graves WHERE usn = -1 AND type = 1", []),
         intColumn64("SELECT oid FROM graves WHERE usn = -1 AND type = 2", []))
    }

    func pendingTags() -> [String] {
        colJSON("tags").compactMap { key, value in (value as? NSNumber)?.intValue == -1 ? key : nil }
    }

    // MARK: Ce que le serveur envoie

    /// Suppressions faites ailleurs.
    func applyServerGraves(_ graves: [String: Any]) {
        let cards = (graves["cards"] as? [NSNumber])?.map(\.int64Value) ?? []
        let notes = (graves["notes"] as? [NSNumber])?.map(\.int64Value) ?? []
        let decks = (graves["decks"] as? [NSNumber])?.map(\.int64Value) ?? []
        for id in cards { execute("DELETE FROM cards WHERE id = ?", [id]) }
        for id in notes {
            execute("DELETE FROM cards WHERE nid = ?", [id])
            execute("DELETE FROM notes WHERE id = ?", [id])
        }
        if !decks.isEmpty {
            var json = colJSON("decks")
            for id in decks { json[String(id)] = nil }
            writeCol("decks", json)
        }
    }

    /// Types de notes, paquets, options et étiquettes modifiés ailleurs : le
    /// plus récent l'emporte, comme dans Anki.
    func applyServerChanges(_ changes: [String: Any]) {
        merge("models", (changes["models"] as? [[String: Any]]) ?? [])
        let decks = changes["decks"] as? [Any] ?? []
        merge("decks", (decks.first as? [[String: Any]]) ?? [])
        merge("dconf", (decks.count > 1 ? decks[1] as? [[String: Any]] : nil) ?? [])
        if let tags = changes["tags"] as? [String], !tags.isEmpty {
            var known = colJSON("tags")
            for tag in tags where known[tag] == nil { known[tag] = usn }
            writeCol("tags", known)
        }
        if let conf = changes["conf"] as? [String: Any] { writeCol("conf", conf) }
        if let crt = (changes["crt"] as? NSNumber)?.int64Value { execute("UPDATE col SET crt = ?", [crt]) }
    }

    private func merge(_ column: String, _ items: [[String: Any]]) {
        guard !items.isEmpty else { return }
        var json = colJSON(column)
        for item in items {
            guard let id = (item["id"] as? NSNumber).map({ String($0.int64Value) }) else { continue }
            let localMod = ((json[id] as? [String: Any])?["mod"] as? NSNumber)?.int64Value ?? -1
            let serverMod = (item["mod"] as? NSNumber)?.int64Value ?? 0
            if serverMod >= localMod { json[id] = item }
        }
        writeCol(column, json)
    }

    private func writeCol(_ column: String, _ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        execute("UPDATE col SET \(column) = ?", [String(decoding: data, as: UTF8.self)])
    }

    /// Lignes modifiées ailleurs : historique ajouté, cartes et notes
    /// remplacées quand celles du serveur sont plus récentes.
    func applyServerChunk(_ chunk: [String: Any]) {
        for row in (chunk["revlog"] as? [[Any]]) ?? [] where row.count >= 9 {
            execute("INSERT OR IGNORE INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) VALUES (?,?,?,?,?,?,?,?,?)",
                    row.prefix(9).map(Self.sqlValue))
        }
        for row in (chunk["cards"] as? [[Any]]) ?? [] where row.count >= 18 {
            let id = Self.int64(row[0]), mod = Self.int64(row[4])
            let local = scalarOptional("SELECT mod FROM cards WHERE id = ?", [id])
            guard local == nil || mod >= local! else { continue }
            execute("INSERT OR REPLACE INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    row.prefix(18).map(Self.sqlValue))
        }
        for row in (chunk["notes"] as? [[Any]]) ?? [] where row.count >= 11 {
            let id = Self.int64(row[0]), mod = Self.int64(row[3])
            let local = scalarOptional("SELECT mod FROM notes WHERE id = ?", [id])
            guard local == nil || mod >= local! else { continue }
            execute("INSERT OR REPLACE INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    row.prefix(11).map(Self.sqlValue))
        }
    }

    /// Fin de synchronisation : nos lignes portent désormais le numéro du
    /// serveur, et la collection son nouvel état.
    ///
    /// `startedAt` (secondes) : seules les lignes modifiées **avant** le début
    /// de la synchronisation ont été envoyées. Une révision faite pendant
    /// qu'elle tournait reste en attente, au lieu d'être marquée envoyée à tort.
    func markSynced(serverUsn: Int, modified: Int64, startedAt: Int64 = .max, graves sentGraves: [Int64]? = nil) {
        execute("BEGIN")
        execute("UPDATE cards SET usn = ? WHERE usn = -1 AND mod < ?", [serverUsn, startedAt])
        execute("UPDATE notes SET usn = ? WHERE usn = -1 AND mod < ?", [serverUsn, startedAt])
        execute("UPDATE revlog SET usn = ? WHERE usn = -1 AND id < ?", [serverUsn, startedAt == .max ? Int64.max : startedAt * 1000])
        if let sentGraves {
            for oid in sentGraves { execute("UPDATE graves SET usn = ? WHERE usn = -1 AND oid = ?", [serverUsn, oid]) }
        } else {
            execute("UPDATE graves SET usn = ? WHERE usn = -1", [serverUsn])
        }
        var tags = colJSON("tags")
        var touched = false
        for (key, value) in tags where (value as? NSNumber)?.intValue == -1 { tags[key] = serverUsn; touched = true }
        if touched { writeCol("tags", tags) }
        execute("UPDATE col SET usn = ?, mod = ?, ls = ?", [serverUsn + 1, modified, modified])
        execute("COMMIT")
    }

    /// Après un téléchargement complet : le numéro de synchronisation du serveur.
    func adopt(serverUsn: Int, modified: Int64) {
        execute("UPDATE col SET usn = ?, mod = ?, ls = ?", [serverUsn, modified, modified])
    }

    // MARK: Utilitaires SQL

    func scalarOptional(_ sql: String, _ bind: [Any] = []) -> Int64? {
        var value: Int64?
        rows(sql, bind) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func intColumn(_ sql: String, _ bind: [Any]) -> [Int] {
        var values: [Int] = []
        rows(sql, bind) { values.append(Int(sqlite3_column_int64($0, 0))) }
        return values
    }

    private func intColumn64(_ sql: String, _ bind: [Any]) -> [Int64] {
        var values: [Int64] = []
        rows(sql, bind) { values.append(sqlite3_column_int64($0, 0)) }
        return values
    }

    private static func int64(_ value: Any) -> Int64 {
        (value as? NSNumber)?.int64Value ?? Int64(value as? String ?? "") ?? 0
    }

    /// JSON → valeur liable par `bindAll` (les nombres JSON arrivent en NSNumber).
    private static func sqlValue(_ value: Any) -> Any {
        if let number = value as? NSNumber {
            if CFNumberIsFloatType(number) { return number.doubleValue }
            return number.int64Value
        }
        if value is NSNull { return NSNull() }
        return value as? String ?? "\(value)"
    }
}
