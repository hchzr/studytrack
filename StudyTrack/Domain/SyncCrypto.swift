import Foundation
import CryptoKit

/// Le chiffrement de bout en bout de la synchronisation, **pur** : aucune clé n'est
/// rangée ici (c'est `SyncKeyStore`), aucun réseau. Le pendant octet pour octet de
/// `windows/src/domain/syncCrypto.ts` (WebCrypto) ; `supabase/e2ee-vectors.json` est
/// lu par les deux suites de tests. Voir docs/sync-e2ee.md.
///
///   • `AK`, la clé du compte : 32 octets aléatoires, jamais envoyés au serveur ;
///   • `dataKey` et `keyId` en sont dérivés par HKDF-SHA256 (sel vide) ;
///   • une ligne = AES-256-GCM(dataKey, nonce aléatoire de 12 octets, JSON des champs,
///     AAD « <table>/<id>/v1 »), rangée nonce ‖ chiffré ‖ étiquette ;
///   • l'appairage : X25519 éphémère + un secret court `S` (le code), mêlés par HKDF.
enum SyncCrypto {

    enum Failure: Error, Equatable {
        case malformed
        case wrongKey
    }

    enum RecoveryFailure: Error, Equatable {
        case format
        case checksum
    }

    static let infoDataKey = "studytrack/sync/data/v1"
    static let infoKeyID = "studytrack/sync/key-id/v1"
    static let infoPairChannel = "studytrack/pair/channel/v1"
    static let infoPairKey = "studytrack/pair/key/v1"
    static let aadPairAK = "studytrack/pair/ak/v1"
    static let aadPairOK = "studytrack/pair/ok/v1"
    private static let recoveryChecksumTag = "studytrack/recovery/v1"

    // MARK: Octets

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func data(hex text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    /// HKDF-SHA256, sel vide (RFC 5869 : HashLen zéros).
    static func hkdf(_ ikm: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(), info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func hkdf(_ ikm: Data, info: String, length: Int) -> Data { hkdf(ikm, info: Data(info.utf8), length: length) }

    // MARK: Clé du compte

    static func newAccountKey() -> Data { randomBytes(32) }

    struct Keys: Equatable {
        let dataKey: Data
        let keyID: String
    }

    static func keys(for accountKey: Data) throws -> Keys {
        guard accountKey.count == 32 else { throw Failure.malformed }
        return Keys(dataKey: hkdf(accountKey, info: infoDataKey, length: 32),
                    keyID: hex(hkdf(accountKey, info: infoKeyID, length: 16)))
    }

    // MARK: AES-GCM (nonce ‖ chiffré ‖ étiquette)

    /// `nonce` : pour les vecteurs de test seulement ; en usage réel, aléatoire.
    static func gcmSeal(_ plain: Data, key: Data, aad: Data, nonce: Data? = nil) throws -> Data {
        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: n, authenticating: aad)
        guard let combined = box.combined else { throw Failure.malformed }
        return combined
    }

    static func gcmOpen(_ combined: Data, key: Data, aad: Data) throws -> Data {
        guard combined.count >= 28, let box = try? AES.GCM.SealedBox(combined: combined) else { throw Failure.malformed }
        guard let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad) else { throw Failure.wrongKey }
        return plain
    }

    // MARK: Lignes

    /// Les données associées : une ligne ne se recolle pas dans un autre id ni une autre table.
    static func rowAAD(table: String, id: String) -> Data { Data("\(table)/\(id.lowercased())/v1".utf8) }

    /// JSON compact, clés triées, échappements de `JSON.stringify` : le même texte que Windows
    /// pour des valeurs simples. Les valeurs sont celles de `SyncTable.encode` (nil/NSNull, texte,
    /// entier, réel, booléen). Seul le chiffrement doit coïncider octet pour octet ; le JSON, lui,
    /// se relit partout.
    static func canonicalJSON(_ fields: [String: Any]) -> String {
        var out = "{"
        for (index, key) in fields.keys.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }).enumerated() {
            if index > 0 { out += "," }
            out += jsonString(key) + ":" + jsonValue(fields[key] ?? NSNull())
        }
        return out + "}"
    }

    private static func jsonValue(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let b as Bool: return b ? "true" : "false"
        case let s as String: return jsonString(s)
        case let i as Int: return String(i)
        case let d as Double:
            guard d.isFinite else { return "0" }
            if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) } // JS écrit 4 pour 4.0
            return "\(d)"
        default: return "null"
        }
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func sealRow(dataKey: Data, table: String, id: String, fields: [String: Any], nonce: Data? = nil) throws -> Data {
        try gcmSeal(Data(canonicalJSON(fields).utf8), key: dataKey, aad: rowAAD(table: table, id: id), nonce: nonce)
    }

    static func openRow(dataKey: Data, table: String, id: String, box: Data) throws -> [String: Any] {
        let plain = try gcmOpen(box, key: dataKey, aad: rowAAD(table: table, id: id))
        guard let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw Failure.malformed }
        return object
    }

    /// `bytea` sur PostgREST : « \x » puis de l'hexadécimal.
    static func bytea(_ data: Data) -> String { "\\x" + hex(data) }

    static func data(fromBytea text: Any?) -> Data? {
        guard let text = text as? String, text.hasPrefix("\\x") else { return nil }
        return data(hex: String(text.dropFirst(2)))
    }

    // MARK: Base32 de Crockford

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Les bits en tête-bêche : le dernier symbole est complété de zéros.
    static func crockfordEncode(_ bytes: Data) -> String {
        var out = ""
        var acc = 0, bits = 0
        for b in bytes {
            acc = (acc << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(acc >> (bits - 5)) & 31])
                bits -= 5
            }
            acc &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
        return out
    }

    /// Minuscules, tirets, espaces tolérés, et les confusions O→0, I/L→1.
    private static func normalized(_ text: String) -> String {
        String(text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
            .map { $0 == "O" ? "0" : ($0 == "I" || $0 == "L" ? "1" : $0) })
    }

    /// `nil` si invalide ou si les bits de remplissage ne sont pas nuls.
    static func crockfordDecode(_ text: String, byteLength: Int) -> Data? {
        let clean = normalized(text)
        guard clean.count == (byteLength * 8 + 4) / 5 else { return nil }
        var out = Data()
        var acc = 0, bits = 0
        for ch in clean {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            acc = (acc << 5) | v
            bits += 5
            if bits >= 8 {
                guard out.count < byteLength else { return nil }
                out.append(UInt8((acc >> (bits - 8)) & 255))
                bits -= 8
            }
            acc &= (1 << bits) - 1
        }
        return acc == 0 && out.count == byteLength ? out : nil
    }

    private static func grouped(_ text: String) -> String {
        var out = ""
        for (i, ch) in text.enumerated() {
            if i > 0, i % 4 == 0 { out += "-" }
            out.append(ch)
        }
        return out
    }

    // MARK: Code d'appairage (S, 16 octets → 26 caractères)

    static let pairingCodeBytes = 16
    static func newPairingSecret() -> Data { randomBytes(pairingCodeBytes) }
    static func encodePairingCode(_ secret: Data) -> String { grouped(crockfordEncode(secret)) }
    static func decodePairingCode(_ text: String) -> Data? { crockfordDecode(text, byteLength: pairingCodeBytes) }
    static func pairingQRText(_ secret: Data) -> String { "studytrack-pair:" + encodePairingCode(secret) }

    /// Le texte d'un QR (« studytrack-pair:… ») ou un code nu.
    static func parsePairingInput(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "studytrack-pair:"
        let body = trimmed.lowercased().hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
        return decodePairingCode(body)
    }

    // MARK: Clé de secours (AK, 32 octets → 52 caractères + 2 de contrôle)

    /// Deux symboles (10 bits) : les 10 premiers bits de SHA-256(« studytrack/recovery/v1 » ‖ AK).
    private static func recoveryChecksum(_ accountKey: Data) -> String {
        let d = Array(SHA256.hash(data: Data(recoveryChecksumTag.utf8) + accountKey))
        let v = ((Int(d[0]) << 8) | Int(d[1])) >> 6
        return String([alphabet[v >> 5], alphabet[v & 31]])
    }

    static func encodeRecoveryKey(_ accountKey: Data) -> String {
        grouped(crockfordEncode(accountKey) + recoveryChecksum(accountKey))
    }

    static func decodeRecoveryKey(_ text: String) throws -> Data {
        let clean = normalized(text)
        guard clean.count == 54, let ak = crockfordDecode(String(clean.prefix(52)), byteLength: 32) else { throw RecoveryFailure.format }
        guard String(clean.suffix(2)) == recoveryChecksum(ak) else { throw RecoveryFailure.checksum }
        return ak
    }

    // MARK: Appairage

    struct Ephemeral {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        var publicKey: Data { privateKey.publicKey.rawRepresentation }

        init(privateKey raw: Data? = nil) throws {
            privateKey = try raw.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) } ?? Curve25519.KeyAgreement.PrivateKey()
        }
    }

    /// « pair-<32 hex> » : le nom du canal du relais, déduit du secret.
    static func pairChannel(_ secret: Data) -> String { "pair-" + hex(hkdf(secret, info: infoPairChannel, length: 16)) }

    /// k = HKDF(ECDH(moi, lui) ‖ S, « studytrack/pair/key/v1 » ‖ pubA ‖ pubB, 32).
    /// Le secret court `S` entre dans la clé : voir les deux clés publiques ne suffit pas.
    static func pairKey(mine: Ephemeral, theirPublic: Data, secret: Data, pubA: Data, pubB: Data) throws -> Data {
        guard let their = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublic),
              let shared = try? mine.privateKey.sharedSecretFromKeyAgreement(with: their) else { throw Failure.wrongKey }
        let ecdh = shared.withUnsafeBytes { Data($0) }
        return hkdf(ecdh + secret, info: Data(infoPairKey.utf8) + pubA + pubB, length: 32)
    }

    static func sealAccountKey(_ k: Data, accountKey: Data, nonce: Data? = nil) throws -> Data {
        try gcmSeal(accountKey, key: k, aad: Data(aadPairAK.utf8), nonce: nonce)
    }

    static func openAccountKey(_ k: Data, box: Data) throws -> Data {
        let ak = try gcmOpen(box, key: k, aad: Data(aadPairAK.utf8))
        guard ak.count == 32 else { throw Failure.malformed }
        return ak
    }

    static func sealOK(_ k: Data, nonce: Data? = nil) throws -> Data {
        try gcmSeal(Data("ok".utf8), key: k, aad: Data(aadPairOK.utf8), nonce: nonce)
    }

    static func openOK(_ k: Data, box: Data) -> Bool {
        (try? gcmOpen(box, key: k, aad: Data(aadPairOK.utf8))).map { String(decoding: $0, as: UTF8.self) == "ok" } ?? false
    }
}
