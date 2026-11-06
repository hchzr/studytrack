import Foundation
import SwiftData
import CryptoKit

// Synchronisation Supabase : le modèle de données du protocole.
//
// Le protocole est celui du client Windows (windows/src/sync/*.ts) : une table
// `sync_*` par `@Model`, `updated_at` posé par l'appareil (la plus récente écriture
// gagne), `deleted_at` en pierre tombale, `server_updated_at` en curseur. Les noms
// de colonnes viennent du même `schema.ts` (SyncSchema.generated.swift).
//
// SwiftData n'a ni `updated_at` ni pierres tombales : l'état de synchronisation
// (`SyncState`) vit donc à côté de la base, dans un fichier propre à l'appareil.

// MARK: - Valeurs

/// Une valeur de colonne, telle qu'elle voyage. Les dates sont déjà en texte
/// canonique (ISO 8601, UTC, à la milliseconde) : c'est ce que Windows écrit.
enum SyncValue: Equatable {
    case null
    case text(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(String)

    /// Forme stable servant au calcul d'empreinte.
    var canonical: String {
        switch self {
        case .null: return "~"
        case .text(let s): return "t\(s.utf8.count):\(s)"
        case .int(let i): return "i\(i)"
        case .double(let d): return "d\(d.bitPattern)"
        case .bool(let b): return b ? "b1" : "b0"
        case .date(let s): return "D\(s)"
        }
    }
}

typealias SyncPayload = [String: SyncValue]

enum SyncKind { case text, int, double, bool, date }

// MARK: - Temps

/// Horodatages du protocole, sans `DateFormatter` : exacts à la microseconde,
/// indépendants du fuseau, et utilisables depuis n'importe quel fil.
enum SyncTime {
    /// Jours depuis 1970-01-01 pour une date civile (algorithme de H. Hinnant).
    private static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func civil(days z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Microsecondes depuis l'époque d'un horodatage ISO 8601 / Postgres
    /// (« 2026-10-30T10:00:00.123456+00:00 », « …Z », sans fraction, « 2026-10-30 10:00:00+00 »).
    static func micros(_ raw: String) -> Int64? {
        let s = Array(raw.utf8)
        var i = 0
        func number(_ count: Int) -> Int? {
            guard i + count <= s.count else { return nil }
            var v = 0
            for k in 0..<count {
                let c = s[i + k]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            i += count
            return v
        }
        func expect(_ chars: [UInt8]) -> Bool {
            guard i < s.count, chars.contains(s[i]) else { return false }
            i += 1
            return true
        }
        guard let year = number(4), expect([45]), let month = number(2), expect([45]), let day = number(2),
              expect([84, 32]), let hour = number(2), expect([58]), let minute = number(2), expect([58]),
              let second = number(2) else { return nil }
        var frac: Int64 = 0
        if i < s.count, s[i] == 46 {
            i += 1
            var digits = 0
            while i < s.count, s[i] >= 48, s[i] <= 57 {
                if digits < 6 { frac = frac * 10 + Int64(s[i] - 48); digits += 1 }
                i += 1
            }
            while digits < 6 { frac *= 10; digits += 1 }
        }
        var offset = 0
        if i < s.count {
            if s[i] == 90 || s[i] == 122 {
                i += 1
            } else if s[i] == 43 || s[i] == 45 {
                let sign = s[i] == 43 ? 1 : -1
                i += 1
                guard let oh = number(2) else { return nil }
                var om = 0
                if i < s.count {
                    if s[i] == 58 { i += 1 }
                    om = number(2) ?? 0
                }
                offset = sign * (oh * 3600 + om * 60)
            }
        }
        let secs = Int64(days(year: year, month: month, day: day)) * 86400
            + Int64(hour * 3600 + minute * 60 + second) - Int64(offset)
        return secs * 1_000_000 + frac
    }

    /// « 2026-10-30T10:00:00.123Z » (ou à la microseconde si `digits` vaut 6).
    static func iso(micros: Int64, digits: Int = 3) -> String {
        let secs = Int(floorDiv(micros, 1_000_000))
        let frac = Int(micros - Int64(secs) * 1_000_000)
        let (days, rest) = (floorDiv(secs, 86400), secs - floorDiv(secs, 86400) * 86400)
        let (y, m, d) = civil(days: days)
        var out = pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2) + "T"
        out += pad(rest / 3600, 2) + ":" + pad((rest % 3600) / 60, 2) + ":" + pad(rest % 60, 2)
        let f = pad(frac, 6)
        out += "." + String(f.prefix(digits)) + "Z"
        return out
    }

    private static func floorDiv<T: BinaryInteger>(_ a: T, _ b: T) -> T {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// Un `Date` → texte canonique à la milliseconde (arrondi : stable après un aller-retour).
    static func string(_ date: Date) -> String {
        iso(micros: Int64((date.timeIntervalSince1970 * 1000).rounded()) * 1000)
    }

    static func date(_ raw: String) -> Date? {
        micros(raw).map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
    }

    /// Texte canonique à la milliseconde d'un horodatage serveur (les microsecondes sont tronquées,
    /// comme `new Date(…).toISOString()` côté Windows).
    static func canonical(_ raw: String) -> String? {
        micros(raw).map { iso(micros: floorDiv($0, 1000) * 1000) }
    }

    /// Reculer un curseur de `seconds`, à la microseconde, au format que PostgREST accepte dans une URL (sans « + »).
    static func rewound(_ raw: String, seconds: Int) -> String? {
        micros(raw).map { iso(micros: $0 - Int64(seconds) * 1_000_000, digits: 6) }
    }

    /// Le même horodatage, sans « + » (un « + » non encodé se lit comme une espace dans une URL).
    static func urlSafe(_ raw: String) -> String {
        micros(raw).map { iso(micros: $0, digits: 6) } ?? raw
    }
}

// MARK: - Modèles

/// Un `@Model` synchronisé : un identifiant, et de quoi en fabriquer un vide.
protocol SyncModel: PersistentModel {
    var id: UUID { get set }
    static func syncBlank() -> Self
}

enum SyncDeleteRule { case cascade, nullify }

/// Un champ : sa colonne, et comment le lire / l'écrire sur le modèle.
struct SyncField<M: PersistentModel> {
    let column: String
    let kind: SyncKind
    let get: (M) -> SyncValue
    let set: (M, SyncValue) -> Void

    static func text(_ c: String, _ kp: ReferenceWritableKeyPath<M, String>) -> SyncField {
        SyncField(column: c, kind: .text, get: { .text($0[keyPath: kp]) }, set: { m, v in if case .text(let s) = v { m[keyPath: kp] = s } })
    }
    static func textOptional(_ c: String, _ kp: ReferenceWritableKeyPath<M, String?>) -> SyncField {
        SyncField(column: c, kind: .text, get: { $0[keyPath: kp].map { .text($0) } ?? .null },
                  set: { m, v in if case .text(let s) = v { m[keyPath: kp] = s } else { m[keyPath: kp] = nil } })
    }
    static func int(_ c: String, _ kp: ReferenceWritableKeyPath<M, Int>) -> SyncField {
        SyncField(column: c, kind: .int, get: { .int($0[keyPath: kp]) }, set: { m, v in if case .int(let i) = v { m[keyPath: kp] = i } })
    }
    static func intOptional(_ c: String, _ kp: ReferenceWritableKeyPath<M, Int?>) -> SyncField {
        SyncField(column: c, kind: .int, get: { $0[keyPath: kp].map { .int($0) } ?? .null },
                  set: { m, v in if case .int(let i) = v { m[keyPath: kp] = i } else { m[keyPath: kp] = nil } })
    }
    static func double(_ c: String, _ kp: ReferenceWritableKeyPath<M, Double>) -> SyncField {
        SyncField(column: c, kind: .double, get: { .double($0[keyPath: kp]) }, set: { m, v in if case .double(let d) = v { m[keyPath: kp] = d } })
    }
    static func doubleOptional(_ c: String, _ kp: ReferenceWritableKeyPath<M, Double?>) -> SyncField {
        SyncField(column: c, kind: .double, get: { $0[keyPath: kp].map { .double($0) } ?? .null },
                  set: { m, v in if case .double(let d) = v { m[keyPath: kp] = d } else { m[keyPath: kp] = nil } })
    }
    static func bool(_ c: String, _ kp: ReferenceWritableKeyPath<M, Bool>) -> SyncField {
        SyncField(column: c, kind: .bool, get: { .bool($0[keyPath: kp]) }, set: { m, v in if case .bool(let b) = v { m[keyPath: kp] = b } })
    }
    static func date(_ c: String, _ kp: ReferenceWritableKeyPath<M, Date>) -> SyncField {
        SyncField(column: c, kind: .date, get: { .date(SyncTime.string($0[keyPath: kp])) },
                  set: { m, v in if case .date(let s) = v, let d = SyncTime.date(s) { m[keyPath: kp] = d } })
    }
    static func dateOptional(_ c: String, _ kp: ReferenceWritableKeyPath<M, Date?>) -> SyncField {
        SyncField(column: c, kind: .date, get: { $0[keyPath: kp].map { .date(SyncTime.string($0)) } ?? .null },
                  set: { m, v in if case .date(let s) = v, let d = SyncTime.date(s) { m[keyPath: kp] = d } else { m[keyPath: kp] = nil } })
    }
}

/// Une relation « un » : colonne `<nom>_id`, table cible, règle de suppression côté parent.
struct SyncRef<M: PersistentModel> {
    let column: String
    let table: String
    let onDelete: SyncDeleteRule
    let get: (M) -> UUID?
    let set: (M, AnyObject?) -> Void

    static func one<T: SyncModel>(_ c: String, _ kp: ReferenceWritableKeyPath<M, T?>, table: String, onDelete: SyncDeleteRule) -> SyncRef {
        SyncRef(column: c, table: table, onDelete: onDelete, get: { $0[keyPath: kp]?.id }, set: { m, o in m[keyPath: kp] = o as? T })
    }
}

struct SyncRefInfo {
    let column: String
    let table: String
    let onDelete: SyncDeleteRule
}

/// Une table synchronisée, sans son type de modèle (pour les parcourir toutes).
protocol AnySyncTable {
    var name: String { get }
    /// Nom de l'entité SwiftData (celui que portent les `PersistentIdentifier` d'un enregistrement).
    var entityName: String { get }
    /// Champs puis relations, dans l'ordre du schéma.
    var columns: [String] { get }
    var refInfos: [SyncRefInfo] { get }
    var fieldKinds: [String: SyncKind] { get }
    func fetchAll(_ context: ModelContext) throws -> [(id: UUID, object: AnyObject)]
    func payload(of object: AnyObject) -> SyncPayload
    func create(id: UUID, in context: ModelContext) -> AnyObject
    func apply(_ payload: SyncPayload, to object: AnyObject)
    func setRef(_ column: String, of object: AnyObject, to target: AnyObject?)
    func delete(_ object: AnyObject, in context: ModelContext)
    /// JSON PostgREST → valeurs (colonnes absentes ignorées).
    func decode(_ json: [String: Any]) -> SyncPayload
    /// Valeurs → corps JSON (sans `id`, `updated_at`, `deleted_at`).
    func encode(_ payload: SyncPayload) -> [String: Any]
}

final class SyncTable<M: SyncModel>: AnySyncTable {
    let name: String
    var entityName: String { String(describing: M.self) }
    let fields: [SyncField<M>]
    let refs: [SyncRef<M>]
    let columns: [String]
    let refInfos: [SyncRefInfo]
    let fieldKinds: [String: SyncKind]

    init(name: String, fields: [SyncField<M>], refs: [SyncRef<M>]) {
        self.name = name
        self.fields = fields
        self.refs = refs
        self.columns = fields.map(\.column) + refs.map(\.column)
        self.refInfos = refs.map { SyncRefInfo(column: $0.column, table: $0.table, onDelete: $0.onDelete) }
        self.fieldKinds = Dictionary(uniqueKeysWithValues: fields.map { ($0.column, $0.kind) })
    }

    func fetchAll(_ context: ModelContext) throws -> [(id: UUID, object: AnyObject)] {
        try context.fetch(FetchDescriptor<M>()).map { ($0.id, $0) }
    }

    func payload(of object: AnyObject) -> SyncPayload {
        guard let m = object as? M else { return [:] }
        var out: SyncPayload = [:]
        for f in fields { out[f.column] = f.get(m) }
        for r in refs { out[r.column] = r.get(m).map { .text($0.uuidString.lowercased()) } ?? .null }
        return out
    }

    func create(id: UUID, in context: ModelContext) -> AnyObject {
        let m = M.syncBlank()
        m.id = id
        context.insert(m)
        return m
    }

    func apply(_ payload: SyncPayload, to object: AnyObject) {
        guard let m = object as? M else { return }
        for f in fields { f.set(m, payload[f.column] ?? .null) }
    }

    func setRef(_ column: String, of object: AnyObject, to target: AnyObject?) {
        guard let m = object as? M, let r = refs.first(where: { $0.column == column }) else { return }
        r.set(m, target)
    }

    func delete(_ object: AnyObject, in context: ModelContext) {
        if let m = object as? M { context.delete(m) }
    }

    func decode(_ json: [String: Any]) -> SyncPayload {
        var out: SyncPayload = [:]
        for f in fields {
            guard let raw = json[f.column], !(raw is NSNull) else { out[f.column] = .null; continue }
            switch f.kind {
            case .text: out[f.column] = .text(raw as? String ?? "\(raw)")
            case .int:
                if let n = raw as? NSNumber { out[f.column] = .int(n.intValue) } else { out[f.column] = .null }
            case .double:
                if let n = raw as? NSNumber { out[f.column] = .double(n.doubleValue) } else { out[f.column] = .null }
            case .bool:
                if let n = raw as? NSNumber { out[f.column] = .bool(n.boolValue) } else { out[f.column] = .null }
            case .date:
                if let s = raw as? String, let c = SyncTime.canonical(s) { out[f.column] = .date(c) } else { out[f.column] = .null }
            }
        }
        for r in refs {
            if let s = json[r.column] as? String, UUID(uuidString: s) != nil { out[r.column] = .text(s.lowercased()) } else { out[r.column] = .null }
        }
        return out
    }

    func encode(_ payload: SyncPayload) -> [String: Any] {
        var out: [String: Any] = [:]
        for c in columns {
            switch payload[c] ?? .null {
            case .null: out[c] = NSNull()
            case .text(let s): out[c] = s
            case .int(let i): out[c] = i
            case .double(let d): out[c] = d.isFinite ? d : 0
            case .bool(let b): out[c] = b
            case .date(let s): out[c] = s
            }
        }
        return out
    }
}

// MARK: - État de synchronisation

/// Ce que l'appareil sait d'une ligne : quand elle a changé, et dans quel état
/// le serveur l'a.
struct SyncMeta: Codable, Equatable {
    /// Heure de la dernière modification (texte canonique : se compare comme une chaîne).
    var updatedAt: String
    /// Empreinte du contenu local lors de la dernière détection de changement.
    var seen: String?
    /// Empreinte du contenu que le serveur détient (nil : jamais envoyé).
    var synced: String?
    /// Présent : la ligne est supprimée (pierre tombale).
    var deletedAt: String?
    /// Pierre tombale connue du serveur ?
    var tombstoneSynced: Bool = false
    /// Relations lues du serveur dont la cible n'est pas encore arrivée (colonne → id).
    var pending: [String: String]?

    var isTombstone: Bool { deletedAt != nil }
    var isDirty: Bool { isTombstone ? !tombstoneSynced : seen != synced }
}

struct SyncState: Codable, Equatable {
    var userID: String?
    /// Curseur par table : le plus grand `server_updated_at` lu, tel que le serveur l'a écrit.
    var cursors: [String: String] = [:]
    var rows: [String: [String: SyncMeta]] = [:]
    var lastSyncAt: Date?
}

/// Le fichier d'état, propre à l'appareil (jamais dans iCloud : chaque appareil a son propre curseur).
final class SyncStateStore {
    private let url: URL?
    var state: SyncState
    private var changed = false

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = decoded
        } else {
            state = SyncState()
        }
    }

    static var defaultURL: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Polymestre", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("supabase-sync-state.json")
    }

    func markChanged() { changed = true }

    func save() {
        guard changed, let url else { return }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
            changed = false
        }
    }

    func reset(userID: String?) {
        state = SyncState(userID: userID)
        changed = true
        save()
    }
}

// MARK: - Transport

protocol SyncTransport: AnyObject {
    /// Upsert ; renvoie les lignes telles que le serveur les a gardées.
    func push(table: String, rows: [[String: Any]]) async throws -> [[String: Any]]
    /// Lignes strictement après (since, afterID), triées par (server_updated_at, id).
    func pull(table: String, since: String?, afterID: String?, limit: Int) async throws -> [[String: Any]]
}

/// Empêche le contrôleur de prendre pour une modification de l'utilisateur les
/// enregistrements que la synchronisation fait elle-même.
final class SyncSaveGate: @unchecked Sendable {
    static let shared = SyncSaveGate()
    private let lock = NSLock()
    private var depth = 0
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return depth > 0 }
    func perform<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); depth += 1; lock.unlock()
        defer { lock.lock(); depth -= 1; lock.unlock() }
        return try body()
    }
}

/// Empreinte stable d'un contenu (SHA-256 tronqué) : `hashValue` change à chaque lancement.
enum SyncHash {
    static func of(_ payload: SyncPayload, columns: [String]) -> String {
        var text = ""
        for c in columns {
            text += c
            text += "="
            text += (payload[c] ?? .null).canonical
            text += "|"
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
