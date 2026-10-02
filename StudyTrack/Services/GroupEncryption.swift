import Foundation
import CryptoKit

/// La clé de chaque groupe : la publier, la créer, la recevoir, la transmettre.
///
/// Le protocole est dans `GroupCrypto` (pur, testé) ; les secrets dans
/// `GroupKeyStore` (trousseau). Ici, l'enchaînement avec le serveur :
///
///   1. ma clé **publique** est publiée (`member_keys`) — c'est elle qu'un
///      autre membre utilisera pour me sceller la clé du groupe ;
///   2. le groupe a-t-il une clé (`group_key_epochs`) ?
///        • non → je la crée et je la déclare ; la clé primaire du serveur
///          départage deux membres qui le feraient au même instant ;
///        • oui, et je l'ai → rien à faire ;
///        • oui, et je ne l'ai pas → j'ouvre l'enveloppe qu'un membre m'a
///          laissée (`group_key_shares`), s'il l'a déjà fait ;
///   3. si je l'ai, je scelle pour chaque membre qui n'en a pas encore.
///
/// L'étape 3 est ce qui fait marcher « rejoindre avec un code » : le nouveau
/// membre publie sa clé publique, rejoint, et le premier membre qui a l'app
/// ouverte (prévenu en temps réel par l'adhésion) la lui scelle.
@MainActor
final class GroupEncryption {

    /// La clé en vigueur d'un groupe, connue de cet appareil.
    struct ActiveKey {
        let id: String
        let key: SymmetricKey
    }

    enum State: Equatable {
        /// La clé est là : lire et écrire chiffré.
        case ready
        /// Le groupe a une clé, mais aucun membre ne me l'a encore transmise.
        case waitingForKey
        /// Le serveur ne connaît pas encore le chiffrement (migration absente).
        case unavailable
    }

    private var keys: [String: ActiveKey] = [:]
    private var publishedFor: String?
    /// Dernière distribution par groupe : ne pas relire trois tables à chaque
    /// message reçu. Un événement d'adhésion la force.
    private var lastDistribution: [String: Date] = [:]

    func activeKey(groupID: String) -> ActiveKey? { keys[groupID.lowercased()] }

    /// Oublie tout ce qui est en mémoire (déconnexion, changement de compte).
    /// Le trousseau, lui, garde les clés : elles sont liées au compte.
    func reset() {
        keys = [:]
        publishedFor = nil
        lastDistribution = [:]
    }

    // MARK: Identité

    /// Publie ma clé publique, une fois par lancement et par compte.
    func publishIdentity(client: SupabaseClient) async throws {
        guard let userID = client.userID else { throw SupabaseError.notSignedIn }
        guard publishedFor != userID else { return }
        let identity = GroupKeyStore.identity(for: userID)
        _ = try await client.upsert("member_keys",
                                    rows: [["user_id": userID,
                                            "public_key": GroupCrypto.publicKeyString(identity.publicKey)]],
                                    onConflict: "user_id,public_key",
                                    returning: false)
        publishedFor = userID
    }

    // MARK: Clé du groupe

    /// Rend le groupe prêt à chiffrer, autant que possible maintenant.
    @discardableResult
    func prepare(groupID rawGroupID: String, client: SupabaseClient, forceDistribution: Bool = false) async -> State {
        let groupID = rawGroupID.lowercased()
        guard let userID = client.userID else { return .waitingForKey }
        do {
            try await publishIdentity(client: client)
            let identity = GroupKeyStore.identity(for: userID)

            var epoch = try await fetchEpoch(groupID: groupID, client: client)
            if epoch == nil {
                // Aucun membre n'a encore créé de clé : je la crée. Si un autre
                // a été plus rapide, l'insertion est ignorée et je relis la sienne.
                let fresh = GroupCrypto.newGroupKey()
                let freshID = GroupCrypto.keyID(of: fresh)
                GroupKeyStore.saveGroupKey(fresh, groupID: groupID)
                _ = try await client.request("/rest/v1/group_key_epochs",
                                             method: "POST",
                                             query: [URLQueryItem(name: "on_conflict", value: "group_id")],
                                             body: try JSONSerialization.data(withJSONObject: [
                                                ["group_id": groupID, "key_id": freshID, "created_by": userID]
                                             ]),
                                             prefer: "resolution=ignore-duplicates,return=minimal")
                epoch = try await fetchEpoch(groupID: groupID, client: client)
            }
            guard let keyID = epoch else { return .waitingForKey }

            if keys[groupID]?.id != keyID {
                if let stored = GroupKeyStore.groupKey(groupID: groupID, keyID: keyID) {
                    keys[groupID] = ActiveKey(id: keyID, key: stored)
                } else if let received = try await openShare(groupID: groupID, keyID: keyID,
                                                             identity: identity, client: client) {
                    GroupKeyStore.saveGroupKey(received, groupID: groupID)
                    keys[groupID] = ActiveKey(id: keyID, key: received)
                }
            }
            guard let active = keys[groupID] else { return .waitingForKey }

            let recent = lastDistribution[groupID].map { Date().timeIntervalSince($0) < 120 } ?? false
            if forceDistribution || !recent {
                try await distribute(active, groupID: groupID, identity: identity, client: client)
                lastDistribution[groupID] = Date()
            }
            return .ready
        } catch {
            if case SupabaseError.server(let status, let message) = error,
               status == 404 || message.contains("PGRST205") || message.contains("42P01") {
                return .unavailable
            }
            AppLog.record(.warning, AppLog.Category.sync, "Chiffrement du groupe incomplet",
                          detail: GroupSync.explain(error))
            return keys[groupID] == nil ? .waitingForKey : .ready
        }
    }

    private func fetchEpoch(groupID: String, client: SupabaseClient) async throws -> String? {
        let data = try await client.select("group_key_epochs",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "select", value: "key_id")])
        guard let data,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.first?["key_id"] as? String
    }

    /// L'enveloppe qu'un membre m'a laissée pour la clé `keyID`, ouverte.
    ///
    /// Une enveloppe dont le contenu n'a pas l'empreinte attendue est écartée :
    /// un membre ne peut pas me faire adopter une autre clé que celle du groupe.
    private func openShare(groupID: String,
                           keyID: String,
                           identity: Curve25519.KeyAgreement.PrivateKey,
                           client: SupabaseClient) async throws -> SymmetricKey? {
        let mine = GroupCrypto.publicKeyString(identity.publicKey)
        let data = try await client.select("group_key_shares",
                                           query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                   URLQueryItem(name: "key_id", value: "eq.\(keyID)"),
                                                   URLQueryItem(name: "recipient_key", value: "eq.\(mine)"),
                                                   URLQueryItem(name: "select", value: "sender_key,sealed")])
        guard let data,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for row in rows {
            guard let senderText = row["sender_key"] as? String,
                  let sealed = row["sealed"] as? String,
                  let sender = GroupCrypto.publicKey(from: senderText),
                  let key = try? GroupCrypto.unwrap(sealed, with: identity, from: sender, groupID: groupID),
                  GroupCrypto.keyID(of: key) == keyID else { continue }
            return key
        }
        return nil
    }

    /// Scelle la clé pour chaque clé publique de membre qui ne l'a pas encore.
    private func distribute(_ active: ActiveKey,
                            groupID: String,
                            identity: Curve25519.KeyAgreement.PrivateKey,
                            client: SupabaseClient) async throws {
        guard let userID = client.userID else { return }
        let membersData = try await client.select("group_members",
                                                  query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                          URLQueryItem(name: "select", value: "user_id")])
        let members = Set(((membersData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? [])
            .compactMap { ($0["user_id"] as? String)?.lowercased() })
        guard !members.isEmpty else { return }

        let keysData = try await client.select("member_keys",
                                               query: [URLQueryItem(name: "user_id",
                                                                    value: "in.(\(members.sorted().joined(separator: ",")))"),
                                                       URLQueryItem(name: "select", value: "user_id,public_key")])
        let published = ((keysData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? [])
            .compactMap { row -> (userID: String, key: String)? in
                guard let user = row["user_id"] as? String, let key = row["public_key"] as? String else { return nil }
                return (user.lowercased(), key)
            }

        let servedData = try await client.select("group_key_shares",
                                                 query: [URLQueryItem(name: "group_id", value: "eq.\(groupID)"),
                                                         URLQueryItem(name: "key_id", value: "eq.\(active.id)"),
                                                         URLQueryItem(name: "select", value: "recipient_key")])
        let served = Set(((servedData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? [])
            .compactMap { $0["recipient_key"] as? String })

        let missing = GroupCrypto.missingRecipients(memberIDs: members, publicKeys: published, servedKeys: served)
        guard !missing.isEmpty else { return }

        let senderKey = GroupCrypto.publicKeyString(identity.publicKey)
        let rows: [[String: Any]] = missing.compactMap { entry in
            guard let recipient = GroupCrypto.publicKey(from: entry.key),
                  let sealed = try? GroupCrypto.wrap(active.key, from: identity, to: recipient, groupID: groupID) else {
                return nil
            }
            return ["group_id": groupID, "key_id": active.id,
                    "recipient_id": entry.userID, "recipient_key": entry.key,
                    "sender_id": userID, "sender_key": senderKey, "sealed": sealed]
        }
        guard !rows.isEmpty else { return }
        _ = try await client.request("/rest/v1/group_key_shares",
                                     method: "POST",
                                     query: [URLQueryItem(name: "on_conflict", value: "group_id,key_id,recipient_key")],
                                     body: try JSONSerialization.data(withJSONObject: rows),
                                     prefer: "resolution=ignore-duplicates,return=minimal")
    }
}
