import Foundation
import CryptoKit

/// Le chiffrement de bout en bout de l'entraide d'un groupe, **pur** : aucune
/// clé n'est lue ni rangée ici (c'est `GroupKeyStore`), aucun réseau (c'est
/// `SocialService`). Ce qui reste est ce qui doit être juste — et se teste dans
/// `validate.sh`.
///
/// Le schéma :
///   • une **clé de groupe** symétrique (AES-256) chiffre les messages ;
///   • chaque appareil a une **identité** Curve25519 ; sa clé publique est sur
///     le serveur (`member_keys`), la privée ne quitte pas le trousseau ;
///   • pour donner la clé du groupe à un membre, on la **scelle** avec le secret
///     partagé ECDH(ma privée, sa publique), dérivé par HKDF et lié au groupe.
///     Le serveur ne voit que des clés publiques et des enveloppes.
///
/// Limite assumée : le serveur distribue les clés publiques. Un serveur
/// malveillant pourrait substituer la sienne à celle d'un nouveau membre — la
/// protection vaut contre une fuite de la base, pas contre Supabase lui-même.
enum GroupCrypto {

    enum CryptoError: Error, Equatable {
        case malformed
        case wrongKey
    }

    /// Préfixe des messages chiffrés : une version, pour pouvoir changer
    /// d'algorithme sans casser la lecture des anciens.
    static let messagePrefix = "v1:"

    // MARK: Clé de groupe

    static func newGroupKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// L'identifiant public d'une clé : les huit premiers octets de son
    /// empreinte. Permet de savoir **quelle** clé a chiffré un message sans
    /// rien révéler de la clé.
    static func keyID(of key: SymmetricKey) -> String {
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) } + Data("studytrack-key-id".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    static func decodeKey(_ text: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    // MARK: Messages

    /// Les données associées : un message chiffré pour un groupe ne se recolle
    /// pas dans un autre, ni sous le nom d'un autre auteur.
    private static func context(groupID: String, authorID: String) -> Data {
        Data("studytrack-post|\(groupID.lowercased())|\(authorID.lowercased())".utf8)
    }

    static func seal(_ text: String, key: SymmetricKey, groupID: String, authorID: String) throws -> String {
        let box = try AES.GCM.seal(Data(text.utf8), using: key,
                                   authenticating: context(groupID: groupID, authorID: authorID))
        guard let combined = box.combined else { throw CryptoError.malformed }
        return messagePrefix + combined.base64EncodedString()
    }

    static func open(_ sealed: String, key: SymmetricKey, groupID: String, authorID: String) throws -> String {
        guard sealed.hasPrefix(messagePrefix),
              let data = Data(base64Encoded: String(sealed.dropFirst(messagePrefix.count))),
              let box = try? AES.GCM.SealedBox(combined: data) else { throw CryptoError.malformed }
        guard let plain = try? AES.GCM.open(box, using: key,
                                            authenticating: context(groupID: groupID, authorID: authorID)),
              let text = String(data: plain, encoding: .utf8) else { throw CryptoError.wrongKey }
        return text
    }

    // MARK: Enveloppes (clé de groupe scellée pour un membre)

    static func publicKeyString(_ key: Curve25519.KeyAgreement.PublicKey) -> String {
        key.rawRepresentation.base64EncodedString()
    }

    static func publicKey(from text: String) -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = Data(base64Encoded: text) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    /// La clé d'enveloppe entre deux identités, pour **ce** groupe : la même
    /// des deux côtés (ECDH est symétrique), différente pour chaque groupe.
    private static func wrappingKey(mine: Curve25519.KeyAgreement.PrivateKey,
                                    theirs: Curve25519.KeyAgreement.PublicKey,
                                    groupID: String) throws -> SymmetricKey {
        let secret = try mine.sharedSecretFromKeyAgreement(with: theirs)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: Data(groupID.lowercased().utf8),
                                              sharedInfo: Data("studytrack-group-key-v1".utf8),
                                              outputByteCount: 32)
    }

    static func wrap(_ groupKey: SymmetricKey,
                     from sender: Curve25519.KeyAgreement.PrivateKey,
                     to recipient: Curve25519.KeyAgreement.PublicKey,
                     groupID: String) throws -> String {
        let wrapping = try wrappingKey(mine: sender, theirs: recipient, groupID: groupID)
        let box = try AES.GCM.seal(groupKey.withUnsafeBytes { Data($0) }, using: wrapping)
        guard let combined = box.combined else { throw CryptoError.malformed }
        return combined.base64EncodedString()
    }

    static func unwrap(_ sealed: String,
                       with recipient: Curve25519.KeyAgreement.PrivateKey,
                       from sender: Curve25519.KeyAgreement.PublicKey,
                       groupID: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: data) else { throw CryptoError.malformed }
        let wrapping = try wrappingKey(mine: recipient, theirs: sender, groupID: groupID)
        guard let raw = try? AES.GCM.open(box, using: wrapping), raw.count == 32 else {
            throw CryptoError.wrongKey
        }
        return SymmetricKey(data: raw)
    }

    // MARK: Distribution

    /// Les clés publiques de membres à qui il manque une enveloppe pour la clé
    /// `keyID` — ce qu'un membre qui détient la clé doit sceller.
    ///
    /// Pur, pour être testé : un membre sans clé publique n'est pas servi (il
    /// n'a pas encore ouvert l'app), une clé déjà servie ne l'est pas deux fois,
    /// et un ancien membre n'est jamais servi.
    static func missingRecipients(memberIDs: Set<String>,
                                  publicKeys: [(userID: String, key: String)],
                                  servedKeys: Set<String>) -> [(userID: String, key: String)] {
        var seen = Set<String>()
        return publicKeys.filter { entry in
            memberIDs.contains(entry.userID)
                && !servedKeys.contains(entry.key)
                && seen.insert(entry.key).inserted
        }
    }
}
